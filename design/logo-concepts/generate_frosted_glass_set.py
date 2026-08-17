from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import math

OUT = Path('/Users/mac/Desktop/ZiYan_副本/design/logo-concepts/frosted-glass')
OUT.mkdir(parents=True, exist_ok=True)
N=1024
SETS=[
 ('01-cyan-violet',(14,176,245),(104,55,224),(48,235,202),(218,63,188)),
 ('02-rose-ice',(255,135,181),(147,94,234),(255,196,135),(68,142,238)),
 ('03-arctic-blue',(102,225,247),(49,111,225),(194,244,255),(130,80,223)),
]
TILES=[(0,0),(1,0),(2,0),(3,0),(3,1),(2,2),(1,3),(0,4),(1,4),(2,4),(3,4)]
PHASE=[-7,5,-4,8,-6,3,-8,7,-2,6,-5]
def mix(a,b,t): return tuple(int(a[i]*(1-t)+b[i]*t) for i in range(3))
def quad(a,b,c,d,u,v): return mix(mix(a,b,u),mix(c,d,u),v)
for n,(name,a,b,c,d) in enumerate(SETS,1):
 bg=Image.new('RGB',(N,N)); p=bg.load()
 for y in range(N):
  v=y/(N-1)
  for x in range(N):
   u=x/(N-1); color=quad(a,b,c,d,u,v)
   glow=max(0,1-math.hypot(u-.22,v-.12)/.9)*20
   p[x,y]=tuple(min(255,int(k+glow)) for k in color)
 bg=bg.convert('RGBA')
 lights=Image.new('RGBA',(N,N),(0,0,0,0)); ld=ImageDraw.Draw(lights)
 ld.ellipse((-180,-160,520,510),fill=(255,255,255,63)); ld.ellipse((520,560,1230,1260),fill=(255,225,255,50))
 bg=Image.alpha_composite(bg,lights.filter(ImageFilter.GaussianBlur(75)))
 blur=bg.filter(ImageFilter.GaussianBlur(22))
 shadows=Image.new('RGBA',(N,N),(0,0,0,0)); sd=ImageDraw.Draw(shadows)
 glass=Image.new('RGBA',(N,N),(0,0,0,0)); gd=ImageDraw.Draw(glass)
 cell=122; ox=268; oy=268; s=94
 for i,(gx,gy) in enumerate(TILES):
  x=ox+gx*cell; y=oy+gy*cell+PHASE[i]
  # softly blurred background is clipped into every tile for actual translucency
  mask=Image.new('L',(N,N),0); md=ImageDraw.Draw(mask); md.rounded_rectangle((x,y,x+s,y+s),radius=25,fill=188)
  clipped=Image.new('RGBA',(N,N),(0,0,0,0)); clipped.paste(blur,(0,0),mask)
  glass=Image.alpha_composite(glass,clipped)
  sd.rounded_rectangle((x+12,y+28,x+s+12,y+s+28),radius=25,fill=(24,23,104,100))
  # translucent milk-glass layer, bevel, and inner reflection.
  gd.rounded_rectangle((x,y,x+s,y+s),radius=25,fill=(235,250,255,76),outline=(255,255,255,210),width=5)
  gd.rounded_rectangle((x+9,y+9,x+s-9,y+38),radius=13,fill=(255,255,255,100))
  gd.arc((x+8,y+8,x+s-8,y+s-8),188,354,fill=(255,255,255,165),width=3)
 bg=Image.alpha_composite(bg,shadows.filter(ImageFilter.GaussianBlur(18)))
 bg=Image.alpha_composite(bg,glass)
 bg=Image.alpha_composite(bg,glass.filter(ImageFilter.GaussianBlur(.25)))
 # sharper highlight pass
 bg=Image.alpha_composite(bg,Image.new('RGBA',(N,N),(0,0,0,0)))
 hi=Image.new('RGBA',(N,N),(0,0,0,0)); hd=ImageDraw.Draw(hi)
 for i,(gx,gy) in enumerate(TILES):
  x=ox+gx*cell; y=oy+gy+PHASE[i]
  hd.rounded_rectangle((x,y,x+s,y+s),radius=25,outline=(255,255,255,175),width=4)
 bg=Image.alpha_composite(bg,hi)
 bg.convert('RGB').save(OUT/f'ziyan-frosted-glass-{n:02d}-{name}.png',quality=95)
print(OUT)
