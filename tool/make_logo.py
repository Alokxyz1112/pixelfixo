"""Builds every logo file from one SVG. Needs: pip install cairosvg pillow"""
import cairosvg, io, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter
os.chdir(os.path.join(os.path.dirname(__file__), '..'))
A, B = '#7C3AED', '#06B6D4'
def glyph(fill='#FFFFFF'):
    # A "P": the stem is chunky pixels that get cleaner toward the top, the bowl is one smooth curve.
    px = ''.join(f'<rect x="{x}" y="{y}" width="{s}" height="{s}" rx="{r}" fill="{fill}" opacity="{o}"/>' for x, y, s, r, o in [
        (140, 128, 60, 14, 1), (140, 196, 60, 14, 1), (140, 264, 60, 10, 1), (140, 332, 60, 6, 1),
        (104, 400, 28, 4, .55), (148, 404, 24, 4, .8), (180, 432, 18, 3, .4)])
    bowl = f'<path d="M222 158 H286 A70 70 0 0 1 286 298 H222" fill="none" stroke="{fill}" stroke-width="60" stroke-linecap="round"/>'
    spark = f'<path d="M384 96 l9 23 23 9 -23 9 -9 23 -9 -23 -23 -9 23 -9z" fill="{fill}"/>'
    return px + bowl + spark
grad = f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{A}"/><stop offset="1" stop-color="{B}"/></linearGradient></defs>'
logo = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">{grad}<rect width="512" height="512" rx="116" fill="url(#g)"/>{glyph()}</svg>'
mono = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">{glyph("#000000")}</svg>'
# adaptive icon: 108dp canvas, keep the glyph inside the middle 66dp
fg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><g transform="translate(256 256) scale(0.62) translate(-268 -280)">{glyph()}</g></svg>'
bg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">{grad}<rect width="512" height="512" fill="url(#g)"/></svg>'
for n, s in [('logo', logo), ('logo-mono', mono), ('icon-foreground', fg), ('icon-background', bg)]:
    open(f'branding/{n}.svg', 'w').write(s)
def png(svg, size, out): cairosvg.svg2png(bytestring=svg.encode(), write_to=out, output_width=size, output_height=size)
for z in (512, 1024, 192):
    png(logo, z, f'branding/logo-{z}.png')
png(fg, 1024, 'branding/icon-foreground.png'); png(bg, 1024, 'branding/icon-background.png')
png(logo, 512, 'assets/logo.png')
# social preview 1280x640
W, H = 1280, 640
bgsvg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}"><defs><linearGradient id="h" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0F0B1F"/><stop offset="1" stop-color="#0A1A22"/></linearGradient></defs><rect width="{W}" height="{H}" fill="url(#h)"/></svg>'
im = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=bgsvg.encode()))).convert('RGBA')
d = ImageDraw.Draw(im)
# a row of pixels that go from blocky to smooth
x = 524
for i in range(12):
    r = int(2 + i * 2.2); sz = 30
    d.rounded_rectangle([x, 470, x + sz, 470 + sz], radius=min(r, sz // 2), fill=(124 - i * 8, 58 + i * 11, 237 - i * 3, 230 - i * 8))
    x += sz + 12
glow = Image.new('RGBA', (W, H)); ImageDraw.Draw(glow).ellipse([60, 120, 460, 520], fill=(124, 58, 237, 110)); im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(80)))
lg = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=logo.encode(), output_width=340, output_height=340))).convert('RGBA')
im.alpha_composite(lg, (110, 150))
f1 = ImageFont.truetype('assets/fonts/SpaceGrotesk.ttf', 112); f1.set_variation_by_axes([700])
f2 = ImageFont.truetype('assets/fonts/Inter.ttf', 36); f2.set_variation_by_axes([14, 450])
d.text((520, 210), 'Pixelfixo', font=f1, fill='white')
d.text((524, 350), 'Make small photos big and sharp.', font=f2, fill=(205, 210, 230))
d.text((524, 398), 'On your phone. Free, offline, no limits.', font=f2, fill=(150, 160, 185))
im.convert('RGB').save('branding/social-preview.png', optimize=True)
