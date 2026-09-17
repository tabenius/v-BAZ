# v-BAZ :: Pre-flight checks
# Verifies the machine is in a state where the install can succeed and be
# reversible. Returns a hashtable of gathered facts; throws on hard blockers.

Set-StrictMode -Version Latest

function Test-VBazUefi {
    # On UEFI systems PowerShell exposes SecureBoot cmdlets and the firmware
    # env var. The most reliable signal: Confirm-SecureBootUEFI throws a
    # specific "not supported on this platform" error on legacy BIOS.
    try {
        $null = Confirm-SecureBootUEFI -ErrorAction Stop
        return $true   # cmdlet worked -> UEFI (Secure Boot may be on or off)
    } catch [System.PlatformNotSupportedException] {
        return $false  # legacy BIOS
    } catch {
        # Some systems throw a plain exception when Secure Boot is simply
        # disabled but firmware is still UEFI. Fall back to the env var.
        return ($env:firmware_type -eq 'UEFI') -or (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State')
    }
}

function Get-VBazSecureBootState {
    try { return [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
    catch { return $false }
}

function Invoke-VBazPreflight {
    param([Parameter(Mandatory)][hashtable]$Config)

    Write-VBazLog 'Running pre-flight checks' -Level STEP
    $facts = @{}

    # --- Firmware must be UEFI (BCD firmware chainloading needs it) -------
    $facts.Uefi = Test-VBazUefi
    if (-not $facts.Uefi) {
        throw 'Legacy BIOS detected. v-BAZ requires UEFI firmware (GPT + Windows Boot Manager). See docs/TROUBLESHOOTING.md.'
    }
    Write-VBazLog 'Firmware: UEFI' -Level OK

    # --- Architecture ----------------------------------------------------
    $facts.Arch = $env:PROCESSOR_ARCHITECTURE
    if ($facts.Arch -ne 'AMD64') {
        throw "Unsupported CPU architecture '$($facts.Arch)'. v-BAZ targets x86_64 (AMD64)."
    }

    # --- Secure Boot -----------------------------------------------------
    $facts.SecureBoot = Get-VBazSecureBootState
    if ($facts.SecureBoot) {
        Write-VBazLog 'Secure Boot is ENABLED. Stock Alpine kernels / rEFInd are not signed for the Microsoft UEFI CA.' -Level WARN
        Write-VBazLog 'You will likely need to disable Secure Boot in firmware, or enroll keys via MokManager. See docs/TROUBLESHOOTING.md.' -Level WARN
    } else {
        Write-VBazLog 'Secure Boot: disabled' -Level OK
    }

    # --- Host partition (mode-dependent) --------------------------------
    $facts.HostMode = $Config.HostMode
    $blDrive = $null
    if ($Config.HostMode -eq 'existing') {
        $letter = $Config.HostDriveLetter
        if (-not $letter) { throw "HostMode 'existing' requires HostDriveLetter (the ~15 GB partition to repurpose)." }
        $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        $part = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
        if (-not $part) { throw "Host partition $($letter): not found." }
        if ($part.IsBoot -or $part.IsSystem) { throw "Refusing to use $($letter): as the host - it is a boot/system partition." }
        $min = 8GB
        if ([int64]$part.Size -lt $min) {
            Write-VBazLog ("Host partition $($letter): is only {0}; a full virt+container+ZFS host is tight under 12-15 GB." -f (Format-Bytes ([int64]$part.Size))) -Level WARN
        }
        $facts.HostPartition = $part
        $blDrive = $letter
        Write-VBazLog ("Host: existing partition $($letter): ({0}) - will be reformatted ext4" -f (Format-Bytes ([int64]$part.Size))) -Level OK
    }
    else {
        # shrink mode
        $drive = $Config.ShrinkDriveLetter
        $vol = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
        if (-not $vol) { throw "Drive $($drive): not found. Set ShrinkDriveLetter in the config." }
        if ($vol.FileSystemType -ne 'NTFS') { throw "Drive $($drive): is $($vol.FileSystemType); only NTFS volumes can be shrunk." }
        $facts.TargetVolume = $vol
        $need = (ConvertTo-Bytes $Config.AlpineRootSize)
        if ($Config.AlpineSwapSize -and $Config.AlpineSwapSize -ne '0') { $need += (ConvertTo-Bytes $Config.AlpineSwapSize) }
        $keep = (ConvertTo-Bytes $Config.MinWindowsFreeSpace)
        $facts.NeededBytes = $need
        if (([int64]$vol.SizeRemaining) -lt ($need + $keep)) {
            throw ("Not enough free space on {0}: need {1} plus {2} headroom, have {3}." -f `
                $drive, (Format-Bytes $need), (Format-Bytes $keep), (Format-Bytes ([int64]$vol.SizeRemaining)))
        }
        $blDrive = $drive
        Write-VBazLog ("Host: shrink $($drive): and reserve {0}" -f (Format-Bytes $need)) -Level OK
    }

    # --- ZFS target ------------------------------------------------------
    if ($Config.ZfsEnable) {
        $zl = $Config.ZfsDriveLetter
        if (-not $zl) { throw "ZfsEnable is set but ZfsDriveLetter is empty." }
        $zp = Get-Partition -DriveLetter $zl -ErrorAction SilentlyContinue
        if (-not $zp) { throw "ZFS target $($zl): not found." }
        if ($zp.IsBoot -or $zp.IsSystem) { throw "Refusing to use $($zl): for ZFS - it is a boot/system partition." }
        if ($zl -eq $blDrive) { throw "ZfsDriveLetter and the host partition cannot be the same drive ($zl)." }
        $facts.ZfsPartition = $zp
        Write-VBazLog ("ZFS pool '$($Config.ZfsPoolName)' target: $($zl): ({0}) - DESTRUCTIVE" -f (Format-Bytes ([int64]$zp.Size))) -Level WARN
    }

    # --- Secure Boot enrollment sanity ----------------------------------
    if ($Config.SecureBootEnroll -and -not $facts.SecureBoot) {
        Write-VBazLog 'SecureBootEnroll is set but Secure Boot is currently OFF - shim+MOK will still be staged and will work if you later enable Secure Boot.' -Level INFO
    }

    # --- BitLocker -------------------------------------------------------
    $facts.BitLocker = $false
    try {
        $blv = Get-BitLockerVolume -MountPoint "$($blDrive):" -ErrorAction Stop
        if ($blv.ProtectionStatus -eq 'On') {
            $facts.BitLocker = $true
            Write-VBazLog "BitLocker is ON for $($blDrive):. Repartitioning while encrypted is risky." -Level WARN
            Write-VBazLog 'Suspend BitLocker (Suspend-BitLocker) or ensure you have your recovery key before continuing.' -Level WARN
        }
    } catch {
        # Get-BitLockerVolume absent on Home editions -> treat as unknown.
        Write-VBazLog 'Could not query BitLocker (module absent?). Verify encryption state manually.' -Level WARN
    }

    # --- Fast Startup / hibernation (locks NTFS, corrupts dual boot) -----
    $hiberKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    try {
        $he = (Get-ItemProperty -Path $hiberKey -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled
        $facts.Hibernate = [bool]$he
    } catch { $facts.Hibernate = $null }
    if ($facts.Hibernate) {
        Write-VBazLog 'Hibernation / Fast Startup appears enabled. This leaves NTFS dirty and can corrupt a dual boot.' -Level WARN
        Write-VBazLog 'Recommend: run "powercfg /h off" and reboot before installing.' -Level WARN
    }

    # --- Locate the EFI System Partition ---------------------------------
    $esp = Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
    if (-not $esp) { throw 'No EFI System Partition found. Is this really a UEFI/GPT install of Windows?' }
    $facts.Esp = $esp
    Write-VBazLog ("EFI System Partition: disk {0} partition {1} ({2})" -f $esp.DiskNumber, $esp.PartitionNumber, (Format-Bytes ([int64]$esp.Size))) -Level OK

    Write-VBazLog 'Pre-flight complete.' -Level OK
    return $facts
}
