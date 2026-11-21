# Pakperk product page

A static page that shows what the app does, in English and Chinese. No
framework and no external requests; the only JavaScript is `app.js`, which adds
motion and nothing else — the page is complete without it.

Live at `https://www.pakperk.website/site/` (`/site/zh/` for Chinese, `/`
redirects to the English page).

## Layout

| Path | What it is |
| --- | --- |
| `build.py` | Renders both languages from one copy deck. **Edit this, not the HTML.** |
| `index.html`, `zh/index.html` | Generated. Do not hand-edit. |
| `styles.css`, `app.js` | Hand-maintained. |
| `assets/` | Brand marks, app icon, and the app screenshots. |
| `download/` | The published APK. Gitignored; lives on the server. |
| `Caddyfile.proposed` | A copy of the server config that serves all of this. |

Regenerate after changing copy:

```bash
python3 landing/build.py
```

## Design source of truth

Every visual token is copied from the Flutter client so the page and the app
cannot drift:

| Page | App |
| --- | --- |
| `--paper`, `--ink`, `--moss`, `--ochre`, `--outline`, dark equivalents | `mobile/lib/design_system/colors.dart` |
| `.display` / `.headline` / `.title` / `.body` sizes, weights, letter-spacing | `mobile/lib/design_system/typography.dart` |
| `--r-xs` … `--r-pill` | `mobile/lib/design_system/radii.dart` |
| flat cards, 1px outlines, no shadows | `mobile/lib/design_system/elevation.dart` |
| `--prose` 760px, `--tap` 48px | `mobile/lib/design_system/sizes.dart` |
| the mark in the header and footer | `mobile/assets/brand/pakperk_mark.svg` |

Light and dark follow `prefers-color-scheme` using the app's own dark palette.
When a design token changes in the app, change it here too.

## Screenshots

`assets/shots/*.webp` are real captures from an Android device running the dev
flavor against this server, resized to 600px wide. The paper is
arXiv:2505.13425, which was fully prepared at capture time. To retake them, see
the emulator recipe in `docs/mobile-device-development.md`, then:

```bash
magick <capture>.png -resize 600x -strip out.png && cwebp -q 86 out.png -o out.webp
```

Connections has no screenshot because the stage had no generated content on
this server when these were taken (`/v1/papers/{id}/connections` returns
`ready: false`). Add one when it does.

## Motion

`app.js` reveals sections on scroll, cycles the highlight across the three
stage cards, and bobs the gesture arrow. It animates `transform` and `opacity`
only, pauses looping animations off-screen, and turns everything off under
`prefers-reduced-motion: reduce`. The `.reveal` start state is scoped behind the
`.js` class the script adds, so a browser with JavaScript disabled shows the
finished page rather than a blank one.

## Deploying

Content only (never touches the APK or Caddy):

```bash
rsync -a --delete --exclude 'download/' --exclude 'Caddyfile.proposed' --exclude 'README.md' --exclude 'build.py' landing/ admin@www.pakperk.website:~/pakperk-site-staging/
ssh admin@www.pakperk.website "sudo rsync -a --delete --exclude 'download/' ~/pakperk-site-staging/ /var/www/pakperk-site/ && sudo chown -R root:root /var/www/pakperk-site && sudo find /var/www/pakperk-site -type f -exec chmod 644 {} + && sudo find /var/www/pakperk-site -type d -exec chmod 755 {} +"
```

`--exclude download/` matters: without it the rsync deletes the published APK.

A new APK (update `APK` in `build.py` to match, then rerun it):

```bash
scp <apk> admin@www.pakperk.website:~/pakperk-apk-upload/pakperk-<version>.apk
ssh admin@www.pakperk.website 'sudo install -m 644 -o root -g root ~/pakperk-apk-upload/pakperk-<version>.apk /var/www/pakperk-site/download/ && sudo sha256sum /var/www/pakperk-site/download/pakperk-<version>.apk'
```

Caddy needs no reload for either. It only changes when `Caddyfile.proposed`
does; the previous config is kept at `/etc/caddy/Caddyfile.pre-landing-20260921`.

## Notes

- `robots.txt` and the `noindex` meta tag keep the private test host out of
  search engines. Remove both when the page becomes public. They do not make
  the URL secret — anyone with the link can download the APK.
- The published APK is the dev flavor and points at this test server. It is
  arm64-only: `armeabi-v7a` and `x86_64` carry two small plugin libraries but no
  Flutter engine, so a 32-bit-only device would crash at launch.
