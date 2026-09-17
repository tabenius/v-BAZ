# v-BAZ :: Downloads
# Fetches the Alpine netboot kernel/initramfs/modloop and the rEFInd EFI
# bootloader into a local staging directory, verifying checksums.

Set-StrictMode -Version Latest

function Invoke-VBazDownload {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$StageDir
    )

    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
    Write-VBazLog "Staging downloads in $StageDir" -Level STEP

    # TLS 1.2+ for older PowerShell.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    $branch = $Config.AlpineBranch
    $arch   = $Config.Arch
    $flavor = $Config.Flavor
    $ver    = $Config.AlpineVersion
    $base   = "$($Config.Mirror)/$branch/releases/$arch"

    # Offline: take the boot files from the prebuilt bundle instead of the net.
    if ($Config.Offline) {
        $bootDir = Join-Path $Config.OfflineBundleDir 'boot'
        $result = @{ NetbootBase = $bootDir; Files = @{} }
        foreach ($pair in @(@('Kernel','vmlinuz-lts'), @('Initramfs','initramfs-lts'), @('Modloop','modloop-lts'))) {
            $src = Join-Path $bootDir $pair[1]
            if (-not (Test-Path $src)) { throw "Offline bundle missing $($pair[1]) (expected $src). Rebuild with tools/build-offline-bundle.sh." }
            $dst = Join-Path $StageDir $pair[1]
            Copy-Item $src $dst -Force
            $result.Files[$pair[0]] = $dst
        }
        Write-VBazLog "Offline: boot files taken from $bootDir" -Level OK
        # rEFInd still comes from the network (the Windows box has connectivity).
        Get-VBazRefind -Config $Config -StageDir $StageDir -Result $result
        return $result
    }

    # Alpine ships netboot files under a versioned subdir; the plain
    # "netboot/" symlink usually exists too. Try the versioned path first.
    $candidates = @("$base/netboot-$ver", "$base/netboot")
    $netbootBase = $null
    foreach ($c in $candidates) {
        if (Test-VBazUrl "$c/vmlinuz-$flavor") { $netbootBase = $c; break }
    }
    if (-not $netbootBase) {
        throw "Could not locate Alpine netboot files. Tried: $($candidates -join ', '). Check AlpineBranch/AlpineVersion/Flavor in the config."
    }
    Write-VBazLog "Netboot source: $netbootBase" -Level OK

    $files = @{
        Kernel    = "vmlinuz-$flavor"
        Initramfs = "initramfs-$flavor"
        Modloop   = "modloop-$flavor"
    }
    $result = @{ NetbootBase = $netbootBase; Files = @{} }
    foreach ($key in $files.Keys) {
        $name = $files[$key]
        $dst = Join-Path $StageDir $name
        Get-VBazFile -Url "$netbootBase/$name" -OutFile $dst
        # Verify against the sibling .sha256 when present.
        $shaUrl = "$netbootBase/$name.sha256"
        if (Test-VBazUrl $shaUrl) {
            $expected = ((Invoke-VBazText $shaUrl) -split '\s+')[0].ToLowerInvariant()
            $actual = Get-VBazSha256 $dst
            if ($expected -ne $actual) {
                throw "Checksum mismatch for $name`n  expected $expected`n  got      $actual"
            }
            Write-VBazLog "Verified $name (sha256 ok)" -Level OK
        } else {
            Write-VBazLog "No .sha256 published for $name; skipping verification." -Level WARN
        }
        $result.Files[$key] = $dst
    }

    Get-VBazRefind -Config $Config -StageDir $StageDir -Result $result
    return $result
}

# Fetch + unpack rEFInd (prebuilt EFI bootloader) into the result. Used by both
# the online and offline paths; the Windows box has connectivity either way.
function Get-VBazRefind {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][hashtable]$Result
    )
    if ($Config.Bootloader -ne 'refind') { return }
    # Allow a locally-supplied rEFInd (also handy for an air-gapped Windows box).
    if ($Config.OfflineBundleDir) {
        $local = Get-ChildItem -Recurse -Path $Config.OfflineBundleDir -Filter 'refind_x64.efi' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($local) {
            $Result.RefindEfi = $local.FullName
            $drv = Get-ChildItem -Recurse -Path $Config.OfflineBundleDir -Filter 'ext4_x64.efi' -ErrorAction SilentlyContinue | Select-Object -First 1
            $Result.RefindExt4Driver = if ($drv) { $drv.FullName } else { $null }
            Write-VBazLog "rEFInd taken from the offline bundle: $($local.FullName)" -Level OK
            return
        }
    }
    $refindZip = Join-Path $StageDir 'refind.zip'
    Write-VBazLog 'Downloading rEFInd (prebuilt EFI bootloader)' -Level INFO
    Get-VBazFile -Url $Config.RefindUrl -OutFile $refindZip
    $refindDir = Join-Path $StageDir 'refind'
    if (Test-Path $refindDir) { Remove-Item -Recurse -Force $refindDir }
    Expand-Archive -Path $refindZip -DestinationPath $refindDir -Force
    $efi = Get-ChildItem -Recurse -Path $refindDir -Filter 'refind_x64.efi' | Select-Object -First 1
    if (-not $efi) { throw 'refind_x64.efi not found inside the rEFInd download.' }
    $ext4drv = Get-ChildItem -Recurse -Path $refindDir -Filter 'ext4_x64.efi' | Select-Object -First 1
    $Result.RefindEfi = $efi.FullName
    $Result.RefindExt4Driver = if ($ext4drv) { $ext4drv.FullName } else { $null }
    Write-VBazLog "rEFInd ready: $($efi.FullName)" -Level OK
}

function Test-VBazUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch { return $false }
}

function Invoke-VBazText {
    param([Parameter(Mandatory)][string]$Url)
    (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
}

# Download with up to 4 retries and exponential backoff.
function Get-VBazFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    $delays = @(2, 4, 8, 16)
    for ($i = 0; $i -le $delays.Count; $i++) {
        try {
            Write-VBazLog "GET $Url" -Level INFO
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
            return
        } catch {
            if ($i -eq $delays.Count) { throw "Download failed after retries: $Url`n$($_.Exception.Message)" }
            $d = $delays[$i]
            Write-VBazLog "Download error, retrying in ${d}s: $($_.Exception.Message)" -Level WARN
            Start-Sleep -Seconds $d
        }
    }
}
