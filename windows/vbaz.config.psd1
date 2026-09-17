# v-BAZ installer configuration
#
# PowerShell data file (code-free). Edit values, or override on the
# Install-VBaz.ps1 command line. Sizes accept KB/MB/GB/TB (powers of 1024).
#
# Layout this file assumes (three roles, tagged by GPT type GUID so the
# Linux side finds each unambiguously and never guesses):
#   * a SMALL partition dedicated to the Alpine host        (~15 GB, ext4)
#   * Windows (C:)                                          (left untouched)
#   * a LARGE partition converted to a ZFS pool for guests  (D:, WIPED)

@{
    # ---- Alpine release -------------------------------------------------
    AlpineBranch  = 'v3.21'
    AlpineVersion = '3.21.0'
    Arch          = 'x86_64'
    Flavor        = 'lts'
    Mirror        = 'https://dl-cdn.alpinelinux.org/alpine'

    # ---- Host disk (the small, dedicated Alpine host partition) --------
    # 'existing' : repurpose an already-present partition (its data is WIPED,
    #              it is reformatted ext4). Point HostDriveLetter at it.
    # 'shrink'   : shrink ShrinkDriveLetter and create a new partition.
    HostMode          = 'existing'
    HostDriveLetter   = ''          # e.g. 'E' - the ~15 GB partition (WIPED). REQUIRED for 'existing'.

    # Used only when HostMode = 'shrink':
    ShrinkDriveLetter = 'C'
    AlpineRootSize    = '12GB'

    # With a 15 GB host, prefer a swapfile/zram over a swap partition.
    # '0' => no swap partition; the provisioner sets up zram-based swap.
    AlpineSwapSize    = '0'

    RootPartitionType  = '0FC63DAF-8483-4772-8E79-3D69D8477DE4'  # Linux filesystem
    RootPartitionLabel = 'VBAZ_ROOT'
    SwapPartitionType  = '0657FD6D-A4AB-43C4-84E5-0933C84B4F4F'  # Linux swap
    SwapPartitionLabel = 'VBAZ_SWAP'

    # ---- Guest storage pool (ZFS) --------------------------------------
    # The large partition (D:) is converted to a single-vdev ZFS pool that
    # holds ALL guest state (VM disks, container/image data, microVM rootfs),
    # keeping the 15 GB host root lean.  *** ITS CURRENT DATA IS DESTROYED. ***
    ZfsEnable         = $true
    ZfsDriveLetter    = 'D'         # partition converted to the pool (WIPED). REQUIRED when ZfsEnable.
    ZfsPoolName       = 'vbaz'
    ZfsPartitionType  = '6A898CC3-1DD2-11B2-99A6-080020736631'   # Solaris/ZFS type GUID (our marker)
    ZfsPartitionLabel = 'VBAZ_ZFS'
    # Datasets created under the pool (mountpoints wired by the provisioner):
    #   vms->/var/lib/libvirt/images  docker->/var/lib/docker
    #   firecracker,kata,images,iso->/var/lib/vbaz/<name>
    ZfsDatasets       = @('vms', 'docker', 'firecracker', 'kata', 'images', 'iso')

    # ---- Kata 'kata-fc' devmapper thin-pool (on ZFS zvols) -------------
    # The Firecracker Kata backend needs containerd's devmapper snapshotter,
    # which needs a device-mapper thin-pool. v-BAZ builds one automatically on
    # two sparse ZFS zvols (data + metadata) and re-creates the dm device at
    # each boot before containerd starts. Requires ZfsEnable + the 'kata' set.
    KataDevmapper     = $true
    ThinpoolName      = 'vbaz-thinpool'  # device-mapper name
    ThinpoolDataSize  = '100G'           # sparse data zvol (grows as used)
    ThinpoolMetaSize  = '1G'             # metadata zvol (~1/1000 of data)
    KataBaseImageSize = '10GB'           # per-container base device size

    # ---- Secure Boot (shim + MOK) --------------------------------------
    # $true => stage a Microsoft-signed shim + a v-BAZ Machine Owner Key, sign
    # rEFInd and the Alpine kernels with it. Then the ONLY manual step is one
    # MokManager key-enrollment at first boot (unavoidable by design).
    # $false => you disable Secure Boot in firmware instead (simplest).
    SecureBootEnroll  = $false
    MokSubject        = 'CN=v-BAZ Machine Owner Key'
    # shim is Microsoft-signed and cannot always be auto-downloaded. Provide a
    # URL to an MS-signed shimx64.efi bundle (rpm/deb/zip/dir), OR drop
    # shimx64.efi + mmx64.efi into windows\secureboot\ . See docs/SECUREBOOT.md.
    ShimSource        = ''

    # ---- Boot integration ----------------------------------------------
    EspSubdir     = 'vbaz'
    BootEntryName = 'v-BAZ Alpine (KVM host)'
    Bootloader    = 'refind'
    RefindUrl     = 'https://sourceforge.net/projects/refind/files/latest/download'

    # ---- First-boot provisioning ---------------------------------------
    Hostname      = 'vbaz'
    Username      = 'operator'
    Timezone      = 'UTC'

    # Package/feature sets provisioned on the host:
    #   base virt firecracker zfs docker containers kata
    #   - virt        : KVM + libvirt + QEMU (full/lightweight VMs)
    #   - firecracker : Firecracker microVM VMM
    #   - zfs         : ZFS kernel module + userland (needed for the pool)
    #   - docker      : Docker engine (ZFS storage driver on the pool)
    #   - containers  : containerd + CNI (shared runtime for kata)
    #   - kata        : Kata Containers (VM-isolated containers; qemu + fc backends)
    PackageSets   = @('base', 'virt', 'firecracker', 'zfs', 'docker', 'containers', 'kata')

    # ---- Wi-Fi ----------------------------------------------------------
    # For a machine with no Ethernet. NOTE: the one-time first-boot install
    # still needs connectivity while packages download - a USB phone tether or
    # a USB-Ethernet dongle is the reliable way (Wi-Fi is not available in the
    # minimal netboot environment). These settings configure the INSTALLED host
    # to use Wi-Fi natively afterwards. See docs/WIFI.md.
    WifiSSID     = ''                 # leave empty to skip Wi-Fi setup
    WifiCountry  = ''                 # ISO country code for the regulatory domain, e.g. 'US', 'SE', 'DE'
    WifiFirmware = 'linux-firmware'   # firmware apk; narrow to your chip to save space,
                                      # e.g. 'linux-firmware-iwlwifi' (Intel) or '...-ath10k_pci'
    # The passphrase is captured with -SetWifiPassword (never stored in config).

    # ---- Fully offline first boot --------------------------------------
    # Stage a prebuilt offline bundle (tools/build-offline-bundle.sh) on the
    # ESP so the FIRST boot installs with NO network at all - Wi-Fi is then
    # brought up from the offline packages. No Ethernet, no tether.
    # Set OfflineBundleDir to the bundle directory (or pass -Offline <dir>).
    # See docs/OFFLINE.md.
    Offline         = $false
    OfflineBundleDir = ''

    # ---- Diagnostics ----------------------------------------------------
    # $true => verbose logging on both sides (PowerShell DEBUG lines to the
    # console + the Alpine provisioner runs with shell tracing). A log file is
    # always written regardless (see docs/TROUBLESHOOTING.md for paths).
    Verbose = $false

    # ---- Safety knobs ---------------------------------------------------
    RequireBitLockerAck = $true
    MinWindowsFreeSpace = '20GB'
}
