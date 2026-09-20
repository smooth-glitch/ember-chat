# Exposes the web UI (chat_app's web port, default 8080) to the public
# internet via an ngrok HTTPS tunnel, so anyone with the link can join
# from anywhere -- no port forwarding or router config needed.
#
# One-time setup (ngrok's free tier requires an account since a few
# years ago -- there's no way around this from a script):
#   1. Sign up free at https://dashboard.ngrok.com/signup
#   2. Copy your authtoken from https://dashboard.ngrok.com/get-started/your-authtoken
#   3. Run once:  ngrok config add-authtoken <your-token>
#
# Usage: .\tunnel.ps1 [webPort]   (default 8080 -- must match run.ps1's webPort)
$ErrorActionPreference = "Stop"

function Find-Ngrok {
    $cmd = Get-Command ngrok.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $pkg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter "*Ngrok*" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($pkg) {
        $candidate = Join-Path $pkg.FullName "ngrok.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    throw "ngrok.exe not found. Install it with: winget install --id Ngrok.Ngrok -e"
}

$webPort = if ($args.Count -ge 1) { $args[0] } else { "8080" }
$ngrok = Find-Ngrok

Write-Host "Starting ngrok tunnel to http://localhost:$webPort ..." -ForegroundColor DarkGray
Write-Host "Make sure .\run.ps1 is already running in another window first." -ForegroundColor DarkGray
Write-Host ""

& $ngrok http $webPort
