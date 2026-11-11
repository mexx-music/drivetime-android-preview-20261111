# Erzeugt die Wasserzeichen des Kontrollvideos (transparente Vollbild-PNGs).
# ffmpeg auf diesem Mac hat kein drawtext (ohne freetype) – deshalb als Bild,
# das der Exportdienst per overlay einblendet. Neu erzeugen nur bei Änderung:
#   python3 tool/studio_export/make_watermarks.py
import os
from PIL import Image, ImageDraw, ImageFont
HERE = os.path.dirname(os.path.abspath(__file__))
TEXT = 'DRIVETIME PREVIEW'
FONT = '/System/Library/Fonts/HelveticaNeue.ttc'
for (w, h) in ((640, 360), (360, 640)):
    im = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    size = round(min(w, h) * 0.05)                      # ≈ 18 px bei 360 px Kante: sichtbar, nicht störend
    f = ImageFont.truetype(FONT, size, index=1)          # Helvetica Neue Bold
    tw, th = d.textbbox((0, 0), TEXT, font=f)[2:]
    x, y = w - tw - round(size * 0.9), h - th - round(size * 0.9)
    pad = round(size * 0.35)
    d.rounded_rectangle((x - pad, y - pad, x + tw + pad, y + th + pad + 2), radius=pad, fill=(0, 0, 0, 70))
    d.text((x, y), TEXT, font=f, fill=(255, 255, 255, 190))
    im.save(os.path.join(HERE, 'assets', f'watermark_preview_{w}x{h}.png'))
    print('watermark', w, h, size)
