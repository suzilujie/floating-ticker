# ============================================================
# Round-4 probe: stability soak test (direct connection, no proxy)
#   A: Binance public-data WS, 60s continuous receive -> tick rate / max gap
#   B: CoinEx WS handshake (direct)
#   C: Binance public-data REST latency, 10 rounds
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-stability.ps1
# Read-only diagnostics, modifies nothing.
# ============================================================

$ErrorActionPreference = 'Continue'

Write-Output ''
Write-Output '=== SECTION A: Binance vision WS, 60s soak (direct) ==='
$ws = $null
try {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.Proxy = $null
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(90000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $t = $ws.ConnectAsync([Uri]'wss://data-stream.binance.vision/ws/btcusdt@ticker', $cts.Token)
    if (-not $t.Wait(10000)) { throw 'connect timeout' }
    Write-Output ('connect ok, handshake {0}ms' -f $sw.ElapsedMilliseconds)

    $buf = New-Object byte[] 8192
    $tickCount = 0
    $maxGap = 0
    $gapSum = 0
    $last = [Diagnostics.Stopwatch]::StartNew()
    $firstJson = ''
    $lastJson = ''
    $deadline = (Get-Date).AddSeconds(60)

    while ((Get-Date) -lt $deadline) {
        $rs = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
        $rt = $ws.ReceiveAsync($rs, $cts.Token)
        if (-not $rt.Wait(15000)) { Write-Output 'WARN: 15s receive timeout, stream stalled'; break }
        if ($rt.Result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { Write-Output 'WARN: server closed'; break }
        $tickCount++
        $g = $last.ElapsedMilliseconds
        $last.Restart()
        $gapSum += $g
        if ($g -gt $maxGap) { $maxGap = $g }
        $json = [Text.Encoding]::UTF8.GetString($buf, 0, $rt.Result.Count)
        if ($tickCount -eq 1) { $firstJson = $json }
        $lastJson = $json
    }

    if ($tickCount -gt 0) {
        Write-Output ('ticks received : {0} in 60s ({1:N1} ticks/s)' -f $tickCount, ($tickCount / 60))
        Write-Output ('avg gap        : {0:N0} ms' -f ($gapSum / $tickCount))
        Write-Output ('max gap        : {0} ms  <-- key stability indicator' -f $maxGap)
    } else {
        Write-Output 'ticks received : 0 (stream dead)'
    }
    Write-Output ('first frame    : {0}' -f $firstJson.Substring(0, [Math]::Min(120, $firstJson.Length)))
    Write-Output ('last  frame    : {0}' -f $lastJson.Substring(0, [Math]::Min(120, $lastJson.Length)))
} catch {
    Write-Output ('SECTION A FAILED: {0}' -f $_.Exception.Message)
} finally {
    if ($ws) { try { $ws.Dispose() } catch { } }
}

Write-Output ''
Write-Output '=== SECTION B: CoinEx WS handshake (direct) ==='
$ws2 = $null
try {
    $ws2 = New-Object System.Net.WebSockets.ClientWebSocket
    $ws2.Options.Proxy = $null
    $cts2 = New-Object System.Threading.CancellationTokenSource
    $cts2.CancelAfter(10000)
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    $t2 = $ws2.ConnectAsync([Uri]'wss://ws.coinex.com/v1/', $cts2.Token)
    if (-not $t2.Wait(9000)) { throw 'connect timeout' }
    Write-Output ('handshake ok, {0}ms' -f $sw2.ElapsedMilliseconds)
    $msg = '{"method":"ticker.subscribe","params":["BTCUSDT"],"id":1}'
    $sb = [Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $sb)
    $ws2.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts2.Token).Wait(5000)
    $buf2 = New-Object byte[] 4096
    $rs2 = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf2)
    $rt2 = $ws2.ReceiveAsync($rs2, $cts2.Token)
    if ($rt2.Wait(9000)) {
        $s = [Text.Encoding]::UTF8.GetString($buf2, 0, $rt2.Result.Count)
        Write-Output ('message ok: {0}' -f $s.Substring(0, [Math]::Min(120, $s.Length)))
    } else {
        Write-Output 'no message within 9s'
    }
} catch {
    Write-Output ('SECTION B FAILED: {0}' -f $_.Exception.Message)
} finally {
    if ($ws2) { try { $ws2.Dispose() } catch { } }
}

Write-Output ''
Write-Output '=== SECTION C: Binance vision REST latency, 10 rounds (direct) ==='
Add-Type -AssemblyName System.Net.Http
$h = New-Object System.Net.Http.HttpClientHandler
$h.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($h)
$client.Timeout = [TimeSpan]::FromSeconds(5)
$lat = @()
$fails = 0
for ($i = 1; $i -le 10; $i++) {
    $sw3 = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = $client.GetAsync('https://data-api.binance.vision/api/v3/ticker/price?symbol=BTCUSDT').Result
        $sw3.Stop()
        $body = $r.Content.ReadAsStringAsync().Result
        $lat += $sw3.ElapsedMilliseconds
        Write-Output ('  round {0,2}: {1,5}ms  {2}' -f $i, $sw3.ElapsedMilliseconds, $body)
    } catch {
        $sw3.Stop()
        $fails++
        Write-Output ('  round {0,2}: FAIL   {1}ms' -f $i, $sw3.ElapsedMilliseconds)
    }
}
$client.Dispose()
if ($lat.Count -gt 0) {
    $stat = $lat | Measure-Object -Average -Minimum -Maximum
    Write-Output ('summary: success {0}/10, avg {1:N0}ms, min {2}ms, max {3}ms, failed {4}' -f $lat.Count, $stat.Average, $stat.Minimum, $stat.Maximum, $fails)
}

Write-Output ''
Write-Output '=== DONE ==='
