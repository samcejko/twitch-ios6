# Runs every GraphQL query of src/Twitch/TWGQL.m against the live API with sample variables, as a visitor who is not
# logged in, and reports validation errors. Usage: .\tools\check-gql.ps1 [-Channel agraelus] [-VideoId 2889068196]
param(
    [string]$Channel = 'agraelus',
    [string]$VideoId = '2889068196',
    [string]$ClipSlug = 'SparklyNaiveSandwichOptimizePrime',
    [string]$GameId = '509658'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$source = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Twitch\TWGQL.m') -Raw -Encoding UTF8

# #define NAME @"..." (one line each)
$macros = @{}
foreach ($m in [regex]::Matches($source, '(?m)^#define (TW_[A-Z_]+) @"((?:[^"\\]|\\.)*)"\s*$')) {
    $macros[$m.Groups[1].Value] = $m.Groups[2].Value
}
# static NSString * const TWQueryX = @"..." MACRO @"...";
$queries = [ordered]@{}
foreach ($m in [regex]::Matches($source, 'static NSString \* const (TWQuery\w+) =\s*((?:@"(?:[^"\\]|\\.)*"|TW_[A-Z_]+|\s)+);')) {
    $text = ''
    foreach ($p in [regex]::Matches($m.Groups[2].Value, '@"((?:[^"\\]|\\.)*)"|(TW_[A-Z_]+)')) {
        if ($p.Groups[2].Success) { $text += $macros[$p.Groups[2].Value] } else { $text += $p.Groups[1].Value }
    }
    $queries[$m.Groups[1].Value] = $text.Replace('\"', '"')
}
Write-Host "$($queries.Count) queries found"

$variables = @{
    TWQueryTopStreams    = @{ first = 2; options = @{ broadcasterLanguages = @('CS') } }
    TWQueryTopGames      = @{ first = 2 }
    TWQueryGameStreams   = @{ id = $GameId; first = 2; options = @{ sort = 'VIEWER_COUNT' } }
    TWQueryGameClips     = @{ id = $GameId; first = 2; period = 'LAST_DAY' }
    TWQuerySearch        = @{ q = 'gothic' }
    TWQueryChannel       = @{ login = $Channel }
    TWQueryChannels      = @{ logins = @($Channel, 'zackrawrr') }
    TWQueryVideos        = @{ login = $Channel; first = 2; type = 'ARCHIVE' }
    TWQueryClips         = @{ login = $Channel; first = 2; period = 'ALL_TIME' }
    TWQueryVideo         = @{ id = $VideoId }
    TWQueryStreamToken   = @{ login = $Channel }
    TWQueryVideoToken    = @{ id = $VideoId }
    TWQueryClip          = @{ slug = $ClipSlug }
    TWQueryGlobalBadges  = @{}
    TWQueryChannelBadges = @{ login = $Channel }
    TWQueryComments      = @{ id = $VideoId; offset = 600 }
}

$failed = 0
foreach ($name in $queries.Keys) {
    $vars = $variables[$name]
    if ($null -eq $vars) { Write-Host "$name : no sample variables" -ForegroundColor Yellow; continue }
    $body = @{ query = $queries[$name]; variables = $vars } | ConvertTo-Json -Compress -Depth 10
    try {
        $r = Invoke-RestMethod -Method Post -Uri 'https://gql.twitch.tv/gql' -Headers @{ 'Client-ID' = 'kimne78kx3ncx6brgo4mv6wki5h1ko' } `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'text/plain;charset=UTF-8' -TimeoutSec 25
        $errors = $r.errors
        $data = $r.data
        if ($errors) {
            $failed++
            Write-Host "$name : ERRORS $($errors | ConvertTo-Json -Compress -Depth 5)" -ForegroundColor Red
        } elseif ($null -eq $data) {
            $failed++
            Write-Host "$name : no data" -ForegroundColor Red
        } else {
            $json = $data | ConvertTo-Json -Compress -Depth 12
            Write-Host ("{0} : OK ({1} chars) {2}" -f $name, $json.Length, $json.Substring(0, [Math]::Min(160, $json.Length)))
        }
    } catch {
        $failed++
        Write-Host "$name : REQUEST FAILED $($_.Exception.Message)" -ForegroundColor Red
    }
}
if ($failed) { Write-Host "$failed queries failed" -ForegroundColor Red; exit 1 }
Write-Host "All queries validated." -ForegroundColor Green
