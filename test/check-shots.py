#!/usr/bin/python3 -I
"""Pick the splash frame of a boot and check the logo position.

Usage: check-shots.py SHOTDIR THEMEDIR PREFIX BOX_CENTER SPIN_OFFSET
SHOTDIR has PREFIX-grub.png (the GRUB menu), the burst PREFIX-boot-NNN.png
taken after the menu, and maybe PREFIX-prompt.png (the LUKS prompt) and
the burst PREFIX-unlocked-NNN.png (after the password). BOX_CENTER is the
center of the password box, as an offset from the screen center. The
spinner center is at 3/4 of the screen height plus SPIN_OFFSET.
The script copies the last frame that shows the Plymouth spinner to
PREFIX-splash.png, and the last such frame after the password to
PREFIX-unlocked.png. It prints the center of the spinner. Then it compares
the logo area of the GRUB menu, the splash frame and the prompt with
logo.png drawn on black, and prints the largest difference of one color
channel (0 means the same pixels).
"""
import glob
import os
import shutil
import sys

from PIL import Image, ImageChops

shots, themes, prefix = sys.argv[1:4]
box_center = int(sys.argv[4])
spin_offset = int(sys.argv[5])
logo = Image.open(os.path.join(themes, "grub/debian-dark/logo.png")).convert("RGBA")
ref = Image.new("RGBA", logo.size, (0, 0, 0, 255))
ref.alpha_composite(logo)
ref = ref.convert("RGB")
# The logo is at the top of logo.png. The rows under it are clear.
alpha = logo.getchannel("A")
logo_rows = alpha.getbbox()[3]
ref = ref.crop((0, 0, logo.width, logo_rows))


def theme_value(name):
    """The first menu entry center, from the GRUB theme: the selection bar."""
    text = open(os.path.join(themes, "grub/debian-dark/theme.txt")).read()
    block = text[text.index("+ boot_menu"):]
    values = {}
    for line in block.splitlines()[1:]:
        if "=" in line:
            key, val = [p.strip() for p in line.split("=", 1)]
            values[key] = val
        if line.strip() == "}":
            break
    return values[name]


def first_item_center():
    top = int(theme_value("top").replace("50%", ""))
    return top + int(theme_value("item_padding")) + int(theme_value("item_height")) // 2


def logo_diff(img):
    w, h = img.size
    x0, y0 = w // 2 - logo.width // 2, h // 2 - logo.height // 2
    part = img.crop((x0, y0, x0 + logo.width, y0 + logo_rows))
    return max(hi for lo, hi in ImageChops.difference(part, ref).getextrema())


def spinner_box(img):
    w, h = img.size
    cy = h * 3 // 4 + spin_offset
    return (w // 2 - 45, cy - 45, w // 2 + 45, cy + 45)


def is_dialog(img):
    w, h = img.size
    return img.getpixel((w // 2, h // 2 + box_center)) == (0x1c, 0x1c, 0x1c)


def has_spinner(img):
    """Something drawn where the spinner is, and no password box."""
    box = img.crop(spinner_box(img)).convert("L")
    return box.getextrema()[1] > 60 and not is_dialog(img)


def spinner_rows(img):
    """The top and bottom rows of the spinner arc in a frame."""
    x0, y0, x1, y1 = spinner_box(img)
    lit = img.crop((x0, y0, x1, y1)).convert("L").point(lambda v: 255 if v > 30 else 0)
    bbox = lit.getbbox()
    return y0 + bbox[1], y0 + bbox[3]


def spinner_center(frames):
    """The vertical center of the spinner, as an offset from 3/4 of the height.

    The arc has a gap that turns, so one frame does not show the whole
    circle. The top and bottom rows of all frames together do.
    """
    rows = [spinner_rows(img) for img in frames]
    top, bottom = min(r[0] for r in rows), max(r[1] for r in rows)
    return (top + bottom) / 2 - frames[0].size[1] * 3 / 4


def is_grub(img):
    w, h = img.size
    return img.getpixel((w // 2, h // 2 + first_item_center())) == (0x26, 0x26, 0x26)


def pick(pattern, out, what):
    found = []
    for path in sorted(glob.glob(os.path.join(shots, pattern))):
        img = Image.open(path).convert("RGB")
        if not is_grub(img) and has_spinner(img) and logo_diff(img) <= 2:
            found.append((path, img))
    if not found:
        if glob.glob(os.path.join(shots, pattern)):
            print("%s: no %s frame with the spinner found" % (prefix, what))
        return
    # The last frame: right after the password an old error message can
    # still show for a moment.
    path, img = found[-1]
    shutil.copy(path, os.path.join(shots, out))
    print("%s: %s frame %s, logo diff %d, spinner center 3/4 H %+.1f in %d frames"
          " (wanted %+d)" % (prefix, what, os.path.basename(path), logo_diff(img),
                             spinner_center([f[1] for f in found]), len(found),
                             spin_offset))


def main():
    grub = Image.open(os.path.join(shots, prefix + "-grub.png")).convert("RGB")
    print("%s: GRUB menu %s, logo diff %d" % (prefix, "found" if is_grub(grub) else
                                            "NOT FOUND", logo_diff(grub)))
    pick(prefix + "-boot-*.png", prefix + "-splash.png", "splash")
    pick(prefix + "-unlocked-*.png", prefix + "-unlocked.png", "after the password")
    prompt = os.path.join(shots, prefix + "-prompt.png")
    if os.path.exists(prompt):
        img = Image.open(prompt).convert("RGB")
        print("%s: prompt, logo diff %d" % (prefix, logo_diff(img)))


if __name__ == "__main__":
    main()
