# Apple Emojis for Windows

Replace the Windows 11 emoji font with Apple's iOS/macOS emojis. One script to
install, one to undo. No original Windows file is ever modified or deleted.

Works in Firefox/LibreWolf too — the upstream font alone does not, see
[Firefox support](#firefox-support).

## Install

From the repository folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Approve the UAC prompt and wait for the download (~260 MB). The installer
activates the font in the running session and then reports whether that worked:
usually no reboot is needed and you just restart the apps you want updated.
Already-running apps keep the old font until relaunched.

## Restore original Windows emojis

```powershell
powershell -ExecutionPolicy Bypass -File .\restore.ps1
```

Then reboot Windows.

## Requirements

- Windows 11 (Windows 10 1803+ should also work)
- Administrator rights — the scripts self-elevate via UAC
- ~260 MB download on first install; the font is cached in `work\downloads`
- Nothing to install first: PowerShell 5.1 and `curl.exe` ship with Windows,
  and the OT-SVG build step compiles its hot loops with `Add-Type`, which ships
  with .NET Framework
- ~1.1 GB free disk: the installed font is ~345 MB and the build keeps both it
  and the 256 MB download in `work\downloads`

## How it works

Windows resolves fonts from the registry list at
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`, not by scanning
`C:\Windows\Fonts`. The installer exploits that instead of fighting the locked
system font file:

1. Downloads the latest `AppleColorEmoji-Windows.ttf` from
   [samuelngs/apple-emoji-ttf](https://github.com/samuelngs/apple-emoji-ttf) —
   a build of Apple's emoji font internally renamed to "Segoe UI Emoji", so
   every app requesting that family gets Apple glyphs.
2. Verifies the downloaded size against the GitHub release metadata. A
   truncated download produces a font DirectWrite silently rejects, which
   makes Windows fall back to old monochrome glyphs.
3. Validates the font against DirectWrite (via a WPF `GlyphTypeface` load —
   the same validator Windows uses) before touching the system.
4. Adds an OT-SVG table with `svgify.ps1` so Firefox works — see below.
5. Backs up the original `seguiemj.ttf` and a registry snapshot to
   `work\backup\`.
6. Copies the built font into `C:\Windows\Fonts` **under its own filename** —
   the original `seguiemj.ttf` stays untouched (it is memory-mapped and
   locked anyway).
7. Repoints the registry value `Segoe UI Emoji (TrueType)` at the new file
   and verifies the result.
8. Clears the Windows font cache.
9. Activates the font in the running session with `AddFontResourceEx` and a
   `WM_FONTCHANGE` broadcast, then probes from a *fresh* process which file
   `Segoe UI Emoji` actually resolves to, and reports whether a reboot is
   still needed rather than assuming.

Restoring simply points the registry value back at `seguiemj.ttf`.

### Why a reboot is usually unnecessary

Two caches sit between the registry and what you see. The **GDI session font
table** is built at logon and inherited by new processes, which never re-read
the registry — that is the part a logoff would fix, and it only matters for
legacy GDI apps, which cannot draw color emoji anyway. **DirectWrite** does not
use that table at all: it builds its collection via the FontCache service from
the registry list, so clearing that cache and starting a fresh process is
enough. Every browser, Electron app, Office and Windows UI is DirectWrite.

## Firefox support

The upstream font stores its artwork **only** in `CBDT`/`CBLC`, the OpenType
color *bitmap* format. Firefox/LibreWolf render every emoji as blank space with
that font, and the reason is not a fallback bug:

- DirectWrite does not rasterize `CBDT` for you. It hands the app the raw PNG
  bytes via `IDWriteFontFace4::GetGlyphImageData` and expects the app to blit
  them. Blink/Skia implements that; Gecko never has.
- So Gecko draws the font's `glyf` outlines instead. In a bitmap-only font
  those are 22-byte zero-area placeholders that exist only to pass validation.
- The glyph is therefore found, advance widths are correct, and nothing is
  painted. Blank, not tofu — which is also why font fallback never kicks in.

Gecko *does* implement OT-SVG on every platform, and an OT-SVG glyph document
may embed a raster image. `svgify.ps1` re-wraps each PNG from the largest CBDT
strike (96 ppem) as an `<image>` with a `data:` URI inside an `SVG ` table, and
splices that table into the font **alongside the untouched CBDT**. Each engine
then picks the format it can render:

| Engine | Format used |
|---|---|
| Gecko (Firefox, LibreWolf, Tor Browser) | `SVG ` |
| Blink/Skia (Chrome, Edge, Brave, Electron) | `CBDT` — unchanged |
| Direct2D (Windows apps) | either; both are supported natively |

Blink is unaffected because Skia's DirectWrite backend does try SVG before PNG,
but `drawSVGImage` bails out at `if (!svgFactory)` — Chromium never registers
an OT-SVG decoder — so it falls through to the CBDT strike exactly as before.
Verified by rendering the same page against the installed system font in both
LibreWolf and a Chromium browser: Gecko goes from blank to Apple emoji, Blink
is pixel-for-pixel unchanged.

The Direct2D row is the one claim here that has **not** been measured. It rests
on the API contract — an app passes `IDWriteFontFace4::GetGlyphImageFormats` a
mask of the formats it supports, so an app that cannot draw SVG never receives
it — plus the fact that Direct2D has rendered OT-SVG natively since Windows 10
1703. If some Windows app does regress, `restore.ps1` reverts it.

The splice is done at the sfnt binary level rather than by recompiling the font,
so all 22 original tables — including Apple's `morx`, `bgcl`, `feat` and `trak`
— are copied byte for byte. The font grows from 256 MB to 345 MB, and the build
takes about 3 seconds.

A few glyphs are missing from individual strikes — 20 ligature-only ones (ZWJ
sequences, skin tones) are absent at 96 ppem but present everywhere else — so
each glyph falls back to the largest strike that actually has it. The SVG table
ends up covering exactly the same 6,261 glyphs as CBDT, which is what stops
Firefox showing a blank where Chrome shows art.

You can rebuild it by hand, optionally from a smaller strike for a smaller font:

```powershell
.\svgify.ps1 -InputFont .\work\downloads\AppleColorEmoji-Windows.ttf -OutputFont out.ttf
.\svgify.ps1 -InputFont .\work\downloads\AppleColorEmoji-Windows.ttf -OutputFont out.ttf -Ppem 64
```

### Known limits of the OT-SVG path

These affect Firefox only, and are inherent to Gecko's OT-SVG implementation
rather than to this font:

- A text run containing an OT-SVG glyph opts out of WebRender's GPU glyph cache
  and is rasterized in a software fallback blob. Pages that are mostly emoji
  paint more slowly than they would with a `COLR` font.
- Emoji drawn through `OffscreenCanvas` **in a worker** are still blank:
  Gecko's SVG-glyph lookup hard-returns false off the main thread.
- Emoji may be blank for one frame while the embedded PNG decodes.
- Vertical placement is baked from the 96 ppem strike, whose bearing ratio
  differs from the smaller strikes by up to 0.0375 em. Firefox can sit a
  fraction of an em off from Chrome at some sizes.

## Repository layout

```
install.ps1   installer (self-elevating, idempotent, logs to work\install.log)
restore.ps1   undo script (logs to work\restore.log)
svgify.ps1    adds the OT-SVG table that makes Firefox/LibreWolf work
work\         runtime only, gitignored: download cache, backups, logs
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Old monochrome emojis after reboot | Font failed validation or download was incomplete. Check `work\install.log`, rerun `install.ps1` — it re-verifies and re-downloads on size mismatch. |
| Emojis reverted after a Windows feature update | The update re-registered the original font. Rerun `install.ps1`. |
| Some apps show black-and-white emojis | Legacy GDI-only apps cannot render the CBDT color format. All DirectWrite apps (browsers, Discord, Office, Windows UI) show color. |
| Blank emojis in Firefox/LibreWolf | The OT-SVG table is missing — you installed with `-NoSvg`, or on an older version of this repo. Rerun `install.ps1` without `-NoSvg`, then restart the browser. See [Firefox support](#firefox-support). |
| Emojis unchanged in an app that was already open | Font collections are built per process at startup. Restart that app; nothing else is needed. |
| Upgrading to a newer emoji release | The active font file cannot be overwritten. Run `restore.ps1`, reboot, run `install.ps1`, reboot. |

## Sources and credits

- Font build: [samuelngs/apple-emoji-ttf](https://github.com/samuelngs/apple-emoji-ttf)
  — converts Apple Color Emoji for Linux, Windows, and the web. This project
  downloads its release asset at install time.
- Registry-based font replacement technique:
  [jadenkiu/revert-windows-11-emojis](https://github.com/jadenkiu/revert-windows-11-emojis),
  [Microsoft Q&A: How to change Windows 11 default emojis](https://learn.microsoft.com/en-us/answers/questions/4000000/how-to-change-windows-11-default-emojis)
- Family-name replacement concept:
  [perguto/Country-Flag-Emojis-for-Windows](https://github.com/perguto/Country-Flag-Emojis-for-Windows)
- Windows font table requirements for converted emoji fonts:
  [jjjuk/emoji-win](https://github.com/jjjuk/emoji-win)
- Monochrome fallback symptom:
  [samuelngs/apple-emoji-ttf#118](https://github.com/samuelngs/apple-emoji-ttf/issues/118)
- OT-SVG table format and its coordinate system:
  [OpenType spec: SVG table](https://learn.microsoft.com/en-us/typography/opentype/spec/svg)
- Gecko's color-glyph precedence (`SVG ` before `COLR`, no CBDT path):
  [gfxFont.cpp `DrawOneGlyph`](https://searchfox.org/mozilla-central/source/gfx/thebes/gfxFont.cpp)
- Prior art for bitmap-to-OT-SVG conversion:
  [Bits'N'Picas](https://github.com/kreativekorp/bitsnpicas) (whose docs also
  report gzipped SVG glyph documents failing in Firefox — this project leaves
  them uncompressed)

## Legal

- Apple emoji artwork is copyrighted by Apple Inc. This repository does **not**
  distribute the font; it is downloaded by the user at install time from the
  source above. Use only where legally permitted.
- Not affiliated with Apple or Microsoft. "Segoe" is a trademark of Microsoft.
