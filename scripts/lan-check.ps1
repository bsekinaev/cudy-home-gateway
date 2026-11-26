$failed = $false
foreach ($target in 'https://www.google.com/generate_204', 'https://cp.cloudflare.com/') {
    $code = & curl.exe -q --noproxy '*' --connect-timeout 4 --max-time 10 -sS -o NUL -w '%{http_code}' $target
    $curlExit = $LASTEXITCODE
    $passed = $curlExit -eq 0 -and $code -eq '204'
    [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o')
        Target = $target
        HTTP = $code
        CurlExit = $curlExit
        Passed = $passed
    } | ConvertTo-Json -Compress
    if (!$passed) { $failed = $true }
}
if ($failed) { exit 1 }
exit 0
