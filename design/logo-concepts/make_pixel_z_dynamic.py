from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import math

out = Path('/Users/mac/Desktop/ZiYan_副本/design/logo-concepts/ziyan-logo-19-pixel-z-dynamic.gif')
size = 512
tiles = [(130,130),(187,130),(244,130),(301,130),(301,187),(244,244),(187,301),(130,358),(187,358),(244,358),(301,358)]
frames=[]
for frame in range(32):
    t=frame/32*2*math.pi
    im=Image.new('RGB',(size,size))
    p=im.load()
    for y in range(size):
        for x in range(size):
            u=x/(size-1); v=y/(size-1)
            # saturated blue-violet-magenta background
            p[x,y]=(int(26+160*u+24*v),int(64+13*u+10*v),int(186-55*u+18*v))
    glow=Image.new('RGBA',(size,size),(0,0,0,0)); gd=ImageDraw.Draw(glow)
    for cx,cy,phase in [(88,80,0),(432,404,1.4)]:
        r=100+int(15*math.sin(t+phase)); gd.ellipse((cx-r,cy-r,cx+r,cy+r),fill=(160,255,255,24))
    im=Image.alpha_composite(im.convert('RGBA'),glow.filter(ImageFilter.GaussianBlur(45)))
    lay=Image.new('RGBA',(size,size),(0,0,0,0)); d=ImageDraw.Draw(lay)
    for idx,(x,y) in enumerate(tiles):
        dy=int(10*math.sin(t*1.2+idx*0.76))
        # diffuse glow
        d.rounded_rectangle((x-6,y+dy-6,x+52,y+dy+52),radius=14,fill=(202,250,255,55))
    lay=lay.filter(ImageFilter.GaussianBlur(11)); im=Image.alpha_composite(im,lay)
    fg=Image.new('RGBA',(size,size),(0,0,0,0)); d=ImageDraw.Draw(fg)
    for idx,(x,y) in enumerate(tiles):
        dy=int(10*math.sin(t*1.2+idx*0.76))
        d.rounded_rectangle((x,y+dy,x+46,y+dy+46),radius=10,fill=(227,252,255,255),outline=(255,255,255,235),width=2)
        d.rounded_rectangle((x+4,y+dy+4,x+42,y+dy+19),radius=6,fill=(255,255,255,104))
    # small moving sparkle
    sx=75+int((frame/31)*360); sy=90+int(18*math.sin(t*2))
    d.line((sx-16,sy,sx+16,sy),fill=(255,255,255,170),width=3);d.line((sx,sy-16,sx,sy+16),fill=(255,255,255,170),width=3)
    frames.append(Image.alpha_composite(im,fg).convert('RGB'))
frames[0].save(out,save_all=True,append_images=frames[1:],duration=75,loop=0,optimize=False)
print(out)
