from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import math

OUT = Path('/Users/mac/Desktop/ZiYan_副本/design/logo-concepts/static-10')
OUT.mkdir(parents=True, exist_ok=True)
N = 1024

# Each entry: filename, upper-left, upper-right, lower-left, lower-right, tile fill, outline, style
PALETTES = [
    ('01-aurora-glass', (26, 113, 243), (108, 57, 234), (45, 228, 205), (211, 61, 201), (237,255,255), (255,255,255), 'glass'),
    ('02-electric-sky', (13, 160, 238), (51, 95, 247), (77, 216, 255), (105, 54, 216), (224,250,255), (255,255,255), 'glass'),
    ('03-sunset-signal', (255, 128, 93), (231, 59, 156), (255, 181, 64), (102, 73, 224), (255,245,249), (255,255,255), 'soft'),
    ('04-violet-ice', (111, 100, 238), (186, 97, 228), (101, 208, 255), (117, 55, 184), (238,252,255), (255,255,255), 'glass'),
    ('05-ocean-pulse', (17, 192, 191), (21, 105, 227), (108, 239, 208), (112, 62, 213), (226,255,249), (255,255,255), 'soft'),
    ('06-pearl-future', (205, 232, 255), (224, 203, 255), (156, 232, 238), (191, 164, 245), (61,73,177), (255,255,255), 'darktile'),
    ('07-laser-lime', (133, 232, 107), (55, 180, 207), (237, 255, 112), (126, 81, 227), (242,255,244), (255,255,255), 'glass'),
    ('08-candy-circuit', (255, 148, 174), (172, 74, 237), (255, 201, 112), (65, 121, 236), (255,246,255), (255,255,255), 'soft'),
    ('09-blueprint', (54, 119, 240), (52, 62, 177), (69, 193, 236), (129, 73, 205), (228,244,255), (255,255,255), 'darktile'),
    ('10-royal-plasma', (91, 64, 216), (210, 63, 180), (56, 173, 242), (243, 95, 141), (245,240,255), (255,255,255), 'glass'),
]

TILES = [(0,0),(1,0),(2,0),(3,0),(3,1),(2,2),(1,3),(0,4),(1,4),(2,4),(3,4)]
PHASES = [0.2, 1.1, 2.3, .7, 1.8, 2.7, .5, 1.5, 2.5, .9, 2.0]

def mix(a, b, t): return tuple(int(a[i]*(1-t)+b[i]*t) for i in range(3))
def bilerp(a,b,c,d,u,v): return mix(mix(a,b,u), mix(c,d,u), v)

for idx, (name, a,b,c,d, tile, outline, style) in enumerate(PALETTES, 1):
    bg = Image.new('RGB', (N,N))
    px = bg.load()
    for y in range(N):
        v=y/(N-1)
        for x in range(N):
            u=x/(N-1)
            base=bilerp(a,b,c,d,u,v)
            # gentle radial lift toward upper-left
            lift=max(0, 1-math.hypot(u-.20,v-.15)/.78)*18
            px[x,y]=tuple(min(255,int(q+lift)) for q in base)
    rgba=bg.convert('RGBA')
    ambience=Image.new('RGBA',(N,N),(0,0,0,0)); ad=ImageDraw.Draw(ambience)
    ad.ellipse((-150,-170,520,500), fill=(255,255,255,46))
    ad.ellipse((560,570,1220,1230), fill=(255,220,255,30))
    ad.ellipse((300,260,790,750), outline=(255,255,255,32), width=4)
    rgba=Image.alpha_composite(rgba, ambience.filter(ImageFilter.GaussianBlur(40)))
    shadow=Image.new('RGBA',(N,N),(0,0,0,0)); sd=ImageDraw.Draw(shadow)
    fg=Image.new('RGBA',(N,N),(0,0,0,0)); fd=ImageDraw.Draw(fg)
    cell=122; origin=(268,268); block=94; radius=25
    for j,(gx,gy) in enumerate(TILES):
        x=origin[0]+gx*cell; y=origin[1]+gy*cell
        # fixed, intentionally imperfect elevation to make the pixel Z feel assembled
        dy=int(math.sin(PHASES[j]+idx*.31)*13)
        sd.rounded_rectangle((x+8,y+dy+20,x+block+8,y+dy+block+20),radius=radius,fill=(20,20,90,95))
        if style == 'darktile':
            fill=tile
            hi=tuple(min(255,q+32) for q in tile)
        else:
            fill=tile
            hi=(255,255,255)
        fd.rounded_rectangle((x,y+dy,x+block,y+dy+block),radius=radius,fill=fill,outline=outline,width=5)
        # glass cap / bevel
        fd.rounded_rectangle((x+9,y+dy+9,x+block-9,y+dy+37),radius=12,fill=hi+(70 if style!='darktile' else 55,))
        fd.arc((x+9,y+dy+9,x+block-9,y+dy+block-9),190,350,fill=(255,255,255,110),width=3)
    rgba=Image.alpha_composite(rgba, shadow.filter(ImageFilter.GaussianBlur(16)))
    rgba=Image.alpha_composite(rgba, fg)
    # Sparse stars: enough polish, not a pattern.
    stars=Image.new('RGBA',(N,N),(0,0,0,0)); st=ImageDraw.Draw(stars)
    for sx,sy,r in [(185,295,10),(807,217,8),(817,733,9)]:
        st.line((sx-r*2,sy,sx+r*2,sy),fill=(255,255,255,160),width=3)
        st.line((sx,sy-r*2,sx,sy+r*2),fill=(255,255,255,160),width=3)
    rgba=Image.alpha_composite(rgba, stars.filter(ImageFilter.GaussianBlur(.4)))
    rgba.convert('RGB').save(OUT / f'ziyan-pixel-z-{idx:02d}-{name}.png', quality=95)
print(OUT)
