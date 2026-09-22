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

# Fail early (before any copy) if the EFI System Partition can't hold what we
# are about to stage. A Windows ESP is often only 100-300 MB, so this catches
# the common "no space left" mid-copy failure and, for offline mode, a bundle
# too large for the ESP - with an actionable message instead of a cryptic error.
function Assert-VBazEspSpace {
    param(
        [Parameter(Mandatory)][string]$EspLetter,   # e.g. 'S:'
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Downloads,
        [Parameter(Mandatory)][string]$ApkovlPath,
        [hashtable]$SecureBoot = $null,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $sizeOf = {
        param($p)
        if (-not $p -or -not (Test-Path $p)) { return [int64]0 }
        $item = Get-Item $p
        if (-not $item.PSIsContainer) { return [int64]$item.Length }
        $sum = (Get-ChildItem -Recurse -File $p -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        return [int64]$sum
    }

    $need = 0L
    $need += & $sizeOf $Downloads.Files.Kernel
    $need += & $sizeOf $Downloads.Files.Initramfs
    $need += & $sizeOf $Downloads.RefindEfi
    $need += & $sizeOf $ApkovlPath
    $need += & $sizeOf (Join-Path $RepoRoot 'assets\original\vbaz-splash.png')

    if ($SecureBoot) {
        # rEFInd is copied a second time as grubx64.efi behind shim.
        $need += & $sizeOf $Downloads.RefindEfi
        $need += & $sizeOf $SecureBoot.ShimEfi
        $need += & $sizeOf $SecureBoot.MokManagerEfi
        $need += & $sizeOf $SecureBoot.MokCer
    }

    if ($Config.Offline) {
        $need += & $sizeOf $Downloads.Files.Modloop
        $need += & $sizeOf (Join-Path $Config.OfflineBundleDir 'apks')
        $need += & $sizeOf (Join-Path $Config.OfflineBundleDir 'keys')
    }

    # Newer v-BAZ revisions can also stage Rebekah itself, an Ollama model and
    # gateway TLS material. Count explicit paths first, then offline-bundle
    # fallbacks, exactly as the copy phase below resolves them.
    $rebTar = $Config.RebekahImageTarball
    if ((-not $rebTar -or -not (Test-Path $rebTar)) -and $Config.OfflineBundleDir) {
        $rebTar = Join-Path $Config.OfflineBundleDir 'rebekah\rebekah-image.tar.gz'
    }
    $rebModel = $Config.RebekahModelTarball
    if ((-not $rebModel -or -not (Test-Path $rebModel)) -and $Config.OfflineBundleDir) {
        $rebModel = Join-Path $Config.OfflineBundleDir 'rebekah\ollama-model.tar.gz'
    }
    $need += & $sizeOf $rebTar
    $need += & $sizeOf $rebModel
    if ($Config.RebekahGatewayPublish) {
        $need += & $sizeOf $Config.RebekahGatewayTlsCert
        $need += & $sizeOf $Config.RebekahGatewayTlsKey
    }

    # FAT allocation overhead and rounding headroom.
    $need = [int64]($need + 32MB)

    $vol = Get-Volume -DriveLetter $EspLetter.TrimEnd(':') -ErrorAction SilentlyContinue
    if (-not $vol) { Write-VBazLog "Could not read ESP free space on $EspLetter; skipping the space check." -Level WARN; return }
    $free = [int64]$vol.SizeRemaining
    Write-VBazLog ("ESP $EspLetter free {0}, need ~{1}" -f (Format-Bytes $free), (Format-Bytes $need)) -Level DEBUG
    if ($free -lt $need) {
        $hint = if ($Config.Offline) {
            'The offline bundle is too large for this ESP. Narrow WifiFirmware to your chip, or use the tethered (online) install; see docs/OFFLINE.md.'
        } else {
            'The ESP is unusually small. Free space on it, or see docs/TROUBLESHOOTING.md.'
        }
        throw ("Not enough room on the EFI System Partition ($EspLetter): need ~{0}, have {1}. {2}" -f (Format-Bytes $need), (Format-Bytes $free), $hint)
    }
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

        # Guard against overflowing a small Windows ESP (often 100-300 MB)
        # before we start copying. modloop (~180 MB) + the offline apk repo are
        # the big items and are only staged when actually needed.
        Assert-VBazEspSpace -EspLetter $espLetter -Config $Config -Downloads $Downloads `
            -ApkovlPath $ApkovlPath -SecureBoot $SecureBoot -RepoRoot $RepoRoot

        if ($script:VBazDryRun) {
            Write-VBazLog "DRY-RUN: would copy kernel/initramfs/rEFInd (+modloop/apks if offline) into $espDir" -Level WARN
        } else {
            Copy-Item $Downloads.Files.Kernel    (Join-Path $espDir 'vmlinuz-lts')    -Force
            Copy-Item $Downloads.Files.Initramfs (Join-Path $espDir 'initramfs-lts')  -Force
            # modloop is only needed locally for the OFFLINE first boot; online
            # boots fetch it over the network (modloop=<url>), so staging it on
            # the ESP would just waste ~180 MB and can overflow a small ESP.
            if ($Config.Offline) {
                Copy-Item $Downloads.Files.Modloop (Join-Path $espDir 'modloop-lts') -Force
            }
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

            # Rebekah gateway TLS material (only when the gateway is published on
            # the LAN -- it requires TLS). Baked onto the ESP; the rebekah service
            # installs it for the gateway UID at first boot. Both cert and key are
            # required; a partial pair is refused so the operator notices now.
            if ($Config.RebekahGatewayPublish) {
                $gwCert = $Config.RebekahGatewayTlsCert
                $gwKey  = $Config.RebekahGatewayTlsKey
                if (-not ($gwCert -and $gwKey)) {
                    throw "RebekahGatewayPublish is set but RebekahGatewayTlsCert/RebekahGatewayTlsKey are not both provided (publishing requires TLS)."
                }
                if (-not (Test-Path $gwCert)) { throw "RebekahGatewayTlsCert not found: $gwCert" }
                if (-not (Test-Path $gwKey))  { throw "RebekahGatewayTlsKey not found: $gwKey" }
                $tlsDir = Join-Path (Join-Path $espDir 'rebekah') 'tls'
                New-Item -ItemType Directory -Force -Path $tlsDir | Out-Null
                Copy-Item $gwCert (Join-Path $tlsDir 'cert.pem') -Force
                Copy-Item $gwKey  (Join-Path $tlsDir 'key.pem')  -Force
                Write-VBazLog "Rebekah gateway TLS staged on the ESP (\EFI\$($Config.EspSubdir)\rebekah\tls\)." -Level OK
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
