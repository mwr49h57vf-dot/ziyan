from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import math

src = Path('/Users/mac/Desktop/ZiYan_副本/design/logo-concepts/png-v6/ziyan-logo-15-spark-loop.png')
out = Path('/Users/mac/Desktop/ZiYan_副本/design/logo-concepts/ziyan-logo-dynamic-spark.gif')
base = Image.open(src).convert('RGBA').resize((512, 512), Image.Resampling.LANCZOS)
frames = []
for i in range(24):
    t = i / 24.0
    layer = Image.new('RGBA', base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    # A soft diagonal light sweep moves across the mark.
    x = int(-140 + t * 800)
    for w, a in [(34, 18), (18, 38), (7, 95)]:
        d.line((x - 170, 512, x + 170, 0), fill=(255, 255, 255, a), width=w)
    # Two restrained four-point glints breathe at different phases.
    for cx, cy, phase in [(101, 122, 0.0), (407, 365, 1.7)]:
        amp = 0.45 + 0.55 * max(0, math.sin(2 * math.pi * t + phase))
        r = int(7 + 16 * amp)
        col = (255, 255, 255, int(80 + 165 * amp))
        d.line((cx-r*2, cy, cx+r*2, cy), fill=col, width=max(2, int(r/4)))
        d.line((cx, cy-r*2, cx, cy+r*2), fill=col, width=max(2, int(r/4)))
        d.ellipse((cx-3, cy-3, cx+3, cy+3), fill=(255, 255, 255, int(120+120*amp)))
    layer = layer.filter(ImageFilter.GaussianBlur(1.2))
    frames.append(Image.alpha_composite(base, layer).convert('RGB'))
frames[0].save(out, save_all=True, append_images=frames[1:], duration=85, loop=0, optimize=False)
print(out)
