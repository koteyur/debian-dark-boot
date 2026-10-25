#!/usr/bin/python3 -I
"""Make the GRUB theme and the Plymouth theme "debian-dark".

Run it in the ddboot-tools container (see make-assets.sh). It needs
rsvg-convert, grub-mkfont, Pillow, desktop-base, plymouth-themes and
fonts-dejavu-core. The output goes to themes/grub/debian-dark and
themes/plymouth/debian-dark.

The themes are drawn at one size. --scale sets it, relative to the first
design (an 18 px menu font and a 160 pixel high logo). The shipped themes use
scale 1.5. Every image is drawn at its final size from vector shapes or
from the SVG logo, except the keyboard layout names (see make_dialog).

Both themes use the same logo image. GRUB centers it with "50%-h/2" and
Plymouth with an alignment of 0.5, so the logo is at the same pixels in
both, on every screen. The logo sits above the screen center: the image
has clear rows under the logo. The menu and the password box are placed
relative to the screen center too. The spinner is halfway between the
logo and the bottom of the screen.

The layout is made for the bottom of a screen DESIGN_HEIGHT * scale high
(768 at scale 1.5): there the countdown line is just above the key help,
and 6 menu entries fit. On higher screens the same offsets from the
center apply. Lower screens get an overlap at the bottom.
"""

import argparse
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont

THEME = "debian-dark"

# Look of the themes. All sizes are in screen pixels at scale 1.
LOGO_SVG = "/usr/share/desktop-base/debian-logos/logo.svg"
LOGO_HEIGHT = 173          # 8 % larger than in the first design
LOGO_GREY = (0x4d, 0x4d, 0x4d)
LOGO_GAP = 10              # from the bottom of the logo to the first menu entry
MENU_WIDTH = 720          # wide enough for most "Advanced options" entries
ITEM_HEIGHT = 32
ITEM_SPACING = 2
ITEM_PADDING = 16          # GRUB uses it on all four sides of the menu
MENU_ROWS = 6              # menu entries shown without scrolling
MENU_FONT = 18             # GRUB menu font in pixels, see --menu-font
TERM_FONT = 15             # GRUB terminal font in pixels
HINT_FONT = 14
HINT_BOTTOM = 25           # from the bottom of the screen to the key help
BAR_GAP = 8                # from the countdown line to the key help
BAR_OVERLAP = 17           # the countdown bar starts this far inside the menu box
BAR_HEIGHT = 28            # GRUB makes a progress bar at least 28 pixels high
DESIGN_HEIGHT = 512        # the lowest screen the layout fits (768 at scale 1.5)
SPINNER_SIZE = 36
BOX_WIDTH = 320            # the password box
BOX_HEIGHT = 40
DIALOG_PAD = 6             # clear rows between the box and its text
DIALOG_ROW = 1             # the password box is where this menu row was (0 = first)
SPINNER_VA = 0.75          # vertical alignment of the spinner frame, see Layout
MESSAGE_GAP = 30           # from the spinner center to the Plymouth messages
SPINNER_GREY = (0x9a, 0x9a, 0x9a)
ICON_GREY = (0x80, 0x80, 0x80)
HINT_TEXT = "Enter: boot     E: edit     C: command line     Esc: back"
HINT_GREY = (0x50, 0x50, 0x50)
SPINNER_FRAMES = 30        # Plymouth plays all frames in 2 seconds
PLY_FONT = 12              # Plymouth text, in points
PLY_TITLE_FONT = 20
PLY_MONO_FONT = 11

# GRUB draws text with 1 bit per pixel, so some sizes look better than
# others. These were picked with test/grub-font-compare.py and screenshots
# of the menu: DejaVu Sans with its own hinting, 27 px has more even stems
# than 26 px.
MENU_FONT_PICK = {1.0: 18, 1.5: 27}
# The terminal must be 80 characters wide. At 23 px it does not fit a
# 1280 pixel wide screen.
# GRUB makes the terminal window at least 80 x 24 characters, and moves it
# up when it does not fit under its top edge. Then it covers the bottom of
# the logo. At 1.5, the 17 px font gives a 492 pixel window, which fits
# under the logo on screens from 976 pixels high.
TERM_FONT_PICK = {1.0: 15, 1.5: 17}

DEJAVU = "/usr/share/fonts/truetype/dejavu"
SPINNER_THEME = "/usr/share/plymouth/themes/spinner"


def px(value, scale):
    """Scale a size and round it to whole pixels."""
    return int(value * scale + 0.5)


def even(value, scale):
    """Scale a size and round it to an even number of pixels."""
    return 2 * int(value * scale / 2 + 0.5)


def logo_image(svg, height, grey):
    """Render the SVG, crop it to the drawing and paint it grey."""
    with tempfile.TemporaryDirectory() as tmp:
        big = os.path.join(tmp, "big.png")
        subprocess.run(["rsvg-convert", "-h", "2048", "-o", big, svg], check=True)
        img = Image.open(big).convert("RGBA")
    alpha = img.getchannel("A")
    img = img.crop(alpha.getbbox())
    width = round(img.width * height / img.height)
    width += width % 2
    img = img.resize((width, height), Image.LANCZOS)
    out = Image.new("RGBA", img.size, grey + (0,))
    out.putalpha(img.getchannel("A"))
    return out


def supersampled(size, draw_fn, factor=4, method=Image.LANCZOS):
    """Draw at a larger size and scale down, for smooth edges.

    Image.BOX gives edges without the light halo that LANCZOS leaves on
    small shapes with holes.
    """
    big = Image.new("RGBA", (size[0] * factor, size[1] * factor), (0, 0, 0, 0))
    draw_fn(ImageDraw.Draw(big), factor)
    return big.resize(size, method)


def rounded_box(size, radius, fill, outline=None, line=1):
    def draw(d, s):
        w, h = size[0] * s, size[1] * s
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius * s, fill=fill,
                            outline=outline, width=line * s if outline else 0)
    return supersampled(size, draw)


def spinner_frame(index, size, grey):
    """One frame of a rotating arc with a fading tail."""
    def draw(d, s):
        pad = size / 18 * s
        box = [pad, pad, size * s - pad, size * s - pad]
        width = max(2, size // 10) * s
        start = index * 360 / SPINNER_FRAMES
        steps = 48
        for i in range(steps):
            a = (i + 1) / steps
            color = grey + (round(255 * a ** 1.6),)
            seg0 = start + i * 270 / steps
            d.arc(box, seg0, seg0 + 270 / steps + 1, fill=color, width=width)
    return supersampled((size, size), draw)


def lock_icon(size, grey):
    def draw(d, s):
        w = h = size * s
        fill = grey + (255,)
        stroke = round(w * 0.09)
        d.rounded_rectangle([w * 0.18, h * 0.45, w * 0.82, h * 0.92], w * 0.08, fill=fill)
        d.arc([w * 0.30, h * 0.12, w * 0.70, h * 0.62], 180, 360, fill=fill, width=stroke)
        d.line([w * 0.345, h * 0.36, w * 0.345, h * 0.47], fill=fill, width=stroke)
        d.line([w * 0.655, h * 0.36, w * 0.655, h * 0.47], fill=fill, width=stroke)
        d.ellipse([w * 0.45, h * 0.60, w * 0.55, h * 0.72], fill=(0, 0, 0, 255))
    return supersampled((size, size), draw)


def box(d, u, x0, y0, x1, y1, fill):
    """A rectangle in icon units, with the far edges not included."""
    d.rectangle([x0 * u, y0 * u, x1 * u - 1, y1 * u - 1], fill=fill)


def keyboard_icon(size, grey):
    """A keyboard: a rounded body with two rows of keys and a space bar.

    Same shape as keyboard.png of the Plymouth spinner theme (36x36).
    """
    def draw(d, s):
        u = size * s / 36
        d.rounded_rectangle([3 * u, 7.5 * u, 33 * u - 1, 28.5 * u - 1], 2 * u,
                            fill=grey + (255,))
        clear = (0, 0, 0, 0)
        for y in (12, 16.5):
            for col in range(5):
                x = 7.5 + col * 4.5
                box(d, u, x, y, x + 3, y + 3, clear)
        box(d, u, 12, 22.5, 24, 25.5, clear)
    return supersampled((size, size), draw, method=Image.BOX)


def capslock_icon(width, height, grey):
    """An up arrow over a bar. Same shape as capslock.png of the spinner theme."""
    def draw(d, s):
        u = width * s / 24
        fill = grey + (255,)
        d.polygon([(12 * u, 0), (24 * u, 13.5 * u), (0, 13.5 * u)], fill=fill)
        box(d, u, 6, 13.5, 18, 19.5, fill)
        box(d, u, 6, 21.5, 18, 24.5, fill)
    return supersampled((width, height), draw, method=Image.BOX)


def dot(size, grey):
    def draw(d, s):
        d.ellipse([0, 0, size * s - 1, size * s - 1], fill=grey + (255,))
    return supersampled((size, size), draw)


def pf2_metrics(path):
    """Return (max width, max height) from a GRUB .pf2 font file."""
    with open(path, "rb") as f:
        data = f.read(4096)
    pos, found = 0, {}
    while pos + 8 <= len(data):
        name = data[pos:pos + 4].decode("ascii", "replace")
        size = int.from_bytes(data[pos + 4:pos + 8], "big")
        if name in ("MAXW", "MAXH"):
            found[name] = int.from_bytes(data[pos + 8:pos + 10], "big")
        if name == "CHIX":
            break
        pos += 8 + size
    return found["MAXW"], found["MAXH"]


def line_image(width, height, row, thickness, color):
    """A clear image with one horizontal line in it."""
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(img).rectangle([0, row, width - 1, row + thickness - 1],
                                  fill=color + (255,))
    return img


def text_image(text, ttf, size, grey):
    """Render a line of text with anti-aliasing on a clear background."""
    font = ImageFont.truetype(ttf, size)
    left, top, right, bottom = font.getbbox(text)
    width = right - left + 2
    width += width % 2
    img = Image.new("RGBA", (width, bottom - top + 2), grey + (0,))
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).text((1 - left, 1 - top), text, font=font, fill=255)
    img.putalpha(mask)
    return img


def make_grub_font(out, ttf, size, name):
    # Latin and Cyrillic (including Ukrainian and Belarusian letters),
    # punctuation, arrows and box drawing for GRUB menus and terminals.
    ranges = ("0x20-0x24F,0x400-0x45F,0x490-0x491,"
              "0x2000-0x206F,0x2190-0x21FF,0x2500-0x25FF")
    path = os.path.join(out, name)
    subprocess.run(["grub-mkfont", "-s", str(size), "-r", ranges, "-o", path,
                    os.path.join(DEJAVU, ttf)], check=True)
    return path


def fresh_dir(path):
    """Start with an empty directory, so no old file stays in a theme."""
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)


def write_template(name, path, values):
    with open(os.path.join(os.path.dirname(__file__), name)) as f:
        text = f.read()
    for key, val in values.items():
        text = text.replace("@" + key + "@", str(val))
    assert "@" not in text, "unreplaced value in " + name
    with open(path, "w") as f:
        f.write(text)


def grey_icon(path, grey):
    icon = Image.open(path).convert("RGBA")
    out = Image.new("RGBA", icon.size, grey + (0,))
    out.putalpha(icon.getchannel("A"))
    return out


def padded(img, height, top=0):
    """Put the image into a clear image of the given height, TOP rows down."""
    out = Image.new("RGBA", (img.width, height), (0, 0, 0, 0))
    out.paste(img, (0, top))
    return out


class Layout:
    """Sizes and places, in pixels. Vertical places are offsets from the
    screen center (negative is up)."""

    def __init__(self, scale, menu_font, term_font, logo, hint, term_char):
        s = scale
        self.scale = scale
        self.menu_font = menu_font
        self.term_font = term_font
        self.logo_w, self.logo_h = logo.size
        self.item_h = px(ITEM_HEIGHT, s)
        self.item_sp = px(ITEM_SPACING, s)
        self.item_pad = px(ITEM_PADDING, s)
        self.menu_w = even(MENU_WIDTH, s)
        self.menu_h = MENU_ROWS * (self.item_h + self.item_sp) - self.item_sp \
            + 2 * self.item_pad
        self.bar_h = max(BAR_HEIGHT, px(BAR_HEIGHT, s))
        self.bar_thick = max(1, px(2, s))
        self.bar_row = (self.bar_h - self.bar_thick) // 2
        self.gap = px(LOGO_GAP, s)
        self.hint_w, self.hint_h = hint.size
        self.hint_bottom = px(HINT_BOTTOM, s)
        # Place the countdown line just above the key help, on the lowest
        # screen. The menu is above the line and the logo above the menu.
        self.min_height = even(DESIGN_HEIGHT, s)
        line = self.min_height // 2 - self.hint_bottom - px(BAR_GAP, s) - self.bar_thick
        self.bar_top = line - self.bar_row
        self.menu_top = self.bar_top - self.menu_h + px(BAR_OVERLAP, s)
        self.logo_top = self.menu_top + self.item_pad - self.gap - self.logo_h
        self.logo_top -= self.logo_top % 2
        # The GRUB terminal window (editor, command line, the screen after
        # an entry is chosen) is drawn black over its area. Start it under
        # the logo, or it cuts off the bottom of the logo.
        self.term_top = max(self.menu_top, self.logo_top + self.logo_h)
        # Plymouth: the password box is where menu row DIALOG_ROW was. At the
        # first row it would almost touch the logo.
        self.box_w = even(BOX_WIDTH, s)
        self.box_h = even(BOX_HEIGHT, s)
        self.dialog_pad = even(DIALOG_PAD, s)
        self.box_center = self.menu_top + self.item_pad + self.item_h // 2 \
            + DIALOG_ROW * (self.item_h + self.item_sp)
        # The dialog images are centered on the screen. Clear rows above
        # the box (dialog_top) and under it (dialog_pad) put the box at
        # box_center. The prompt text then starts dialog_pad under the box.
        self.dialog_top = 2 * self.box_center + self.dialog_pad
        assert self.box_center >= 0, "the menu is too high for the dialog"
        # The spinner is halfway between the bottom of the logo and the
        # bottom of the screen: at H / 2 + logo_bottom / 2 + H / 4 on a
        # screen H pixels high. Plymouth puts the center of the frame at
        # SPINNER_VA * H = 3 / 4 * H, so the spinner sits logo_bottom / 2
        # from the frame center. This holds for every screen height.
        self.spin = even(SPINNER_SIZE, s)
        self.spin_offset = (self.logo_top + self.logo_h) // 2
        # Plymouth shows its messages (for example a wrong password) 10
        # pixels under the frame. The frame reaches message_gap under the
        # spinner, below the keyboard layout icons on a 768 pixel screen.
        self.message_gap = px(MESSAGE_GAP, s)
        # GRUB makes the terminal window at least 80x24 characters.
        self.term_border = max(2, px(4, s))
        self.term_w = 80 * term_char[0] + 2 * self.term_border
        self.term_w += self.term_w % 2
        # The terminal window must cover the menu, or the ends of the menu
        # rows show next to it after an entry is chosen.
        self.term_w = max(self.term_w, self.menu_w)
        self.term_h = 24 * term_char[1] + 2 * self.term_border

    def logo_canvas_height(self):
        """Height of the logo image with the clear rows under the logo.

        The image is centered on the screen, so the logo is at logo_top.
        """
        return -2 * self.logo_top

    def grub_values(self):
        return {
            "SCALE": "%g" % self.scale,
            "LOGO_W": self.logo_w, "LOGO_H": self.logo_canvas_height(),
            "LOGO_LEFT": self.logo_w // 2, "LOGO_TOP": -self.logo_top,
            "MENU_TOP": self.menu_top, "MENU_LEFT": self.menu_w // 2,
            "MENU_W": self.menu_w, "MENU_H": self.menu_h,
            "ITEM_H": self.item_h, "ITEM_SP": self.item_sp, "ITEM_PAD": self.item_pad,
            "ITEM_FONT": "DejaVu Sans Regular %d" % self.menu_font,
            "BAR_TOP": self.bar_top, "BAR_H": self.bar_h,
            "TERM_FONT": "DejaVu Sans Mono Regular %d" % self.term_font,
            "TERM_LEFT": self.term_w // 2, "TERM_TOP": self.term_top,
            "TERM_W": self.term_w, "TERM_H": self.term_h,
            "TERM_BORDER": self.term_border,
            "HINT_LEFT": self.hint_w // 2, "HINT_W": self.hint_w, "HINT_H": self.hint_h,
            "HINT_BOTTOM": self.hint_bottom,
        }


def signed(value):
    """A GRUB theme offset: "+N" or "-N"."""
    return "%+d" % value


def make_selection_bar(out, lay):
    """Selection bar: left end, middle, right end."""
    end = px(12, lay.scale)
    bar = rounded_box((2 * end, lay.item_h), 8 * lay.scale, (0x26, 0x26, 0x26, 255))
    bar.crop((0, 0, end, lay.item_h)).save(os.path.join(out, "select_w.png"))
    bar.crop((end, 0, end + 1, lay.item_h)).save(os.path.join(out, "select_c.png"))
    bar.crop((end, 0, 2 * end, lay.item_h)).save(os.path.join(out, "select_e.png"))


def make_progress_bar(out, lay):
    """The bar images are clear except for a thin line in the middle."""
    for name, grey in (("bar_c.png", 0x14), ("hl_c.png", 0x5a)):
        line_image(1, lay.bar_h, lay.bar_row, lay.bar_thick, (grey,) * 3).save(
            os.path.join(out, name))


def make_grub(out, lay, logo, hint):
    make_selection_bar(out, lay)
    make_progress_bar(out, lay)
    padded(logo, lay.logo_canvas_height()).save(os.path.join(out, "logo.png"))
    hint.save(os.path.join(out, "hint.png"))
    values = lay.grub_values()
    values["MENU_TOP"] = signed(lay.menu_top)
    values["BAR_TOP"] = signed(lay.bar_top)
    values["TERM_TOP"] = signed(lay.term_top)
    write_template("grub-theme.txt.in", os.path.join(out, "theme.txt"), values)


def make_dialog(out, lay):
    """Make the password dialog images.

    Plymouth centers the entry image on the screen and puts the prompt
    text right under it. The entry and lock images have dialog_top clear
    rows above the box and dialog_pad clear rows under it.
    """
    top = lay.dialog_top
    full_h = top + lay.box_h + lay.dialog_pad
    line = max(1, px(1, lay.scale))
    box = rounded_box((lay.box_w, lay.box_h), 8 * lay.scale, (0x1c, 0x1c, 0x1c, 255),
                      outline=(0x40, 0x40, 0x40, 255), line=line)
    padded(box, full_h, top).save(os.path.join(out, "entry.png"))
    padded(lock_icon(lay.box_h, ICON_GREY), full_h, top).save(os.path.join(out, "lock.png"))
    # Plymouth centers a bullet on the full entry height, which is the
    # screen center. The clear rows above the dot move it down to the
    # center of the visible box.
    dot_size = even(10, lay.scale)
    shift = 2 * lay.box_center
    padded(dot(dot_size, (0xb0, 0xb0, 0xb0)), dot_size + shift, shift).save(
        os.path.join(out, "bullet.png"))
    keyboard_icon(even(36, lay.scale), ICON_GREY).save(os.path.join(out, "keyboard.png"))
    capslock_icon(even(24, lay.scale), even(28, lay.scale), ICON_GREY).save(
        os.path.join(out, "capslock.png"))
    # The layout names. Plymouth has the place of each name in this image
    # built in, in pixels, so the image cannot be drawn at another size.
    # It is the image of the spinner theme, in grey.
    grey_icon(os.path.join(SPINNER_THEME, "keymap-render.png"), ICON_GREY).save(
        os.path.join(out, "keymap-render.png"))


def make_plymouth(out, lay, logo):
    padded(logo, lay.logo_canvas_height()).save(os.path.join(out, "watermark.png"))
    # The throbber frames are mostly clear. The spinner is spin_offset from
    # the frame center (see Layout).
    half = lay.message_gap - lay.spin_offset
    frame_h = 2 * half
    top = half + lay.spin_offset - lay.spin // 2
    for i in range(SPINNER_FRAMES):
        frame = Image.new("RGBA", (lay.spin, frame_h), (0, 0, 0, 0))
        frame.paste(spinner_frame(i, lay.spin, SPINNER_GREY), (0, top))
        frame.save(os.path.join(out, "throbber-%04d.png" % (i + 1)))
    make_dialog(out, lay)
    s = lay.scale
    values = {
        "SCALE": "%g" % s,
        "SPINNER_VA": "%g" % SPINNER_VA,
        "FONT": "%g" % (round(PLY_FONT * s * 2) / 2),
        "TITLE_FONT": "%g" % (round(PLY_TITLE_FONT * s * 2) / 2),
        "MONO_FONT": "%g" % (round(PLY_MONO_FONT * s * 2) / 2),
    }
    write_template("plymouth-theme.in", os.path.join(out, THEME + ".plymouth"), values)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", help="the themes directory")
    ap.add_argument("--scale", type=float, default=1.5)
    ap.add_argument("--menu-font", type=int, help="GRUB menu font size in pixels")
    ap.add_argument("--term-font", type=int, help="GRUB terminal font size in pixels")
    args = ap.parse_args()
    s = args.scale
    menu_font = args.menu_font or MENU_FONT_PICK.get(s, px(MENU_FONT, s))
    term_font = args.term_font or TERM_FONT_PICK.get(s, px(TERM_FONT, s))
    grub_out = os.path.join(args.outdir, "grub", THEME)
    ply_out = os.path.join(args.outdir, "plymouth", THEME)
    fresh_dir(grub_out)
    fresh_dir(ply_out)
    logo = logo_image(LOGO_SVG, even(LOGO_HEIGHT, s), LOGO_GREY)
    make_grub_font(grub_out, "DejaVuSans.ttf", menu_font, "dejavu-sans-%d.pf2" % menu_font)
    mono = make_grub_font(grub_out, "DejaVuSansMono.ttf", term_font,
                          "dejavu-sans-mono-%d.pf2" % term_font)
    # GRUB draws text with 1 bit per pixel. The key help line does not
    # change, so it is a picture with smooth edges instead.
    hint = text_image(HINT_TEXT, os.path.join(DEJAVU, "DejaVuSans.ttf"),
                      px(HINT_FONT, s), HINT_GREY)
    lay = Layout(s, menu_font, term_font, logo, hint, pf2_metrics(mono))
    make_grub(grub_out, lay, logo, hint)
    make_plymouth(ply_out, lay, logo)
    print("scale %g: logo %dx%d, menu font %d px, terminal font %d px"
          % (s, lay.logo_w, lay.logo_h, menu_font, term_font))
    print("block from %+d to %+d around the center, fits screens from %d pixels high"
          % (lay.logo_top, lay.bar_top + lay.bar_h, lay.min_height))
    print("terminal %dx%d" % (lay.term_w, lay.term_h))
    # The tests need two places, as offsets from the screen center.
    with open(os.path.join(os.path.dirname(__file__), "..", "test", "layout.env"), "w") as f:
        f.write("# Made by src/make-assets.py. Offsets from the screen center.\n")
        f.write("ITEM_CENTER=%d\n" % (lay.menu_top + lay.item_pad + lay.item_h // 2))
        f.write("BOX_CENTER=%d\n" % lay.box_center)
        f.write("# The spinner center is at 3/4 of the screen height plus this.\n")
        f.write("SPIN_OFFSET=%d\n" % lay.spin_offset)


if __name__ == "__main__":
    main()
