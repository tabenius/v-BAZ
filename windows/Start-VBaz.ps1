#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Guided text interface for planning and starting a v-BAZ installation.

.DESCRIPTION
    Lists Windows volumes with stable disk/partition identities, explains the
    destructive choices, collects only installer-supported settings, prints the
    resulting plan, and defaults to a non-destructive dry run.
#>
[CmdletBinding()]
param([string]$Config)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Installer = Join-Path $ScriptRoot 'Install-VBaz.ps1'
if (-not $Config) { $Config = Join-Path $ScriptRoot 'vbaz.config.psd1' }

function Read-Default {
    param([string]$Prompt, [string]$Default = '')
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Prompt [$hint]").Trim().ToLowerInvariant()
        if (-not $answer) { return $Default }
        if ($answer -in @('y','yes','j','ja')) { return $true }
        if ($answer -in @('n','no','nej')) { return $false }
        Write-Host 'Answer y/yes or n/no.' -ForegroundColor Yellow
    }
}

function Get-VolumeCandidates {
    $items = @()
    foreach ($volume in (Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter)) {
        $partition = Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction SilentlyContinue
        if (-not $partition) { continue }
        $items += [pscustomobject]@{
            Drive       = [string]$volume.DriveLetter
            Disk        = [int]$partition.DiskNumber
            Partition   = [int]$partition.PartitionNumber
            SizeGB      = [math]::Round($partition.Size / 1GB, 1)
            FreeGB      = [math]::Round($volume.SizeRemaining / 1GB, 1)
            FileSystem  = [string]$volume.FileSystem
            Label       = [string]$volume.FileSystemLabel
            Boot        = [bool]$partition.IsBoot
            System      = [bool]$partition.IsSystem
        }
    }
    return $items
}

function Show-Volumes {
    param([object[]]$Volumes)
    Write-Host ''
    Write-Host 'Available Windows volumes (identity is disk + partition, not only letter)' -ForegroundColor Cyan
    $Volumes | Format-Table Drive,Disk,Partition,SizeGB,FreeGB,FileSystem,Label,Boot,System -AutoSize
}

function Select-Drive {
    param(
        [object[]]$Volumes,
        [string]$Prompt,
        [string]$Default,
        [switch]$AllowBoot
    )
    while ($true) {
        $letter = (Read-Default -Prompt $Prompt -Default $Default).TrimEnd(':').ToUpperInvariant()
        $candidate = $Volumes | Where-Object Drive -eq $letter | Select-Object -First 1
        if (-not $candidate) {
            Write-Host "No listed volume has drive letter $letter." -ForegroundColor Yellow
            continue
        }
        if (-not $AllowBoot -and ($candidate.Boot -or $candidate.System)) {
            Write-Host "$letter is a boot/system volume and cannot be selected for destructive reuse." -ForegroundColor Red
            continue
        }
        return $candidate
    }
}

Clear-Host
Write-Host 'v-BAZ guided installer' -ForegroundColor Cyan
Write-Host 'This wizard prepares the existing Install-VBaz.ps1 command.' -ForegroundColor DarkGray
Write-Host 'Nothing is changed until the final choice; dry-run is the default.' -ForegroundColor Green

$volumes = @(Get-VolumeCandidates)
if (-not $volumes.Count) { throw 'No drive-letter volumes found.' }
Show-Volumes -Volumes $volumes

Write-Host ''
Write-Host 'Alpine host partition' -ForegroundColor Cyan
Write-Host '  existing: retype and later format one whole partition (all data lost).'
Write-Host '  shrink:   shrink an NTFS volume and create a new Alpine partition.'
$hostMode = Read-Default 'Mode: existing or shrink' 'existing'
while ($hostMode -notin @('existing','shrink')) {
    $hostMode = Read-Default 'Enter existing or shrink' 'existing'
}

$invoke = @{ Config = $Config }
$host = $null
if ($hostMode -eq 'existing') {
    $host = Select-Drive -Volumes $volumes -Prompt 'Partition to erase and use as Alpine host' -Default ''
    $invoke.HostMode = 'existing'
    $invoke.HostDriveLetter = $host.Drive
} else {
    $host = Select-Drive -Volumes $volumes -Prompt 'NTFS volume to shrink' -Default 'C' -AllowBoot
    $invoke.HostMode = 'shrink'
    $invoke.ShrinkDriveLetter = $host.Drive
    $invoke.AlpineRootSize = Read-Default 'New Alpine root size (for example 12GB)' '12GB'
    $invoke.AlpineSwapSize = Read-Default 'Swap partition size; 0 uses zram' '0'
}

Write-Host ''
Write-Host 'Guest storage' -ForegroundColor Cyan
Write-Host 'A ZFS target is converted in full and all existing data on it is lost.'
$useZfs = Read-YesNo 'Create the v-BAZ ZFS guest pool?' $true
$zfs = $null
if ($useZfs) {
    $zfs = Select-Drive -Volumes $volumes -Prompt 'Whole partition to erase for ZFS' -Default 'D'
    if ($hostMode -eq 'existing' -and $zfs.Drive -eq $host.Drive) {
        throw 'The Alpine host and ZFS target cannot be the same partition.'
    }
    $invoke.ZfsDriveLetter = $zfs.Drive
} else {
    $invoke.NoZfs = $true
}

Write-Host ''
Write-Host 'Boot, network, and credentials' -ForegroundColor Cyan
if (Read-YesNo 'Stage shim + MOK enrollment for Secure Boot?' $false) { $invoke.SecureBoot = $true }
$offline = Read-Default 'Offline bundle directory (blank for online install)' ''
if ($offline) { $invoke.Offline = $offline }
$wifi = Read-Default 'Installed-host Wi-Fi SSID (blank to skip)' ''
if ($wifi) {
    $invoke.WifiSSID = $wifi
    if (Read-YesNo 'Capture its passphrase securely during installation?' $true) { $invoke.SetWifiPassword = $true }
}
if (Read-YesNo 'Set the Alpine operator password during installation?' $true) { $invoke.SetPassword = $true }

Write-Host ''
Write-Host 'Decision summary' -ForegroundColor Cyan
if ($hostMode -eq 'existing') {
    Write-Host ("  Alpine host: ERASE {0}: (disk {1}, partition {2}, {3} GB, label '{4}')" -f $host.Drive,$host.Disk,$host.Partition,$host.SizeGB,$host.Label) -ForegroundColor Yellow
} else {
    Write-Host ("  Alpine host: shrink {0}: on disk {1} by root {2} + swap {3}" -f $host.Drive,$host.Disk,$invoke.AlpineRootSize,$invoke.AlpineSwapSize)
}
if ($useZfs) {
    Write-Host ("  Guest pool:  ERASE {0}: (disk {1}, partition {2}, {3} GB, label '{4}') -> ZFS" -f $zfs.Drive,$zfs.Disk,$zfs.Partition,$zfs.SizeGB,$zfs.Label) -ForegroundColor Yellow
} else {
    Write-Host '  Guest pool:  disabled (Kata devmapper/Rebekah defaults require ZFS; adjust package sets if proceeding).' -ForegroundColor Yellow
}
Write-Host ("  Secure Boot enrollment: {0}" -f $invoke.ContainsKey('SecureBoot'))
Write-Host ("  Offline bundle: {0}" -f $(if ($offline) { $offline } else { '<none>' }))
Write-Host ("  Wi-Fi SSID: {0}" -f $(if ($wifi) { $wifi } else { '<none>' }))

Write-Host ''
Write-Host 'Next action: [D]ry-run (recommended), [I]nstall, or [Q]uit' -ForegroundColor Cyan
$action = (Read-Default 'Choose' 'D').ToUpperInvariant()
switch ($action) {
    'D' {
        $invoke.DryRun = $true
        & $Installer @invoke
    }
    'I' {
        Write-Host 'Install selected. The underlying installer will ask again before repartitioning.' -ForegroundColor Red
        & $Installer @invoke
    }
    default {
        Write-Host 'No changes made.'
    }
}
