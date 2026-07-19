# Apple Emojis for Windows

Replace the Windows 11 emoji font with Apple's iOS/macOS emojis. One script to
install, one to undo. No original Windows file is ever modified or deleted.

## Install

From the repository folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Approve the UAC prompt, wait for the download (~260 MB), then reboot Windows.

## Restore original Windows emojis

```powershell
powershell -ExecutionPolicy Bypass -File .\restore.ps1
```

Then reboot Windows.

## Requirements

- Windows 11 (Windows 10 1803+ should also work)
- Administrator rights — the scripts self-elevate via UAC
- ~260 MB download on first install; the font is cached in `work\downloads`
- Nothing to install first: PowerShell 5.1 and `curl.exe` ship with Windows

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
4. Backs up the original `seguiemj.ttf` and a registry snapshot to
   `work\backup\`.
5. Copies the Apple font into `C:\Windows\Fonts` **under its own filename** —
   the original `seguiemj.ttf` stays untouched (it is memory-mapped and
   locked anyway).
6. Repoints the registry value `Segoe UI Emoji (TrueType)` at the new file
   and verifies the result.
7. Clears the Windows font cache.

Restoring simply points the registry value back at `seguiemj.ttf`.

## Repository layout

```
install.ps1   installer (self-elevating, idempotent, logs to work\install.log)
restore.ps1   undo script (logs to work\restore.log)
work\         runtime only, gitignored: download cache, backups, logs
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Old monochrome emojis after reboot | Font failed validation or download was incomplete. Check `work\install.log`, rerun `install.ps1` — it re-verifies and re-downloads on size mismatch. |
| Emojis reverted after a Windows feature update | The update re-registered the original font. Rerun `install.ps1`. |
| Some apps show black-and-white emojis | Legacy GDI-only apps cannot render the CBDT color format. All DirectWrite apps (browsers, Discord, Office, Windows UI) show color. |
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

## Legal

- Apple emoji artwork is copyrighted by Apple Inc. This repository does **not**
  distribute the font; it is downloaded by the user at install time from the
  source above. Use only where legally permitted.
- Not affiliated with Apple or Microsoft. "Segoe" is a trademark of Microsoft.
