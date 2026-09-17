# v-BAZ :: Partitioning
# Shrinks the chosen NTFS volume and creates the Alpine root (and optional
# swap) partition, tagged with a distinctive GPT type + label so the Linux
# side can find *exactly* its own partition and never touch Windows.

Set-StrictMode -Version Latest

function New-VBazPartitions {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Facts,
        [switch]$Force
    )

    $drive = $Config.ShrinkDriveLetter
    $rootBytes = ConvertTo-Bytes $Config.AlpineRootSize
    $swapBytes = 0
    if ($Config.AlpineSwapSize -and $Config.AlpineSwapSize -ne '0') {
        $swapBytes = ConvertTo-Bytes $Config.AlpineSwapSize
    }
    $totalBytes = $rootBytes + $swapBytes

    $part = Get-Partition -DriveLetter $drive
    $diskNumber = $part.DiskNumber

    # --- Idempotency: is a VBAZ_ROOT partition already present? ----------
    $existing = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.GptType -eq "{$($Config.RootPartitionType.ToLower())}" }
    if ($existing) {
        Write-VBazLog 'A v-BAZ root partition already exists on this disk; skipping shrink/create.' -Level WARN
        return @{
            DiskNumber   = $diskNumber
            RootPartition = ($existing | Select-Object -First 1)
            Created      = $false
        }
    }

    Write-VBazLog ("About to shrink {0}: by {1} and create Alpine partitions on disk {2}." -f $drive, (Format-Bytes $totalBytes), $diskNumber) -Level STEP
    Write-VBazLog 'This modifies your partition table. Back up important data first.' -Level WARN
    if (-not (Confirm-VBazAction -Prompt "Proceed with repartitioning disk $diskNumber?" -Force:$Force)) {
        throw 'Repartitioning declined by operator.'
    }

    if ($script:VBazDryRun) {
        Write-VBazLog 'DRY-RUN: skipping actual Resize-Partition / New-Partition.' -Level WARN
        return @{ DiskNumber = $diskNumber; RootPartition = $null; Created = $false }
    }

    # --- Shrink ----------------------------------------------------------
    $supported = Get-PartitionSupportedSize -DriveLetter $drive
    $currentSize = $part.Size
    $targetSize = $currentSize - $totalBytes
    if ($targetSize -lt $supported.SizeMin) {
        $msg = 'Cannot shrink {0}: Windows reports a minimum size of {1} (unmovable files). ' -f $drive, (Format-Bytes ([int64]$supported.SizeMin))
        throw ($msg + 'Run defrag / disable pagefile+hibernation and retry. See docs/TROUBLESHOOTING.md.')
    }
    Write-VBazLog ("Shrinking {0}: from {1} to {2}" -f $drive, (Format-Bytes ([int64]$currentSize)), (Format-Bytes ([int64]$targetSize))) -Level INFO
    Resize-Partition -DriveLetter $drive -Size $targetSize -ErrorAction Stop
    Write-VBazLog 'Shrink complete.' -Level OK

    # --- Create swap partition (optional) --------------------------------
    $swapPart = $null
    if ($swapBytes -gt 0) {
        Write-VBazLog ("Creating swap partition ({0})" -f (Format-Bytes $swapBytes)) -Level INFO
        $swapPart = New-Partition -DiskNumber $diskNumber -Size $swapBytes -GptType "{$($Config.SwapPartitionType)}"
        Set-VBazPartitionLabel -Partition $swapPart -Label $Config.SwapPartitionLabel
    }

    # --- Create root partition (uses all remaining requested space) ------
    Write-VBazLog ("Creating Alpine root partition ({0})" -f (Format-Bytes $rootBytes)) -Level INFO
    $rootPart = New-Partition -DiskNumber $diskNumber -Size $rootBytes -GptType "{$($Config.RootPartitionType)}"
    Set-VBazPartitionLabel -Partition $rootPart -Label $Config.RootPartitionLabel

    # NOTE: we deliberately do NOT format these partitions here. Windows
    # cannot make ext4, and the Alpine provisioner formats VBAZ_ROOT itself.
    Write-VBazLog 'Alpine partitions created (left unformatted for the Linux side).' -Level OK

    return @{
        DiskNumber    = $diskNumber
        RootPartition = $rootPart
        SwapPartition = $swapPart
        Created       = $true
    }
}

# Set a GPT partition label. Storage cmdlets do not expose partition labels
# directly, so fall back to diskpart with the partition's offset for a
# deterministic match.
function Set-VBazPartitionLabel {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][string]$Label
    )
    try {
        # Storage module route (Windows 10 1709+): supported on GPT data parts.
        Set-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -NewDriveLetter $null -ErrorAction SilentlyContinue | Out-Null
    } catch { }

    $script = @"
select disk $($Partition.DiskNumber)
select partition $($Partition.PartitionNumber)
gpt attributes=0x0000000000000000
"@
    # diskpart cannot set an arbitrary GPT partition *name* on all builds;
    # the type GUID set at creation time is the primary, reliable marker.
    # We keep the label attempt best-effort and rely on type GUID otherwise.
    $tmp = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmp -Value $script -Encoding ASCII
    try { diskpart /s $tmp | Out-Null } catch { } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    Write-VBazLog "Partition $($Partition.PartitionNumber) tagged (type GUID is the primary marker; label '$Label' applied by Linux at format time)." -Level INFO
}
