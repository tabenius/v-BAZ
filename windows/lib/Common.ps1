# v-BAZ :: Common helpers (logging, prompts, size parsing, admin checks)
# Dot-sourced by Install-VBaz.ps1 and Uninstall-VBaz.ps1.

Set-StrictMode -Version Latest

$script:VBazVerbose = $false
$script:VBazTranscript = $false

# A log file is ALWAYS written (timestamped, under %ProgramData%\v-BAZ\logs,
# falling back to %TEMP% if that is not writable).
$script:VBazLogFile = $(
    $dir = Join-Path $env:ProgramData 'v-BAZ\logs'
    try { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
    catch { $dir = $env:TEMP }
    Join-Path $dir ("vbaz-install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

function Write-VBazLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'STEP', 'OK')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$stamp][$Level] $Message"
    # File log always gets everything, including DEBUG.
    try { Add-Content -Path $script:VBazLogFile -Value $line -ErrorAction SilentlyContinue } catch { }

    # DEBUG lines only reach the console in verbose mode.
    if ($Level -eq 'DEBUG' -and -not $script:VBazVerbose) { return }

    $color = switch ($Level) {
        'STEP'  { 'Cyan' }   'OK'    { 'Green' }
        'WARN'  { 'Yellow' } 'ERROR' { 'Red' }
        'DEBUG' { 'DarkGray' } default { 'Gray' }
    }
    $prefix = switch ($Level) {
        'STEP'  { '==>' } 'OK'    { ' ok' }
        'WARN'  { ' !!' } 'ERROR' { 'XXX' }
        'DEBUG' { ' ..' } default { '   ' }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Initialise logging: optional explicit path, verbose console, and a full
# console transcript alongside the structured log.
function Initialize-VBazLog {
    param([string]$Path, [switch]$VerboseConsole)
    if ($Path) {
        try {
            $d = Split-Path -Parent $Path
            if ($d) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null }
            $script:VBazLogFile = $Path
        } catch { Write-VBazLog "Cannot use log path '$Path' ($($_.Exception.Message)); keeping default." -Level WARN }
    }
    $script:VBazVerbose = [bool]$VerboseConsole
    try {
        Start-Transcript -Path ($script:VBazLogFile -replace '\.log$', '.transcript.txt') -Append -ErrorAction Stop | Out-Null
        $script:VBazTranscript = $true
    } catch { Write-VBazLog "Console transcript unavailable ($($_.Exception.Message)); structured log still active." -Level DEBUG }
    Write-VBazLog "Logging to $script:VBazLogFile (verbose=$script:VBazVerbose)" -Level INFO
}

function Stop-VBazLog {
    if ($script:VBazTranscript) { try { Stop-Transcript | Out-Null } catch { } ; $script:VBazTranscript = $false }
}

function Test-VBazAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-VBazAdmin {
    if (-not (Test-VBazAdmin)) {
        throw 'v-BAZ must run from an elevated (Administrator) PowerShell session.'
    }
}

# Parse "40GB" / "40G" / "512MB" / raw bytes into an [int64] byte count.
# Accepts both the two-letter (GB) and single-letter (G, as ZFS uses) forms.
function ConvertTo-Bytes {
    param([Parameter(Mandatory)][string]$Value)
    $v = $Value.Trim()
    if ($v -match '^\s*(?<n>[0-9]+(\.[0-9]+)?)\s*(?<u>KB|MB|GB|TB|K|M|G|T|B)?\s*$') {
        $n = [double]$Matches['n']
        $mult = switch -Regex ($Matches['u']) {
            '^K'    { 1KB; break } '^M' { 1MB; break }
            '^G'    { 1GB; break } '^T' { 1TB; break }
            default { 1 }
        }
        return [int64]($n * $mult)
    }
    throw "Cannot parse size value: '$Value'"
}

# Validate the config early (before any disk change) so mistakes surface as a
# clear list of problems rather than a cryptic mid-run failure.
function Test-VBazConfig {
    param([Parameter(Mandatory)][hashtable]$Config)
    $errs = [System.Collections.Generic.List[string]]::new()

    # Sizes consumed by the Windows side must parse.
    foreach ($k in 'AlpineRootSize', 'MinWindowsFreeSpace') {
        if ($Config[$k]) { try { $null = ConvertTo-Bytes $Config[$k] } catch { $errs.Add("$k is not a valid size: '$($Config[$k])'") } }
    }
    if ($Config.AlpineSwapSize -and "$($Config.AlpineSwapSize)" -ne '0') {
        try { $null = ConvertTo-Bytes $Config.AlpineSwapSize } catch { $errs.Add("AlpineSwapSize is not a valid size: '$($Config.AlpineSwapSize)'") }
    }

    if ($Config.HostMode -notin @('existing', 'shrink')) { $errs.Add("HostMode must be 'existing' or 'shrink' (got '$($Config.HostMode)').") }
    if ($Config.HostMode -eq 'existing' -and -not $Config.HostDriveLetter) { $errs.Add("HostMode 'existing' requires HostDriveLetter.") }
    if ($Config.ZfsEnable -and -not $Config.ZfsDriveLetter) { $errs.Add('ZfsEnable is set but ZfsDriveLetter is empty.') }

    # Drive letters must be single letters and distinct.
    $letters = @()
    if ($Config.HostMode -eq 'existing' -and $Config.HostDriveLetter) { $letters += "$($Config.HostDriveLetter)" }
    if ($Config.ZfsEnable -and $Config.ZfsDriveLetter) { $letters += "$($Config.ZfsDriveLetter)" }
    foreach ($l in $letters) { if ($l -notmatch '^[A-Za-z]$') { $errs.Add("drive letter '$l' should be a single letter (A-Z).") } }
    if ($letters.Count -ne ($letters | Sort-Object -Unique).Count) { $errs.Add("host and ZFS drive letters must differ (got: $($letters -join ', ')).") }

    $known = @('base', 'virt', 'firecracker', 'zfs', 'docker', 'containers', 'kata')
    foreach ($s in @($Config.PackageSets)) { if ($s -and $s -notin $known) { $errs.Add("unknown package set '$s' (known: $($known -join ', ')).") } }

    if ($errs.Count) { throw ("Configuration problems:`n  - " + ($errs -join "`n  - ")) }
}

function Format-Bytes {
    param([Parameter(Mandatory)][int64]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return "$Bytes B"
}

# Interactive yes/no gate. Honors -Force (returns $true) and a global
# $script:VBazDryRun (returns $true without prompting, logs intent).
function Confirm-VBazAction {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$Force
    )
    if ($script:VBazDryRun) {
        Write-VBazLog "DRY-RUN would prompt: $Prompt (auto-yes)" -Level WARN
        return $true
    }
    if ($Force) { return $true }
    $ans = Read-Host "$Prompt [type YES to continue]"
    return ($ans -ceq 'YES')
}

# Load and shallow-merge the .psd1 config with any -Override hashtable.
function Import-VBazConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Override = @{}
    )
    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    $cfg = Import-PowerShellDataFile -Path $Path
    foreach ($k in $Override.Keys) {
        if ($null -ne $Override[$k] -and $Override[$k] -ne '') { $cfg[$k] = $Override[$k] }
    }
    return $cfg
}

# SHA-256 of a file as a lowercase hex string.
function Get-VBazSha256 {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}
