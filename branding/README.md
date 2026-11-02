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

## Inter Mono (system font)

Inter Mono (Renzhi Li; SIL Open Font License 1.1, https://openfontlicense.org/) is used for the boot menu, the boot splash,
the Linux text console and the installed system's GRUB. Only the Regular weight exists; bold is synthesized.
The font **files are kept out of Fossil**: the OFL requires the licence text to travel with every copy of the font, and this
repository does not carry that text yet. The licence allows bundling and redistributing, so adding the OFL text next to the
TTF would let CI builds include it. Clean checkouts (CI) fall back to GRUB's default font and DejaVu Sans.

Local-only files (ignored by Fossil):
- `config/includes.chroot/usr/share/fonts/truetype/inter-mono/InterMono-Regular.ttf` - lets the build render the splash text
  (`splash.svg` uses `Inter Mono, DejaVu Sans`).
- `config/bootloaders/grub-pc/` - theme override: `theme.cfg`, `live-theme/theme.txt`, `live-theme/intermono-{Regular,Bold}-16.pf2`
  (made with `grub-mkfont [-b] -s 16 -r 0x20-0x7e,0xa0-0xff,0x2190-0x2193,0x2500-0x25ff`).
- `config/includes.chroot/boot/grub/fonts/intermono-Regular-16.pf2` + tracked `etc/default/grub.d/10-interkit.cfg`: the installed
  system's GRUB font (and a visible menu); `etc/grub.d/41_interkit_font` adds GRUB's unicode font as a fallback.
- `config/includes.chroot/usr/share/consolefonts/InterMono-{10x20,16x32}.psf` - console fonts made by `branding/mkpsf.py`
  (Linux console fonts must have exactly 256 glyphs). `interkit-console-font.service` loads one on tty1-6 at boot:
  16x32 on framebuffers 1920 px wide or more, else 10x20 (the unit needs `kbd`'s `setfont`).
- `installer-banner.png` is a rendered image of the word "interkit".
