#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    v-BAZ installer: carve out a partition, drop Alpine Linux (KVM/libvirt/
    QEMU host) onto it, and add a Windows Boot Manager entry to boot it -
    all from within Windows, no USB stick.

.DESCRIPTION
    Runs entirely on Windows. It:
      1. Pre-flight checks (UEFI, Secure Boot, free space, BitLocker, ...).
      2. Shrinks the chosen NTFS volume and creates a tagged Alpine
         partition (left unformatted; Linux formats it).
      3. Downloads Alpine netboot files + the rEFInd EFI bootloader.
      4. Builds an Alpine overlay (apkovl) with an unattended provisioner.
      5. Stages everything on the EFI System Partition and registers a
         Windows Boot Manager entry.

    On the FIRST boot into that entry, Alpine runs the provisioner which
    formats VBAZ_ROOT, installs Alpine "sys" onto it, installs the
    virtualization stack, then flips the boot entry to the installed system.

    Read docs/SAFETY.md before running. Repartitioning can destroy data;
    take a backup. Use -DryRun first to see the plan without touching disk.

.PARAMETER Config
    Path to a .psd1 config (defaults to windows\vbaz.config.psd1).

.PARAMETER DryRun
    Print/plan everything but make no destructive change.

.PARAMETER Force
    Skip interactive confirmations (for automation). Dangerous.

.EXAMPLE
    # Preview only:
    .\Install-VBaz.ps1 -DryRun

.EXAMPLE
    # Real run, 60 GB root on D:, no swap partition:
    .\Install-VBaz.ps1 -ShrinkDriveLetter D -AlpineRootSize 60GB -AlpineSwapSize 0
#>
[CmdletBinding()]
param(
    [string]$Config,
    [ValidateSet('existing', 'shrink')][string]$HostMode,
    [string]$HostDriveLetter,
    [string]$ShrinkDriveLetter,
    [string]$AlpineRootSize,
    [string]$AlpineSwapSize,
    [string]$AlpineBranch,
    [string]$AlpineVersion,
    [string]$ZfsDriveLetter,
    [switch]$NoZfs,
    [switch]$SecureBoot,
    [switch]$SetPassword,
    [string]$WifiSSID,
    [switch]$SetWifiPassword,
    [string]$Offline,          # path to a bundle built by tools/build-offline-bundle.sh
    [switch]$VerboseLog,
    [string]$LogFile,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptRoot

# Load libraries.
. (Join-Path $ScriptRoot 'lib\Common.ps1')
. (Join-Path $ScriptRoot 'lib\Preflight.ps1')
. (Join-Path $ScriptRoot 'lib\Partition.ps1')
. (Join-Path $ScriptRoot 'lib\Download.ps1')
. (Join-Path $ScriptRoot 'lib\SecureBoot.ps1')
. (Join-Path $ScriptRoot 'lib\Apkovl.ps1')
. (Join-Path $ScriptRoot 'lib\Boot.ps1')

$script:VBazDryRun = [bool]$DryRun

Write-Host ''
Write-Host '  v-BAZ  ::  Alpine + KVM/libvirt/QEMU, side by side with Windows' -ForegroundColor Cyan
Write-Host '  ---------------------------------------------------------------' -ForegroundColor Cyan
Initialize-VBazLog -Path $LogFile -VerboseConsole:$VerboseLog
if ($DryRun) { Write-VBazLog 'DRY-RUN mode: no disk or boot changes will be made.' -Level WARN }

try {
    Assert-VBazAdmin
    Write-VBazLog "Args: HostMode=$HostMode HostDriveLetter=$HostDriveLetter ZfsDriveLetter=$ZfsDriveLetter SecureBoot=$SecureBoot NoZfs=$NoZfs DryRun=$DryRun" -Level DEBUG

    if (-not $Config) { $Config = Join-Path $ScriptRoot 'vbaz.config.psd1' }
    $override = @{
        HostMode          = $HostMode
        HostDriveLetter   = $HostDriveLetter
        ShrinkDriveLetter = $ShrinkDriveLetter
        AlpineRootSize    = $AlpineRootSize
        AlpineSwapSize    = $AlpineSwapSize
        AlpineBranch      = $AlpineBranch
        AlpineVersion     = $AlpineVersion
        ZfsDriveLetter    = $ZfsDriveLetter
        WifiSSID          = $WifiSSID
    }
    $cfg = Import-VBazConfig -Path $Config -Override $override
    if ($NoZfs)     { $cfg.ZfsEnable = $false }
    if ($SecureBoot){ $cfg.SecureBootEnroll = $true }
    if ($VerboseLog){ $cfg.Verbose = $true }  # carry verbosity into the Alpine provisioner
    if ($Offline)   { $cfg.OfflineBundleDir = $Offline }
    if ($cfg.OfflineBundleDir) {
        if (-not (Test-Path (Join-Path $cfg.OfflineBundleDir 'bundle.env'))) {
            throw "Offline bundle not found at '$($cfg.OfflineBundleDir)' (no bundle.env). Build it with tools/build-offline-bundle.sh. See docs/OFFLINE.md."
        }
        $cfg.Offline = $true
        Write-VBazLog "Offline mode: bundle $($cfg.OfflineBundleDir)" -Level INFO
    }
    Write-VBazLog "Config: $Config (log: $script:VBazLogFile)" -Level INFO
    Write-VBazLog ("Effective config: " + (($cfg.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')) -Level DEBUG

    # 1) Pre-flight
    $facts = Invoke-VBazPreflight -Config $cfg
    if ($facts.BitLocker -and $cfg.RequireBitLockerAck -and -not $Force) {
        if (-not (Confirm-VBazAction -Prompt 'BitLocker is ON. Do you have your recovery key and accept the risk?')) {
            throw 'Aborted: acknowledge BitLocker risk (or suspend BitLocker) before continuing.'
        }
    }

    # Summary + master confirmation.
    Write-Host ''
    Write-VBazLog 'PLAN' -Level STEP
    if ($cfg.HostMode -eq 'existing') {
        Write-VBazLog ("  Host: repurpose existing partition {0}: as Alpine root (reformat ext4)" -f $cfg.HostDriveLetter) -Level INFO
    } else {
        Write-VBazLog ("  Host: shrink {0}: and create Alpine root {1}" -f $cfg.ShrinkDriveLetter, $cfg.AlpineRootSize) -Level INFO
    }
    Write-VBazLog ("  Alpine {0} ({1}/{2})" -f $cfg.AlpineVersion, $cfg.AlpineBranch, $cfg.Flavor) -Level INFO
    if ($cfg.ZfsEnable) {
        Write-VBazLog ("  Guest pool: convert {0}: to ZFS pool '{1}' [DESTRUCTIVE]" -f $cfg.ZfsDriveLetter, $cfg.ZfsPoolName) -Level WARN
    }
    if ($cfg.SecureBootEnroll) {
        Write-VBazLog "  Secure Boot: stage shim + MOK (one MokManager enrollment at first boot)" -Level INFO
    }
    Write-VBazLog ("  Boot entry: '{0}' via {1} on the ESP" -f $cfg.BootEntryName, $cfg.Bootloader) -Level INFO
    Write-VBazLog ("  Provision sets: {0}" -f ($cfg.PackageSets -join ', ')) -Level INFO
    Write-Host ''
    if (-not (Confirm-VBazAction -Prompt 'Proceed with the full install?' -Force:$Force)) {
        throw 'Aborted by operator at plan confirmation.'
    }

    # Optional password capture.
    $pw = $null
    if ($SetPassword) {
        Write-VBazLog 'Capturing a password for the Alpine operator account (stored transiently on the ESP).' -Level WARN
        $pw = Read-Host -AsSecureString "Password for '$($cfg.Username)'"
    }

    # Optional Wi-Fi passphrase capture (installed-host Wi-Fi).
    $wifiPsk = $null
    if ($SetWifiPassword) {
        if (-not $cfg.WifiSSID) { throw 'Set WifiSSID (config or -WifiSSID) before -SetWifiPassword.' }
        Write-VBazLog "Capturing the Wi-Fi passphrase for '$($cfg.WifiSSID)' (stored transiently on the ESP)." -Level WARN
        $wifiPsk = Read-Host -AsSecureString "Wi-Fi passphrase for '$($cfg.WifiSSID)'"
    }

    $stage = Join-Path $env:TEMP 'vbaz-stage'

    # 2) Partitioning - host (existing or shrink) + optional ZFS tag
    if ($cfg.HostMode -eq 'existing') {
        $parts = Set-VBazExistingHost -Config $cfg -Force:$Force
    } else {
        $parts = New-VBazPartitions -Config $cfg -Facts $facts -Force:$Force
    }
    if ($cfg.ZfsEnable) { $null = Set-VBazZfsPartition -Config $cfg -Force:$Force }

    # 3) Downloads
    $dl = Invoke-VBazDownload -Config $cfg -StageDir $stage

    # 4) Secure Boot (sign rEFInd + installer kernel, gather shim + MOK)
    $sb = $null
    if ($cfg.SecureBootEnroll) {
        $sb = Invoke-VBazSecureBoot -Config $cfg -Downloads $dl -ScriptRoot $ScriptRoot -StageDir $stage
    }

    # 5) Overlay (carries MOK key when Secure Boot is on)
    $mokDir = if ($sb) { $sb.MokDir } else { $null }
    $apkovl = Build-VBazApkovl -Config $cfg -RepoRoot $RepoRoot -StageDir $stage -Password $pw -WifiPsk $wifiPsk -MokDir $mokDir

    # 6) Boot integration
    Install-VBazBoot -Config $cfg -Facts $facts -Downloads $dl -RepoRoot $RepoRoot -ApkovlPath $apkovl -SecureBoot $sb -Force:$Force

    Write-Host ''
    Write-VBazLog 'v-BAZ Windows-side install complete.' -Level OK
    Write-VBazLog "Next: reboot and select '$($cfg.BootEntryName)' from the boot menu." -Level INFO
    Write-VBazLog 'First Alpine boot runs unattended provisioning (formats VBAZ_ROOT, installs the KVM stack, then reboots into the installed system).' -Level INFO
    Write-VBazLog 'Watch the first boot on-screen; keep this machine plugged in and on the network.' -Level INFO
}
catch {
    Write-VBazLog $_.Exception.Message -Level ERROR
    Write-VBazLog ($_.ScriptStackTrace) -Level DEBUG
    Write-VBazLog "See $script:VBazLogFile and docs/TROUBLESHOOTING.md" -Level ERROR
    Stop-VBazLog
    exit 1
}
finally {
    Stop-VBazLog
}
