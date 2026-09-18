# ============================================================
# check-perp.ps1 - probe PERPETUAL (swap) BTC sources
#
# Purpose: the existing data source (*.binance.vision) is spot-only.
#          The product needs perpetual (BTC-USDT-SWAP style) pricing,
#          so re-rank candidate sources for direct vs proxied access.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-perp.ps1
# Read-only network probe, modifies nothing.
# ============================================================

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Net.Http

$proxyUrl = 'http://127.0.0.1:7897'

function New-Http {
    param([bool]$UseProxy, [string]$ProxyUrl)
    $h = New-Object System.Net.Http.HttpClientHandler
    $h.UseProxy = $UseProxy
    if ($UseProxy -and $ProxyUrl) { $h.Proxy = New-Object System.Net.WebProxy($ProxyUrl) }
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [TimeSpan]::FromSeconds(6)
    return $c
}

# ---------------------------- REST candidates ----------------------------
$restCases = @(
    @{ N = 'OKX swap';        U = 'https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP' },
    @{ N = 'CoinEx futures';  U = 'https://api.coinex.com/v2/futures/ticker?market=BTCUSDT' },
    @{ N = 'Binance vision fapi'; U = 'https://data-api.binance.vision/fapi/v1/ticker/price?symbol=BTCUSDT' },
    @{ N = 'Binance fapi';    U = 'https://fapi.binance.com/fapi/v1/ticker/price?symbol=BTCUSDT' },
    @{ N = 'Gate futures';    U = 'https://api.gateio.ws/api/v4/futures/usdt/tickers?contract=BTC_USDT' },
    @{ N = 'Bitget mix';      U = 'https://api.bitget.com/api/v2/mix/market/ticker?symbol=BTCUSDT&productType=usdt-futures' },
    @{ N = 'Bybit linear';    U = 'https://api.bybit.com/v5/market/tickers?category=linear&symbol=BTCUSDT' }
)

Write-Output ''
Write-Output '=== SECTION 1: PERPETUAL REST, direct vs proxy (6s timeout) ==='
Write-Output ('{0,-18} {1,-8} {2,-6} {3,8}  {4}' -f 'SOURCE', 'MODE', 'RESULT', 'ELAPSED', 'HEAD')
Write-Output ('-' * 118)

foreach ($mode in @('direct', 'proxy')) {
    $useProxy = ($mode -eq 'proxy')
    foreach ($c in $restCases) {
        $client = New-Http -UseProxy $useProxy -ProxyUrl $proxyUrl
        $res = 'FAIL'
        $head = ''
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = $client.GetAsync($c.U).Result
            $sw.Stop()
            if ([int]$r.StatusCode -eq 200) { $res = 'OK' }
            $head = $r.Content.ReadAsStringAsync().Result
            if ($head.Length -gt 100) { $head = $head.Substring(0, 100) }
        } catch {
            $sw.Stop()
            $head = $_.Exception.Message
            if ($head.Length -gt 100) { $head = $head.Substring(0, 100) }
        } finally { $client.Dispose() }
        Write-Output ('{0,-18} {1,-8} {2,-6} {3,7}ms  {4}' -f $c.N, $mode, $res, $sw.ElapsedMilliseconds, $head)
    }
}

# ---------------------------- WebSocket candidates ----------------------------
Write-Output ''
Write-Output '=== SECTION 2: PERPETUAL WebSocket, direct vs proxy ==='

function Test-Ws {
    param([string]$Name, [string]$Url, [string]$Sub, [bool]$UseProxy, [string]$ProxyUrl)
    $res = 'FAIL'
    $detail = ''
    $ms = -1
    $ws = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        if ($UseProxy) { $ws.Options.Proxy = New-Object System.Net.WebProxy($ProxyUrl) }
        else { $ws.Options.Proxy = $null }
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(9000)
        $t = $ws.ConnectAsync([Uri]$Url, $cts.Token)
        if (-not $t.Wait(9000)) { throw 'connect timeout' }
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw ('state=' + $ws.State) }
        $ms = $sw.ElapsedMilliseconds
        if ($Sub) {
            $sb = [Text.Encoding]::UTF8.GetBytes($Sub)
            $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $sb)
            $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
        }
        $buf = New-Object byte[] 4096
        $rs = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
        $rt = $ws.ReceiveAsync($rs, $cts.Token)
        if ($rt.Wait(9000)) {
            $detail = [Text.Encoding]::UTF8.GetString($buf, 0, $rt.Result.Count)
            if ($detail.Length -gt 110) { $detail = $detail.Substring(0, 110) }
            $res = 'OK'
        } else { $detail = 'no message within 9s' }
    } catch {
        $detail = $_.Exception.Message
        if ($detail.Length -gt 110) { $detail = $detail.Substring(0, 110) }
    } finally {
        if ($ws) { try { $ws.Dispose() } catch { } }
    }
    $mode = 'direct'
    if ($UseProxy) { $mode = 'proxy' }
    Write-Output ('{0,-22} {1,-8} {2,-6} {3,7}ms  {4}' -f $Name, $mode, $res, $ms, $detail)
}

$okxSwapSub = '{"op":"subscribe","args":[{"channel":"tickers","instId":"BTC-USDT-SWAP"}]}'

Test-Ws -Name 'OKX swap' -Url 'wss://ws.okx.com:8443/ws/v5/public' -Sub $okxSwapSub -UseProxy $true -ProxyUrl $proxyUrl
Test-Ws -Name 'OKX swap' -Url 'wss://ws.okx.com:8443/ws/v5/public' -Sub $okxSwapSub -UseProxy $false -ProxyUrl $proxyUrl
Test-Ws -Name 'Binance futures' -Url 'wss://fstream.binance.com/ws/btcusdt@ticker' -Sub '' -UseProxy $true -ProxyUrl $proxyUrl
Test-Ws -Name 'Binance futures' -Url 'wss://fstream.binance.com/ws/btcusdt@ticker' -Sub '' -UseProxy $false -ProxyUrl $proxyUrl
Test-Ws -Name 'CoinEx futures' -Url 'wss://ws.coinex.com/v2/' -Sub '{"method":"ticker.subscribe","params":["BTCUSDT"],"id":1}' -UseProxy $false -ProxyUrl $proxyUrl
Test-Ws -Name 'Gate futures' -Url 'wss://fx-ws.gateio.ws/v4/ws/usdt' -Sub '{"time":1690000000,"channel":"futures.tickers","event":"subscribe","payload":["BTC_USDT"]}' -UseProxy $false -ProxyUrl $proxyUrl

Write-Output ''
Write-Output '=== DONE ==='
