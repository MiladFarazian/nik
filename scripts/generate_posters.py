#!/usr/bin/env python3
"""Extract a poster JPG per template preview, timed so the first text layer
(the hook) is visible — feed cards show the hook, matching what the pager plays.
Run after generate_previews.py:  python3 scripts/generate_posters.py
"""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
catalog = json.loads((ROOT / "catalog/catalog.json").read_text())

for template in catalog["templates"]:
    tid = template["id"]
    mp4 = ROOT / "previews" / f"{tid}.mp4"
    if not mp4.exists():
        print(f"skip {tid}: no preview")
        continue
    duration = sum(s["duration"] for s in template["slots"])
    layers = template.get("textLayers") or []
    if layers:
        first = min(layers, key=lambda l: l["start"])
        t = min(first["start"] + first["duration"] / 2, duration - 0.3)
    else:
        t = duration * 0.4
    out = ROOT / "previews" / f"{tid}-poster.jpg"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-ss", f"{t:.2f}", "-i", str(mp4),
         "-frames:v", "1", "-q:v", "4", str(out)],
        check=True,
    )
    print(f"{tid}-poster.jpg @ {t:.2f}s ({out.stat().st_size // 1024}KB)")
