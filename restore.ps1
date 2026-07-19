param(
    [switch]$Elevated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkDir = Join-Path $PSScriptRoot "work"
$logFile = Join-Path $WorkDir "restore.log"

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Requesting administrator permission (UAC)..." -ForegroundColor Yellow
        try {
            $proc = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$PSCommandPath`"",
                "-Elevated"
            ) -Wait -PassThru
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

$fontRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
$fontValueName = "Segoe UI Emoji (TrueType)"
$appleFontPath = Join-Path $env:windir "Fonts\AppleColorEmoji-Windows.ttf"

if (-not (Test-Path -LiteralPath $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
}
Set-Content -LiteralPath $logFile -Value "=== restore run $(Get-Date -Format s) ==="

try {
    Write-Log "[INFO] Pointing '$fontValueName' back at seguiemj.ttf"
    New-ItemProperty -Path $fontRegPath -Name $fontValueName -Value "seguiemj.ttf" -PropertyType String -Force | Out-Null

    if (Test-Path -LiteralPath $appleFontPath) {
        # May still be memory-mapped until reboot; leaving it is harmless once unregistered.
        Remove-Item -LiteralPath $appleFontPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $appleFontPath) {
            Write-Log "[WARN] $appleFontPath is in use; delete it manually after reboot." Yellow
        }
        else {
            Write-Log "[OK]   Removed $appleFontPath" Green
        }
    }

    Write-Log "[INFO] Clearing font cache"
    Stop-Service -Name FontCache -Force -ErrorAction SilentlyContinue
    $fontCachePath = "$env:windir\ServiceProfiles\LocalService\AppData\Local\FontCache"
    if (Test-Path -LiteralPath $fontCachePath) {
        Get-ChildItem -LiteralPath $fontCachePath -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Start-Service -Name FontCache -ErrorAction SilentlyContinue

    Write-Log "[OK]   Original Windows emojis restored. Reboot to apply." Green
}
catch {
    Write-Log "[FAIL] $($_.Exception.Message)" Red
    if ($Elevated) { exit 1 }
    throw
}
