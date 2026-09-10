param([ValidateSet('test-first', 'test-second')][string]$Phase)
$ErrorActionPreference = 'Stop'
$directory = "$env:RUNNER_TEMP/windows-diagnostics"
# Change only source mtime: preserve content, dependencies, flags and build outputs.
$source = Get-Item 'spotify_player/src/main.rs'
$before = (Get-FileHash $source.FullName).Hash
$source.LastWriteTimeUtc = [DateTime]::UtcNow
if ((Get-FileHash $source.FullName).Hash -ne $before) { throw 'Source content changed unexpectedly.' }
@{phase = $Phase; utc = [DateTime]::UtcNow.ToString('o'); sourceHash = $before; sourceMtime = $source.LastWriteTimeUtc.ToString('o'); boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')} |
    ConvertTo-Json -Compress | Add-Content "$directory/forced-rebuilds.jsonl"
& "$PSScriptRoot/windows-diagnostics.ps1" -Mode Run -Phase $Phase -CargoArguments @('test', '--locked', '--timings', '--no-default-features', '--features', $env:RUST_FEATURES)
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$report = Get-Content "$directory/$Phase-timings/cargo-timing.html" -Raw
$match = [regex]::Match($report, '(?s)const UNIT_DATA = (\[.*?\]);')
if (-not $match.Success) { throw 'Cannot read Cargo timing units; rebuild was not verified.' }
$compiled = @(($match.Groups[1].Value | ConvertFrom-Json) | Where-Object { $_.duration -gt 0 })
if (-not ($compiled | Where-Object { $_.name -eq 'spotify_player' })) { throw 'App did not rebuild; comparison is invalid.' }
if ($compiled | Where-Object { $_.name -ne 'spotify_player' }) { throw 'Dependencies rebuilt; expected only the app to rebuild.' }
$compiled | ConvertTo-Json -Depth 10 | Set-Content "$directory/$Phase-compiled-units.json"
"$Phase : verified app rebuild, with dependencies reused" >> $env:GITHUB_STEP_SUMMARY
