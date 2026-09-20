# Compiles all modules into ./ebin. Run this after any src/ change.
$ErrorActionPreference = "Stop"

function Find-Erlc {
    $cmd = Get-Command erlc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = "C:\Program Files\Erlang OTP\bin\erlc.exe"
    if (Test-Path $candidate) { return $candidate }
    throw "erlc.exe not found. Install Erlang/OTP from https://www.erlang.org/downloads (free) or add it to PATH."
}

$erlc = Find-Erlc
$root = $PSScriptRoot
New-Item -ItemType Directory -Force -Path "$root\ebin" | Out-Null

$sources = Get-ChildItem "$root\src\*.erl" | ForEach-Object { $_.FullName }
& $erlc -o "$root\ebin" @sources
if ($LASTEXITCODE -ne 0) { throw "Compilation failed." }
Write-Host "Build OK -> $root\ebin"
