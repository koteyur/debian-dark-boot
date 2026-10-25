#!/usr/bin/python3 -I
"""Check the checked-in GRUB fonts, including Cyrillic character coverage.

Run after src/make-assets.sh. install.sh copies these PF2 files as-is.
"""

from pathlib import Path
from struct import unpack_from

ROOT = Path(__file__).resolve().parent.parent
FONTS = (
    ROOT / "themes/grub/debian-dark/dejavu-sans-27.pf2",
    ROOT / "themes/grub/debian-dark/dejavu-sans-mono-17.pf2",
)
CYRILLIC = set(range(0x0400, 0x0460)) | {0x0490, 0x0491}
EXAMPLES = "Debian GNU/Linux"


def check_font(path):
    data = path.read_bytes()
    assert data.startswith(b"FILE\x00\x00\x00\x04PFF2"), f"{path}: invalid PF2 header"
    pos = 12
    index = {}
    while pos + 8 <= len(data):
        tag, length = unpack_from(">4sI", data, pos)
        start = pos + 8
        if tag == b"CHIX":
            assert length % 9 == 0 and start + length <= len(data)
            for off in range(start, start + length, 9):
                codepoint, flags, glyph = unpack_from(">IBI", data, off)
                assert flags == 0, f"{path}: compressed glyph U+{codepoint:04X}"
                assert codepoint not in index, f"{path}: duplicate U+{codepoint:04X}"
                index[codepoint] = glyph
            break
        assert length != 0xFFFFFFFF and start + length <= len(data)
        pos = start + length
    else:
        raise AssertionError(f"{path}: PF2 character index not found")

    for cp in sorted(CYRILLIC | {ord(c) for c in EXAMPLES if c != " "}):
        assert cp in index, f"{path.name}: missing U+{cp:04X}"
    for cp, off in index.items():
        assert off + 10 <= len(data), f"{path}: bad U+{cp:04X} offset"
        width, height = unpack_from(">HH", data, off)
        end = off + 10 + (width * height + 7) // 8
        assert end <= len(data), f"{path}: truncated U+{cp:04X} glyph"
        if cp in CYRILLIC:
            assert width and height, f"{path}: empty U+{cp:04X} glyph"
    print(f"OK {path.name}: {len(index)} indexed glyphs, Cyrillic present")


if __name__ == "__main__":
    for font in FONTS:
        check_font(font)
