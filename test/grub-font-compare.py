#!/usr/bin/python3 -I
"""Make a GRUB test theme that shows the menu text at several pixel sizes.

Usage: grub-font-compare.py OUTDIR
GRUB draws every glyph with 1 bit per pixel. This shows DejaVu Sans with
its own hinting (as in the theme) at sizes near 27 px, and DejaVu Sans
Mono near 22 px. Each size gets two lines: the color of a selected menu
item and the color of a normal item.
"""
import os
import subprocess
import sys

TEXT = ("Debian GNU/Linux    Advanced options for Debian GNU/Linux    "
        "Windows Boot Manager (on /dev/nvme0n1p1)")
MONO_TEXT = "linux /vmlinuz-6.12.113+deb13-amd64 root=/dev/mapper/vg_debian-root ro quiet"
DEJAVU = "/usr/share/fonts/truetype/dejavu/"
SANS = [("DejaVu Sans", DEJAVU + "DejaVuSans.ttf", s, TEXT) for s in (24, 25, 26, 27, 28, 29)]
MONO = [("DejaVu Sans Mono", DEJAVU + "DejaVuSansMono.ttf", s, MONO_TEXT)
        for s in (20, 21, 22, 23)]


def make_font(out, index, path, size):
    name = "Cmp%02d" % index
    pf2 = os.path.join(out, "%s.pf2" % name)
    subprocess.run(["grub-mkfont", "-n", name, "-s", str(size), "-r", "0x20-0x7E",
                    "-o", pf2, path], check=True)
    return pf2_name(pf2)


def pf2_name(path):
    """The font name that GRUB uses, from the NAME section of the file."""
    with open(path, "rb") as f:
        data = f.read(512)
    pos = data.index(b"NAME") + 4
    size = int.from_bytes(data[pos:pos + 4], "big")
    return data[pos + 4:pos + 4 + size].rstrip(b"\0").decode()


def label(left, top, font, color, text):
    return ('+ label { left = %d top = %d width = 100%% height = 40 '
            'font = "%s" color = "%s" text = "%s" }\n' % (left, top, font, color, text))


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    theme = ['title-text: ""\ndesktop-color: "#000000"\n']
    small = make_font(out, 99, DEJAVU + "DejaVuSans.ttf", 14)
    top = 20
    for i, (title, path, size, text) in enumerate(SANS + MONO):
        font = make_font(out, i, path, size)
        theme.append(label(30, top, small, "#8080ff", "%s, %d px" % (title, size)))
        top += 18
        theme.append(label(30, top, font, "#e6e6e6", text))
        top += size + 6
        theme.append(label(30, top, font, "#7a7a7a", text))
        top += size + 12
    with open(os.path.join(out, "theme.txt"), "w") as f:
        f.write("".join(theme))


if __name__ == "__main__":
    main()
