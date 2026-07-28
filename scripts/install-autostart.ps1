<#
.SYNOPSIS
  Register (or remove) a per-user logon scheduled task that keeps the OmniRoute server
  running, so `claude-omni` always has a live backend.

.DESCRIPTION
  Creates a scheduled task named "OmniRoute Server" that runs scripts\start-omniroute.ps1
  at logon. start-omniroute.ps1 is idempotent (health-checks first), so the task never
  spawns a duplicate server. The task is resolved relative to this script's location, so
  it works from wherever the repo is cloned.

.PARAMETER Port
  OmniRoute server port passed to start-omniroute.ps1 (default: 20128).

.PARAMETER TaskName
  Scheduled task name (default: "OmniRoute Server").

.PARAMETER Uninstall
  Remove the scheduled task instead of creating it.

.EXAMPLE
  pwsh -File .\install-autostart.ps1

.EXAMPLE
  pwsh -File .\install-autostart.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [int]$Port = 20128,
  [string]$TaskName = "OmniRoute Server",
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

if ($Uninstall) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
  } else {
    Write-Host "No scheduled task named '$TaskName' found." -ForegroundColor Yellow
  }
  return
}

$startScript = Join-Path $PSScriptRoot "start-omniroute.ps1"
if (-not (Test-Path $startScript)) { throw "start-omniroute.ps1 not found next to this script ($startScript)." }

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }

$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`" -Port $Port"
$action    = New-ScheduledTaskAction -Execute $pwsh -Argument $arg
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Registered logon task '$TaskName' (port $Port)." -ForegroundColor Green
Write-Host "  Run now : Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Remove  : pwsh -File .\install-autostart.ps1 -Uninstall"
