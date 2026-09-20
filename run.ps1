# Starts the chat server. Usage: .\run.ps1 [tcpPort] [webPort]
# Defaults: TCP 5555, Web UI http://localhost:8080
$ErrorActionPreference = "Stop"

function Find-Erl {
    $cmd = Get-Command erl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = "C:\Program Files\Erlang OTP\bin\erl.exe"
    if (Test-Path $candidate) { return $candidate }
    throw "erl.exe not found. Install Erlang/OTP from https://www.erlang.org/downloads (free) or add it to PATH."
}

$tcpPort = if ($args.Count -ge 1) { $args[0] } else { "5555" }
$webPort = if ($args.Count -ge 2) { $args[1] } else { "8080" }
$erl = Find-Erl
$root = $PSScriptRoot

& $erl -noshell -pa "$root\ebin" -s chat_app start $tcpPort $webPort
