#!/usr/bin/python3 -I
"""Fix a QEMU screenshot of a screen whose width is not a multiple of 8.

QEMU saves such a screen (for example 1366x768) 1360 pixels wide, while
the frame buffer has rows of 1366 pixels, so the picture is skewed. This
reads the pixels again with the right row width. The last few rows are
lost. Usage: unskew.py IN.png OUT.png WIDTH
"""
import sys

from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
width = int(sys.argv[3])
if img.width == width:
    # Fixed already.
    if sys.argv[1] != sys.argv[2]:
        img.save(sys.argv[2])
    sys.exit(0)
data = img.tobytes()
rows = len(data) // (3 * width)
Image.frombytes("RGB", (width, rows), data[:rows * width * 3]).save(sys.argv[2])
