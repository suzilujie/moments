# start.ps1 - one-click build & push to trigger CI
#
# Usage (run in PowerShell):
#   .\start.ps1                        commit changes & push (skips if no changes)
#   .\start.ps1 -Message "feat: xxx"   custom commit message
#   .\start.ps1 -Wait                  also wait for CI and print the result
#   .\start.ps1 -Empty                 push an empty commit (no file changes)
#
# Tip: double-click start.bat to run without worrying about execution policy.
#
# Why this project uses an unsigned-ipa pipeline (see docs/设计文档.html 12.1):
#   M0/M1 only produce an unsigned ipa, which is side-loaded over USB with
#   Sideloadly. No App Store Connect setup and no repository Secrets are needed.
#   Ad Hoc distribution can be added later without touching the app code.
#
# NOTE: all scripts in this project are written in pure ASCII on purpose.
#   This workspace path contains non-ASCII characters, and passing such paths
#   as arguments to external processes is known to corrupt them on Windows.

param(
    [string]$Message = "",
    [switch]$Wait,
    [switch]$Empty
)

# ---------------------------------------------------------------------------
# GitHub repository coordinates. Used by -Wait to poll the Actions API.
# If left empty the script still commits and pushes, it just cannot poll CI.
# ---------------------------------------------------------------------------
$Owner = "suzilujie"
$Repo  = "moments"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host ""
Write-Host "=== One-click build ===" -ForegroundColor Cyan
Write-Host ("Project: " + (Get-Location))

# --- helper: run a git command, fail on non-zero exit code ---
function Invoke-Git([string[]]$GitArgs) {
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) { Write-Host $line }
    if ($code -ne 0) {
        Write-Host ("git " + ($GitArgs -join ' ') + " failed (exit $code)") -ForegroundColor Red
        exit 1
    }
}

# --- helper: GitHub Actions API request headers ---
function New-ApiHeaders() {
    return @{ 'User-Agent' = 'start-script'; 'Accept' = 'application/vnd.github+json' }
}

# --- helper: print the exact ipa download links for a run ---
#
# Why this exists: the Actions tab only shows a list of runs, so the user has to
# hunt for the right one and then click through. The per-artifact URL is stable
# and can be pasted straight into a download, so print it here instead of
# describing where to look.
function Write-IpaLinks([string]$RunId, [string]$RunUrl) {
    Write-Host ""
    Write-Host "=== ipa download ===" -ForegroundColor Cyan
    Write-Host ("Run page : " + $RunUrl)
    try {
        $auri = "https://api.github.com/repos/$Owner/$Repo/actions/runs/" + $RunId + "/artifacts"
        $arts = Invoke-RestMethod -Uri $auri -Headers (New-ApiHeaders) -TimeoutSec 25
        foreach ($art in $arts.artifacts) {
            $size = [math]::Round($art.size_in_bytes / 1MB, 1)
            Write-Host ("Artifact : " + $art.name + "  (" + $size + " MB)")
            Write-Host ("Download : https://github.com/" + $Owner + "/" + $Repo + "/actions/runs/" + $RunId + "/artifacts/" + $art.id)
        }
    }
    catch {
        Write-Host "  (artifact list unavailable; open the run page above)" -ForegroundColor Yellow
    }
}

# --- helper: find the Actions run for a commit sha (best effort) ---
function Get-RunForSha([string]$Sha) {
    try {
        $uri = "https://api.github.com/repos/$Owner/$Repo/actions/runs?per_page=10"
        $result = Invoke-RestMethod -Uri $uri -Headers (New-ApiHeaders) -TimeoutSec 25
        return @($result.workflow_runs | Where-Object { $_.head_sha -like "$Sha*" } | Select-Object -First 1)
    }
    catch {
        return @()
    }
}

# --- [0/5] make sure this is a git repository with a remote ---
if (-not (Test-Path (Join-Path $ScriptDir ".git"))) {
    Write-Host "[0/5] No .git found. Initialising a new repository..." -ForegroundColor Yellow
    Invoke-Git @("init", "-b", "main")
    Write-Host "      Repository initialised. Next step (once, manually):" -ForegroundColor Yellow
    Write-Host "        git remote add origin https://github.com/<owner>/<repo>.git" -ForegroundColor Yellow
    Write-Host "      Then run this script again." -ForegroundColor Yellow
    exit 0
}

$remote = (& git remote) 2>&1
if (-not ($remote -contains "origin")) {
    Write-Host "[0/5] No 'origin' remote configured. Add it first, then re-run:" -ForegroundColor Red
    Write-Host "        git remote add origin https://github.com/<owner>/<repo>.git" -ForegroundColor Red
    exit 1
}

# --- [1/5] stage ---
Write-Host ""
Write-Host "[1/5] Staging changes..." -ForegroundColor Yellow
Invoke-Git @("add", "-A")
$changes = @(git status --porcelain)

# --- [2/5] commit ---
$pushed = $false
if ($changes.Count -gt 0) {
    if (-not $Message) { $Message = "build: one-click " + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Write-Host ("[2/5] Committing: " + $Message) -ForegroundColor Yellow
    Invoke-Git @("commit", "-m", $Message)
    $pushed = $true
}
elseif ($Empty) {
    if (-not $Message) { $Message = "build: empty commit " + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Write-Host ("[2/5] No changes; pushing empty commit: " + $Message) -ForegroundColor Yellow
    Invoke-Git @("commit", "--allow-empty", "-m", $Message)
    $pushed = $true
}
else {
    Write-Host "[2/5] No local changes. Nothing to commit." -ForegroundColor Gray
    Write-Host "      Tip: use -Empty to trigger a rebuild without code changes." -ForegroundColor Gray
}

# --- [3/5] push ---
if ($pushed) {
    Write-Host "[3/5] Pushing to origin/main..." -ForegroundColor Yellow
    $env:GIT_TERMINAL_PROMPT = "0"
    Invoke-Git @("push", "origin", "main")
    $sha = (git rev-parse HEAD).Substring(0, 7)
    Write-Host ("Pushed: " + $sha) -ForegroundColor Green
}
else {
    Write-Host "[3/5] Nothing to push." -ForegroundColor Gray
}

# --- [4/5] tell the user where to grab the ipa ---
#
# Prints the exact run + per-artifact URL for the commit that was just pushed,
# not just a link to the Actions list. Without -Wait the run may still be
# queued, in which case the artifact links are not there yet -- that is called
# out explicitly rather than printing a link that does not work.
Write-Host ""
Write-Host "[4/5] Where to get the ipa" -ForegroundColor Cyan
$shaHead = (git rev-parse HEAD).Substring(0, 7)
if ($Owner -and $Repo) {
    $run = Get-RunForSha $shaHead
    if ($run) {
        Write-IpaLinks ([string]$run.id) $run.html_url
        if ($run.status -ne 'completed') {
            Write-Host "  (the run is still in progress; artifact links appear when it finishes)" -ForegroundColor Gray
            Write-Host "  (re-run with -Wait to print them automatically)" -ForegroundColor Gray
        }
    }
    else {
        Write-Host ("      https://github.com/" + $Owner + "/" + $Repo + "/actions") -ForegroundColor Green
        Write-Host "      Open the latest 'ios-build' run and download 'Moments-unsigned-ipa'."
    }
}
else {
    Write-Host "      Set Owner/Repo at the top of this script to print the exact link."
    Write-Host "      Otherwise: open the repository's Actions tab and pick the latest run."
}
Write-Host "      Side-load the ipa with Sideloadly, then check the commit shown on the"
Write-Host ("      self-check screen matches: " + $shaHead)

# --- [5/5] optionally wait for CI ---
if ($Wait) {
    if (-not ($Owner -and $Repo)) {
        Write-Host ""
        Write-Host "[5/5] -Wait requested but Owner/Repo are empty. Set them first." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    $shaToWatch = (git rev-parse HEAD).Substring(0, 7)
    Write-Host ""
    Write-Host "[5/5] Waiting for GitHub Actions..." -ForegroundColor Yellow
    $headers = @{ 'User-Agent' = 'start-script' }
    $deadline = (Get-Date).AddMinutes(12)
    $done = $false

    while (-not $done -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        try {
            $uri = "https://api.github.com/repos/$Owner/$Repo/actions/runs?per_page=10"
            $result = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 25
            $mine = @($result.workflow_runs | Where-Object { $_.head_sha -like "$shaToWatch*" })
            $running = @($mine | Where-Object { $_.status -in @('queued', 'in_progress', 'waiting') })
            if ($mine.Count -gt 0 -and $running.Count -eq 0) {
                Write-Host ""
                Write-Host "=== Build results ===" -ForegroundColor Cyan
                foreach ($run in $mine) {
                    $color = if ($run.conclusion -eq 'success') { 'Green' } else { 'Red' }
                    Write-Host ("{0,-14} -> {1}" -f $run.name, $run.conclusion) -ForegroundColor $color
                }
                $okRun = $mine | Where-Object { $_.conclusion -eq 'success' } | Select-Object -First 1
                if ($okRun) {
                    Write-IpaLinks ([string]$okRun.id) $okRun.html_url
                }
                $done = $true
            }
        }
        catch {
            Write-Host ("  query failed, retrying... (" + $_.Exception.Message + ")") -ForegroundColor Gray
        }
    }

    if (-not $done) {
        Write-Host "Timed out waiting for CI. Check the Actions tab manually." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
