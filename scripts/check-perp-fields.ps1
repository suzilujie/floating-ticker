# ============================================================
# check-perp-fields.ps1 - dump FULL payloads to confirm field names
#
# Why: parsing code must use exact field names. Guessing costs a
#      full CI cycle (~5 min), so dump raw payloads first.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-perp-fields.ps1
# ============================================================

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Net.Http

function Get-Direct {
    param([string]$Url)
    $h = New-Object System.Net.Http.HttpClientHandler
    $h.UseProxy = $false
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [TimeSpan]::FromSeconds(6)
    try { return $c.GetAsync($Url).Result.Content.ReadAsStringAsync().Result }
    catch { return 'ERROR: ' + $_.Exception.Message }
    finally { $c.Dispose() }
}

Write-Output ''
Write-Output '=== Gate futures REST (full payload) ==='
$gate = Get-Direct 'https://api.gateio.ws/api/v4/futures/usdt/tickers?contract=BTC_USDT'
Write-Output $gate

Write-Output ''
Write-Output '=== CoinEx futures REST (full payload) ==='
$coinex = Get-Direct 'https://api.coinex.com/v2/futures/ticker?market=BTCUSDT'
Write-Output $coinex

Write-Output ''
Write-Output '=== Gate futures WS (first 3 messages) ==='
$ws = $null
try {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.Proxy = $null
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(20000)
    $t = $ws.ConnectAsync([Uri]'wss://fx-ws.gateio.ws/v4/ws/usdt', $cts.Token)
    if ($t.Wait(9000) -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $sub = '{"time":1690000000,"channel":"futures.tickers","event":"subscribe","payload":["BTC_USDT"]}'
        $sb = [Text.Encoding]::UTF8.GetBytes($sub)
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(, $sb)
        $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)

        $buf = New-Object byte[] 8192
        for ($i = 1; $i -le 3; $i++) {
            $rs = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)
            $rt = $ws.ReceiveAsync($rs, $cts.Token)
            if ($rt.Wait(10000)) {
                $msg = [Text.Encoding]::UTF8.GetString($buf, 0, $rt.Result.Count)
                Write-Output ("--- msg {0} ---" -f $i)
                Write-Output $msg
            } else {
                Write-Output ("--- msg {0}: timeout ---" -f $i)
                break
            }
        }
    } else {
        Write-Output 'WS connect failed'
    }
} catch {
    Write-Output ('WS error: ' + $_.Exception.Message)
} finally {
    if ($ws) { try { $ws.Dispose() } catch { } }
}

Write-Output ''
Write-Output '=== OKX SWAP WS via proxy (first 2 messages, for reference) ==='
$ws2 = $null
try {
    $ws2 = New-Object System.Net.WebSockets.ClientWebSocket
    $ws2.Options.Proxy = New-Object System.Net.WebProxy('http://127.0.0.1:7897')
    $cts2 = New-Object System.Threading.CancellationTokenSource
    $cts2.CancelAfter(20000)
    $t2 = $ws2.ConnectAsync([Uri]'wss://ws.okx.com:8443/ws/v5/public', $cts2.Token)
    if ($t2.Wait(9000) -and $ws2.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $sub2 = '{"op":"subscribe","args":[{"channel":"tickers","instId":"BTC-USDT-SWAP"}]}'
        $sb2 = [Text.Encoding]::UTF8.GetBytes($sub2)
        $seg2 = New-Object System.ArraySegment[byte] -ArgumentList @(, $sb2)
        $ws2.SendAsync($seg2, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts2.Token).Wait(5000)

        $buf2 = New-Object byte[] 8192
        for ($i = 1; $i -le 2; $i++) {
            $rs2 = New-Object System.ArraySegment[byte] -ArgumentList @(, $buf2)
            $rt2 = $ws2.ReceiveAsync($rs2, $cts2.Token)
            if ($rt2.Wait(10000)) {
                $msg2 = [Text.Encoding]::UTF8.GetString($buf2, 0, $rt2.Result.Count)
                Write-Output ("--- msg {0} ---" -f $i)
                Write-Output $msg2
            } else {
                Write-Output ("--- msg {0}: timeout ---" -f $i)
                break
            }
        }
    } else {
        Write-Output 'WS connect failed'
    }
} catch {
    Write-Output ('WS error: ' + $_.Exception.Message)
} finally {
    if ($ws2) { try { $ws2.Dispose() } catch { } }
}

Write-Output ''
Write-Output '=== DONE ==='
