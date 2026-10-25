"""Builds the Pixelfixo logo, launcher icon layers and social preview. Needs cairosvg and Pillow.

The mark: a small solid square (the original photo) sitting in the corner of a larger open frame (the upscaled one).
"""
import io
import cairosvg
from PIL import Image, ImageDraw, ImageFont

def glyph(c):
    return (f'<rect x="26" y="50" width="24" height="24" rx="3" fill="{c}"/>'
            f'<path d="M26 38 V30 a4 4 0 0 1 4 -4 H70 a4 4 0 0 1 4 4 V70 a4 4 0 0 1 -4 4 H62" fill="none" stroke="{c}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>')

def svg(body, bg=None, r=22):
    b = f'<rect width="100" height="100" rx="{r}" fill="{bg}"/>' if bg else ''
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">{b}{body}</svg>'

files = {
    'logo': svg(glyph('#FFFFFF'), '#000000'),            # black tile, white mark
    'logo-light': svg(glyph('#000000'), '#FFFFFF'),      # white tile, black mark
    'logo-mono': svg(glyph('#000000')),                  # bare mark
    'icon-background': svg('', '#000000', 0),
    # adaptive icon foreground keeps the mark inside the 66% safe zone
    'icon-foreground': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><g transform="translate(25 25) scale(.5)">' + glyph('#FFFFFF') + '</g></svg>',
}
for n, s in files.items():
    open(f'branding/{n}.svg', 'w').write(s)

def png(s, size, out):
    cairosvg.svg2png(bytestring=s.encode(), write_to=out, output_width=size, output_height=size)

for z in (1024, 512, 192):
    png(files['logo'], z, f'branding/logo-{z}.png')
png(files['logo-light'], 512, 'branding/logo-light-512.png')
png(files['icon-foreground'], 1024, 'branding/icon-foreground.png')
png(files['icon-background'], 1024, 'branding/icon-background.png')
# in-app: dark theme shows the white tile, light theme the black tile
png(files['logo'], 256, 'assets/logo.png')
png(files['logo-light'], 256, 'assets/logo_dark.png')

# 1280x640 social preview
W, H = 1280, 640
im = Image.new('RGB', (W, H), 'black')
d = ImageDraw.Draw(im)
for x in range(0, W, 40):
    d.line([(x, 0), (x, H)], fill=(14, 14, 14))
for y in range(0, H, 40):
    d.line([(0, y), (W, y)], fill=(14, 14, 14))
mark = Image.open(io.BytesIO(cairosvg.svg2png(bytestring=svg(glyph('#FFFFFF')).encode(), output_width=200, output_height=200))).convert('RGBA')
im.paste(mark, (110, 220), mark)
def font(size, w):
    f = ImageFont.truetype('assets/fonts/Inter.ttf', size)
    try:
        f.set_variation_by_axes([32 if size > 40 else 14, w])
    except Exception:
        pass
    return f
d.text((360, 222), 'Pixelfixo', font=font(112, 700), fill='white')
d.text((364, 366), 'Bigger, sharper photos. On your phone, offline.', font=font(34, 400), fill=(150, 150, 150))
d.line([(110, 560), (1170, 560)], fill=(38, 38, 38), width=1)
d.text((110, 578), 'Free  /  No ads  /  No account  /  Android', font=font(22, 500), fill=(110, 110, 110))
im.save('branding/social-preview.png', optimize=True)
