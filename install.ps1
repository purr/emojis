param(
    [switch]$SkipDownload,
    [switch]$NoSvg,
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkDir = Join-Path $PSScriptRoot "work"
$logFile = Join-Path $WorkDir "install.log"

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Requesting administrator permission (UAC)..." -ForegroundColor Yellow
        $argList = @(
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-Elevated"
        )
        if ($SkipDownload) {
            $argList += "-SkipDownload"
        }
        if ($NoSvg) {
            $argList += "-NoSvg"
        }
        try {
            $proc = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList -Wait -PassThru
        }
        catch {
            Write-Host "Administrator permission denied. Nothing was changed." -ForegroundColor Red
            exit 1
        }
        if (Test-Path -LiteralPath $logFile) {
            Get-Content -LiteralPath $logFile | Write-Host
        }
        exit $proc.ExitCode
    }
}

function Write-Log([string]$message, [string]$color = "Cyan") {
    Write-Host $message -ForegroundColor $color
    Add-Content -LiteralPath $logFile -Value $message
}

# DirectWrite must accept the font, otherwise Windows silently drops the
# family and falls back to old monochrome Segoe UI Symbol glyphs.
function Assert-DirectWrite([string]$path, [string]$label) {
    Add-Type -AssemblyName PresentationCore
    try {
        $fontUri = "file:///" + $path.Replace('\', '/')
        $typeface = New-Object System.Windows.Media.GlyphTypeface($fontUri)
        Write-Log "[OK]   DirectWrite accepts $label`: $($typeface.FamilyNames.Values -join ', ') ($($typeface.GlyphCount) glyphs)" Green
    }
    catch {
        throw "DirectWrite rejects $label (would render as monochrome fallback): $($_.Exception.Message)"
    }
}

# Two caches stand between the registry entry and what apps actually draw:
#
#   GDI session font table - built at logon from the registry list. New
#     processes inherit it rather than re-reading the registry, so a registry
#     edit alone stays invisible to GDI until the next logon. AddFontResourceEx
#     plus a WM_FONTCHANGE broadcast mutates it in place.
#   DirectWrite - does not use the GDI table. It builds its font collection via
#     the FontCache service from the registry list, so clearing that cache and
#     starting a fresh process is enough. Every browser is in this category.
#
# Best effort: a failure here is not fatal, because the registry entry is
# already correct and a reboot would apply it regardless.
function Enable-FontNow([string]$path) {
    if (-not ('NativeFont' -as [type])) {
        Add-Type -Namespace '' -Name NativeFont -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int AddFontResourceExW(string file, uint flags, IntPtr pdv);
[DllImport("user32.dll", SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam,
    IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
'@
    }
    $added = [NativeFont]::AddFontResourceExW($path, 0, [IntPtr]::Zero)
    $result = [UIntPtr]::Zero
    # HWND_BROADCAST = 0xFFFF, WM_FONTCHANGE = 0x1D, SMTO_ABORTIFHUNG = 0x2
    [void][NativeFont]::SendMessageTimeout([IntPtr]0xFFFF, 0x1D, [IntPtr]::Zero,
        [IntPtr]::Zero, 0x2, 5000, [ref]$result)
    return $added
}

# Ask a FRESH process which file now backs the family. This process built its
# own font collection before the change, so asking in-process proves nothing.
#
# The child script goes over as -EncodedCommand rather than -Command. Windows
# PowerShell re-parses a -Command string through native argument splitting,
# which eats the quotes around "Segoe UI Emoji" and kills the child with "The
# term 'Segoe' is not recognized"; base64 survives that round trip intact.
# The child also silences its own error and progress streams instead of the
# parent redirecting with 2>$null: anything a native command writes to stderr
# raises a terminating NativeCommandError under $ErrorActionPreference = Stop,
# and because stdout is captured here, a progress record would be serialized as
# CLIXML onto stderr and trip exactly that.
function Get-ActiveEmojiFontFile {
    $probe = @'
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationCore
$family = New-Object System.Windows.Media.FontFamily("Segoe UI Emoji")
foreach ($tf in $family.GetTypefaces()) {
    $gt = $null
    if ($tf.TryGetGlyphTypeface([ref]$gt)) { Write-Output $gt.FontUri.AbsoluteUri }
}
'@
    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        return @($out | Where-Object { $_ })
    }
    catch { return @() }
}

Assert-Admin

$releaseApi = "https://api.github.com/repos/samuelngs/apple-emoji-ttf/releases/latest"
$fontValueName = "Segoe UI Emoji (TrueType)"
$fontRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
$fontsDir = Join-Path $env:windir "Fonts"
$appleFontName = "AppleColorEmoji-Windows.ttf"
$svgFontName = "AppleColorEmoji-SVG.ttf"
$backupDir = Join-Path $WorkDir "backup"
$downloadDir = Join-Path $WorkDir "downloads"
$downloadedFont = Join-Path $downloadDir $appleFontName
$svgFont = Join-Path $downloadDir $svgFontName
$svgifyScript = Join-Path $PSScriptRoot "svgify.ps1"

New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
Set-Content -LiteralPath $logFile -Value "=== install run $(Get-Date -Format s) ==="

try {
    if (-not $SkipDownload) {
        Write-Log "[INFO] Fetching latest release metadata"
        $release = Invoke-RestMethod -Uri $releaseApi -Headers @{ "User-Agent" = "apple-emoji-installer" }
        $asset = $release.assets | Where-Object { $_.name -eq $appleFontName } | Select-Object -First 1
        if ($null -eq $asset) {
            throw "Could not find $appleFontName in latest release assets."
        }
        $haveSize = if (Test-Path -LiteralPath $downloadedFont) { (Get-Item -LiteralPath $downloadedFont).Length } else { 0 }
        if ($haveSize -ne $asset.size) {
            Write-Log "[INFO] Downloading $($asset.name) ($([math]::Round($asset.size / 1MB)) MB)"
            & curl.exe -L --progress-bar --retry 3 --retry-delay 2 -o $downloadedFont $asset.browser_download_url
            $gotSize = (Get-Item -LiteralPath $downloadedFont).Length
            if ($gotSize -ne $asset.size) {
                throw "Download truncated: got $gotSize bytes, expected $($asset.size). Rerun the installer."
            }
            # Source changed, so any previously built SVG variant is stale.
            if (Test-Path -LiteralPath $svgFont) {
                Remove-Item -LiteralPath $svgFont -Force
            }
        }
    }
    if (-not (Test-Path -LiteralPath $downloadedFont)) {
        throw "Font file missing: $downloadedFont"
    }

    Write-Log "[INFO] Validating downloaded font against DirectWrite"
    Assert-DirectWrite $downloadedFont "downloaded font"

    # The upstream font is CBDT/CBLC only. Gecko does not rasterize CBDT on
    # Windows, so Firefox/LibreWolf draw the font's zero-area placeholder
    # outlines and every emoji comes out blank. svgify.ps1 adds an OT-SVG table
    # carrying the same PNG artwork, which Gecko does render, while leaving
    # CBDT untouched for Blink and Direct2D.
    $installFontName = $appleFontName
    $sourceFont = $downloadedFont
    if ($NoSvg) {
        Write-Log "[WARN] -NoSvg specified: installing CBDT-only font. Emojis will be blank in Firefox/LibreWolf." Yellow
    }
    else {
        if (-not (Test-Path -LiteralPath $svgifyScript)) {
            throw "Missing $svgifyScript - it builds the OT-SVG table that makes emojis render in Firefox/LibreWolf. Restore it from the repository, or rerun with -NoSvg to install the CBDT-only font."
        }
        $needsBuild = $true
        if (Test-Path -LiteralPath $svgFont) {
            $svgTime = (Get-Item -LiteralPath $svgFont).LastWriteTimeUtc
            $srcTime = (Get-Item -LiteralPath $downloadedFont).LastWriteTimeUtc
            $scriptTime = (Get-Item -LiteralPath $svgifyScript).LastWriteTimeUtc
            if ($svgTime -gt $srcTime -and $svgTime -gt $scriptTime) {
                Write-Log "[INFO] Reusing existing $svgFontName (newer than source and svgify.ps1)"
                $needsBuild = $false
            }
        }
        if ($needsBuild) {
            Write-Log "[INFO] Building OT-SVG table for Gecko (this takes a few seconds)"
            & $svgifyScript -InputFont $downloadedFont -OutputFont $svgFont | ForEach-Object { Write-Log "       $_" }
        }
        if (-not (Test-Path -LiteralPath $svgFont)) {
            throw "svgify.ps1 did not produce $svgFont"
        }
        Write-Log "[INFO] Validating OT-SVG font against DirectWrite"
        Assert-DirectWrite $svgFont "OT-SVG font"
        $installFontName = $svgFontName
        $sourceFont = $svgFont
    }
    $targetFont = Join-Path $fontsDir $installFontName

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backupFont = Join-Path $backupDir "seguiemj.original.ttf"
    if (-not (Test-Path -LiteralPath $backupFont)) {
        Copy-Item -LiteralPath (Join-Path $fontsDir "seguiemj.ttf") -Destination $backupFont -Force
        Write-Log "[OK]   Backed up original font to $backupFont" Green
    }
    reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" (Join-Path $backupDir "fonts.reg") /y | Out-Null

    # Original seguiemj.ttf is locked by Windows and stays untouched. Instead the
    # Apple font is added under its own filename and the registry family entry is
    # repointed - Windows loads fonts from this registry list, not the folder.
    $srcSize = (Get-Item -LiteralPath $sourceFont).Length
    if ((Test-Path -LiteralPath $targetFont) -and (Get-Item -LiteralPath $targetFont).Length -eq $srcSize) {
        Write-Log "[INFO] $installFontName already present in $fontsDir, skipping copy"
    }
    else {
        Write-Log "[INFO] Copying $installFontName into $fontsDir ($([math]::Round($srcSize / 1MB)) MB)"
        try {
            Copy-Item -LiteralPath $sourceFont -Destination $targetFont -Force
        }
        catch {
            throw "Cannot overwrite $targetFont - a previous version is currently active. Run restore.ps1, reboot, then run install.ps1 again."
        }
    }

    Write-Log "[INFO] Pointing '$fontValueName' registry entry at $installFontName"
    New-ItemProperty -Path $fontRegPath -Name $fontValueName -Value $installFontName -PropertyType String -Force | Out-Null

    $regValue = (Get-ItemProperty -Path $fontRegPath).$fontValueName
    $installedSize = (Get-Item -LiteralPath $targetFont).Length
    if ($regValue -ne $installFontName -or $installedSize -ne $srcSize) {
        throw "Post-install verification failed: registry='$regValue', installed size=$installedSize (expected $srcSize)."
    }
    Write-Log "[OK]   Verified: registry entry and font file in place" Green

    # A stale registration of the other variant would keep a second face in the
    # same family, leaving font matching ambiguous.
    $otherName = if ($installFontName -eq $svgFontName) { $appleFontName } else { $svgFontName }
    $otherFont = Join-Path $fontsDir $otherName
    if (Test-Path -LiteralPath $otherFont) {
        Remove-Item -LiteralPath $otherFont -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $otherFont) {
            Write-Log "[WARN] Previous $otherName is still in use; it will be gone after reboot." Yellow
        }
        else {
            Write-Log "[OK]   Removed previous $otherName" Green
        }
    }

    Write-Log "[INFO] Clearing font cache"
    Stop-Service -Name FontCache -Force -ErrorAction SilentlyContinue
    $fontCachePath = "$env:windir\ServiceProfiles\LocalService\AppData\Local\FontCache"
    if (Test-Path -LiteralPath $fontCachePath) {
        Get-ChildItem -LiteralPath $fontCachePath -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Start-Service -Name FontCache -ErrorAction SilentlyContinue

    Write-Log "[INFO] Activating the font in the running session"
    $added = Enable-FontNow $targetFont
    if ($added -gt 0) {
        Write-Log "[OK]   AddFontResourceEx registered $added face(s)" Green
    }
    else {
        Write-Log "[WARN] AddFontResourceEx registered nothing; a reboot will still apply it." Yellow
    }

    # Report what is actually true rather than assuming the activation worked.
    $active = @(Get-ActiveEmojiFontFile)
    $live = @($active | Where-Object { $_ -match [regex]::Escape($installFontName) })
    if ($live.Count -gt 0) {
        Write-Log "[OK]   'Segoe UI Emoji' now resolves to $installFontName" Green
        Write-Log "[OK]   No reboot needed. Restart any app to pick it up -" Green
        Write-Log "[OK]   already-running apps keep the old font until relaunched." Green
    }
    elseif ($active.Count -gt 0) {
        Write-Log "[WARN] 'Segoe UI Emoji' still resolves to:" Yellow
        foreach ($uri in $active) { Write-Log "       $uri" Yellow }
        Write-Log "[WARN] Live activation did not take. Sign out and back in (or reboot) to apply." Yellow
    }
    else {
        Write-Log "[WARN] Could not probe the active font. Reboot to be sure." Yellow
    }

    Write-Log "[OK]   To undo: run restore.ps1" Green
}
catch {
    Write-Log "[FAIL] $($_.Exception.Message)" Red
    if ($Elevated) { exit 1 }
    throw
}
