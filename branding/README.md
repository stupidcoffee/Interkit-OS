Brand assets (sources) and where they are used by the build:

- logo-dark-1024.png / logo-light-1024.png : the interkit logo (white on transparent). Both currently hold the same
  image (from Pic_3 2.png); the earlier iOS-style rounded-square icons were replaced.
- wallpaper.png : 16:9 wallpaper (not used yet)
- logo-dark-256.png : embedded (base64) in config/bootloaders/splash.svg and installer-banner
- config/bootloaders/splash.svg            -> GRUB boot splash (replaces live-build's yellow hard hat). live-build
                                              fills @VERSION@, @ARCHITECTURE@, ... at build time.
- config/includes.installer/.../logo_debian{,_dark}.png -> graphical installer banner (800x75)
- config/includes.chroot/usr/share/pixmaps/debian-logo.png -> 48x48 icon (owned by the debconf package;
                                              a debconf upgrade could overwrite it)
- wallpaper.png is not used yet (no desktop in the image).

## Inter Mono (splash only)

Inter Mono (Renzhi Li; SIL Open Font License 1.1) is used only to render the boot splash text. It is **not** used for the GRUB
menu or the Linux console any more: the rasterized bitmap fonts looked blurry. GRUB uses its built-in Unifont (crisp pixel font)
and the console keeps the stock Debian font.
Look: the Debian text installer's default blue theme everywhere. GRUB uses plain text colours (`theme.cfg`, `10-interkit.cfg`: white on
blue, gray bars, red selection) and the tty gets `vt.color=0x1f` (white on blue) from `build.sh`.
`config/includes.chroot/usr/share/fonts/truetype/inter-mono/InterMono-Regular.ttf` lets the build render the splash text
(`splash.svg` uses `Inter Mono, DejaVu Sans`). `mkpsf.py` is kept for reference; nothing loads its output.
- `config/bootloaders/grub-pc/` - theme override: `theme.cfg`.
- `installer-banner.png` is a rendered image of the word "interkit".
