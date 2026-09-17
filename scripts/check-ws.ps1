# ============================================================
# Round-2 probe: proxy config + real WebSocket handshake + alt domains
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-ws.ps1
# Read-only diagnostics, modifies nothing.
# ============================================================

$ErrorActionPreference = 'Continue'

Write-Output ''
Write-Output '=== SECTION A: system proxy configuration ==='
$reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
Write-Output ('WinINET ProxyEnable : {0}' -f $reg.ProxyEnable)
Write-Output ('WinINET ProxyServer : {0}' -f $reg.ProxyServer)
Write-Output ('WinINET AutoConfig  : {0}' -f $reg.AutoConfigURL)
Write-Output ('ENV HTTP_PROXY      : {0}' -f $env:HTTP_PROXY)
Write-Output ('ENV HTTPS_PROXY     : {0}' -f $env:HTTPS_PROXY)
Write-Output '--- winhttp ---'
netsh winhttp show proxy

Write-Output ''
Write-Output '=== SECTION B: local proxy port scan (127.0.0.1) ==='
$proxyPorts = @(1080, 1081, 7890, 7891, 7897, 8080, 8118, 8889, 10808, 10809, 33210, 4780)
foreach ($p in $proxyPorts) {
    $c = New-Object System.Net.Sockets.TcpClient
    $open = $false
    try {
        $t = $c.ConnectAsync('127.0.0.1', $p)
        $open = $t.Wait(300)
    } catch { $open = $false }
    finally { $c.Dispose() }
    if ($open) { Write-Output ('port {0,-6} OPEN' -f $p) }
}
Write-Output '(only open ports listed above)'

Write-Output ''
Write-Output '=== SECTION C: real WebSocket handshake + live tick ==='
$wsCases = @(
    @{ Name = 'OKX';     Url = 'wss://ws.okx.com:8443/ws/v5/public'; Sub = '{"op":"subscribe","args":[{"channel":"tickers","instId":"BTC-USDT-SWAP"}]}' },
    @{ Name = 'CoinEx';  Url = 'wss://ws.coinex.com/v1/';            Sub = '{"method":"ticker.subscribe","params":["BTCUSDT"],"id":1}' },
    @{ Name = 'Gate';    Url = 'wss://api.gateio.ws/ws/v4/';         Sub = '{"time":1690000000,"channel":"spot.tickers","event":"subscribe","payload":["BTC_USDT"]}' }
)

foreach ($w in $wsCases) {
    $result = 'FAIL'
    $detail = ''
    $ms = -1
    $ws = $null
    try {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(9000)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ct = $ws.ConnectAsync([Uri]$w.Url, $cts.Token)
        if (-not $ct.Wait(9000)) { throw 'connect timeout' }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw ('state=' + $ws.State) }
        $ms = $sw.ElapsedMilliseconds

        $sb = [Text.Encoding]::UTF8.GetBytes($w.Sub)
        $ss = New-Object System.ArraySegment[byte] -ArgumentList @(, $sb)
        $ws.SendAsync($ss, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)

        $buf = New-Object byte[] 4096
        $rs = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
        $rt = $ws.ReceiveAsync($rs, $cts.Token)
        if ($rt.Wait(9000)) {
            $detail = [Text.Encoding]::UTF8.GetString($buf, 0, $rt.Result.Count)
            if ($detail.Length -gt 150) { $detail = $detail.Substring(0, 150) }
            $result = 'OK'
        } else {
            $detail = 'no message within timeout'
        }
    } catch {
        $detail = $_.Exception.Message
        if ($detail.Length -gt 150) { $detail = $detail.Substring(0, 150) }
    } finally {
        if ($ws) { try { $ws.Dispose() } catch { } }
    }
    Write-Output ('{0,-8} {1,-6} {2,7}ms  {3}' -f $w.Name, $result, $ms, $detail)
}

Write-Output ''
Write-Output '=== SECTION D: extra REST candidates (5s timeout) ==='
$extra = @(
    'https://api1.binance.com/api/v3/ticker/price?symbol=BTCUSDT',
    'https://api2.binance.com/api/v3/ticker/price?symbol=BTCUSDT',
    'https://api3.binance.com/api/v3/ticker/price?symbol=BTCUSDT',
    'https://api4.binance.com/api/v3/ticker/price?symbol=BTCUSDT',
    'https://data-api.binance.vision/api/v3/ticker/price?symbol=BTCUSDT',
    'https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP',
    'https://api.coinex.com/v2/spot/ticker?market=BTCUSDT',
    'https://hq.sinajs.cn/list=btcusd'
)
foreach ($u in $extra) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $res = 'FAIL'
    $head = ''
    try {
        $r = Invoke-WebRequest -Uri $u -TimeoutSec 5 -UseBasicParsing -Headers @{ Referer = 'https://finance.sina.com.cn' }
        $sw.Stop()
        if ($r.StatusCode -eq 200) { $res = 'OK' }
        $head = $r.Content
        if ($head.Length -gt 110) { $head = $head.Substring(0, 110) }
    } catch {
        $sw.Stop()
        $head = $_.Exception.Message
        if ($head.Length -gt 110) { $head = $head.Substring(0, 110) }
    }
    Write-Output ('{0,-6} {1,7}ms  {2}  <= {3}' -f $res, $sw.ElapsedMilliseconds, $u, $head)
}

Write-Output ''
Write-Output '=== DONE ==='
