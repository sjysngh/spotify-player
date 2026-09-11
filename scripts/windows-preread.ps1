param([ValidateSet('control', 'dependencies', 'tools')][string]$Treatment)
$ErrorActionPreference = 'Stop'
$directory = "$env:RUNNER_TEMP/windows-diagnostics"
New-Item -ItemType Directory -Force $directory | Out-Null
$started = [DateTime]::UtcNow
$timer = [Diagnostics.Stopwatch]::StartNew()
$roots = [System.Collections.Generic.List[string]]::new()
$files = @()
if ($Treatment -eq 'dependencies') {
    $roots.Add((Resolve-Path 'target/debug/deps').Path)
    $roots.Add((Resolve-Path 'target/debug/build').Path)
    $files = @(foreach ($root in $roots) {
        Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in '.rlib', '.lib', '.dll', '.rmeta' }
    })
} elseif ($Treatment -eq 'tools') {
    $rustc = (& rustup which rustc).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot locate pinned Rust compiler.' }
    $rustRoot = Split-Path (Split-Path $rustc)
    $roots.Add((Join-Path $rustRoot 'bin'))
    $roots.Add((Join-Path $rustRoot 'lib/rustlib/x86_64-pc-windows-msvc/lib'))
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    $vs = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    if (-not $vs) { throw 'Cannot locate Visual C++ toolchain.' }
    $vc = Get-ChildItem "$vs/VC/Tools/MSVC" -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $roots.Add((Join-Path $vc.FullName 'bin/Hostx64/x64'))
    $roots.Add((Join-Path $vc.FullName 'lib/x64'))
    $sdk = Get-ChildItem "${env:ProgramFiles(x86)}/Windows Kits/10/Lib" -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $roots.Add((Join-Path $sdk.FullName 'um/x64'))
    $roots.Add((Join-Path $sdk.FullName 'ucrt/x64'))
    $files = @(foreach ($root in $roots) {
        if (-not (Test-Path $root)) { throw "Missing tool directory: $root" }
        Get-ChildItem $root -File | Where-Object { $_.Extension -in '.rlib', '.lib', '.dll', '.exe', '.rmeta' }
    })
}
$files = @($files | Sort-Object FullName -Unique)
if ($Treatment -ne 'control' -and $files.Count -eq 0) { throw 'Treatment selected no files.' }
$buffer = [byte[]]::new(1024 * 1024)
[long]$totalBytes = 0
foreach ($file in $files) {
    $fileTimer = [Diagnostics.Stopwatch]::StartNew()
    [long]$bytes = 0
    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $bytes += $count }
    } finally { $stream.Dispose() }
    $totalBytes += $bytes
    @{path = $file.FullName; bytes = $bytes; seconds = $fileTimer.Elapsed.TotalSeconds} |
        ConvertTo-Json -Compress | Add-Content "$directory/preread-files.jsonl"
}
$timer.Stop()
@{
    treatment = $Treatment; started = $started.ToString('o'); ended = [DateTime]::UtcNow.ToString('o')
    boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    roots = @($roots); fileCount = $files.Count; bytes = $totalBytes; seconds = $timer.Elapsed.TotalSeconds
} | ConvertTo-Json -Depth 5 | Set-Content "$directory/preread.json"
"Pre-read $Treatment : $($files.Count) files, $totalBytes bytes, $($timer.Elapsed.TotalSeconds) seconds" >> $env:GITHUB_STEP_SUMMARY
