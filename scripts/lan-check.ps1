param(
    [ValidatePattern('^[0-9a-f]{32}$')]
    [string] $OperationToken
)

$checks = @()
$failed = $false
foreach ($target in 'https://www.google.com/generate_204', 'https://cp.cloudflare.com/') {
    $code = & curl.exe -q --noproxy '*' --connect-timeout 4 --max-time 10 -sS -o NUL -w '%{http_code}' $target
    $curlExit = $LASTEXITCODE
    $passed = $curlExit -eq 0 -and $code -eq '204'
    $check = [pscustomobject]@{
        CheckedAt = [DateTimeOffset]::Now.ToString('o')
        Target = $target
        HTTP = $code
        CurlExit = $curlExit
        Passed = $passed
    }
    if ($OperationToken) { $checks += $check }
    else { $check | ConvertTo-Json -Compress }
    if (!$passed) { $failed = $true }
}
if ($OperationToken) {
    [pscustomobject]@{
        schema_version = 1
        token = $OperationToken
        checks = $checks
    } | ConvertTo-Json -Depth 4 -Compress
}
if ($failed) { exit 1 }
exit 0
