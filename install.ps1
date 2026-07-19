param(
    [switch]$SkipDownload,
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

Assert-Admin

$releaseApi = "https://api.github.com/repos/samuelngs/apple-emoji-ttf/releases/latest"
$fontValueName = "Segoe UI Emoji (TrueType)"
$fontRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
$fontsDir = Join-Path $env:windir "Fonts"
$appleFontName = "AppleColorEmoji-Windows.ttf"
$backupDir = Join-Path $WorkDir "backup"
$downloadDir = Join-Path $WorkDir "downloads"
$downloadedFont = Join-Path $downloadDir $appleFontName
$targetFont = Join-Path $fontsDir $appleFontName

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
        }
    }
    if (-not (Test-Path -LiteralPath $downloadedFont)) {
        throw "Font file missing: $downloadedFont"
    }

    # DirectWrite must accept the font, otherwise Windows silently drops the
    # family and falls back to old monochrome Segoe UI Symbol glyphs.
    Write-Log "[INFO] Validating font against DirectWrite"
    Add-Type -AssemblyName PresentationCore
    try {
        $fontUri = "file:///" + $downloadedFont.Replace('\', '/')
        $typeface = New-Object System.Windows.Media.GlyphTypeface($fontUri)
        Write-Log "[OK]   DirectWrite accepts font: $($typeface.FamilyNames.Values -join ', ') ($($typeface.GlyphCount) glyphs)" Green
    }
    catch {
        throw "DirectWrite rejects this font file (would render as monochrome fallback): $($_.Exception.Message)"
    }

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
    $srcSize = (Get-Item -LiteralPath $downloadedFont).Length
    if ((Test-Path -LiteralPath $targetFont) -and (Get-Item -LiteralPath $targetFont).Length -eq $srcSize) {
        Write-Log "[INFO] $appleFontName already present in $fontsDir, skipping copy"
    }
    else {
        Write-Log "[INFO] Copying $appleFontName into $fontsDir"
        try {
            Copy-Item -LiteralPath $downloadedFont -Destination $targetFont -Force
        }
        catch {
            throw "Cannot overwrite $targetFont - a previous version is currently active. Run restore.ps1, reboot, then run install.ps1 again."
        }
    }

    Write-Log "[INFO] Pointing '$fontValueName' registry entry at $appleFontName"
    New-ItemProperty -Path $fontRegPath -Name $fontValueName -Value $appleFontName -PropertyType String -Force | Out-Null

    $regValue = (Get-ItemProperty -Path $fontRegPath).$fontValueName
    $installedSize = (Get-Item -LiteralPath $targetFont).Length
    if ($regValue -ne $appleFontName -or $installedSize -ne $srcSize) {
        throw "Post-install verification failed: registry='$regValue', installed size=$installedSize (expected $srcSize)."
    }
    Write-Log "[OK]   Verified: registry entry and font file in place" Green

    Write-Log "[INFO] Clearing font cache"
    Stop-Service -Name FontCache -Force -ErrorAction SilentlyContinue
    $fontCachePath = "$env:windir\ServiceProfiles\LocalService\AppData\Local\FontCache"
    if (Test-Path -LiteralPath $fontCachePath) {
        Get-ChildItem -LiteralPath $fontCachePath -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Start-Service -Name FontCache -ErrorAction SilentlyContinue

    Write-Log "[OK]   Done. Reboot Windows to apply emoji change system-wide." Green
    Write-Log "[OK]   To undo: run restore.ps1" Green
}
catch {
    Write-Log "[FAIL] $($_.Exception.Message)" Red
    if ($Elevated) { exit 1 }
    throw
}
