#!/usr/bin/env python3
"""Draws the M7 acceptance sample's app icon and App Store screenshots (opaque RGB PNGs, standard library only).

The screenshots show the app's one screen as SwiftUI lays it out (a bell, the title, the caption, the button), drawn
with plain shapes and a 5x7 pixel font, at the sizes App Store Connect takes for the iPhone 6.9" and iPad 13" displays.
The app is not localized, so every locale gets the same pictures. Run from anywhere:

    python3 -I samples/m7-acceptance/make-images.py
"""
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BLUE = (10, 132, 255)
WHITE = (255, 255, 255)
INK = (28, 28, 30)
GREY = (110, 110, 115)
BACKGROUND = (242, 242, 247)

FONT = {  # 5x7, rows top to bottom, '#' = ink
    'A': ".###.#...##...#######...##...##...#", 'B': "####.#...##...#####.#...##...#####.",
    'C': ".###.#...##....#....#....#...#.###.", 'D': "####.#...##...##...##...##...#####.",
    'E': "######....#....####.#....#....#####", 'F': "######....#....####.#....#....#....",
    'G': ".###.#...##....#.####...##...#.####", 'H': "#...##...##...#######...##...##...#",
    'I': ".###...#....#....#....#....#...###.", 'K': "#...##..#.#.#..##...#.#..#..#.#...#",
    'L': "#....#....#....#....#....#....#####", 'M': "#...###.###.#.##...##...##...##...#",
    'N': "#...###..##.#.##..###...##...##...#", 'O': ".###.#...##...##...##...##...#.###.",
    'P': "####.#...##...#####.#....#....#....", 'R': "####.#...##...#####.#.#..#..#.#...#",
    'S': ".#####....#.....###.....#....#####.", 'T': "#####..#....#....#....#....#....#..",
    'U': "#...##...##...##...##...##...#.###.", 'V': "#...##...##...##...##...#.#.#...#..",
    'W': "#...##...##...##.#.##.#.##.#.#.#.#.", 'X': "#...##...#.#.#...#...#.#.#...##...#",
    'Y': "#...##...#.#.#...#....#....#....#..", 'Z': "#####....#...#...#...#...#....#####",
    ' ': "." * 35, '.': "." * 30 + "..#..", '7': "#####....#...#...#...#....#....#...",
}


assert all(len(g) == 35 for g in FONT.values()), "a glyph is not 5x7"


def png(path, width, height, pixels):
    raw = b"".join(b"\x00" + bytes(pixels[y * width * 3:(y + 1) * width * 3]) for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    head = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB: no alpha, as App Store Connect wants
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


class Canvas:
    def __init__(self, width, height, color):
        self.w, self.h = width, height
        self.px = bytearray(bytes(color) * (width * height))

    def rect(self, x0, y0, x1, y1, color, radius=0):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                if radius:
                    cx = min(max(x, x0 + radius), x1 - radius - 1)
                    cy = min(max(y, y0 + radius), y1 - radius - 1)
                    if (x - cx) ** 2 + (y - cy) ** 2 > radius * radius:
                        continue
                i = (y * self.w + x) * 3
                self.px[i:i + 3] = bytes(color)

    def circle(self, cx, cy, r, color):
        for y in range(max(0, cy - r), min(self.h, cy + r + 1)):
            for x in range(max(0, cx - r), min(self.w, cx + r + 1)):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    i = (y * self.w + x) * 3
                    self.px[i:i + 3] = bytes(color)

    def text(self, s, cx, y, scale, color):
        width = len(s) * 6 * scale - scale
        x = cx - width // 2
        for ch in s:
            glyph = FONT[ch]
            for row in range(7):
                for col in range(5):
                    if glyph[row * 5 + col] == "#":
                        self.rect(x + col * scale, y + row * scale, x + (col + 1) * scale, y + (row + 1) * scale, color)
            x += 6 * scale

    def bell(self, cx, cy, size, color):
        self.circle(cx, cy - size // 6, size // 3, color)                       # dome
        self.rect(cx - size // 3, cy - size // 6, cx + size // 3, cy + size // 4, color)
        self.rect(cx - size // 2, cy + size // 4, cx + size // 2, cy + size // 3, color, radius=size // 24)  # rim
        self.circle(cx, cy + size // 3 + size // 12, size // 10, color)           # clapper
        self.circle(cx, cy - size // 2, size // 14, color)                       # knob


def screenshot(path, width, height):
    c = Canvas(width, height, BACKGROUND)
    u = width // 100                     # one hundredth of the width
    mid, top = width // 2, height // 3
    c.bell(mid, top, 22 * u, BLUE)
    c.text("HELLO FROM LINUX", mid, top + 22 * u, u, INK)
    c.text("BUILT SIGNED AND SHIPPED BY XLESS", mid, top + 32 * u, max(1, u // 2), GREY)
    c.rect(mid - 30 * u, top + 42 * u, mid + 30 * u, top + 52 * u, BLUE, radius=5 * u)
    c.text("ALLOW NOTIFICATIONS", mid, top + 47 * u - (7 * max(1, u // 2)) // 2, max(1, u // 2), WHITE)
    png(path, width, height, c.px)


def icon(path):
    c = Canvas(1024, 1024, BLUE)
    c.bell(512, 470, 520, WHITE)
    c.text("XLESS M7", 512, 840, 14, WHITE)
    png(path, 1024, 1024, c.px)


def main():
    icon(os.path.join(HERE, "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"))
    sets = {"APP_IPHONE_67": (1320, 2868), "APP_IPAD_PRO_3GEN_129": (2064, 2752)}
    for locale in ("en-US", "pt-BR"):
        for display, (w, h) in sets.items():
            d = os.path.join(HERE, "appstore", locale, "screenshots", display)
            os.makedirs(d, exist_ok=True)
            screenshot(os.path.join(d, "01-home.png"), w, h)


if __name__ == "__main__":
    main()
