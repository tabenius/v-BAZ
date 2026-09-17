#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reverse the v-BAZ Windows-side changes: remove the boot entry and the
    files staged on the ESP, and (optionally) delete the Alpine partitions.

.DESCRIPTION
    By default this removes ONLY the boot entry and ESP files - it does NOT
    touch the Alpine partition, so you can re-run the installer or keep the
    data. Pass -RemovePartitions to also delete VBAZ_ROOT/VBAZ_SWAP and hand
    the space back (you must extend C: manually afterwards).

.EXAMPLE
    .\Uninstall-VBaz.ps1
.EXAMPLE
    .\Uninstall-VBaz.ps1 -RemovePartitions
#>
[CmdletBinding()]
param(
    [string]$Config,
    [switch]$RemovePartitions,
    [switch]$VerboseLog,
    [string]$LogFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $ScriptRoot 'lib\Common.ps1')
. (Join-Path $ScriptRoot 'lib\Preflight.ps1')
. (Join-Path $ScriptRoot 'lib\Boot.ps1')

$script:VBazDryRun = $false
Initialize-VBazLog -Path $LogFile -VerboseConsole:$VerboseLog

try {
    Assert-VBazAdmin
    if (-not $Config) { $Config = Join-Path $ScriptRoot 'vbaz.config.psd1' }
    $cfg = Import-VBazConfig -Path $Config

    Write-VBazLog 'Removing Windows Boot Manager entry' -Level STEP
    Remove-VBazBcdEntry

    Write-VBazLog 'Removing v-BAZ files from the EFI System Partition' -Level STEP
    $esp = Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
    if ($esp) {
        $letter = Mount-VBazEsp -EspPartition $esp
        try {
            $dir = Join-Path "$letter\EFI" $cfg.EspSubdir
            if (Test-Path $dir) { Remove-Item -Recurse -Force $dir; Write-VBazLog "Deleted $dir" -Level OK }
            else { Write-VBazLog "Nothing at $dir" -Level WARN }
            $apkovl = Join-Path "$letter\" 'vbaz.apkovl.tar.gz'
            if (Test-Path $apkovl) { Remove-Item -Force $apkovl; Write-VBazLog "Deleted $apkovl" -Level OK }
        } finally { Dismount-VBazEsp -EspPartition $esp -AccessPath $letter }
    }

    if ($RemovePartitions) {
        Write-VBazLog 'Deleting Alpine partitions (VBAZ_ROOT / VBAZ_SWAP)' -Level STEP
        $targets = Get-Partition | Where-Object {
            $_.GptType -eq "{$($cfg.RootPartitionType.ToLower())}" -or
            $_.GptType -eq "{$($cfg.SwapPartitionType.ToLower())}"
        }
        foreach ($p in $targets) {
            if (Confirm-VBazAction -Prompt "Delete disk $($p.DiskNumber) partition $($p.PartitionNumber) ($([math]::Round($p.Size/1GB,1)) GB)?" -Force:$Force) {
                Remove-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
                Write-VBazLog "Removed partition $($p.PartitionNumber) on disk $($p.DiskNumber)" -Level OK
            }
        }
        Write-VBazLog 'Reclaimed space is now unallocated. Extend C: via Disk Management if desired.' -Level INFO
    } else {
        Write-VBazLog 'Left Alpine partitions in place (use -RemovePartitions to delete them).' -Level INFO
    }

    Write-VBazLog 'Uninstall complete.' -Level OK
}
catch {
    Write-VBazLog $_.Exception.Message -Level ERROR
    Write-VBazLog ($_.ScriptStackTrace) -Level DEBUG
    exit 1
}
finally {
    Stop-VBazLog
}
