param([ValidateSet('control', 'suppressed')][string]$Treatment)
$ErrorActionPreference = 'Stop'
$directory = "$env:RUNNER_TEMP/windows-diagnostics"
New-Item -ItemType Directory -Force $directory | Out-Null
$serviceNames = @('wuauserv', 'UsoSvc', 'BITS', 'DoSvc', 'TrustedInstaller', 'edgeupdate', 'edgeupdatem')
function Snapshot {
    @{
        utc = [DateTime]::UtcNow.ToString('o')
        boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        launched = $env:RUNS_ON_INSTANCE_LAUNCHED_AT
        treatment = $Treatment
        services = @(Get-Service -Name $serviceNames -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType)
        processes = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'TiWorker|TrustedInstaller|MoUso|UsoClient|EdgeUpdate' } | Select-Object Name, ProcessId)
    }
}
Snapshot | ConvertTo-Json -Depth 5 | Set-Content "$directory/updates-before.json"
$operations = [System.Collections.Generic.List[object]]::new()
if ($Treatment -eq 'suppressed') {
    # Only disposable diagnostic runners: defer OS/browser updates for this experiment.
    $windowsPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $edgePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    New-Item -Force $windowsPolicy | Out-Null
    New-ItemProperty $windowsPolicy -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
    New-Item -Force $edgePolicy | Out-Null
    New-ItemProperty $edgePolicy -Name UpdateDefault -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty $edgePolicy -Name AutoUpdateCheckPeriodMinutes -Value 0 -PropertyType DWord -Force | Out-Null
    foreach ($task in (Get-ScheduledTask | Where-Object {
        $_.TaskPath -match '^\\Microsoft\\Windows\\(WindowsUpdate|UpdateOrchestrator|Servicing)\\' -or $_.TaskName -match 'MicrosoftEdgeUpdate'
    })) {
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
            Stop-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath
            $operations.Add(@{task = "$($task.TaskPath)$($task.TaskName)"; result = 'disabled'})
        } catch { $operations.Add(@{task = "$($task.TaskPath)$($task.TaskName)"; error = $_.Exception.Message}) }
    }
    foreach ($name in $serviceNames) {
        $service = Get-Service $name -ErrorAction SilentlyContinue
        if (-not $service) { continue }
        try {
            Set-Service $name -StartupType Disabled
            Stop-Service $name -Force
            $operations.Add(@{service = $name; result = 'disabled and stopped'})
        } catch { $operations.Add(@{service = $name; error = $_.Exception.Message}) }
    }
}
$operations | ConvertTo-Json -Depth 5 | Set-Content "$directory/update-operations.json"
Snapshot | ConvertTo-Json -Depth 5 | Set-Content "$directory/updates-after.json"
# The process samples throughout Cargo are the final check that suppression held.
# Protected Windows tasks/services can reject changes; preserve that evidence.
