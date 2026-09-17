# v-BAZ :: Secure Boot (shim + MOK) automation
#
# Strategy: keep Secure Boot ON. A Microsoft-signed *shim* is the first-stage
# EFI binary (loads under the MS UEFI CA). shim then loads a second stage
# (rEFInd) and validates it - and the kernels - against a Machine Owner Key
# (MOK) that we generate here and sign everything with. On first boot shim
# runs MokManager so you enroll our certificate ONE time (a physically-present
# key-press; this cannot be automated away - it is the whole point of MOK).
#
# We generate the MOK and Authenticode-sign the EFI binaries entirely on
# Windows (New-SelfSignedCertificate + Set-AuthenticodeSignature). The private
# key is handed to the Alpine provisioner (via the apkovl) so it can re-sign
# the installed kernel on upgrades; it is then kept root-only on the ext4 root
# and shredded from the ESP. See docs/SECUREBOOT.md.

Set-StrictMode -Version Latest

function New-VBazMok {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$StageDir
    )
    Write-VBazLog "Generating v-BAZ Machine Owner Key ($Subject)" -Level INFO
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $Subject `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(10)

    $mokDir = Join-Path $StageDir 'mok'
    New-Item -ItemType Directory -Force -Path $mokDir | Out-Null

    # Public cert in DER (.cer / .crt) - what MokManager enrolls.
    $cerPath = Join-Path $mokDir 'vbaz-mok.cer'
    Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null

    # Private key as PFX (transient) so the provisioner can sign the installed
    # kernel. Random password, written next to it (both shredded on first boot).
    $pfxPwPlain = [Convert]::ToBase64String((1..24 | ForEach-Object { Get-Random -Max 256 }))
    $pfxPw = ConvertTo-SecureString $pfxPwPlain -AsPlainText -Force
    $pfxPath = Join-Path $mokDir 'vbaz-mok.pfx'
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPw | Out-Null
    Set-Content -Path (Join-Path $mokDir 'vbaz-mok.pfx.pass') -Value $pfxPwPlain -Encoding Ascii -NoNewline

    return @{
        Cert    = $cert
        CerPath = $cerPath
        PfxPath = $pfxPath
        MokDir  = $mokDir
    }
}

function Set-VBazSignature {
    param(
        [Parameter(Mandatory)]$Cert,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path $Path)) { throw "Cannot sign missing file: $Path" }
    $res = Set-AuthenticodeSignature -FilePath $Path -Certificate $Cert -HashAlgorithm SHA256
    if ($res.Status -ne 'Valid') {
        Write-VBazLog "Signature status for $(Split-Path -Leaf $Path): $($res.Status) - $($res.StatusMessage)" -Level WARN
    } else {
        Write-VBazLog "Signed $(Split-Path -Leaf $Path)" -Level OK
    }
}

# Obtain a Microsoft-signed shimx64.efi + mmx64.efi (MokManager).
# Order: explicit local dir / file, then windows\secureboot\, then a URL that
# we try to unpack with bsdtar (rpm/deb/zip). Throws with guidance otherwise.
function Get-VBazShim {
    param(
        [string]$Source,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$StageDir
    )
    $out = Join-Path $StageDir 'shim'
    New-Item -ItemType Directory -Force -Path $out | Out-Null

    # $ScriptRoot is the 'windows' directory; the drop-folder is windows\secureboot.
    $searchDirs = @()
    if ($Source -and (Test-Path $Source)) { $searchDirs += (Resolve-Path $Source).Path }
    $searchDirs += (Join-Path $ScriptRoot 'secureboot')

    foreach ($d in $searchDirs) {
        if (Test-Path $d -PathType Container) {
            $shim = Get-ChildItem -Recurse -Path $d -Include 'shimx64.efi','bootx64.efi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            $mm   = Get-ChildItem -Recurse -Path $d -Include 'mmx64.efi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($shim -and $mm) {
                Copy-Item $shim.FullName (Join-Path $out 'shimx64.efi') -Force
                Copy-Item $mm.FullName   (Join-Path $out 'mmx64.efi')   -Force
                Write-VBazLog "Using shim from $d" -Level OK
                return @{ ShimEfi = (Join-Path $out 'shimx64.efi'); MokManagerEfi = (Join-Path $out 'mmx64.efi') }
            }
        }
    }

    if ($Source -and $Source -match '^https?://') {
        $pkg = Join-Path $StageDir 'shim-src'
        New-Item -ItemType Directory -Force -Path $pkg | Out-Null
        $dl = Join-Path $pkg ([IO.Path]::GetFileName(($Source -split '\?')[0]))
        if (-not $dl -or $dl -eq $pkg) { $dl = Join-Path $pkg 'shim-download' }
        Get-VBazFile -Url $Source -OutFile $dl
        # Try to unpack (zip/rpm/deb are all readable by libarchive `tar`).
        try { & tar -xf $dl -C $pkg 2>$null } catch { }
        # deb: unpack the inner data.tar.* too.
        Get-ChildItem -Path $pkg -Filter 'data.tar*' -ErrorAction SilentlyContinue | ForEach-Object {
            try { & tar -xf $_.FullName -C $pkg 2>$null } catch { }
        }
        $shim = Get-ChildItem -Recurse -Path $pkg -Include 'shimx64.efi','bootx64.efi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $mm   = Get-ChildItem -Recurse -Path $pkg -Include 'mmx64.efi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($shim -and $mm) {
            Copy-Item $shim.FullName (Join-Path $out 'shimx64.efi') -Force
            Copy-Item $mm.FullName   (Join-Path $out 'mmx64.efi')   -Force
            Write-VBazLog "Extracted shim from $Source" -Level OK
            return @{ ShimEfi = (Join-Path $out 'shimx64.efi'); MokManagerEfi = (Join-Path $out 'mmx64.efi') }
        }
    }

    throw @'
Secure Boot needs a Microsoft-signed shim, which cannot be reliably
auto-downloaded (licensing/format). Provide one of:
  * a folder or URL in the config's ShimSource (rpm/deb/zip/dir), or
  * drop shimx64.efi + mmx64.efi into windows\secureboot\
A known-good source is your distro's signed shim (e.g. Fedora's shim-x64
RPM, openSUSE's shim, or Ubuntu's shim-signed .deb). See docs/SECUREBOOT.md.
'@
}

# Orchestrate the Windows-side Secure Boot preparation. Signs the *installer*
# kernel + rEFInd, produces the MOK material, and gathers shim. The staged
# outputs are consumed by Install-VBazBoot / Build-VBazApkovl.
function Invoke-VBazSecureBoot {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Downloads,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$StageDir
    )
    Write-VBazLog 'Preparing Secure Boot (shim + MOK)' -Level STEP

    $mok = New-VBazMok -Subject $Config.MokSubject -StageDir $StageDir
    $shim = Get-VBazShim -Source $Config.ShimSource -ScriptRoot $ScriptRoot -StageDir $StageDir

    if (-not $script:VBazDryRun) {
        # Sign rEFInd (loaded by shim) and the installer kernel (loaded by rEFInd).
        Set-VBazSignature -Cert $mok.Cert -Path $Downloads.RefindEfi
        Set-VBazSignature -Cert $mok.Cert -Path $Downloads.Files.Kernel
    } else {
        Write-VBazLog 'DRY-RUN: would sign rEFInd + installer kernel with the MOK.' -Level WARN
    }

    return @{
        Mok           = $mok
        ShimEfi        = $shim.ShimEfi
        MokManagerEfi  = $shim.MokManagerEfi
        MokCer         = $mok.CerPath
        MokDir         = $mok.MokDir
    }
}
