# v-BAZ installer configuration
#
# This is a PowerShell data file (a restricted, code-free hashtable). Edit the
# values below, or override any of them on the Install-VBaz.ps1 command line.
#
# Sizes accept the suffixes KB/MB/GB/TB (powers of 1024). "Auto" where noted.

@{
    # ---- Alpine release -------------------------------------------------
    # Pin an Alpine release. "latest-stable" resolves to the newest stable
    # branch at download time; a value like "3.21" pins a branch.
    AlpineBranch  = 'v3.21'
    AlpineVersion = '3.21.0'      # full point release used to build file names
    Arch          = 'x86_64'      # only x86_64 is supported today
    Flavor        = 'lts'         # kernel flavor: lts (recommended) or virt

    # Mirror used for netboot files and, later, for the package install.
    Mirror        = 'https://dl-cdn.alpinelinux.org/alpine'

    # ---- Disk layout ----------------------------------------------------
    # Which existing Windows volume to shrink to make room. By drive letter.
    ShrinkDriveLetter = 'C'

    # How much space to hand to Alpine. This becomes the size of the new
    # ext4 root partition (v-BAZ formats it on first Linux boot).
    AlpineRootSize    = '40GB'

    # Optional dedicated swap partition. Set to '0' to skip and use a
    # swapfile inside the root partition instead.
    AlpineSwapSize    = '4GB'

    # GPT partition type GUID + label used to *unambiguously* mark the
    # partition v-BAZ owns. The Linux provisioner only ever formats/installs
    # onto the partition carrying this exact type+label, so it can never
    # guess wrong and clobber Windows. 0FC63DAF... is the standard
    # "Linux filesystem" type GUID.
    RootPartitionType  = '0FC63DAF-8483-4772-8E79-3D69D8477DE4'
    RootPartitionLabel = 'VBAZ_ROOT'
    SwapPartitionType  = '0657FD6D-A4AB-43C4-84E5-0933C84B4F4F'  # Linux swap
    SwapPartitionLabel = 'VBAZ_SWAP'

    # ---- Boot integration ----------------------------------------------
    # Subdirectory created under the EFI System Partition (\EFI\<dir>\...).
    EspSubdir     = 'vbaz'

    # Text shown for the entry that the firmware/Windows Boot Manager adds.
    BootEntryName = 'v-BAZ Alpine (KVM host)'

    # Bootloader placed on the ESP and chainloaded from Windows Boot
    # Manager. 'refind' ships prebuilt EFI binaries (no toolchain needed on
    # Windows) and is purpose-built for this. Only 'refind' is implemented.
    Bootloader    = 'refind'
    RefindUrl     = 'https://sourceforge.net/projects/refind/files/latest/download'

    # ---- First-boot provisioning ---------------------------------------
    # Hostname for the Alpine install.
    Hostname      = 'vbaz'

    # Login user created on the Alpine side (added to kvm/libvirt groups).
    # The password is NOT stored here; the installer prompts for it and
    # writes only a hashed value into the answer overlay.
    Username      = 'operator'

    # Timezone (see /usr/share/zoneinfo). 'UTC' is a safe default.
    Timezone      = 'UTC'

    # Package sets provisioned on the Alpine host. 'virt' pulls in the
    # KVM/libvirt/QEMU stack. 'firecracker' additionally installs the
    # Firecracker VMM (from Alpine testing / pinned binary) for microVM work.
    PackageSets   = @('base', 'virt', 'firecracker')

    # ---- Safety knobs ---------------------------------------------------
    # Refuse to run when BitLocker is on unless explicitly acknowledged.
    RequireBitLockerAck = $true

    # Minimum free space (after the shrink) to leave on the shrunk volume.
    MinWindowsFreeSpace = '20GB'
}
