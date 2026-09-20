# Interactive chat client, pure PowerShell (no Erlang console involved,
# to sidestep a known Windows console-driver bug in newer Erlang/OTP
# builds). Usage: .\client.ps1 [hostname] [port]
$ErrorActionPreference = "Stop"

$chatHost = if ($args.Count -ge 1) { $args[0] } else { "localhost" }
$port = if ($args.Count -ge 2) { [int]$args[1] } else { 5555 }

$client = New-Object System.Net.Sockets.TcpClient($chatHost, $port)
$stream = $client.GetStream()
$enc = [System.Text.Encoding]::ASCII
$buf = New-Object byte[] 4096

Write-Host "Connected to $chatHost`:$port. Type /quit to disconnect." -ForegroundColor DarkGray

# KeyAvailable requires a real attached console; fall back to a simple
# blocking read loop if that's not available (e.g. non-interactive hosts).
$canPoll = $true
try { [void][Console]::KeyAvailable } catch { $canPoll = $false }

try {
    while ($client.Connected) {
        while ($stream.DataAvailable) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [Console]::Out.Write($enc.GetString($buf, 0, $n))
        }
        if ($canPoll -and -not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            continue
        }
        $line = [Console]::ReadLine()
        if ($null -eq $line) { break }
        $bytes = $enc.GetBytes("$line`n")
        $stream.Write($bytes, 0, $bytes.Length)
        if ($line -eq "/quit") {
            Start-Sleep -Milliseconds 200
            break
        }
    }
} finally {
    $stream.Close()
    $client.Close()
    Write-Host "`nDisconnected." -ForegroundColor DarkGray
}
