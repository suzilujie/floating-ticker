# ============================================================
# Market data source connectivity probe
# Purpose: rank candidate exchanges for the failover list
# Usage:   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-sources.ps1
# Note:    read-only network probe, does not modify anything
# ============================================================

$ErrorActionPreference = 'Continue'

$tcpTargets = @(
    @{ Name = 'OKX WS primary';    Host = 'ws.okx.com';        Port = 8443 },
    @{ Name = 'OKX WS aws';        Host = 'wsaws.okx.com';     Port = 8443 },
    @{ Name = 'OKX REST';          Host = 'www.okx.com';       Port = 443  },
    @{ Name = 'Binance WS stream'; Host = 'stream.binance.com'; Port = 9443 },
    @{ Name = 'Binance WS fstream';Host = 'fstream.binance.com'; Port = 443 },
    @{ Name = 'Binance REST';      Host = 'api.binance.com';   Port = 443  },
    @{ Name = 'HTX REST';          Host = 'api.htx.com';       Port = 443  },
    @{ Name = 'Gate REST';         Host = 'api.gateio.ws';     Port = 443  },
    @{ Name = 'Bitget REST';       Host = 'api.bitget.com';    Port = 443  },
    @{ Name = 'Bybit WS';          Host = 'stream.bybit.com';  Port = 443  },
    @{ Name = 'MEXC REST';         Host = 'api.mexc.com';      Port = 443  },
    @{ Name = 'CoinEx REST';       Host = 'api.coinex.com';    Port = 443  },
    @{ Name = 'CoinGecko REST';    Host = 'api.coingecko.com'; Port = 443  },
    @{ Name = 'Kraken REST';       Host = 'api.kraken.com';    Port = 443  }
)

$restTargets = @(
    @{ Name = 'OKX';       Url = 'https://www.okx.com/api/v5/market/ticker?instId=BTC-USDT-SWAP' },
    @{ Name = 'Binance';   Url = 'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT' },
    @{ Name = 'HTX';       Url = 'https://api.htx.com/market/detail/merged?symbol=btcusdt' },
    @{ Name = 'Gate';      Url = 'https://api.gateio.ws/api/v4/spot/tickers?currency_pair=BTC_USDT' },
    @{ Name = 'Bitget';    Url = 'https://api.bitget.com/api/v2/spot/market/tickers?symbol=BTCUSDT' },
    @{ Name = 'Bybit';     Url = 'https://api.bybit.com/v5/market/tickers?category=linear&symbol=BTCUSDT' },
    @{ Name = 'MEXC';      Url = 'https://api.mexc.com/api/v3/ticker/price?symbol=BTCUSDT' },
    @{ Name = 'CoinGecko'; Url = 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd' }
)

Write-Output ''
Write-Output '=== SECTION 1: TCP reachability (3s timeout) ==='
Write-Output ('{0,-20} {1,-24} {2,-6} {3,-6} {4,8}  {5}' -f 'SOURCE', 'HOST', 'PORT', 'RESULT', 'LATENCY', 'RESOLVED IP')
Write-Output ('-' * 100)

foreach ($t in $tcpTargets) {
    $ip = ''
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($t.Host)
        if ($addrs.Count -gt 0) { $ip = $addrs[0].IPAddressToString }
    } catch { $ip = 'DNS-FAIL' }

    $ok = $false
    $ms = -1
    if ($ip -ne '' -and $ip -ne 'DNS-FAIL') {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $task = $client.ConnectAsync($t.Host, $t.Port)
            $ok = $task.Wait(3000)
            $sw.Stop()
            $ms = $sw.ElapsedMilliseconds
        } catch { $ok = $false }
        finally { $client.Dispose() }
    }

    $result = 'FAIL'
    if ($ok) { $result = 'OK' }
    Write-Output ('{0,-20} {1,-24} {2,-6} {3,-6} {4,8}  {5}' -f $t.Name, $t.Host, $t.Port, $result, $ms, $ip)
}

Write-Output ''
Write-Output '=== SECTION 2: REST data fetch (6s timeout, first 140 chars) ==='
Write-Output ('{0,-12} {1,-8} {2,9}  {3}' -f 'SOURCE', 'RESULT', 'ELAPSED', 'RESPONSE HEAD')
Write-Output ('-' * 100)

foreach ($r in $restTargets) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = 'FAIL'
    $head = ''
    try {
        $resp = Invoke-WebRequest -Uri $r.Url -TimeoutSec 6 -UseBasicParsing
        $sw.Stop()
        if ($resp.StatusCode -eq 200) { $result = 'OK' }
        $head = $resp.Content
        if ($head.Length -gt 140) { $head = $head.Substring(0, 140) }
    } catch {
        $sw.Stop()
        $head = $_.Exception.Message
        if ($head.Length -gt 140) { $head = $head.Substring(0, 140) }
    }
    Write-Output ('{0,-12} {1,-8} {2,8}ms  {3}' -f $r.Name, $result, $sw.ElapsedMilliseconds, $head)
}

Write-Output ''
Write-Output '=== DONE ==='
