# Rasterize a monospace font (default: Inter Mono, SIL OFL) into a Linux console font (PSF2, exactly 256 glyphs, code-point positions).
#   python3 branding/mkpsf.py Regular 10 20 config/includes.chroot/usr/share/consolefonts/InterMono-10x20.psf
# Needs Pillow and <FONT_FAMILY>-Regular.ttf in FONT_DIR (default InterMono in ~/Library/Fonts).

import sys, struct
from PIL import Image, ImageDraw, ImageFont
import os
FONT_DIR=os.environ.get("FONT_DIR",os.path.expanduser("~/Library/Fonts")); FAMILY=os.environ.get("FONT_FAMILY","InterMono")
def TTF_for(weight):
    p=os.path.join(FONT_DIR,"%s-%s.ttf"%(FAMILY,weight))
    return p if os.path.exists(p) else os.path.join(FONT_DIR,"%s-Regular.ttf"%FAMILY)
# box drawing / blocks that go into the otherwise unused control-code positions
EXTRA=list("─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬━┃┏┓┗┛▀▄█░▒▓■▌▐")
def build_psf2(weight,W,H,path,thr=110):
    probe=ImageFont.truetype(TTF_for(weight),100); adv=probe.getlength('M')/100.0
    f=ImageFont.truetype(TTF_for(weight),W/adv); asc,desc=f.getmetrics(); y0=max(0,(H-(asc+desc))//2)
    def render(ch):
        im=Image.new('L',(W,H),0); ImageDraw.Draw(im).text((0,y0),ch,font=f,fill=255)
        return im.point(lambda v:255 if v>=thr else 0)
    slots=[None]*256                      # exactly 256 glyphs, position = code point where possible
    for c in list(range(0x20,0x7f))+list(range(0xa0,0x100)): slots[c]=chr(c)
    free=[p for p in list(range(1,32))+list(range(0x7f,0xa0)) if slots[p] is None]
    for ch,p in zip(EXTRA,free): slots[p]=ch
    rowb=(W+7)//8; charsize=rowb*H; body=b''; table=b''
    for p in range(256):
        ch=slots[p]
        im=render(ch) if ch else Image.new('L',(W,H),0); px=im.load()
        for y in range(H):
            for bx in range(rowb):
                v=0
                for b in range(8):
                    x=bx*8+b
                    if x<W and px[x,y]: v|=0x80>>b
                body+=bytes([v])
        table+=(ch.encode('utf-8') if ch else b'')+b'\xff'
    hdr=struct.pack('<IIIIIIII',0x864ab572,0,32,1,256,charsize,H,W)
    open(path,'wb').write(hdr+body+table)
    return len([s for s in slots if s]),W/adv
if __name__=='__main__':
    n,size=build_psf2(sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),sys.argv[4])
    print(f"{sys.argv[4]}: 256 glyph slots ({n} drawn), font px {size:.1f}")
