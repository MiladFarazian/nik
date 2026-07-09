#!/usr/bin/env python3
"""
generate_previews.py

Renders a real preview MP4 for every template in catalog/catalog.json, showing
each template's actual pacing, cuts, transitions and text layers.

Because this ffmpeg build has NO drawtext filter, all text is rendered with PIL
onto transparent PNGs and composited with ffmpeg's overlay filter. Backgrounds
are per-slot gradient PNGs (built from each template's previewColors) animated
with zoompan; cuts are visible because each slot varies angle / inversion /
brightness. Transitions:
  - cut       -> plain concat
  - crossfade -> xfade transition=fade duration~0.25
  - zoomIn    -> incoming slot starts at 1.10 zoom settling to 1.0
  - punchIn   -> incoming slot starts at 1.18 settling fast (~0.3s)

Output: previews/<template-id>.mp4  (540x960, 30fps, h264, no audio)

Idempotent: re-running overwrites everything. Usage:

    python3 scripts/generate_previews.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "catalog", "catalog.json")
OUT_DIR = os.path.join(ROOT, "previews")
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FFPROBE = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"

W, H = 540, 960          # output canvas
GW, GH = 1080, 1920      # gradient render size (2x -> crisp downscale via zoompan)
FPS = 30
MAX_DURATION = 15.0      # cap total duration
XFADE = 0.25             # nominal crossfade duration (seconds)

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]


def _find_font():
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    return None


FONT_PATH = _find_font()


# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
def hex_to_rgb(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# ---------------------------------------------------------------------------
# Gradient / background PNG generation
# ---------------------------------------------------------------------------
def make_gradient_png(c1, c2, idx, path):
    """Diagonal gradient between two colors, varied per slot index so cuts read
    as different shots: rotate the gradient angle, alternately invert the color
    order, apply a slot-varied brightness offset, and add a soft vignette."""
    a = np.array(hex_to_rgb(c1), dtype=np.float32)
    b = np.array(hex_to_rgb(c2), dtype=np.float32)
    if idx % 2 == 1:
        a, b = b, a  # alternate direction so adjacent slots differ

    # Angle rotates with slot index; gives each shot a distinct light direction.
    angle = np.deg2rad(35 + (idx * 47) % 130)
    ca, sa = np.cos(angle), np.sin(angle)

    yy, xx = np.mgrid[0:GH, 0:GW].astype(np.float32)
    xn = xx / (GW - 1)
    yn = yy / (GH - 1)
    proj = xn * ca + yn * sa
    proj = (proj - proj.min()) / (proj.max() - proj.min())
    t = proj[..., None]

    grad = a * (1.0 - t) + b * t  # HxWx3

    # Slot-varied brightness so shots read as distinct exposures.
    bright = 1.0 + (((idx % 3) - 1) * 0.10)
    grad *= bright

    # Soft radial vignette.
    cx, cy = GW / 2.0, GH / 2.0
    r = np.sqrt(((xx - cx) / cx) ** 2 + ((yy - cy) / cy) ** 2)
    vig = np.clip(1.0 - 0.35 * np.clip(r - 0.25, 0, None), 0.45, 1.0)
    grad *= vig[..., None]

    grad = np.clip(grad, 0, 255).astype(np.uint8)
    Image.fromarray(grad).save(path)


# ---------------------------------------------------------------------------
# zoompan expression per slot (bakes in zoomIn / punchIn entrances + speed)
# ---------------------------------------------------------------------------
def zoompan_filter(slot, idx, nframes):
    """Return a zoompan filter string for a single slot's animated background."""
    transition = slot.get("transition", "cut")
    speed = float(slot.get("speed", 1.0) or 1.0)
    maxf = max(nframes - 1, 1)
    cx = "iw/2-(iw/zoom/2)"
    cy = "ih/2-(ih/zoom/2)"

    if transition == "zoomIn":
        # start at 1.10, settle to 1.0 across the whole slot
        z = f"1.10-0.10*min(1,on*{speed:.3f}/{maxf})"
        x, y = cx, cy
    elif transition == "punchIn":
        # start at 1.18, hard settle over ~0.3s (9 frames), then hold
        pf = max(min(9, nframes - 1), 1)
        z = f"if(lt(on,{pf}),1.18-0.18*on/{pf},1.0)"
        x, y = cx, cy
    else:
        kind = idx % 3
        if kind == 0:
            # slow diagonal pan at a mild constant zoom
            z = "1.08"
            x = f"(iw-iw/zoom)*min(1,on*{speed:.3f}/{maxf})"
            y = cy
        elif kind == 1:
            # slow zoom in 1.0 -> 1.08
            z = f"1.0+0.08*min(1,on*{speed:.3f}/{maxf})"
            x, y = cx, cy
        else:
            # drifting zoom with a vertical pan
            z = f"1.0+0.05*min(1,on*{speed:.3f}/{maxf})"
            x = cx
            y = f"(ih-ih/zoom)*min(1,on*{speed:.3f}/{maxf})"

    return (
        f"zoompan=z='{z}':x='{x}':y='{y}':d=1:s={W}x{H}:fps={FPS},"
        f"setsar=1,format=yuv420p,settb=1/{FPS}"
    )


# ---------------------------------------------------------------------------
# Text layer PNG generation (2x oversample, per-style rendering)
# ---------------------------------------------------------------------------
def make_text_png(layer, path):
    """Render a text layer to a transparent RGBA PNG at 2x for crispness.

    Returns (width, height) of the PNG in *composite* pixels (i.e. half the PNG
    size), used to position the overlay centered at y = H * relativeY.
    """
    text = layer["text"]
    style = layer.get("style", "bold")
    # fontSize is authored against a 1080-wide canvas; scale to 540 then 2x.
    px_font = max(int(round(layer["fontSize"] * (W / 1080.0) * 2)), 12)

    if FONT_PATH:
        font = ImageFont.truetype(FONT_PATH, px_font)
    else:
        font = ImageFont.load_default()

    # Measure text.
    tmp = Image.new("RGBA", (10, 10))
    d = ImageDraw.Draw(tmp)
    stroke = 0
    if style == "outlined":
        stroke = max(px_font // 14, 2)
    elif style == "caption":
        stroke = max(px_font // 18, 2)

    bbox = d.textbbox((0, 0), text, font=font, stroke_width=stroke)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]

    pad = max(px_font // 2, 20)
    iw = tw + pad * 2
    ih = th + pad * 2
    img = Image.new("RGBA", (iw, ih), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    tx = pad - bbox[0]
    ty = pad - bbox[1]

    white = (255, 255, 255, 255)

    if style == "block":
        # White text on a rounded, 75%-alpha black rectangle.
        rx0, ry0 = pad // 2, pad // 2
        rx1, ry1 = iw - pad // 2, ih - pad // 2
        radius = max(px_font // 4, 12)
        draw.rounded_rectangle([rx0, ry0, rx1, ry1], radius=radius,
                               fill=(0, 0, 0, 191))
        draw.text((tx, ty), text, font=font, fill=white)
    elif style == "outlined":
        draw.text((tx, ty), text, font=font, fill=white,
                  stroke_width=stroke, stroke_fill=(0, 0, 0, 255))
    elif style == "caption":
        draw.text((tx, ty), text, font=font, fill=white,
                  stroke_width=stroke, stroke_fill=(0, 0, 0, 230))
    else:  # bold: heavy white with a soft black shadow
        for dx, dy in ((3, 3), (2, 2), (4, 4)):
            draw.text((tx + dx, ty + dy), text, font=font,
                      fill=(0, 0, 0, 130))
        draw.text((tx, ty), text, font=font, fill=white)

    img.save(path)
    # Composite size is half the oversampled PNG.
    return iw / 2.0, ih / 2.0


# ---------------------------------------------------------------------------
# Per-template render
# ---------------------------------------------------------------------------
def render_template(tpl, workdir):
    tid = tpl["id"]
    slots = tpl["slots"]
    colors = tpl.get("previewColors", ["#888888", "#222222"])
    c1, c2 = colors[0], colors[1]

    # Clamp slot durations so total <= MAX_DURATION.
    durations = [float(s["duration"]) for s in slots]
    total = sum(durations)
    if total > MAX_DURATION:
        scale = MAX_DURATION / total
        durations = [d * scale for d in durations]

    # --- inputs & per-slot background filters -----------------------------
    inputs = []          # ffmpeg -i args
    filt = []            # filter_complex parts
    seg_labels = []
    for i, slot in enumerate(slots):
        dur = durations[i]
        nframes = max(int(round(dur * FPS)), 1)
        gpath = os.path.join(workdir, f"{tid}_bg_{i}.png")
        make_gradient_png(c1, c2, i, gpath)
        inputs += ["-loop", "1", "-framerate", str(FPS), "-t", f"{dur:.4f}",
                   "-i", gpath]
        zp = zoompan_filter(slot, i, nframes)
        lbl = f"v{i}"
        filt.append(f"[{i}:v]{zp}[{lbl}]")
        seg_labels.append((lbl, dur, slot.get("transition", "cut")))

    n_slots = len(slots)

    # --- combine segments (concat for cut/zoomIn/punchIn, xfade for crossfade)
    prev_lbl = seg_labels[0][0]
    prev_dur = seg_labels[0][1]
    step = 0
    for i in range(1, n_slots):
        lbl, dur, transition = seg_labels[i]
        out = f"m{step}"
        if transition == "crossfade":
            d = min(XFADE, dur * 0.8, prev_dur * 0.8)
            offset = max(prev_dur - d, 0.0)
            filt.append(
                f"[{prev_lbl}][{lbl}]xfade=transition=fade:"
                f"duration={d:.4f}:offset={offset:.4f},settb=1/{FPS}[{out}]"
            )
            prev_dur = prev_dur + dur - d
        else:
            filt.append(
                f"[{prev_lbl}][{lbl}]concat=n=2:v=1:a=0,settb=1/{FPS}[{out}]")
            prev_dur = prev_dur + dur
        prev_lbl = out
        step += 1

    total_dur = prev_dur

    # --- text overlays -----------------------------------------------------
    text_inputs = []
    text_filt = []
    base_lbl = prev_lbl
    for j, layer in enumerate(tpl.get("textLayers", [])):
        tpath = os.path.join(workdir, f"{tid}_txt_{j}.png")
        cw, ch = make_text_png(layer, tpath)
        idx = n_slots + (len(text_inputs) // 6)  # ffmpeg input index for PNG
        text_inputs += ["-loop", "1", "-framerate", str(FPS),
                        "-t", f"{total_dur:.4f}", "-i", tpath]

        start = float(layer.get("start", 0.0))
        dur = float(layer.get("duration", 1.5))
        end = min(start + dur, total_dur)
        if start >= total_dur:
            continue
        cy = H * float(layer.get("relativeY", 0.5))
        # Scale the 2x PNG down to composite size, add a 0.15s alpha fade-in.
        pl = f"tp{j}"
        text_filt.append(
            f"[{idx}:v]scale=iw/2:ih/2,format=rgba,"
            f"fade=t=in:st={start:.3f}:d=0.15:alpha=1[{pl}]"
        )
        ox = f"(W-w)/2"
        oy = f"{cy:.1f}-h/2"
        out = f"o{j}"
        text_filt.append(
            f"[{base_lbl}][{pl}]overlay=x={ox}:y={oy}:"
            f"enable='between(t,{start:.3f},{end:.3f})'[{out}]"
        )
        base_lbl = out

    filt += text_filt
    inputs += text_inputs

    filter_complex = ";".join(filt)

    out_path = os.path.join(OUT_DIR, f"{tid}.mp4")
    cmd = [FFMPEG, "-y"] + inputs + [
        "-filter_complex", filter_complex,
        "-map", f"[{base_lbl}]",
        "-c:v", "libx264", "-crf", "27", "-preset", "veryfast",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        "-r", str(FPS), "-an",
        out_path,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(f"\n[FFMPEG ERROR] {tid}\n")
        sys.stderr.write(" ".join(cmd) + "\n")
        sys.stderr.write(proc.stderr[-4000:] + "\n")
        raise RuntimeError(f"ffmpeg failed for {tid}")

    return out_path, total_dur


# ---------------------------------------------------------------------------
# ffprobe helpers
# ---------------------------------------------------------------------------
def probe(path):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=codec_name:format=duration",
         "-of", "json", path],
        capture_output=True, text=True,
    )
    info = json.loads(out.stdout or "{}")
    codec = info.get("streams", [{}])[0].get("codec_name", "?")
    dur = float(info.get("format", {}).get("duration", 0.0))
    return codec, dur


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    with open(CATALOG) as f:
        catalog = json.load(f)
    templates = catalog["templates"]

    os.makedirs(OUT_DIR, exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="nikprev_")

    rows = []
    total_bytes = 0
    try:
        for tpl in templates:
            out_path, planned = render_template(tpl, workdir)
            codec, dur = probe(out_path)
            size = os.path.getsize(out_path)
            total_bytes += size
            rows.append((tpl["id"], dur, size / 1024.0, codec))
            print(f"{tpl['id']:<24} dur={dur:6.2f}s  "
                  f"size={size/1024.0:7.1f}KB  codec={codec}")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    print("-" * 60)
    print(f"{len(rows)} previews  total={total_bytes/1024.0:.1f}KB "
          f"({total_bytes/1024.0/1024.0:.2f}MB)")


if __name__ == "__main__":
    main()
