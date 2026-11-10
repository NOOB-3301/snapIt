#!/usr/bin/env python3
"""One-off: cut the single combined Gemini sheet into the per-state 2x2 sheets the app loads.

Sheets generated one state at a time (see gemini-prompts.md) need no slicing:
drop them straight into sprites/ as <state>.png.
Usage: python3 tools/slice_sheet.py <combined.png> sprites/
"""
import sys
from PIL import Image

CELL = 256
KEY = (255, 0, 255)
# Pose boxes (x0, y0, x1, y1) found by connected components on the combined sheet.
FRAMES = {
    "idle":     [(250, 8, 371, 168), (396, 14, 516, 168), (396, 180, 516, 339), (250, 176, 371, 339)],
    "thinking": [(540, 8, 668, 168), (703, 8, 835, 168), (540, 174, 673, 339), (703, 8, 835, 168)],
    "talking":  [(874, 11, 1004, 168), (703, 176, 835, 339), (874, 176, 1004, 339), (703, 176, 835, 339)],
    "happy":    [(19, 347, 141, 511), (188, 343, 320, 511), (19, 514, 150, 681), (191, 517, 319, 681)],
    "snap":     [(363, 343, 491, 511), (532, 343, 661, 511), (874, 343, 1003, 511), (706, 343, 837, 511)],
    "carry":    [(362, 518, 493, 681), (362, 518, 493, 681), (531, 518, 662, 681), (531, 518, 662, 681)],
    "tired":    [(706, 516, 837, 681), (706, 516, 837, 681), (874, 516, 1003, 681), (874, 516, 1003, 681)],
    "sleep":    [(19, 690, 135, 851), (185, 691, 302, 851), (19, 860, 162, 1020), (185, 860, 335, 1022)],
    "dragged":  [(365, 756, 512, 1008), (365, 756, 512, 1008), (526, 756, 674, 1006), (526, 756, 674, 1006)],
    "menubar":  [(690, 699, 846, 857), (860, 699, 1015, 857), (690, 865, 847, 1022), (859, 865, 1016, 1022)],
}

src = Image.open(sys.argv[1]).convert("RGB")
for state, boxes in FRAMES.items():
    sheet = Image.new("RGB", (CELL * 2, CELL * 2), KEY)
    for i, box in enumerate(boxes):
        frame = src.crop(box)
        assert frame.width <= CELL and frame.height <= CELL, (state, i, frame.size)
        x = (i % 2) * CELL + (CELL - frame.width) // 2      # centred
        y = (i // 2) * CELL + CELL - frame.height - 2        # feet on a shared baseline
        sheet.paste(frame, (x, y))
    sheet.save(f"{sys.argv[2].rstrip('/')}/{state}.png")
    print("wrote", state)
