# v-BAZ :: Boot integration
# Stages files onto the EFI System Partition and registers a Windows Boot
# Manager entry that chainloads rEFInd -> the Alpine kernel.
#
# The BCD entry is created by COPYING {bootmgr} (a UEFI firmware-class
# object) and repointing its path at our EFI binary. Because the copy is
# also a firmware entry, UEFI presents it in the boot menu and loads the
# EFI application at that path. This is the most broadly compatible way to
# add a Linux entry from inside Windows. See docs/ARCHITECTURE.md.

Set-StrictMode -Version Latest

function Mount-VBazEsp {
    param([Parameter(Mandatory)]$EspPartition)
    # Already mounted with a letter? Reuse it.
    $existing = (Get-Partition -DiskNumber $EspPartition.DiskNumber -PartitionNumber $EspPartition.PartitionNumber).AccessPaths
    foreach ($ap in $existing) { if ($ap -match '^[A-Z]:\\$') { Write-VBazLog "ESP already at $($ap.TrimEnd('\'))" -Level DEBUG; return $ap.TrimEnd('\') } }

    # Pick a free drive letter (S..Z then Q..R), avoiding ones in use.
    $used = (Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | ForEach-Object { $_.DriveLetter }) +
            (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $letter = $null
    foreach ($c in @('S','T','U','V','W','Y','Z','Q','R')) { if ($used -notcontains $c) { $letter = $c; break } }
    if (-not $letter) { throw 'No free drive letter available to mount the ESP.' }

    Add-PartitionAccessPath -DiskNumber $EspPartition.DiskNumber -PartitionNumber $EspPartition.PartitionNumber -AccessPath "$($letter):\" -ErrorAction Stop
    Write-VBazLog "Mounted ESP at $($letter):" -Level INFO
    return "$($letter):"
}

function Dismount-VBazEsp {
    param([Parameter(Mandatory)]$EspPartition, [Parameter(Mandatory)][string]$AccessPath)
    try {
        Remove-PartitionAccessPath -DiskNumber $EspPartition.DiskNumber -PartitionNumber $EspPartition.PartitionNumber -AccessPath "$AccessPath\" -ErrorAction Stop
        Write-VBazLog "Unmounted ESP ($AccessPath)" -Level INFO
    } catch { Write-VBazLog "Could not unmount ESP: $($_.Exception.Message)" -Level WARN }
}

function Install-VBazBoot {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Facts,
        [Parameter(Mandatory)][hashtable]$Downloads,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ApkovlPath,
        [hashtable]$SecureBoot = $null,
        [switch]$Force
    )

    Write-VBazLog 'Installing boot files onto the EFI System Partition' -Level STEP
    $espLetter = Mount-VBazEsp -EspPartition $Facts.Esp
    try {
        $espDir = Join-Path "$espLetter\EFI" $Config.EspSubdir
        New-Item -ItemType Directory -Force -Path $espDir | Out-Null

        if ($script:VBazDryRun) {
            Write-VBazLog "DRY-RUN: would copy kernel/initramfs/modloop/rEFInd into $espDir" -Level WARN
        } else {
            Copy-Item $Downloads.Files.Kernel    (Join-Path $espDir 'vmlinuz-lts')    -Force
            Copy-Item $Downloads.Files.Initramfs (Join-Path $espDir 'initramfs-lts')  -Force
            Copy-Item $Downloads.Files.Modloop   (Join-Path $espDir 'modloop-lts')    -Force
            Copy-Item $Downloads.RefindEfi       (Join-Path $espDir 'refind_x64.efi') -Force
            if ($SecureBoot) {
                # shim's default second stage is grubx64.efi: hand it the
                # MOK-signed rEFInd under that name, and stage shim + MokManager
                # + the MOK certificate for one-time enrollment.
                Copy-Item $Downloads.RefindEfi        (Join-Path $espDir 'grubx64.efi')  -Force
                Copy-Item $SecureBoot.ShimEfi         (Join-Path $espDir 'shimx64.efi')  -Force
                Copy-Item $SecureBoot.MokManagerEfi   (Join-Path $espDir 'mmx64.efi')    -Force
                Copy-Item $SecureBoot.MokCer          (Join-Path $espDir 'vbaz-mok.cer') -Force
                Write-VBazLog 'Secure Boot: staged shim + MokManager + MOK certificate + signed rEFInd (grubx64.efi).' -Level OK
            }
            if ($Downloads.RefindExt4Driver) {
                New-Item -ItemType Directory -Force -Path (Join-Path $espDir 'drivers_x64') | Out-Null
                Copy-Item $Downloads.RefindExt4Driver (Join-Path $espDir 'drivers_x64\ext4_x64.efi') -Force
            }
            # The apkovl goes at the ESP ROOT: Alpine's initramfs overlay scan
            # looks for *.apkovl.tar.gz at the root of each filesystem, not in
            # subdirectories.
            Copy-Item $ApkovlPath (Join-Path "$espLetter\" 'vbaz.apkovl.tar.gz') -Force
            # RAGBAZ / v-BAZ boot splash (referenced by refind.conf banner).
            $splash = Join-Path $RepoRoot 'assets\original\vbaz-splash.png'
            if (Test-Path $splash) { Copy-Item $splash (Join-Path $espDir 'splash.png') -Force }
            else { Write-VBazLog 'splash image not found (assets\original\vbaz-splash.png); rEFInd will boot without a banner.' -Level WARN }

            # Offline: stage the local apk repo + its signing key on the ESP so
            # the first boot installs with no network.
            if ($Config.Offline) {
                $apksSrc = Join-Path $Config.OfflineBundleDir 'apks'
                $keysSrc = Join-Path $Config.OfflineBundleDir 'keys'
                if (-not (Test-Path (Join-Path $apksSrc "$($Config.Arch)\APKINDEX.tar.gz"))) {
                    throw "Offline bundle repo missing ($apksSrc\$($Config.Arch)\APKINDEX.tar.gz)."
                }
                Copy-Item $apksSrc (Join-Path $espDir 'apks') -Recurse -Force
                if (Test-Path $keysSrc) { Copy-Item $keysSrc (Join-Path $espDir 'apk-keys') -Recurse -Force }
                Write-VBazLog "Offline repo staged on the ESP (\EFI\$($Config.EspSubdir)\apks)." -Level OK
            }

            # Rebekah image tarball (gap-less offline / air-gapped fallback). The
            # rebekah OpenRC service pulls the image at first boot and, if that
            # fails, loads this staged tarball. Source: an explicit config path,
            # or a tarball the offline bundle placed under <bundle>\rebekah\.
            $rebTar = $null
            if ($Config.RebekahImageTarball -and (Test-Path $Config.RebekahImageTarball)) {
                $rebTar = $Config.RebekahImageTarball
            } elseif ($Config.OfflineBundleDir) {
                $bundled = Join-Path $Config.OfflineBundleDir 'rebekah\rebekah-image.tar.gz'
                if (Test-Path $bundled) { $rebTar = $bundled }
            }
            # The default Ollama model (Ollama ships no weights) -- the runtime
            # data an off-grid mini-cloud needs so inference works with no
            # network. Source: an explicit config path, or the offline bundle.
            $rebModel = $null
            if ($Config.RebekahModelTarball -and (Test-Path $Config.RebekahModelTarball)) {
                $rebModel = $Config.RebekahModelTarball
            } elseif ($Config.OfflineBundleDir) {
                $bundledModel = Join-Path $Config.OfflineBundleDir 'rebekah\ollama-model.tar.gz'
                if (Test-Path $bundledModel) { $rebModel = $bundledModel }
            }
            if ($rebTar -or $rebModel) {
                $rebDir = Join-Path $espDir 'rebekah'
                New-Item -ItemType Directory -Force -Path $rebDir | Out-Null
                if ($rebTar) {
                    Copy-Item $rebTar (Join-Path $rebDir 'rebekah-image.tar.gz') -Force
                    Write-VBazLog "Rebekah image staged on the ESP (\EFI\$($Config.EspSubdir)\rebekah\rebekah-image.tar.gz)." -Level OK
                }
                if ($rebModel) {
                    Copy-Item $rebModel (Join-Path $rebDir 'ollama-model.tar.gz') -Force
                    Write-VBazLog "Rebekah Ollama model staged on the ESP (\EFI\$($Config.EspSubdir)\rebekah\ollama-model.tar.gz)." -Level OK
                }
            }
            Write-VBazLog 'Boot files copied.' -Level OK
        }

        # --- Render refind.conf ------------------------------------------
        $tmpl = Get-Content -Raw (Join-Path $RepoRoot 'refind\refind.conf.template')
        $mirror = $Config.Mirror
        $branch = $Config.AlpineBranch
        $arch   = $Config.Arch
        $ver    = $Config.AlpineVersion
        $sub    = $Config.EspSubdir
        # Kernel command line for the provisioner (stanza 1). Offline drops the
        # network params and skips modloop fetch (the provisioner mounts the
        # ESP-staged modloop itself); online fetches modloop + repo over the net.
        $baseOpts = 'modules=loop,squashfs,sd-mod,usb-storage,ext4 quiet console=tty0'
        if ($Config.Offline) {
            $kopts = "$baseOpts nomodloop vbaz_provision=1"
        } else {
            $modloopUrl = "$mirror/$branch/releases/$arch/netboot-$ver/modloop-lts"
            $repoUrl    = "$mirror/$branch/main"
            $kopts = "$baseOpts ip=dhcp modloop=$modloopUrl alpine_repo=$repoUrl vbaz_provision=1"
        }
        $conf = $tmpl `
            -replace '@@ESPSUBDIR@@', $sub `
            -replace '@@ENTRYNAME@@', $Config.BootEntryName `
            -replace '@@KERNEL_OPTS@@', $kopts `
            -replace '@@ROOTLABEL@@', $Config.RootPartitionLabel
        $confPath = Join-Path $espDir 'refind.conf'
        if ($script:VBazDryRun) {
            Write-VBazLog "DRY-RUN: would write refind.conf to $confPath" -Level WARN
        } else {
            Set-Content -Path $confPath -Value $conf -Encoding ASCII
            Write-VBazLog "Wrote $confPath" -Level OK
        }

        # --- Register the Windows Boot Manager entry ---------------------
        # Under Secure Boot the chain must start at the MS-signed shim.
        $efiName = if ($SecureBoot) { 'shimx64.efi' } else { 'refind_x64.efi' }
        $efiRelPath = "\EFI\$sub\$efiName"
        Register-VBazBcdEntry -Description $Config.BootEntryName -EfiPath $efiRelPath -Force:$Force
    }
    finally {
        Dismount-VBazEsp -EspPartition $Facts.Esp -AccessPath $espLetter
    }
}

function Register-VBazBcdEntry {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$EfiPath,
        [switch]$Force
    )
    Write-VBazLog 'Registering Windows Boot Manager entry (bcdedit)' -Level STEP

    if ($script:VBazDryRun) {
        Write-VBazLog "DRY-RUN: would run: bcdedit /copy {bootmgr} /d `"$Description`"" -Level WARN
        Write-VBazLog "DRY-RUN: would run: bcdedit /set {GUID} path $EfiPath" -Level WARN
        return
    }

    # Copy the firmware boot manager object; capture the new GUID.
    $out = & bcdedit /copy '{bootmgr}' /d $Description 2>&1 | Out-String
    if ($out -notmatch '\{[0-9a-fA-F-]+\}') {
        throw "bcdedit /copy did not return a GUID. Output:`n$out"
    }
    $guid = ($out | Select-String -Pattern '\{[0-9a-fA-F-]+\}').Matches[0].Value
    Write-VBazLog "Created BCD object $guid" -Level INFO

    & bcdedit /set $guid path $EfiPath | Out-Null
    # NOTE: the copied {bootmgr} already inherits the ESP as its `device`, so
    # we deliberately do NOT override it (a wrong HarddiskVolume would break
    # the entry). Put it last in the firmware boot order so Windows stays default.
    & bcdedit /set '{fwbootmgr}' displayorder $guid /addlast | Out-Null

    # Record the GUID so the uninstaller can remove exactly this entry.
    $marker = Join-Path $env:ProgramData 'v-BAZ\bcd-entry.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
    Set-Content -Path $marker -Value $guid -Encoding ASCII

    Write-VBazLog "Windows Boot Manager entry '$Description' created ($guid)." -Level OK
    Write-VBazLog "To boot Alpine, pick '$Description' from the firmware/boot menu." -Level INFO
    Write-VBazLog 'If the entry does not appear, see docs/TROUBLESHOOTING.md (firmware NVRAM quirks).' -Level WARN
}

function Remove-VBazBcdEntry {
    $marker = Join-Path $env:ProgramData 'v-BAZ\bcd-entry.txt'
    if (-not (Test-Path $marker)) { Write-VBazLog 'No recorded BCD entry to remove.' -Level WARN; return }
    $guid = (Get-Content -Raw $marker).Trim()
    if ($guid -match '^\{[0-9a-fA-F-]+\}$') {
        & bcdedit /delete $guid /f | Out-Null
        Write-VBazLog "Removed BCD entry $guid" -Level OK
        Remove-Item $marker -ErrorAction SilentlyContinue
    }
}
