#!/bin/zsh
# Headless renders of the app's views into renders/, then side-by-side comparisons with the prototype's reference
# shots (refs/) into renders/compare/ (prototype left, app right). Never launches the app or shows a window.
#   zsh scripts/render-all.sh            every render suite (ARenders, BRenders, CRenders, DRenders)
#   zsh scripts/render-all.sh DRenders   one stream's suite (any `swift test --filter` pattern)
#   RENDER_DIR=renders/final zsh scripts/render-all.sh   write the renders (and compare/) under another folder
# Streams extend this by adding tests to their own Tests/JuiceIslandUITests/Renders/<X>Renders.swift; a render named
# like a reference shot (refs/<name>.png) gets a comparison automatically.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
filter=${1:-Renders}
out=${RENDER_DIR:-renders}
mkdir -p "$out/compare"
JI_RENDER_DIR="$root/$out" swift test --filter "$filter" 2>&1 | grep -E "error:|✘|Test run|passed|failed" | grep -v "^$" | tail -40
python3 - "$root" "$out" <<'PY'
import os, sys
from PIL import Image, ImageDraw
root, rel = sys.argv[1], sys.argv[2]
renders, refs, out = (os.path.join(root, d) for d in (rel, "refs", os.path.join(rel, "compare")))
pairs = 0
for name in sorted(os.listdir(renders)):
    if not name.endswith(".png"): continue
    ref_path = os.path.join(refs, name)
    if not os.path.exists(ref_path): continue
    a, b = Image.open(ref_path).convert("RGB"), Image.open(os.path.join(renders, name)).convert("RGB")
    gap, label = 24, 36
    sheet = Image.new("RGB", (a.width + b.width + gap, max(a.height, b.height) + label), (40, 40, 44))
    sheet.paste(a, (0, label)); sheet.paste(b, (a.width + gap, label))
    d = ImageDraw.Draw(sheet)
    d.text((8, 10), f"prototype  {name}  {a.width//2}x{a.height//2}pt", fill=(220, 220, 220))
    d.text((a.width + gap + 8, 10), f"app  {b.width//2}x{b.height//2}pt", fill=(220, 220, 220))
    sheet.save(os.path.join(out, name)); pairs += 1
print(f"renders: {len([n for n in os.listdir(renders) if n.endswith('.png')])} · comparisons: {pairs} in {rel}/compare/")
PY
python3 scripts/compare-c-cards.py "$out"
