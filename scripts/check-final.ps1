# ============================================================
# Round-3 probe: direct vs proxied, REST + WebSocket
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-final.ps1
# Read-only diagnostics, modifies nothing.
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
    $c.Timeout = [TimeSpan]::FromSeconds(4)
    return $c
}

$restCases = @(
    @{ N = 'Binance vision'; U = 'https://data-api.binance.vision/api/v3/ticker/price?symbol=BTCUSDT' },
    @{ N = 'OKX swap';       U = 'https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP' },
    @{ N = 'CoinEx spot';    U = 'https://api.coinex.com/v2/spot/ticker?market=BTCUSDT' },
    @{ N = 'Gate spot';      U = 'https://api.gateio.ws/api/v4/spot/tickers?currency_pair=BTC_USDT' },
    @{ N = 'KuCoin spot';    U = 'https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=BTC-USDT' },
    @{ N = 'CoinCap';        U = 'https://api.coincap.io/v2/assets/bitcoin' },
    @{ N = 'AiCoin';         U = 'https://api.aicoin.com/api/v1/market/tickers?symbol=btcusdt' }
)

Write-Output ''
Write-Output '=== SECTION 1: REST, direct vs proxy (4s timeout) ==='
Write-Output ('{0,-16} {1,-8} {2,-8} {3,8}  {4}' -f 'SOURCE', 'MODE', 'RESULT', 'ELAPSED', 'HEAD')
Write-Output ('-' * 110)

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
            if ($head.Length -gt 90) { $head = $head.Substring(0, 90) }
        } catch {
            $sw.Stop()
            $head = $_.Exception.Message
            if ($head.Length -gt 90) { $head = $head.Substring(0, 90) }
        } finally { $client.Dispose() }
        Write-Output ('{0,-16} {1,-8} {2,-8} {3,7}ms  {4}' -f $c.N, $mode, $res, $sw.ElapsedMilliseconds, $head)
    }
}

Write-Output ''
Write-Output '=== SECTION 2: WebSocket, direct vs proxy ==='

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

$okxSub = '{"op":"subscribe","args":[{"channel":"tickers","instId":"BTC-USDT-SWAP"}]}'
Test-Ws -Name 'OKX public' -Url 'wss://ws.okx.com:8443/ws/v5/public' -Sub $okxSub -UseProxy $true -ProxyUrl $proxyUrl
Test-Ws -Name 'OKX public' -Url 'wss://ws.okx.com:8443/ws/v5/public' -Sub $okxSub -UseProxy $false -ProxyUrl $proxyUrl
Test-Ws -Name 'Binance vision WS' -Url 'wss://data-stream.binance.vision/ws/btcusdt@ticker' -Sub '' -UseProxy $false -ProxyUrl $proxyUrl
Test-Ws -Name 'Binance vision WS' -Url 'wss://data-stream.binance.vision/ws/btcusdt@ticker' -Sub '' -UseProxy $true -ProxyUrl $proxyUrl

Write-Output ''
Write-Output '=== DONE ==='
