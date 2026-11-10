#!/usr/bin/env python3
"""Draw the covers of the screenshot catalog: make_covers.py <out dir> writes <n>.png for every showcase book.

Deterministic (no randomness), drawn with KOReader's own Noto Serif fonts from $KOREADER_DIR. Needs Pillow,
for example in the repository's local venv: .tools/venv/bin/pip install pillow
"""
import os
import sys
import textwrap

from PIL import Image, ImageDraw, ImageFont

from showcase import PALETTE, SHOWCASE

WIDTH, HEIGHT = 400, 600
FONTS = os.path.join(os.environ.get("KOREADER_DIR", "/usr/lib/koreader"), "fonts", "noto")


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def gradient(top, bottom):
    image = Image.new("RGB", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    for y in range(HEIGHT):
        t = y / (HEIGHT - 1)
        draw.line([(0, y), (WIDTH, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return image


def centred(draw, y, text, face, fill):
    left, top, right, bottom = draw.textbbox((0, 0), text, font=face)
    draw.text(((WIDTH - (right - left)) / 2 - left, y - top), text, font=face, fill=fill)
    return y + (bottom - top)


def cover(index, title, author, series, number):
    top, bottom = PALETTE[index % len(PALETTE)]
    image = gradient(top, bottom)
    draw = ImageDraw.Draw(image)
    ink, rule = (245, 236, 214), (214, 190, 140)
    draw.rectangle([18, 18, WIDTH - 19, HEIGHT - 19], outline=rule, width=3)
    draw.rectangle([28, 28, WIDTH - 29, HEIGHT - 29], outline=rule, width=1)

    lines = textwrap.wrap(title.upper(), width=14)
    size = 40
    title_face = font("NotoSerif-Bold.ttf", size)
    while size > 20 and max(draw.textlength(line, font=title_face) for line in lines) > WIDTH - 90:
        size -= 2
        title_face = font("NotoSerif-Bold.ttf", size)
    y = 170 - 26 * (len(lines) - 1)
    for line in lines:
        y = centred(draw, y, line, title_face, ink) + 14
    y += 16
    draw.line([(WIDTH / 2 - 60, y), (WIDTH / 2 + 60, y)], fill=rule, width=2)
    y = centred(draw, y + 28, author, font("NotoSerif-Italic.ttf", 26), ink)
    if series:
        centred(draw, y + 30, f"{series} · {number}", font("NotoSerif-Regular.ttf", 20), rule)
    draw.ellipse([WIDTH / 2 - 7, HEIGHT - 92, WIDTH / 2 + 7, HEIGHT - 78], outline=rule, width=2)
    return image


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make_covers.py <out dir>")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for index, (title, author, series, number) in enumerate(SHOWCASE):
        cover(index, title, author, series, number).save(os.path.join(out, f"{index + 1}.png"), optimize=True)
    print(f"{len(SHOWCASE)} covers in {out}")


if __name__ == "__main__":
    main()
