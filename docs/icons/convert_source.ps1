# Convert the user-provided hand-drawn sketch photo into a BMP so that the
# pure-Python pipeline (no Pillow / numpy on this machine) can read it.
#
# Two machine-specific traps are handled here, both worth remembering:
#   1) The original photo lives in the IDE's history folder and its full path is
#      261 characters long. Windows' classic path limit (MAX_PATH) is 259, so
#      .NET Framework file APIs and Test-Path report "file not found" even though
#      the file is right there. The '\\?\' prefix lifts that limit.
#   2) GDI+ (System.Drawing) is unreliable with the '\\?\' prefix, so the bytes
#      are copied to a short path in this folder first and decoded from there.
#      Side benefit: the source artwork ends up versioned next to its output.
#
# This file is intentionally pure ASCII (Windows PowerShell 5.1 reads .ps1 files
# without a BOM as ANSI), and every path is derived from $PSScriptRoot so the
# Chinese characters in the workspace path never travel through a command line.
#
# Usage (from this folder):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File convert_source.ps1

$ErrorActionPreference = "Stop"

$localJpg = Join-Path $PSScriptRoot "source-sketch.jpg"
$localBmp = Join-Path $PSScriptRoot "source-sketch.bmp"
$original = "C:\Users\36055\AppData\Local\CodeBuddyExtension\Data\35ca90ea-2b83-4917-a4eb-6899c3a614e8\VSCode\35ca90ea-2b83-4917-a4eb-6899c3a614e8\history\0f47c68bf6f9d681ea627640b1ffc9d7\fc9326324ff64e83835a7c2522747a1b\assets\efd8a702edf124bcd6bbad1a8b57c2b9.247bef2dde.jpg"
$longOriginal = '\\?\' + $original

Write-Output ("original path length: {0} (MAX_PATH is 259)" -f $original.Length)

$src = $null
if ([System.IO.File]::Exists($localJpg)) {
    $src = $localJpg
} elseif ([System.IO.File]::Exists($longOriginal)) {
    $src = $longOriginal
}

if (-not $src) {
    Write-Output "ERROR: source image not found"
    Write-Output ("  checked: " + $original)
    Write-Output ("  long-path variant: " + $longOriginal)
    exit 1
}
Write-Output ("using: " + $src)

if ($src -ne $localJpg) {
    $bytes = [System.IO.File]::ReadAllBytes($src)
    [System.IO.File]::WriteAllBytes($localJpg, $bytes)
    Write-Output ("kept source copy: source-sketch.jpg ({0} bytes)" -f $bytes.Length)
}

Add-Type -AssemblyName System.Drawing

$img = [System.Drawing.Image]::FromFile($localJpg)
Write-Output ("source-size {0} x {1}" -f $img.Width, $img.Height)
$img.Save($localBmp, [System.Drawing.Imaging.ImageFormat]::Bmp)
$img.Dispose()

Write-Output ("wrote-bmp bytes {0}" -f (Get-Item -LiteralPath $localBmp).Length)
