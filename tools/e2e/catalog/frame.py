#!/usr/bin/env python3
"""Put screenshots in an e-reader frame: frame.py <raw dir> <out dir> frames every <raw dir>/*.png into <out dir>.

The frame is a dark bezel with rounded corners and a soft shadow on a transparent background, so the pictures
suit GitHub's light and dark themes. Needs Pillow.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

BEZEL, CHIN, MARGIN, RADIUS = 34, 62, 31, 36
BODY, EDGE = (38, 40, 44, 255), (70, 73, 78, 255)


def frame(screen):
    w, h = screen.size
    body_w, body_h = w + 2 * BEZEL, h + BEZEL + CHIN
    canvas = Image.new("RGBA", (body_w + 2 * MARGIN, body_h + 2 * MARGIN), (0, 0, 0, 0))

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [MARGIN, MARGIN + 8, MARGIN + body_w, MARGIN + body_h + 8], RADIUS, fill=(0, 0, 0, 90))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(12)))

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle([MARGIN, MARGIN, MARGIN + body_w, MARGIN + body_h], RADIUS, fill=BODY, outline=EDGE,
                           width=2)
    canvas.paste(screen.convert("RGB"), (MARGIN + BEZEL, MARGIN + BEZEL))
    cx, cy = MARGIN + body_w // 2, MARGIN + BEZEL + h + CHIN // 2
    draw.rounded_rectangle([cx - 36, cy - 4, cx + 36, cy + 4], 4, fill=EDGE)
    return canvas


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: frame.py <raw dir> <out dir>")
    raw, out = sys.argv[1:]
    names = sorted(name for name in os.listdir(raw) if name.endswith(".png"))
    if not names:
        sys.exit(f"no screenshots in {raw}")
    os.makedirs(out, exist_ok=True)
    for name in names:
        with Image.open(os.path.join(raw, name)) as screen:
            frame(screen).save(os.path.join(out, name), optimize=True)
    print(f"{len(names)} screenshots framed into {out}")


if __name__ == "__main__":
    main()
