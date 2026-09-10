param(
    [ValidateSet('Start', 'Collect', 'Run', 'Stop')][string]$Mode,
    [string]$Directory = "$env:RUNNER_TEMP/windows-diagnostics",
    [string]$Phase,
    [string[]]$CargoArguments
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
New-Item -ItemType Directory -Force -Path $Directory | Out-Null
$stopFile = Join-Path $Directory 'stop'
function Mark([string]$EventName) {
    @{ utc = [DateTime]::UtcNow.ToString('o'); phase = $Phase; event = $EventName } |
        ConvertTo-Json -Compress | Add-Content (Join-Path $Directory 'phases.jsonl')
}
if ($Mode -eq 'Collect') {
    $counters = @(
        '\Processor(*)\% Processor Time',
        '\Memory\Available MBytes', '\Memory\Committed Bytes', '\Memory\Commit Limit',
        '\Memory\Pages Input/sec', '\Memory\Pages Output/sec',
        '\PhysicalDisk(*)\Avg. Disk sec/Read', '\PhysicalDisk(*)\Avg. Disk sec/Write',
        '\PhysicalDisk(*)\Current Disk Queue Length',
        '\PhysicalDisk(*)\Disk Read Bytes/sec', '\PhysicalDisk(*)\Disk Write Bytes/sec'
    )
    $lastProcesses = [DateTime]::MinValue
    # Stream to disk rather than retaining an entire run in memory.
    try {
        Get-Counter -Counter $counters -SampleInterval 1 -MaxSamples 1800 -ErrorAction Continue 2> (Join-Path $Directory 'counter-errors.log') |
            ForEach-Object {
                if (Test-Path $stopFile) { throw 'Collector stopped' }
                $samples = @($_.CounterSamples | Where-Object { $_.Status -eq 0 } | ForEach-Object {
                    @{ path = $_.Path; value = $_.CookedValue }
                })
                @{ utc = $_.Timestamp.ToUniversalTime().ToString('o'); samples = $samples } |
                    ConvertTo-Json -Depth 5 -Compress | Add-Content (Join-Path $Directory 'counters.jsonl')
                # Rediscover processes so compilers launched after collection starts appear.
                # Sample these less frequently to limit observer overhead on the 2-CPU host.
                if (([DateTime]::UtcNow - $lastProcesses).TotalSeconds -ge 5) {
                    $lastProcesses = [DateTime]::UtcNow
                    try {
                        $processes = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
                            Select-Object Name, IDProcess, PercentProcessorTime, IOReadBytesPersec, IOWriteBytesPersec, WorkingSetPrivate)
                        @{ utc = $lastProcesses.ToString('o'); processes = $processes } |
                            ConvertTo-Json -Depth 5 -Compress | Add-Content (Join-Path $Directory 'processes.jsonl')
                    } catch { $_ | Out-String | Add-Content (Join-Path $Directory 'process-errors.log') }
                }
                if ($samples.Count -gt 0) { Set-Content (Join-Path $Directory 'ready') 'ready' }
            }
    } catch {
        if (-not (Test-Path $stopFile)) { $_ | Out-String | Add-Content (Join-Path $Directory 'collector-error.log'); exit 1 }
    }
    exit 0
}
if ($Mode -eq 'Start') {
    Remove-Item $stopFile -ErrorAction SilentlyContinue
    $metadata = @{
        utc = [DateTime]::UtcNow.ToString('o'); revision = $env:GITHUB_SHA
        cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
        computer = Get-CimInstance Win32_ComputerSystem | Select-Object TotalPhysicalMemory
        pagefile = @(Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage)
        cargoHome = $env:CARGO_HOME; instanceType = $env:RUNS_ON_INSTANCE_TYPE
    }
    try { $metadata.defender = Get-MpComputerStatus | Select-Object AntivirusEnabled, RealTimeProtectionEnabled } catch { $metadata.defender = $_.Exception.Message }
    $metadata | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Directory 'machine.json')
    $childArgs = @('-NoProfile', '-File', "`"$PSCommandPath`"", '-Mode', 'Collect', '-Directory', "`"$Directory`"")
    $collector = Start-Process pwsh -ArgumentList $childArgs -PassThru -RedirectStandardOutput (Join-Path $Directory 'collector.stdout') -RedirectStandardError (Join-Path $Directory 'collector.stderr')
    Set-Content (Join-Path $Directory 'collector.pid') $collector.Id
    for ($i = 0; $i -lt 15; $i++) {
        if (Test-Path (Join-Path $Directory 'ready')) { break }
        if ($collector.HasExited) { throw 'Counter collector exited before producing samples; inspect artifacts.' }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path (Join-Path $Directory 'ready'))) { throw 'Counter collector produced no valid samples; inspect artifacts.' }
    $Phase = 'cache-restore'; Mark 'start'
    exit 0
}
if ($Mode -eq 'Run') {
    if ($CargoArguments -contains '--timings') {
        Remove-Item 'target/cargo-timings' -Recurse -Force -ErrorAction SilentlyContinue
    }
    Mark 'start'
    $env:CARGO_LOG = 'cargo::core::compiler::fingerprint=info'
    $env:CARGO_TERM_COLOR = 'never'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $code = 1
    try {
        & cargo @CargoArguments 2>&1 | Tee-Object -FilePath (Join-Path $Directory "$Phase.log")
        $code = $LASTEXITCODE
    } finally {
        $timer.Stop(); Mark 'end'
        @{ phase = $Phase; seconds = $timer.Elapsed.TotalSeconds; exitCode = $code } |
            ConvertTo-Json -Compress | Add-Content (Join-Path $Directory 'durations.jsonl')
        if (($CargoArguments -contains '--timings') -and (Test-Path 'target/cargo-timings')) {
            Copy-Item 'target/cargo-timings' (Join-Path $Directory "$Phase-timings") -Recurse -Force
        }
    }
    exit $code
}
if ($Mode -eq 'Stop') {
    $Phase = 'diagnostics'; Mark 'stop'
    Set-Content $stopFile 'stop'
    $pidFile = Join-Path $Directory 'collector.pid'
    if (Test-Path $pidFile) {
        $collectorId = [int](Get-Content $pidFile)
        Wait-Process -Id $collectorId -Timeout 5 -ErrorAction SilentlyContinue
        Stop-Process -Id $collectorId -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path (Join-Path $Directory 'counters.jsonl'))) { Write-Warning 'No counters were collected. Check collector logs.' }
}
