# =============================================================================
# Unified Device Sync Tool
# =============================================================================
# Auto-detects ADB vs MTP transport, syncs saves/mods/configs/APKs between
# PC and Android devices running Stardew Valley with SMAPI.
#
# Replaces both mtp_sync.ps1 (MTP/Odin) and sync.sh (ADB/Ayaneo/G Cloud).
#
# Usage:
#   .\sync.ps1                   Full sync (updates + saves + mods + configs)
#   .\sync.ps1 status            Show device + local state
#   .\sync.ps1 check-updates     Query SMAPI API for mod updates
#   .\sync.ps1 update [ModName]  Download + install mod update
#   .\sync.ps1 saves             Bidirectional save sync with backup
#   .\sync.ps1 pull-saves        Force pull saves from device
#   .\sync.ps1 push-saves        Force push saves to device
#   .\sync.ps1 mods              Sync mods (push missing local mods)
#   .\sync.ps1 pull-mods         Pull all mods from device
#   .\sync.ps1 push-mods         Push all mods to device
#   .\sync.ps1 configs           Sync configs
#   .\sync.ps1 pull-configs      Pull configs from device
#   .\sync.ps1 push-configs      Push configs to device
#   .\sync.ps1 deploy            Deploy AndroidConsolizer DLL + manifest
#   .\sync.ps1 logs              Pull SMAPI-latest.txt
#   .\sync.ps1 launch            Force-stop + relaunch game
#   .\sync.ps1 apk-status        Check if SDV + SMAPI are installed
#   .\sync.ps1 apk-pull          Pull APKs from device to cache
#   .\sync.ps1 apk-install       Install cached APKs to device
#   .\sync.ps1 smapi-install     Push SMAPI zip + launch installer
#   .\sync.ps1 --help            Show this help
#
# Flags:
#   --force                      Skip confirmations (auto newer-wins)
#   --dry-run                    Show what would happen without doing it
# =============================================================================

param(
    [Parameter(Position=0)]
    [string]$Command = "sync",

    [Parameter(Position=1)]
    [string]$Arg1 = "",

    [switch]$Force,
    [Alias("dry-run")]
    [switch]$DryRun,

    [Alias("h")]
    [switch]$Help
)

$script:DryRun = $DryRun.IsPresent
$script:ForceMode = $Force.IsPresent

$ErrorActionPreference = "Stop"

# =============================================================================
# Constants
# =============================================================================

$ADB = "C:\Program Files\platform-tools\adb.exe"
$PACKAGE = "abc.smapi.gameloader"
$SDV_PACKAGE = "com.chucklefish.stardewvalley"
$SYNCDEW_ROOT = $PSScriptRoot
$PROJECT_ROOT = Split-Path $SYNCDEW_ROOT -Parent
$BUILD_DIR = Join-Path $PROJECT_ROOT "AndroidConsolizer\bin\Release\net6.0"
$SOURCE_DLL = Join-Path $BUILD_DIR "AndroidConsolizer.dll"
$SOURCE_MANIFEST = Join-Path $PROJECT_ROOT "AndroidConsolizer\manifest.json"
$LOG_DEST = Join-Path $BUILD_DIR "SMAPI-latest.txt"

# Sync directories (inside SyncdewValley/)
$SYNC_ROOT = Join-Path $SYNCDEW_ROOT "sync"
$SAVES_DIR = Join-Path $SYNC_ROOT "saves"
$MODS_DIR = Join-Path $SYNC_ROOT "mods"
$CONFIGS_DIR = Join-Path $SYNC_ROOT "configs"
$APKS_DIR = Join-Path $SYNC_ROOT "apks"
$SAVES_BAK_DIR = Join-Path $SYNC_ROOT "saves.bak"
$DOWNLOADS_DIR = Join-Path $SYNC_ROOT "downloads"
$PROFILES_FILE = Join-Path $SYNC_ROOT ".device_profiles.json"
$TIMESTAMP_FILE = Join-Path $SYNC_ROOT ".last_sync"

# Device path segments from Internal shared storage root
$GAME_ROOT_SEGMENTS = @("Android", "data", "abc.smapi.gameloader", "files")
$SAVES_SEGMENTS = $GAME_ROOT_SEGMENTS + @("Saves")
$MODS_SEGMENTS = $GAME_ROOT_SEGMENTS + @("Mods")
$MOD_SEGMENTS = $GAME_ROOT_SEGMENTS + @("Mods", "AndroidConsolizer")
$LOG_SEGMENTS = $GAME_ROOT_SEGMENTS + @("ErrorLogs")
$SMAPI_SEGMENTS = $GAME_ROOT_SEGMENTS + @("Stardew Assemblies", "smapi-internal")

# ADB game root path — use /storage/emulated/0/ (NEVER /sdcard/)
$ADB_GAME_ROOT = "/storage/emulated/0/Android/data/abc.smapi.gameloader/files"

# =============================================================================
# Output Helpers
# =============================================================================

function Write-Header($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Success($text) {
    Write-Host $text -ForegroundColor Green
}

function Write-Warn($text) {
    Write-Host $text -ForegroundColor Yellow
}

function Write-Err($text) {
    Write-Host $text -ForegroundColor Red
}

function Write-Dim($text) {
    Write-Host $text -ForegroundColor DarkGray
}

function Write-DryRun($text) {
    if ($script:DryRun) {
        Write-Host "[DRY RUN] $text" -ForegroundColor Magenta
    }
}

# =============================================================================
# Layer 1: Transport Abstraction
# =============================================================================

# Transport object structure:
# @{
#   Type       = "ADB" | "MTP"
#   DeviceName = "Ayaneo Pocket Air Mini" | "Odin_M2" | etc.
#   DeviceId   = ADB serial or MTP device name
#   Model      = device model string
#   CanAdbShell = $true  (always — used for app control)
#   CanAdbFiles = $true | $false  (false = scoped storage, need MTP)
#   MtpDevice  = COM object (MTP only)
#   MtpStorage = COM object (MTP only)
# }

# --- MTP Core (lifted from mtp_sync.ps1) ---

$script:Shell = $null

function Get-MtpShell {
    if (-not $script:Shell) {
        $script:Shell = New-Object -ComObject Shell.Application
    }
    return $script:Shell
}

function Find-MtpDevice {
    $shell = Get-MtpShell
    $ns = $shell.NameSpace(17)  # My Computer
    $devices = @()
    foreach ($item in $ns.Items()) {
        # Check if it's a portable device (not a drive letter)
        if ($item.Path -notmatch '^[A-Z]:\\' -and $item.IsFolder) {
            $devices += $item
        }
    }
    return $devices
}

function Get-MtpInternalStorage {
    param([object]$Device)
    $deviceFolder = $Device.GetFolder
    foreach ($sub in $deviceFolder.Items()) {
        if ($sub.Name -like "*Internal*" -or $sub.Name -like "*shared*") {
            return $sub
        }
    }
    return $null
}

function Navigate-MtpPath {
    param(
        [object]$StartFolder,
        [string[]]$Segments
    )
    $current = $StartFolder
    foreach ($segment in $Segments) {
        $found = $null
        foreach ($item in $current.Items()) {
            if ($item.Name -eq $segment) {
                $found = $item
                break
            }
        }
        if (-not $found) {
            return $null
        }
        $current = $found.GetFolder
    }
    return $current
}

function Remove-MtpItem {
    param([object]$Item)
    $tempDir = Join-Path $env:TEMP "mtp_delete_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $tempNs = (Get-MtpShell).NameSpace($tempDir)
        $tempNs.MoveHere($Item, 0x14)  # 0x14 = no progress dialog + yes to all
        $timeout = 15; $elapsed = 0
        while ($elapsed -lt $timeout) {
            Start-Sleep -Milliseconds 500
            $elapsed += 0.5
            if ((Get-ChildItem $tempDir -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) { break }
        }
    }
    finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Wait-MtpCopy {
    param(
        [object]$MtpFolder,
        [string]$ExpectedName,
        [int]$TimeoutSeconds = 30
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
        foreach ($item in $MtpFolder.Items()) {
            if ($item.Name -eq $ExpectedName) { return $true }
        }
    }
    Write-Warn "  Timed out waiting for $ExpectedName"
    return $false
}

function Copy-FileToMtp {
    param(
        [object]$MtpFolder,
        [string]$LocalPath
    )
    $name = [System.IO.Path]::GetFileName($LocalPath)
    # Remove existing to prevent duplicates
    foreach ($item in $MtpFolder.Items()) {
        if ($item.Name -eq $name) {
            Remove-MtpItem -Item $item
            break
        }
    }
    $MtpFolder.CopyHere($LocalPath, 0x14)
    Wait-MtpCopy -MtpFolder $MtpFolder -ExpectedName $name | Out-Null
}

function Copy-MtpFileToLocal {
    param(
        [object]$MtpItem,
        [string]$LocalDir
    )
    if (-not (Test-Path -LiteralPath $LocalDir)) {
        New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
    }
    $localNs = (Get-MtpShell).NameSpace($LocalDir)
    $localNs.CopyHere($MtpItem, 0x14)
    $destPath = Join-Path $LocalDir $MtpItem.Name
    # Use -LiteralPath to handle brackets and special chars in paths
    $timeout = 30; $elapsed = 0
    while ($elapsed -lt 2) {
        if (Test-Path -LiteralPath $destPath) { return $destPath }
        Start-Sleep -Milliseconds 100
        $elapsed += 0.1
    }
    while ($elapsed -lt $timeout) {
        if (Test-Path -LiteralPath $destPath) { return $destPath }
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }
    Write-Warn "  Timed out waiting for $($MtpItem.Name) to copy"
    return $null
}

function Copy-MtpFolderToLocal {
    param(
        [object]$MtpFolder,
        [string]$LocalDir,
        [string]$Prefix = ""
    )
    if (-not (Test-Path -LiteralPath $LocalDir)) {
        New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
    }
    # Snapshot items before copy operations (COM enumerator can be invalidated)
    $folders = @()
    $files = @()
    foreach ($item in $MtpFolder.Items()) {
        if ($item.IsFolder) {
            $folders += @{ Name = $item.Name; Folder = $item.GetFolder }
        } else {
            $files += $item
        }
    }
    foreach ($file in $files) {
        Write-Host "    Pulling: $Prefix$($file.Name)"
        Copy-MtpFileToLocal -MtpItem $file -LocalDir $LocalDir | Out-Null
    }
    foreach ($folder in $folders) {
        $subDir = Join-Path $LocalDir $folder.Name
        Copy-MtpFolderToLocal -MtpFolder $folder.Folder -LocalDir $subDir -Prefix "$Prefix$($folder.Name)/"
    }
}

function Copy-LocalFolderToMtp {
    param(
        [object]$MtpFolder,
        [string]$LocalDir,
        [string]$Prefix = ""
    )
    foreach ($file in Get-ChildItem -Path $LocalDir -File) {
        Write-Host "    Pushing: $Prefix$($file.Name)"
        Copy-FileToMtp -MtpFolder $MtpFolder -LocalPath $file.FullName
    }
    foreach ($dir in Get-ChildItem -Path $LocalDir -Directory) {
        $subFolder = $null
        foreach ($item in $MtpFolder.Items()) {
            if ($item.Name -eq $dir.Name -and $item.IsFolder) {
                $subFolder = $item.GetFolder
                break
            }
        }
        if (-not $subFolder) {
            Write-Warn "    Folder $($dir.Name) doesn't exist on device, skipping"
            continue
        }
        Copy-LocalFolderToMtp -MtpFolder $subFolder -LocalDir $dir.FullName -Prefix "$Prefix$($dir.Name)/"
    }
}

# --- Transport Detection ---

function Detect-Transport {
    <#
    .SYNOPSIS
    Auto-detect connected device and return a transport object.
    Priority: ADB with file access > ADB with MTP fallback > MTP-only
    #>

    # Step 1: Check ADB
    $adbDevice = $null
    $adbModel = $null
    $adbSerial = $null
    try {
        $adbOut = & $ADB devices -l 2>&1
        foreach ($line in $adbOut) {
            if ($line -match '^(\S+)\s+device\s') {
                $adbSerial = $Matches[1]
                if ($line -match 'model:(\S+)') {
                    $adbModel = $Matches[1]
                }
                break
            }
        }
    } catch { }

    if ($adbSerial) {
        # Step 2: Can ADB access the game files? (scoped storage check)
        $canAdbFiles = $false
        try {
            $lsResult = & $ADB shell "ls $ADB_GAME_ROOT/ 2>/dev/null" 2>&1
            $lsStr = ($lsResult | Out-String).Trim()
            if ($lsStr -and $lsStr -notmatch "Permission denied|No such file") {
                $canAdbFiles = $true
            }
        } catch { }

        if ($canAdbFiles) {
            # Pure ADB transport (Ayaneo, G Cloud)
            return @{
                Type        = "ADB"
                DeviceName  = $adbModel
                DeviceId    = $adbSerial
                Model       = $adbModel
                CanAdbShell = $true
                CanAdbFiles = $true
                MtpDevice   = $null
                MtpStorage  = $null
            }
        }

        # ADB connected but can't access files — try MTP for file ops
        $mtpDevices = Find-MtpDevice
        foreach ($dev in $mtpDevices) {
            $storage = Get-MtpInternalStorage -Device $dev
            if ($storage) {
                # Verify it has the game files
                $testNav = Navigate-MtpPath -StartFolder $storage.GetFolder -Segments $GAME_ROOT_SEGMENTS
                if ($testNav) {
                    return @{
                        Type        = "MTP"
                        DeviceName  = $dev.Name
                        DeviceId    = $adbSerial
                        Model       = $adbModel
                        CanAdbShell = $true
                        CanAdbFiles = $false
                        MtpDevice   = $dev
                        MtpStorage  = $storage
                    }
                }
            }
        }

        # ADB but no MTP — return ADB-only (shell commands work, file ops will fail gracefully)
        return @{
            Type        = "ADB"
            DeviceName  = $adbModel
            DeviceId    = $adbSerial
            Model       = $adbModel
            CanAdbShell = $true
            CanAdbFiles = $false
            MtpDevice   = $null
            MtpStorage  = $null
        }
    }

    # Step 3: No ADB — try MTP only
    $mtpDevices = Find-MtpDevice
    foreach ($dev in $mtpDevices) {
        $storage = Get-MtpInternalStorage -Device $dev
        if ($storage) {
            $testNav = Navigate-MtpPath -StartFolder $storage.GetFolder -Segments $GAME_ROOT_SEGMENTS
            if ($testNav) {
                return @{
                    Type        = "MTP"
                    DeviceName  = $dev.Name
                    DeviceId    = $dev.Name
                    Model       = $dev.Name
                    CanAdbShell = $false
                    CanAdbFiles = $false
                    MtpDevice   = $dev
                    MtpStorage  = $storage
                }
            }
        }
    }

    # Nothing found
    return $null
}

# --- Transport Operations ---

function Device-ListDir {
    <#
    .SYNOPSIS
    List items in a device directory. Returns array of @{Name; IsFolder}
    #>
    param($Transport, [string[]]$Segments)

    if ($Transport.Type -eq "ADB" -and $Transport.CanAdbFiles) {
        $path = "$ADB_GAME_ROOT/" + ($Segments[$GAME_ROOT_SEGMENTS.Count..($Segments.Count-1)] -join "/")
        if ($Segments.Count -le $GAME_ROOT_SEGMENTS.Count) { $path = "$ADB_GAME_ROOT" }
        $output = & $ADB shell "ls -1 '$path' 2>/dev/null" 2>&1
        $results = @()
        foreach ($line in $output) {
            $name = ($line -replace "`r","").Trim()
            if ($name -and $name -notmatch "^ls:") {
                # Check if it's a directory
                $isDir = $false
                try {
                    $typeCheck = & $ADB shell "[ -d '$path/$name' ] && echo D || echo F" 2>&1
                    $isDir = ($typeCheck -replace "`r","").Trim() -eq "D"
                } catch { }
                $results += @{ Name = $name; IsFolder = $isDir }
            }
        }
        return $results
    }
    elseif ($Transport.Type -eq "MTP") {
        $folder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments $Segments
        if (-not $folder) { return @() }
        $results = @()
        foreach ($item in $folder.Items()) {
            $results += @{ Name = $item.Name; IsFolder = $item.IsFolder }
        }
        return $results
    }
    return @()
}

function Device-PullFile {
    param($Transport, [string[]]$Segments, [string]$Name, [string]$LocalDest)

    if ($script:DryRun) {
        Write-DryRun "Pull: $Name -> $LocalDest"
        return $true
    }

    if (-not (Test-Path (Split-Path $LocalDest))) {
        New-Item -ItemType Directory -Path (Split-Path $LocalDest) -Force | Out-Null
    }

    if ($Transport.Type -eq "ADB" -and $Transport.CanAdbFiles) {
        $path = "$ADB_GAME_ROOT/" + ($Segments[$GAME_ROOT_SEGMENTS.Count..($Segments.Count-1)] -join "/")
        if ($Segments.Count -le $GAME_ROOT_SEGMENTS.Count) { $path = "$ADB_GAME_ROOT" }
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        $output = & $ADB pull "$path/$Name" "$LocalDest" 2>&1
        $exitCode = $LASTEXITCODE; $ErrorActionPreference = $prevEAP
        if ($exitCode -ne 0) {
            Write-Err "ADB pull failed: $output"
            return $false
        }
        return (Test-Path $LocalDest)
    }
    elseif ($Transport.Type -eq "MTP") {
        $folder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments $Segments
        if (-not $folder) { return $false }
        foreach ($item in $folder.Items()) {
            if ($item.Name -eq $Name) {
                $result = Copy-MtpFileToLocal -MtpItem $item -LocalDir (Split-Path $LocalDest)
                return ($null -ne $result)
            }
        }
        return $false
    }
    return $false
}

function Device-PushFile {
    param($Transport, [string[]]$Segments, [string]$LocalPath)

    if ($script:DryRun) {
        Write-DryRun "Push: $LocalPath -> device"
        return $true
    }

    $name = [System.IO.Path]::GetFileName($LocalPath)

    if ($Transport.Type -eq "ADB" -and $Transport.CanAdbFiles) {
        $path = "$ADB_GAME_ROOT/" + ($Segments[$GAME_ROOT_SEGMENTS.Count..($Segments.Count-1)] -join "/")
        if ($Segments.Count -le $GAME_ROOT_SEGMENTS.Count) { $path = "$ADB_GAME_ROOT" }
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        $output = & $ADB push "$LocalPath" "$path/$name" 2>&1
        $exitCode = $LASTEXITCODE; $ErrorActionPreference = $prevEAP
        if ($exitCode -ne 0) {
            Write-Err "ADB push failed: $output"
            return $false
        }
        return $true
    }
    elseif ($Transport.Type -eq "MTP") {
        $folder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments $Segments
        if (-not $folder) { return $false }
        Copy-FileToMtp -MtpFolder $folder -LocalPath $LocalPath
        return $true
    }
    return $false
}

function Device-PullFolder {
    param($Transport, [string[]]$Segments, [string]$LocalDest)

    if ($script:DryRun) {
        $segStr = $Segments[-1]
        Write-DryRun "Pull folder: $segStr -> $LocalDest"
        return $true
    }

    if (-not (Test-Path $LocalDest)) {
        New-Item -ItemType Directory -Path $LocalDest -Force | Out-Null
    }

    if ($Transport.Type -eq "ADB" -and $Transport.CanAdbFiles) {
        $path = "$ADB_GAME_ROOT/" + ($Segments[$GAME_ROOT_SEGMENTS.Count..($Segments.Count-1)] -join "/")
        if ($Segments.Count -le $GAME_ROOT_SEGMENTS.Count) { $path = "$ADB_GAME_ROOT" }
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        $output = & $ADB pull "$path/" "$LocalDest/" 2>&1
        $exitCode = $LASTEXITCODE; $ErrorActionPreference = $prevEAP
        if ($exitCode -ne 0) {
            Write-Err "ADB pull failed: $output"
            return $false
        }
        return $true
    }
    elseif ($Transport.Type -eq "MTP") {
        $folder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments $Segments
        if (-not $folder) { return $false }
        Copy-MtpFolderToLocal -MtpFolder $folder -LocalDir $LocalDest
        return $true
    }
    return $false
}

function Device-PushFolder {
    param($Transport, [string[]]$Segments, [string]$LocalDir)

    if ($script:DryRun) {
        $segStr = $Segments[-1]
        Write-DryRun "Push folder: $LocalDir -> $segStr"
        return $true
    }

    if ($Transport.Type -eq "ADB" -and $Transport.CanAdbFiles) {
        $path = "$ADB_GAME_ROOT/" + ($Segments[$GAME_ROOT_SEGMENTS.Count..($Segments.Count-1)] -join "/")
        if ($Segments.Count -le $GAME_ROOT_SEGMENTS.Count) { $path = "$ADB_GAME_ROOT" }
        # Clear target first — adb push nests dir inside existing dir, causing double-nesting
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        & $ADB shell "rm -rf '$path'" 2>&1 | Out-Null
        $output = & $ADB push "$LocalDir" "$path" 2>&1
        $exitCode = $LASTEXITCODE; $ErrorActionPreference = $prevEAP
        if ($exitCode -ne 0) {
            Write-Err "ADB push failed: $output"
            return $false
        }
        return $true
    }
    elseif ($Transport.Type -eq "MTP") {
        $folder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments $Segments
        if (-not $folder) { return $false }
        Copy-LocalFolderToMtp -MtpFolder $folder -LocalDir $LocalDir
        return $true
    }
    return $false
}

function Device-DeleteItem {
    param($Transport, [string[]]$Segments, [string]$Name)

    if ($script:DryRun) {
        Write-DryRun "Delete: $Name"
        return $true
    }

    if ($Transport.Type -eq "ADB" -and $Transport.CanAdbFiles) {
        $path = "$ADB_GAME_ROOT/" + ($Segments[$GAME_ROOT_SEGMENTS.Count..($Segments.Count-1)] -join "/")
        if ($Segments.Count -le $GAME_ROOT_SEGMENTS.Count) { $path = "$ADB_GAME_ROOT" }
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        & $ADB shell "rm -rf '$path/$Name'" 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP
        return $true
    }
    elseif ($Transport.Type -eq "MTP") {
        $folder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments $Segments
        if (-not $folder) { return $false }
        foreach ($item in $folder.Items()) {
            if ($item.Name -eq $Name) {
                Remove-MtpItem -Item $item
                return $true
            }
        }
        return $false
    }
    return $false
}

function Device-GetFileDate {
    <#
    .SYNOPSIS
    Get the modification date of a file on the device.
    #>
    param($Transport, [string[]]$Segments, [string]$Name)

    if ($Transport.Type -eq "ADB" -and $Transport.CanAdbFiles) {
        $path = "$ADB_GAME_ROOT/" + ($Segments[$GAME_ROOT_SEGMENTS.Count..($Segments.Count-1)] -join "/")
        if ($Segments.Count -le $GAME_ROOT_SEGMENTS.Count) { $path = "$ADB_GAME_ROOT" }
        try {
            $epoch = & $ADB shell "stat -c '%Y' '$path/$Name' 2>/dev/null" 2>&1
            $epoch = ($epoch -replace "`r","").Trim()
            if ($epoch -match '^\d+$') {
                return ([DateTimeOffset]::FromUnixTimeSeconds([long]$epoch)).LocalDateTime
            }
        } catch { }
        return $null
    }
    elseif ($Transport.Type -eq "MTP") {
        $folder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments $Segments
        if (-not $folder) { return $null }
        foreach ($item in $folder.Items()) {
            if ($item.Name -eq $Name) {
                # Try detail columns for date modified (varies by device)
                foreach ($col in @(3, 4, 5)) {
                    $dateStr = $folder.GetDetailsOf($item, $col)
                    if ($dateStr) {
                        try {
                            $parsed = [DateTime]::Parse($dateStr)
                            if ($parsed.Year -gt 2000) { return $parsed }
                        } catch { }
                    }
                }
                return $null
            }
        }
        return $null
    }
    return $null
}

# =============================================================================
# Layer 2: Device Profiles
# =============================================================================

$script:DeviceProfiles = @{}

function Load-DeviceProfiles {
    if (Test-Path $PROFILES_FILE) {
        try {
            $json = Get-Content $PROFILES_FILE -Raw | ConvertFrom-Json
            $script:DeviceProfiles = @{}
            foreach ($prop in $json.PSObject.Properties) {
                $script:DeviceProfiles[$prop.Name] = $prop.Value
            }
        } catch {
            $script:DeviceProfiles = @{}
        }
    }
}

function Save-DeviceProfiles {
    if (-not (Test-Path $SYNC_ROOT)) {
        New-Item -ItemType Directory -Path $SYNC_ROOT -Force | Out-Null
    }
    $script:DeviceProfiles | ConvertTo-Json -Depth 5 | Set-Content $PROFILES_FILE -Encoding UTF8
}

function Update-DeviceProfile {
    param($Transport)
    $key = $Transport.DeviceId
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Known device tap coordinates
    $tapCoords = $null
    if ($Transport.Model -like "*Odin*") { $tapCoords = "540 1436" }
    elseif ($Transport.Model -like "*G_Cloud*") { $tapCoords = "540 1398" }

    $script:DeviceProfiles[$key] = @{
        Name        = $Transport.DeviceName
        Model       = $Transport.Model
        Transport   = $Transport.Type
        TapCoords   = $tapCoords
        LastSeen    = $now
    }
    Save-DeviceProfiles
}

function Get-TapCoords {
    param($Transport)
    $key = $Transport.DeviceId
    if ($script:DeviceProfiles.ContainsKey($key)) {
        $profile = $script:DeviceProfiles[$key]
        if ($profile -is [PSCustomObject]) {
            return $profile.TapCoords
        }
        if ($profile -is [hashtable]) {
            return $profile.TapCoords
        }
    }
    # Fallback based on model name
    if ($Transport.Model -like "*Odin*") { return "540 1436" }
    if ($Transport.Model -like "*G_Cloud*") { return "540 1398" }
    return $null
}

# =============================================================================
# Layer 3: App Control (ADB shell — works on all devices)
# =============================================================================

function Stop-Game {
    param($Transport)
    if (-not $Transport.CanAdbShell) {
        Write-Warn "Cannot stop game (no ADB shell access)"
        return
    }
    Write-Host "Stopping game..."
    try {
        & $ADB shell am force-stop $PACKAGE 2>&1 | Out-Null
    } catch { }
    Start-Sleep -Seconds 1
}

function Start-Game {
    param($Transport)
    if (-not $Transport.CanAdbShell) {
        Write-Warn "Cannot launch game (no ADB shell access)"
        return
    }
    Write-Host "Launching game..."
    try {
        & $ADB shell monkey -p $PACKAGE -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
    } catch { }

    $tapCoords = Get-TapCoords -Transport $Transport
    if ($tapCoords) {
        Write-Host "Waiting for launcher..."
        Start-Sleep -Seconds 4
        Write-Host "Tapping 'Start Game'..."
        try {
            & $ADB shell input tap $tapCoords.Split(" ") 2>&1 | Out-Null
        } catch { }
    }
}

# =============================================================================
# Layer 4: Feature Modules
# =============================================================================

# --- Ensure sync directories exist ---

function Ensure-SyncDirs {
    foreach ($dir in @($SYNC_ROOT, $SAVES_DIR, $MODS_DIR, $CONFIGS_DIR, $APKS_DIR, $SAVES_BAK_DIR, $DOWNLOADS_DIR)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

# --- Status ---

function Invoke-Status {
    param($Transport)

    Write-Header "Sync Status"

    # Device info
    if ($Transport) {
        $icon = if ($Transport.Type -eq "ADB") { "ADB" } else { "MTP" }
        Write-Success "Device: $($Transport.DeviceName) [$icon]"
        Write-Host "  Serial: $($Transport.DeviceId)"
        Write-Host "  File access: $(if ($Transport.CanAdbFiles) { 'ADB' } elseif ($Transport.MtpDevice) { 'MTP' } else { 'NONE' })"
        Write-Host "  Shell access: $(if ($Transport.CanAdbShell) { 'Yes' } else { 'No' })"

        # Device saves
        Write-Host ""
        Write-Host "  Device saves:"
        $deviceSaves = Device-ListDir -Transport $Transport -Segments $SAVES_SEGMENTS
        $saveCount = 0
        foreach ($item in $deviceSaves) {
            if ($item.IsFolder) {
                Write-Host "    $($item.Name)"
                $saveCount++
            }
        }
        if ($saveCount -eq 0) { Write-Host "    (none)" }

        # Device mods
        Write-Host "  Device mods:"
        $deviceMods = Device-ListDir -Transport $Transport -Segments $MODS_SEGMENTS
        $modCount = 0
        foreach ($item in $deviceMods) {
            if ($item.IsFolder) {
                Write-Host "    $($item.Name)"
                $modCount++
            }
        }
        if ($modCount -eq 0) { Write-Host "    (none)" }
    }
    else {
        Write-Err "Device: NOT CONNECTED"
        Write-Host "  Connect a device via USB and ensure File Transfer mode is enabled."
    }

    # Local state
    Write-Host ""
    Write-Host "Local sync: $SYNC_ROOT"

    Write-Host "  Saves:"
    if ((Test-Path $SAVES_DIR) -and (Get-ChildItem $SAVES_DIR -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        foreach ($d in Get-ChildItem $SAVES_DIR -Directory) {
            $size = "{0:N1} KB" -f ((Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1KB)
            Write-Host "    $($d.Name) ($size)"
        }
    }
    else { Write-Host "    (none)" }

    Write-Host "  Mods:"
    if ((Test-Path $MODS_DIR) -and (Get-ChildItem $MODS_DIR -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        foreach ($d in Get-ChildItem $MODS_DIR -Directory) {
            # Try to read version from manifest
            $manifest = Join-Path $d.FullName "manifest.json"
            $ver = ""
            if (Test-Path $manifest) {
                try {
                    $m = Get-Content $manifest -Raw | ConvertFrom-Json
                    $ver = " v$($m.Version)"
                } catch { }
            }
            $size = "{0:N1} KB" -f ((Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1KB)
            Write-Host "    $($d.Name)$ver ($size)"
        }
    }
    else { Write-Host "    (none)" }

    Write-Host "  Configs:"
    if ((Test-Path $CONFIGS_DIR) -and (Get-ChildItem $CONFIGS_DIR -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        foreach ($d in Get-ChildItem $CONFIGS_DIR -Directory) {
            Write-Host "    $($d.Name)/config.json"
        }
    }
    else { Write-Host "    (none)" }

    # APK cache
    if (Test-Path $APKS_DIR) {
        $apkDirs = Get-ChildItem $APKS_DIR -Directory -ErrorAction SilentlyContinue
        if ($apkDirs.Count -gt 0) {
            Write-Host "  APK cache:"
            foreach ($d in $apkDirs) {
                $count = (Get-ChildItem $d.FullName -File -ErrorAction SilentlyContinue | Measure-Object).Count
                Write-Host "    $($d.Name) ($count files)"
            }
        }
    }

    # Last sync
    if (Test-Path $TIMESTAMP_FILE) {
        Write-Host ""
        Write-Dim "Last sync: $(Get-Content $TIMESTAMP_FILE -Tail 1)"
    }
}

# --- Deploy ---

function Invoke-Deploy {
    param($Transport)

    Write-Header "Deploy AndroidConsolizer"

    if (-not (Test-Path $SOURCE_DLL)) {
        Write-Err "DLL not found: $SOURCE_DLL"
        Write-Host "Run 'dotnet build' first."
        return
    }
    if (-not (Test-Path $SOURCE_MANIFEST)) {
        Write-Err "Manifest not found: $SOURCE_MANIFEST"
        return
    }

    $dllSize = (Get-Item $SOURCE_DLL).Length
    Write-Host "DLL: $dllSize bytes"

    if ($script:DryRun) {
        Write-DryRun "Would push AndroidConsolizer.dll + manifest.json to device"
        Write-DryRun "Would restart game"
        return
    }

    Write-Host "Pushing AndroidConsolizer.dll..."
    if (-not (Device-PushFile -Transport $Transport -Segments $MOD_SEGMENTS -LocalPath $SOURCE_DLL)) {
        Write-Err "Failed to push DLL — aborting deploy"
        return
    }
    Write-Host "Pushing manifest.json..."
    if (-not (Device-PushFile -Transport $Transport -Segments $MOD_SEGMENTS -LocalPath $SOURCE_MANIFEST)) {
        Write-Err "Failed to push manifest — aborting deploy"
        return
    }

    # Restart game
    Write-Host ""
    Stop-Game -Transport $Transport
    Start-Game -Transport $Transport

    Write-Success "Deploy complete!"
}

# --- Logs ---

function Invoke-Logs {
    param($Transport)

    Write-Header "Pull SMAPI Log"

    Stop-Game -Transport $Transport

    if (Test-Path $LOG_DEST) {
        Remove-Item $LOG_DEST -Force
    }

    Write-Host "Pulling SMAPI-latest.txt..."
    $result = Device-PullFile -Transport $Transport -Segments $LOG_SEGMENTS -Name "SMAPI-latest.txt" -LocalDest $LOG_DEST

    if ($result -and (Test-Path $LOG_DEST)) {
        $size = (Get-Item $LOG_DEST).Length
        Write-Success "Log saved: $LOG_DEST ($size bytes)"
        Write-Host ""
        Write-Dim "--- Last 10 lines ---"
        Get-Content $LOG_DEST -Tail 10 | ForEach-Object { Write-Dim "  $_" }
    }
    else {
        Write-Err "Failed to pull log file."
    }
}

# --- Launch ---

function Invoke-Launch {
    param($Transport)
    Write-Header "Launch Game"
    Stop-Game -Transport $Transport
    Start-Game -Transport $Transport
    Write-Success "Game launched!"
}

# --- Pull/Push Saves ---

function Invoke-PullSaves {
    param($Transport)
    Write-Header "Pull Saves"

    Stop-Game -Transport $Transport
    Ensure-SyncDirs

    $deviceSaves = Device-ListDir -Transport $Transport -Segments $SAVES_SEGMENTS
    $saveCount = 0

    foreach ($item in $deviceSaves) {
        if (-not $item.IsFolder) { continue }
        Write-Host "  Pulling: $($item.Name)/"
        $localDir = Join-Path $SAVES_DIR $item.Name

        # Clean existing local copy
        if (Test-Path $localDir) { Remove-Item $localDir -Recurse -Force }

        Device-PullFolder -Transport $Transport -Segments ($SAVES_SEGMENTS + @($item.Name)) -LocalDest $localDir | Out-Null
        $saveCount++
    }

    if ($saveCount -eq 0) { Write-Host "  No saves found on device." }
    else { Write-Success "Pulled $saveCount save(s)" }
}

function Invoke-PushSaves {
    param($Transport)
    Write-Header "Push Saves"

    if (-not (Test-Path $SAVES_DIR) -or (Get-ChildItem $SAVES_DIR -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        Write-Warn "No local saves to push."
        return
    }

    Stop-Game -Transport $Transport

    foreach ($localSave in Get-ChildItem $SAVES_DIR -Directory) {
        Write-Host "  Pushing: $($localSave.Name)/"

        # For MTP, target folder must already exist (can't create via MTP)
        if (-not $Transport.CanAdbFiles) {
            $deviceSaves = Device-ListDir -Transport $Transport -Segments $SAVES_SEGMENTS
            $exists = $false
            foreach ($ds in $deviceSaves) {
                if ($ds.Name -eq $localSave.Name -and $ds.IsFolder) { $exists = $true; break }
            }
            if (-not $exists) {
                Write-Warn "    Save '$($localSave.Name)' doesn't exist on device, skipping"
                continue
            }
        }

        Device-PushFolder -Transport $Transport -Segments ($SAVES_SEGMENTS + @($localSave.Name)) -LocalDir $localSave.FullName | Out-Null
    }

    Write-Success "Saves pushed."
}

# --- Pull/Push Mods ---

function Invoke-PullMods {
    param($Transport)
    Write-Header "Pull Mods"

    Ensure-SyncDirs

    # Clean local mods dir
    if (Test-Path $MODS_DIR) { Remove-Item $MODS_DIR -Recurse -Force }
    New-Item -ItemType Directory -Path $MODS_DIR -Force | Out-Null

    $deviceMods = Device-ListDir -Transport $Transport -Segments $MODS_SEGMENTS
    $modCount = 0

    foreach ($item in $deviceMods) {
        if (-not $item.IsFolder) { continue }
        Write-Host "  Pulling: $($item.Name)/"
        $localDir = Join-Path $MODS_DIR $item.Name
        Device-PullFolder -Transport $Transport -Segments ($MODS_SEGMENTS + @($item.Name)) -LocalDest $localDir | Out-Null
        $modCount++
    }

    if ($modCount -eq 0) { Write-Host "  No mods found on device." }
    else { Write-Success "Pulled $modCount mod(s)" }
}

function Invoke-PushMods {
    param($Transport)
    Write-Header "Push Mods"

    if (-not (Test-Path $MODS_DIR) -or (Get-ChildItem $MODS_DIR -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        Write-Warn "No local mods to push."
        return
    }

    $deviceMods = Device-ListDir -Transport $Transport -Segments $MODS_SEGMENTS
    $deviceModNames = $deviceMods | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }

    foreach ($localMod in Get-ChildItem $MODS_DIR -Directory) {
        Write-Host "  Pushing: $($localMod.Name)/"

        if ($localMod.Name -notin $deviceModNames) {
            Write-Warn "    Mod folder doesn't exist on device, skipping"
            continue
        }

        Device-PushFolder -Transport $Transport -Segments ($MODS_SEGMENTS + @($localMod.Name)) -LocalDir $localMod.FullName | Out-Null
    }

    Write-Success "Mods pushed."
}

# --- Pull/Push Configs ---

function Invoke-PullConfigs {
    param($Transport)
    Write-Header "Pull Configs"

    Ensure-SyncDirs

    # Clean local configs
    if (Test-Path $CONFIGS_DIR) { Remove-Item $CONFIGS_DIR -Recurse -Force }
    New-Item -ItemType Directory -Path $CONFIGS_DIR -Force | Out-Null

    $configCount = 0

    # Pull config.json from each mod
    $deviceMods = Device-ListDir -Transport $Transport -Segments $MODS_SEGMENTS
    foreach ($mod in $deviceMods) {
        if (-not $mod.IsFolder) { continue }
        $modSegments = $MODS_SEGMENTS + @($mod.Name)
        $modFiles = Device-ListDir -Transport $Transport -Segments $modSegments
        foreach ($f in $modFiles) {
            if ($f.Name -eq "config.json") {
                Write-Host "  Pulling: $($mod.Name)/config.json"
                $configDir = Join-Path $CONFIGS_DIR $mod.Name
                Device-PullFile -Transport $Transport -Segments $modSegments -Name "config.json" -LocalDest (Join-Path $configDir "config.json") | Out-Null
                $configCount++
                break
            }
        }
    }

    # Also pull SMAPI internal config
    $smapiFiles = Device-ListDir -Transport $Transport -Segments $SMAPI_SEGMENTS
    foreach ($f in $smapiFiles) {
        if ($f.Name -eq "config.json") {
            Write-Host "  Pulling: smapi-internal/config.json"
            $smapiDir = Join-Path $CONFIGS_DIR "smapi-internal"
            Device-PullFile -Transport $Transport -Segments $SMAPI_SEGMENTS -Name "config.json" -LocalDest (Join-Path $smapiDir "config.json") | Out-Null
            $configCount++
            break
        }
    }

    if ($configCount -eq 0) { Write-Host "  No configs found." }
    else { Write-Success "Pulled $configCount config(s)" }
}

function Invoke-PushConfigs {
    param($Transport)
    Write-Header "Push Configs"

    if (-not (Test-Path $CONFIGS_DIR) -or (Get-ChildItem $CONFIGS_DIR -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        Write-Warn "No local configs to push."
        return
    }

    foreach ($configDir in Get-ChildItem $CONFIGS_DIR -Directory) {
        $configFile = Join-Path $configDir.FullName "config.json"
        if (-not (Test-Path $configFile)) { continue }

        if ($configDir.Name -eq "smapi-internal") {
            Write-Host "  Pushing: smapi-internal/config.json"
            Device-PushFile -Transport $Transport -Segments $SMAPI_SEGMENTS -LocalPath $configFile | Out-Null
        }
        else {
            Write-Host "  Pushing: $($configDir.Name)/config.json"
            Device-PushFile -Transport $Transport -Segments ($MODS_SEGMENTS + @($configDir.Name)) -LocalPath $configFile | Out-Null
        }
    }

    Write-Success "Configs pushed."
}

# --- Bidirectional Save Sync ---

function Invoke-SaveSync {
    param($Transport)
    Write-Header "Bidirectional Save Sync"

    Stop-Game -Transport $Transport
    Ensure-SyncDirs

    # Gather all save names from both sides
    $localSaveNames = @()
    if (Test-Path $SAVES_DIR) {
        $localSaveNames = Get-ChildItem $SAVES_DIR -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
    }

    $deviceSaves = Device-ListDir -Transport $Transport -Segments $SAVES_SEGMENTS
    $deviceSaveNames = $deviceSaves | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }

    $allNames = @($localSaveNames) + @($deviceSaveNames) | Sort-Object -Unique
    if ($allNames.Count -eq 0) {
        Write-Host "No saves found on either side."
        return
    }

    $synced = 0

    foreach ($name in $allNames) {
        $localDir = Join-Path $SAVES_DIR $name
        $localExists = Test-Path $localDir
        $deviceExists = $name -in $deviceSaveNames

        # Get timestamps
        $localDate = $null
        $deviceDate = $null

        if ($localExists) {
            $saveFile = Join-Path $localDir $name
            if (Test-Path $saveFile) {
                $localDate = (Get-Item $saveFile).LastWriteTime
            }
        }

        if ($deviceExists) {
            $deviceDate = Device-GetFileDate -Transport $Transport -Segments ($SAVES_SEGMENTS + @($name)) -Name $name
        }

        # Format dates for display
        $localStr = if ($localDate) { $localDate.ToString("yyyy-MM-dd HH:mm:ss") } else { "(missing)" }
        $deviceStr = if ($deviceDate) { $deviceDate.ToString("yyyy-MM-dd HH:mm:ss") } else { "(missing)" }

        Write-Host "  $name"
        Write-Host "    Local:  $localStr"
        Write-Host "    Device: $deviceStr"

        # Determine action
        if ($localExists -and $deviceExists -and $localDate -and $deviceDate) {
            $diff = ($deviceDate - $localDate).TotalSeconds
            if ([Math]::Abs($diff) -lt 60) {
                Write-Dim "    -> Same (within 60s tolerance)"
                continue
            }
            elseif ($diff -gt 0) {
                # Device is newer
                if (-not $script:ForceMode) {
                    $choice = Read-Host "    -> Device is NEWER. Pull to local? [Y/n]"
                    if ($choice -eq "n") { continue }
                }
                Write-Host "    -> Pulling (device newer)"
                Backup-LocalSave -Name $name
                if (Test-Path $localDir) { Remove-Item $localDir -Recurse -Force }
                Device-PullFolder -Transport $Transport -Segments ($SAVES_SEGMENTS + @($name)) -LocalDest $localDir | Out-Null
                $synced++
            }
            else {
                # Local is newer
                if (-not $script:ForceMode) {
                    $choice = Read-Host "    -> Local is NEWER. Push to device? [Y/n]"
                    if ($choice -eq "n") { continue }
                }
                Write-Host "    -> Pushing (local newer)"
                Device-PushFolder -Transport $Transport -Segments ($SAVES_SEGMENTS + @($name)) -LocalDir $localDir | Out-Null
                $synced++
            }
        }
        elseif ($localExists -and -not $deviceExists) {
            if (-not $script:ForceMode) {
                $choice = Read-Host "    -> Only exists locally. Push to device? [y/N]"
                if ($choice -ne "y") { continue }
            } else {
                Write-Host "    -> Pushing (only local, creating on device)"
            }
            Device-PushFolder -Transport $Transport -Segments ($SAVES_SEGMENTS + @($name)) -LocalDir $localDir | Out-Null
            $synced++
        }
        elseif (-not $localExists -and $deviceExists) {
            if (-not $script:ForceMode) {
                $choice = Read-Host "    -> Only exists on device. Pull to local? [y/N]"
                if ($choice -ne "y") { continue }
            } else {
                Write-Host "    -> Pulling (only on device, creating locally)"
            }
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            Device-PullFolder -Transport $Transport -Segments ($SAVES_SEGMENTS + @($name)) -LocalDest $localDir | Out-Null
            $synced++
        }
    }

    Write-Host ""
    Write-Success "Save sync complete. $synced save(s) synced."
}

function Backup-LocalSave {
    param([string]$Name)
    $localDir = Join-Path $SAVES_DIR $Name
    if (-not (Test-Path $localDir)) { return }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $bakDir = Join-Path $SAVES_BAK_DIR "$timestamp\$Name"
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
    Copy-Item -Path "$localDir\*" -Destination $bakDir -Recurse -Force
    Write-Dim "    Backed up to: saves.bak/$timestamp/$Name/"

    # Prune old backups (keep 5 most recent)
    $allBackups = Get-ChildItem $SAVES_BAK_DIR -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($allBackups.Count -gt 5) {
        $toRemove = $allBackups | Select-Object -Skip 5
        foreach ($old in $toRemove) {
            Remove-Item $old.FullName -Recurse -Force
        }
    }
}

# --- Mod Sync (push missing) ---

function Invoke-ModSync {
    param($Transport)
    Write-Header "Mod Sync"

    if (-not (Test-Path $MODS_DIR) -or (Get-ChildItem $MODS_DIR -Directory -ErrorAction SilentlyContinue | Measure-Object).Count -eq 0) {
        Write-Warn "No local mods. Run 'pull-mods' first to populate sync/mods/."
        return
    }

    $deviceMods = Device-ListDir -Transport $Transport -Segments $MODS_SEGMENTS
    $deviceModNames = $deviceMods | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }

    $pushed = 0
    foreach ($localMod in Get-ChildItem $MODS_DIR -Directory) {
        if ($localMod.Name -in $deviceModNames) {
            Write-Dim "  $($localMod.Name) - already on device"
        }
        else {
            Write-Host "  $($localMod.Name) - MISSING on device, pushing..."
            if (-not $script:DryRun) {
                Device-PushFolder -Transport $Transport -Segments ($MODS_SEGMENTS + @($localMod.Name)) -LocalDir $localMod.FullName | Out-Null
            }
            $pushed++
        }
    }

    # Report device-only mods
    $localModNames = Get-ChildItem $MODS_DIR -Directory | ForEach-Object { $_.Name }
    foreach ($dm in $deviceModNames) {
        if ($dm -notin $localModNames) {
            Write-Warn "  $dm - on device only (run 'pull-mods' to sync locally)"
        }
    }

    if ($pushed -eq 0) {
        Write-Success "All local mods are on device."
    } else {
        Write-Success "Pushed $pushed new mod(s) to device."
    }
}

# --- Config Sync ---

function Invoke-ConfigSync {
    param($Transport)
    Write-Header "Config Sync"

    Ensure-SyncDirs

    # Get configs from both sides and sync newer
    $deviceMods = Device-ListDir -Transport $Transport -Segments $MODS_SEGMENTS
    $synced = 0

    foreach ($mod in $deviceMods) {
        if (-not $mod.IsFolder) { continue }
        $modSegments = $MODS_SEGMENTS + @($mod.Name)
        $modFiles = Device-ListDir -Transport $Transport -Segments $modSegments
        $hasConfig = $false
        foreach ($f in $modFiles) {
            if ($f.Name -eq "config.json") { $hasConfig = $true; break }
        }
        if (-not $hasConfig) { continue }

        $localConfig = Join-Path $CONFIGS_DIR "$($mod.Name)\config.json"
        $localExists = Test-Path $localConfig

        if ($localExists) {
            $localDate = (Get-Item $localConfig).LastWriteTime
            $deviceDate = Device-GetFileDate -Transport $Transport -Segments $modSegments -Name "config.json"

            if ($deviceDate -and $localDate) {
                $diff = ($deviceDate - $localDate).TotalSeconds
                if ([Math]::Abs($diff) -lt 60) {
                    continue  # Same
                }
                elseif ($diff -gt 0) {
                    Write-Host "  $($mod.Name)/config.json - device newer, pulling"
                    Device-PullFile -Transport $Transport -Segments $modSegments -Name "config.json" -LocalDest $localConfig | Out-Null
                    $synced++
                }
                else {
                    Write-Host "  $($mod.Name)/config.json - local newer, pushing"
                    Device-PushFile -Transport $Transport -Segments $modSegments -LocalPath $localConfig | Out-Null
                    $synced++
                }
            }
        }
        else {
            Write-Host "  $($mod.Name)/config.json - pulling from device"
            $configDir = Join-Path $CONFIGS_DIR $mod.Name
            Device-PullFile -Transport $Transport -Segments $modSegments -Name "config.json" -LocalDest (Join-Path $configDir "config.json") | Out-Null
            $synced++
        }
    }

    if ($synced -eq 0) {
        Write-Success "All configs in sync."
    } else {
        Write-Success "$synced config(s) synced."
    }
}

# --- Check Updates (SMAPI API) ---

function Get-LocalModManifests {
    <#
    .SYNOPSIS
    Scan sync/mods/ for all manifest.json files and extract mod info.
    Handles nested sub-mods (like SVE with multiple sub-folders).
    Handles JSON with comments (GMCM, StardewUI) and bracket paths ([CP], [FTM]).
    #>
    $manifests = @()
    if (-not (Test-Path $MODS_DIR)) { return $manifests }

    $manifestFiles = Get-ChildItem $MODS_DIR -Filter "manifest.json" -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $manifestFiles) {
        try {
            # Use -LiteralPath for paths with brackets like [CP], [FTM]
            $raw = Get-Content -LiteralPath $file.FullName -Raw
            # Strip C-style block comments (/* ... */) for mods that use them (GMCM, StardewUI)
            $raw = [regex]::Replace($raw, '/\*[\s\S]*?\*/', '')
            # Strip line comments (// ...) but NOT inside strings (avoid breaking URLs like https://)
            $raw = [regex]::Replace($raw, '(?m)^\s*//[^\n]*', '')
            $m = $raw | ConvertFrom-Json
            # Force UpdateKeys to always be an array (PS collapses single-element arrays)
            $uk = @()
            if ($m.UpdateKeys) {
                if ($m.UpdateKeys -is [string]) { $uk = @($m.UpdateKeys) }
                else { $uk = [string[]]@($m.UpdateKeys) }
            }
            $manifests += @{
                Name       = $m.Name
                UniqueID   = $m.UniqueID
                Version    = [string]$m.Version
                UpdateKeys = $uk
                Path       = $file.DirectoryName
                RelPath    = $file.DirectoryName.Substring($MODS_DIR.Length + 1)
            }
        } catch { }
    }
    return $manifests
}

function Invoke-CheckUpdates {
    Write-Header "Check for Mod Updates"

    $manifests = Get-LocalModManifests
    if ($manifests.Count -eq 0) {
        Write-Warn "No mods found in sync/mods/. Run 'pull-mods' first."
        return @()
    }

    # Build SMAPI API request — skip mods with no update keys (user's own mods)
    $modsToCheck = $manifests | Where-Object { $_.UpdateKeys.Count -gt 0 }
    if ($modsToCheck.Count -eq 0) {
        Write-Host "No mods with update keys to check."
        return @()
    }

    Write-Host "Checking $($modsToCheck.Count) mods against SMAPI API..."

    # Build JSON body manually to ensure updateKeys stays an array
    # (ConvertTo-Json collapses single-element arrays to strings)
    $modEntries = @()
    foreach ($m in $modsToCheck) {
        $ukJson = ($m.UpdateKeys | ForEach-Object { "`"$_`"" }) -join ","
        $modEntries += "{`"id`":`"$($m.UniqueID)`",`"updateKeys`":[$ukJson],`"installedVersion`":`"$($m.Version)`",`"isBroken`":false}"
    }
    $body = "{`"mods`":[" + ($modEntries -join ",") + "],`"includeExtendedMetadata`":true}"

    try {
        $response = Invoke-RestMethod -Uri "https://smapi.io/api/v4.0.0/mods" -Method Post -Body $body -ContentType "application/json"
    }
    catch {
        Write-Err "Failed to query SMAPI API: $_"
        return @()
    }

    # Build results table
    $updates = @()
    $maxNameLen = 10
    foreach ($mod in $modsToCheck) {
        if ($mod.Name.Length -gt $maxNameLen) { $maxNameLen = $mod.Name.Length }
    }

    $header = "{0,-$($maxNameLen + 2)} {1,-12} {2,-12} {3}" -f "Mod Name", "Installed", "Latest", "Status"
    Write-Host ""
    Write-Host $header -ForegroundColor White
    Write-Host ("-" * $header.Length) -ForegroundColor DarkGray

    foreach ($result in $response) {
        $mod = $modsToCheck | Where-Object { $_.UniqueID -eq $result.id } | Select-Object -First 1
        if (-not $mod) { continue }

        $installed = $mod.Version
        $latest = $installed
        $status = "Up to date"
        $color = "DarkGray"

        # Check for suggested update
        if ($result.suggestedUpdate) {
            $latest = $result.suggestedUpdate.version
            $status = "UPDATE AVAILABLE"
            $color = "Yellow"
            $updates += @{
                Mod     = $mod
                Latest  = $latest
                NexusId = $null
            }

            # Extract Nexus ID from metadata
            if ($result.metadata -and $result.metadata.nexusID) {
                $updates[-1].NexusId = $result.metadata.nexusID
            }
            elseif ($mod.UpdateKeys | Where-Object { $_ -match "^Nexus:(\d+)" }) {
                $updates[-1].NexusId = $Matches[1]
            }
        }

        $line = "{0,-$($maxNameLen + 2)} {1,-12} {2,-12} {3}" -f $mod.Name, $installed, $latest, $status
        Write-Host $line -ForegroundColor $color
    }

    # Show skipped mods
    $skipped = $manifests | Where-Object { $_.UpdateKeys.Count -eq 0 }
    if ($skipped.Count -gt 0) {
        Write-Host ""
        Write-Dim "Skipped (no update keys): $(($skipped | ForEach-Object { $_.Name }) -join ', ')"
    }

    Write-Host ""
    if ($updates.Count -gt 0) {
        Write-Warn "$($updates.Count) update(s) available."
    } else {
        Write-Success "All mods are up to date."
    }

    return $updates
}

# --- Mod Download ---

function Invoke-Update {
    param($Transport, [string]$ModName)
    Write-Header "Update Mods"

    $updates = Invoke-CheckUpdates

    if ($updates.Count -eq 0) {
        return
    }

    # Filter to specific mod if requested
    if ($ModName) {
        $updates = $updates | Where-Object { $_.Mod.Name -like "*$ModName*" }
        if ($updates.Count -eq 0) {
            Write-Warn "No updates found matching '$ModName'"
            return
        }
    }

    foreach ($update in $updates) {
        $mod = $update.Mod
        $nexusId = $update.NexusId

        Write-Host ""
        Write-Host "Updating $($mod.Name) ($($mod.Version) -> $($update.Latest))..."

        $downloaded = $false

        # Tier 1: Try Nexus API (requires API key)
        if ($nexusId -and -not $downloaded) {
            $apiKeyFile = Join-Path $env:USERPROFILE ".nexus_api_key"
            if (Test-Path $apiKeyFile) {
                $apiKey = (Get-Content $apiKeyFile -Raw).Trim()
                $downloaded = Download-FromNexus -NexusId $nexusId -ApiKey $apiKey -ModName $mod.Name
            }
        }

        # Tier 2: Try GitHub
        if (-not $downloaded) {
            $ghKey = $mod.UpdateKeys | Where-Object { $_ -match "^GitHub:" } | Select-Object -First 1
            if ($ghKey -and $ghKey -match "^GitHub:(.+)$") {
                $repo = $Matches[1]
                $downloaded = Download-FromGitHub -Repo $repo -ModName $mod.Name
            }
        }

        # Tier 3: Browser fallback
        if (-not $downloaded -and $nexusId) {
            Write-Host "  Opening Nexus Mods in browser..."
            Start-Process "https://www.nexusmods.com/stardewvalley/mods/$nexusId`?tab=files"
            Write-Host "  Download the latest file and save to: $DOWNLOADS_DIR"
            Read-Host "  Press Enter when done"

            # Look for downloaded zip
            $zips = Get-ChildItem $DOWNLOADS_DIR -Filter "*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($zips.Count -gt 0) {
                $downloaded = Install-ModFromZip -ZipPath $zips[0].FullName -ModName $mod.Name -ModDir $mod.Path
            }
        }

        if ($downloaded) {
            Write-Success "  Updated $($mod.Name)!"

            # Push to device if connected
            if ($Transport) {
                Write-Host "  Pushing to device..."
                Device-PushFolder -Transport $Transport -Segments ($MODS_SEGMENTS + @((Split-Path $mod.Path -Leaf))) -LocalDir $mod.Path | Out-Null
            }
        }
        else {
            Write-Err "  Could not download update for $($mod.Name)"
        }
    }
}

function Download-FromNexus {
    param([string]$NexusId, [string]$ApiKey, [string]$ModName)

    try {
        $headers = @{ "apikey" = $ApiKey }
        $filesUrl = "https://api.nexusmods.com/v1/games/stardewvalley/mods/$NexusId/files.json"
        $response = Invoke-RestMethod -Uri $filesUrl -Headers $headers

        # Find latest main file
        $mainFile = $response.files | Where-Object { $_.category_name -eq "MAIN" } | Sort-Object uploaded_timestamp -Descending | Select-Object -First 1
        if (-not $mainFile) {
            $mainFile = $response.files | Sort-Object uploaded_timestamp -Descending | Select-Object -First 1
        }
        if (-not $mainFile) { return $false }

        Write-Host "  Found: $($mainFile.file_name)"

        # Try download link (Premium only)
        try {
            $dlUrl = "https://api.nexusmods.com/v1/games/stardewvalley/mods/$NexusId/files/$($mainFile.file_id)/download_link.json"
            $dlResponse = Invoke-RestMethod -Uri $dlUrl -Headers $headers
            $url = $dlResponse[0].URI

            Ensure-SyncDirs
            $destFile = Join-Path $DOWNLOADS_DIR $mainFile.file_name
            Write-Host "  Downloading..."
            Invoke-WebRequest -Uri $url -OutFile $destFile
            return Install-ModFromZip -ZipPath $destFile -ModName $ModName
        }
        catch {
            Write-Dim "  Download link not available (Premium-only feature)"
            return $false
        }
    }
    catch {
        Write-Dim "  Nexus API failed: $_"
        return $false
    }
}

function Download-FromGitHub {
    param([string]$Repo, [string]$ModName)

    try {
        Ensure-SyncDirs
        $destDir = Join-Path $DOWNLOADS_DIR "gh-$($ModName -replace '\s','_')"
        if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null

        Write-Host "  Downloading from GitHub: $Repo..."
        & gh release download --repo $Repo --dir $destDir --pattern "*.zip" 2>&1

        $zips = Get-ChildItem $destDir -Filter "*.zip" -ErrorAction SilentlyContinue
        if ($zips.Count -gt 0) {
            return Install-ModFromZip -ZipPath $zips[0].FullName -ModName $ModName
        }
        return $false
    }
    catch {
        Write-Dim "  GitHub download failed: $_"
        return $false
    }
}

function Install-ModFromZip {
    param([string]$ZipPath, [string]$ModName, [string]$ModDir = $null)

    Ensure-SyncDirs
    $extractDir = Join-Path $DOWNLOADS_DIR "extract_$([guid]::NewGuid().ToString('N').Substring(0,8))"

    try {
        Write-Host "  Extracting: $(Split-Path $ZipPath -Leaf)"
        Expand-Archive -Path $ZipPath -DestinationPath $extractDir -Force

        # Find the manifest.json to locate the mod root
        $manifestFile = Get-ChildItem $extractDir -Filter "manifest.json" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $manifestFile) {
            Write-Err "  No manifest.json found in zip"
            return $false
        }

        $modRoot = $manifestFile.DirectoryName
        $manifest = Get-Content $manifestFile.FullName -Raw | ConvertFrom-Json
        Write-Host "  Found: $($manifest.Name) v$($manifest.Version)"

        # Determine target directory
        if (-not $ModDir) {
            $ModDir = Join-Path $MODS_DIR (Split-Path $modRoot -Leaf)
        }

        # Preserve config.json if it exists
        $configBackup = $null
        $existingConfig = Join-Path $ModDir "config.json"
        if (Test-Path $existingConfig) {
            $configBackup = Get-Content $existingConfig -Raw
        }

        # Replace mod folder
        if (Test-Path $ModDir) { Remove-Item $ModDir -Recurse -Force }
        Copy-Item $modRoot -Destination $ModDir -Recurse -Force

        # Restore config
        if ($configBackup) {
            Set-Content (Join-Path $ModDir "config.json") $configBackup -Encoding UTF8
            Write-Dim "  Preserved existing config.json"
        }

        return $true
    }
    catch {
        Write-Err "  Extract failed: $_"
        return $false
    }
    finally {
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- APK Management ---

function Invoke-ApkStatus {
    param($Transport)
    Write-Header "APK Status"

    if (-not $Transport.CanAdbShell) {
        Write-Err "APK status check requires ADB shell access."
        return
    }

    # Check installed packages
    $packages = & $ADB shell pm list packages 2>&1 | Out-String

    Write-Host "  Stardew Valley ($SDV_PACKAGE):"
    if ($packages -match $SDV_PACKAGE) {
        $versionInfo = & $ADB shell dumpsys package $SDV_PACKAGE 2>&1 | Select-String "versionName" | Select-Object -First 1
        $ver = if ($versionInfo -match 'versionName=(\S+)') { $Matches[1] } else { "installed" }
        Write-Success "    Installed (v$ver)"
    } else {
        Write-Err "    NOT INSTALLED"
    }

    Write-Host "  SMAPI Launcher ($PACKAGE):"
    if ($packages -match [regex]::Escape($PACKAGE)) {
        $versionInfo = & $ADB shell dumpsys package $PACKAGE 2>&1 | Select-String "versionName" | Select-Object -First 1
        $ver = if ($versionInfo -match 'versionName=(\S+)') { $Matches[1] } else { "installed" }
        Write-Success "    Installed (v$ver)"
    } else {
        Write-Err "    NOT INSTALLED"
    }

    # Check local APK cache
    Write-Host ""
    Write-Host "  Local APK cache ($APKS_DIR):"
    if (Test-Path $APKS_DIR) {
        $sdvDir = Join-Path $APKS_DIR "stardew-valley"
        $smapiDir = Join-Path $APKS_DIR "smapi-launcher"
        if (Test-Path $sdvDir) {
            $count = (Get-ChildItem $sdvDir -Filter "*.apk" -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Host "    stardew-valley: $count APK(s)"
        } else {
            Write-Host "    stardew-valley: (not cached)"
        }
        if (Test-Path $smapiDir) {
            $count = (Get-ChildItem $smapiDir -Filter "*.apk" -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Host "    smapi-launcher: $count APK(s)"
        } else {
            Write-Host "    smapi-launcher: (not cached)"
        }
    } else {
        Write-Host "    (no cache directory)"
    }
}

function Invoke-ApkPull {
    param($Transport)
    Write-Header "Pull APKs"

    if (-not $Transport.CanAdbShell) {
        Write-Err "APK pull requires ADB shell access."
        return
    }

    Ensure-SyncDirs

    # Pull SDV APKs (split APK)
    Write-Host "Pulling Stardew Valley APKs..."
    $sdvDir = Join-Path $APKS_DIR "stardew-valley"
    if (-not (Test-Path $sdvDir)) { New-Item -ItemType Directory -Path $sdvDir -Force | Out-Null }

    $ErrorActionPreference = "SilentlyContinue"
    $sdvPaths = & $ADB shell pm path $SDV_PACKAGE 2>&1
    $ErrorActionPreference = "Stop"
    foreach ($line in $sdvPaths) {
        $line = ($line -replace "`r","").Trim()
        if ($line -match "^package:(.+)$") {
            $apkPath = $Matches[1]
            $apkName = [System.IO.Path]::GetFileName($apkPath)
            Write-Host "  Pulling: $apkName"
            if (-not $script:DryRun) {
                $ErrorActionPreference = "SilentlyContinue"
                & $ADB pull "$apkPath" (Join-Path $sdvDir $apkName) 2>&1 | Out-Null
                $ErrorActionPreference = "Stop"
            }
        }
    }

    # Pull SMAPI Launcher APK
    Write-Host "Pulling SMAPI Launcher APK..."
    $smapiDir = Join-Path $APKS_DIR "smapi-launcher"
    if (-not (Test-Path $smapiDir)) { New-Item -ItemType Directory -Path $smapiDir -Force | Out-Null }

    $ErrorActionPreference = "SilentlyContinue"
    $smapiPaths = & $ADB shell pm path $PACKAGE 2>&1
    $ErrorActionPreference = "Stop"
    foreach ($line in $smapiPaths) {
        $line = ($line -replace "`r","").Trim()
        if ($line -match "^package:(.+)$") {
            $apkPath = $Matches[1]
            $apkName = [System.IO.Path]::GetFileName($apkPath)
            Write-Host "  Pulling: $apkName"
            if (-not $script:DryRun) {
                $ErrorActionPreference = "SilentlyContinue"
                & $ADB pull "$apkPath" (Join-Path $smapiDir $apkName) 2>&1 | Out-Null
                $ErrorActionPreference = "Stop"
            }
        }
    }

    Write-Success "APKs cached to: $APKS_DIR"
}

function Invoke-ApkInstall {
    param($Transport)
    Write-Header "Install APKs"

    if (-not $Transport.CanAdbShell) {
        Write-Err "APK install requires ADB shell access."
        return
    }

    $packages = & $ADB shell pm list packages 2>&1 | Out-String

    # Install SDV if missing
    $sdvDir = Join-Path $APKS_DIR "stardew-valley"
    if ($packages -notmatch $SDV_PACKAGE) {
        if (-not (Test-Path $sdvDir)) {
            Write-Err "SDV not installed and no cached APKs. Run 'apk-pull' from a device that has it."
            return
        }
        $apks = Get-ChildItem $sdvDir -Filter "*.apk" | ForEach-Object { $_.FullName }
        if ($apks.Count -gt 1) {
            Write-Host "Installing Stardew Valley (split APK, $($apks.Count) parts)..."
            if (-not $script:DryRun) {
                & $ADB install-multiple @apks 2>&1
            }
        } elseif ($apks.Count -eq 1) {
            Write-Host "Installing Stardew Valley..."
            if (-not $script:DryRun) {
                & $ADB install $apks[0] 2>&1
            }
        }
    } else {
        Write-Dim "Stardew Valley already installed."
    }

    # Install SMAPI Launcher if missing
    $smapiDir = Join-Path $APKS_DIR "smapi-launcher"
    if ($packages -notmatch [regex]::Escape($PACKAGE)) {
        if (-not (Test-Path $smapiDir)) {
            Write-Err "SMAPI Launcher not installed and no cached APKs. Run 'apk-pull' from a device that has it."
            return
        }
        $apk = Get-ChildItem $smapiDir -Filter "*.apk" | Select-Object -First 1
        if ($apk) {
            Write-Host "Installing SMAPI Launcher..."
            if (-not $script:DryRun) {
                & $ADB install $apk.FullName 2>&1
            }
        }
    } else {
        Write-Dim "SMAPI Launcher already installed."
    }

    Write-Success "APK installation complete."
}

function Invoke-SmapiInstall {
    param($Transport)
    Write-Header "SMAPI Installer"

    if (-not $Transport.CanAdbShell) {
        Write-Err "SMAPI install requires ADB shell access."
        return
    }

    $smapiInstallDir = Join-Path $APKS_DIR "smapi-install"
    $zips = Get-ChildItem $smapiInstallDir -Filter "*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

    if ($zips.Count -eq 0) {
        Write-Err "No SMAPI installer zip found in: $smapiInstallDir"
        Write-Host "Download the SMAPI Android installer zip and place it there."
        return
    }

    $zip = $zips[0]
    Write-Host "Pushing: $($zip.Name) to device /storage/emulated/0/Download/..."

    if (-not $script:DryRun) {
        if ($Transport.CanAdbShell) {
            $output = & $ADB push $zip.FullName "/storage/emulated/0/Download/$($zip.Name)" 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Err "ADB push failed: $output" }
        }
        elseif ($Transport.MtpDevice) {
            $dlFolder = Navigate-MtpPath -StartFolder $Transport.MtpStorage.GetFolder -Segments @("Download")
            if ($dlFolder) {
                Copy-FileToMtp -MtpFolder $dlFolder -LocalPath $zip.FullName
            }
        }

        # Launch SMAPI app
        & $ADB shell monkey -p $PACKAGE -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
    }

    Write-Host ""
    Write-Warn "Tap 'Install' in the SMAPI Launcher to complete installation."
    Read-Host "Press Enter when done"

    Write-Success "SMAPI install complete."
}

# --- Bootstrap ---

function Invoke-Bootstrap {
    param($Transport)

    # Bootstrap only needed when we have ADB shell but no file access
    if (-not $Transport.CanAdbShell) { return $false }
    if ($Transport.CanAdbFiles) { return $false }
    # MTP transport with file access means game root exists
    if ($Transport.MtpDevice -and $Transport.MtpStorage) { return $false }

    Write-Header "Bootstrap SMAPI"

    # Check what's installed on device
    $packages = & $ADB shell pm list packages 2>&1 | Out-String
    $hasSdv = $packages -match [regex]::Escape($SDV_PACKAGE)
    $hasSmapi = $packages -match [regex]::Escape($PACKAGE)

    if ($hasSmapi) {
        # SMAPI installed but data dir doesn't exist -- launch game to create it
        Write-Host "SMAPI is installed but game data directory not found."
        Write-Host "Launching game to initialize data directory..."

        if ($script:DryRun) {
            Write-Dim "[DryRun] Would launch game and wait for data directory creation."
            return $false
        }

        Start-Game -Transport $Transport

        $timeout = 60
        $elapsed = 0
        Write-Host "Waiting up to ${timeout}s for data directory..."
        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds 3
            $elapsed += 3
            try {
                $lsResult = & $ADB shell "ls $ADB_GAME_ROOT/ 2>/dev/null" 2>&1
                $lsStr = ($lsResult | Out-String).Trim()
                if ($lsStr -and $lsStr -notmatch "Permission denied|No such file") {
                    Write-Success "Data directory created after ${elapsed}s."
                    Stop-Game -Transport $Transport
                    return $true
                }
            } catch { }
            Write-Host "  ... ${elapsed}s"
        }

        Write-Err "Timed out waiting for data directory."
        Stop-Game -Transport $Transport
        return $false
    }

    # SMAPI not installed -- check cached APKs
    $sdvDir = Join-Path $APKS_DIR "stardew-valley"
    $smapiLauncherDir = Join-Path $APKS_DIR "smapi-launcher"
    $smapiInstallDir = Join-Path $APKS_DIR "smapi-install"

    $missing = @()
    if (-not $hasSdv) {
        if (-not (Test-Path $sdvDir) -or (Get-ChildItem $sdvDir -Filter "*.apk" -ErrorAction SilentlyContinue).Count -eq 0) {
            $missing += "Stardew Valley APK(s) in: $sdvDir"
        }
    }
    if (-not (Test-Path $smapiLauncherDir) -or (Get-ChildItem $smapiLauncherDir -Filter "*.apk" -ErrorAction SilentlyContinue).Count -eq 0) {
        $missing += "SMAPI Launcher APK in: $smapiLauncherDir"
    }
    if (-not (Test-Path $smapiInstallDir) -or (Get-ChildItem $smapiInstallDir -Filter "*.zip" -ErrorAction SilentlyContinue).Count -eq 0) {
        $missing += "SMAPI installer zip in: $smapiInstallDir"
    }

    if ($missing.Count -gt 0) {
        Write-Err "Cannot bootstrap -- missing required files:"
        foreach ($m in $missing) {
            Write-Host "  - $m"
        }
        Write-Host ""
        Write-Host "Pull these from an existing device with 'apk-pull', or download manually."
        return $false
    }

    # All files present -- confirm with user
    if (-not $script:ForceMode) {
        Write-Warn "SMAPI is not installed on this device."
        $choice = Read-Host "Bootstrap full SMAPI installation now? [Y/n]"
        if ($choice -eq "n") { return $false }
    }

    if ($script:DryRun) {
        Write-Dim "[DryRun] Would install SDV + SMAPI Launcher, push SMAPI installer, and launch game."
        return $false
    }

    # 1. Install SDV if needed
    if (-not $hasSdv) {
        $apks = Get-ChildItem $sdvDir -Filter "*.apk" | ForEach-Object { $_.FullName }
        if ($apks.Count -gt 1) {
            Write-Host "Installing Stardew Valley (split APK, $($apks.Count) parts)..."
            try { & $ADB install-multiple @apks 2>&1 } catch { }
        } elseif ($apks.Count -eq 1) {
            Write-Host "Installing Stardew Valley..."
            try { & $ADB install $apks[0] 2>&1 } catch { }
        }
    } else {
        Write-Dim "Stardew Valley already installed."
    }

    # 2. Install SMAPI Launcher
    $apk = Get-ChildItem $smapiLauncherDir -Filter "*.apk" | Select-Object -First 1
    Write-Host "Installing SMAPI Launcher..."
    try { & $ADB install $apk.FullName 2>&1 } catch { }

    # 3. Push SMAPI installer zip to Download
    $zip = Get-ChildItem $smapiInstallDir -Filter "*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host "Pushing $($zip.Name) to /storage/emulated/0/Download/..."
    $output = & $ADB push $zip.FullName "/storage/emulated/0/Download/$($zip.Name)" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Err "ADB push failed: $output" }

    # 4. Launch SMAPI Launcher for user to tap Install
    Write-Host "Launching SMAPI Launcher..."
    try { & $ADB shell monkey -p $PACKAGE -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null } catch { }

    Write-Host ""
    Write-Warn "Tap 'Install' in the SMAPI Launcher to complete SMAPI installation."
    Read-Host "Press Enter when done"

    # 5. Launch game to create data directory
    Write-Host "Launching game to initialize data directory..."
    Start-Game -Transport $Transport

    $timeout = 60
    $elapsed = 0
    Write-Host "Waiting up to ${timeout}s for data directory..."
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        try {
            $lsResult = & $ADB shell "ls $ADB_GAME_ROOT/ 2>/dev/null" 2>&1
            $lsStr = ($lsResult | Out-String).Trim()
            if ($lsStr -and $lsStr -notmatch "Permission denied|No such file") {
                Write-Success "Data directory created after ${elapsed}s."
                Stop-Game -Transport $Transport
                return $true
            }
        } catch { }
        Write-Host "  ... ${elapsed}s"
    }

    Write-Err "Timed out waiting for data directory."
    Stop-Game -Transport $Transport
    return $false
}

# --- Full Sync ---

function Invoke-FullSync {
    param($Transport)

    Write-Header "Full Sync"

    # 1. APK status
    if ($Transport.CanAdbShell) {
        Invoke-ApkStatus -Transport $Transport
    }

    # 2. Check for mod updates
    $updates = Invoke-CheckUpdates
    if ($updates.Count -gt 0 -and -not $script:DryRun) {
        if ($script:ForceMode) {
            Invoke-Update -Transport $Transport
        } else {
            $choice = Read-Host "Download updates? [y/N]"
            if ($choice -eq "y") {
                Invoke-Update -Transport $Transport
            }
        }
    }

    # 3. Bidirectional save sync
    Invoke-SaveSync -Transport $Transport

    # 4. Push missing mods
    Invoke-ModSync -Transport $Transport

    # 5. Config sync
    Invoke-ConfigSync -Transport $Transport

    # Record timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  SYNC with $($Transport.DeviceName) ($($Transport.Type))" | Add-Content $TIMESTAMP_FILE -Encoding UTF8

    Write-Host ""
    Write-Success "Full sync complete!"
}

# =============================================================================
# Help
# =============================================================================

function Show-Help {
    Write-Host "Unified Device Sync Tool" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\sync.ps1 <command> [options]"
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor White
    Write-Host "  sync            Full sync (default): updates + saves + mods + configs"
    Write-Host "  status          Show device + local state"
    Write-Host "  check-updates   Query SMAPI API for mod updates"
    Write-Host "  update [name]   Download + install mod update(s)"
    Write-Host "  saves           Bidirectional save sync with backup"
    Write-Host "  pull-saves      Force pull saves from device"
    Write-Host "  push-saves      Force push saves to device"
    Write-Host "  mods            Sync mods (push missing local mods to device)"
    Write-Host "  pull-mods       Pull all mods from device"
    Write-Host "  push-mods       Push all mods to device"
    Write-Host "  configs         Sync configs (newer wins)"
    Write-Host "  pull-configs    Pull all configs from device"
    Write-Host "  push-configs    Push all configs to device"
    Write-Host "  deploy          Deploy AndroidConsolizer DLL + manifest, launch game"
    Write-Host "  logs            Pull SMAPI-latest.txt to build output"
    Write-Host "  launch          Force-stop + relaunch game"
    Write-Host "  apk-status      Check SDV + SMAPI installed on device"
    Write-Host "  apk-pull        Pull APKs from device to local cache"
    Write-Host "  apk-install     Install cached APKs to device"
    Write-Host "  smapi-install   Push SMAPI installer zip + launch app"
    Write-Host ""
    Write-Host "Flags:" -ForegroundColor White
    Write-Host "  --force         Skip confirmations"
    Write-Host "  --dry-run       Show what would happen without doing it"
}

# =============================================================================
# Main
# =============================================================================

# Load device profiles
Load-DeviceProfiles

# Early-out commands that don't need a device
if ($Help -or $Command -in @("--help", "-h", "help")) {
    Show-Help
    exit 0
}

if ($Command -eq "check-updates") {
    Ensure-SyncDirs
    Invoke-CheckUpdates | Out-Null
    exit 0
}

# Detect transport
$transport = Detect-Transport

if (-not $transport -and $Command -ne "status") {
    Write-Err "No device connected."
    Write-Host "Connect a device via USB and ensure File Transfer mode is enabled."
    Write-Host "Run '.\sync.ps1 status' for more info."
    exit 1
}

# Update device profile
if ($transport) {
    Update-DeviceProfile -Transport $transport
}

# Ensure sync dirs exist
Ensure-SyncDirs

# Bootstrap SMAPI if needed (skip for commands that don't need file access)
$bootstrapSkip = @("status", "apk-status", "apk-pull", "apk-install", "smapi-install", "help")
if ($transport -and $transport.CanAdbShell -and $Command.ToLower() -notin $bootstrapSkip) {
    $bootstrapped = Invoke-Bootstrap -Transport $transport
    if ($bootstrapped) {
        Write-Host ""
        Write-Dim "Re-detecting transport after bootstrap..."
        $transport = Detect-Transport
        Update-DeviceProfile -Transport $transport
    }
}

# Route command
switch ($Command.ToLower()) {
    "sync"          { Invoke-FullSync -Transport $transport }
    "status"        { Invoke-Status -Transport $transport }
    "check-updates" { Invoke-CheckUpdates | Out-Null }
    "update"        { Invoke-Update -Transport $transport -ModName $Arg1 }
    "saves"         { Invoke-SaveSync -Transport $transport }
    "pull-saves"    { Invoke-PullSaves -Transport $transport }
    "push-saves"    { Invoke-PushSaves -Transport $transport }
    "mods"          { Invoke-ModSync -Transport $transport }
    "pull-mods"     { Invoke-PullMods -Transport $transport }
    "push-mods"     { Invoke-PushMods -Transport $transport }
    "configs"       { Invoke-ConfigSync -Transport $transport }
    "pull-configs"  { Invoke-PullConfigs -Transport $transport }
    "push-configs"  { Invoke-PushConfigs -Transport $transport }
    "deploy"        { Invoke-Deploy -Transport $transport }
    "logs"          { Invoke-Logs -Transport $transport }
    "launch"        { Invoke-Launch -Transport $transport }
    "apk-status"    { Invoke-ApkStatus -Transport $transport }
    "apk-pull"      { Invoke-ApkPull -Transport $transport }
    "apk-install"   { Invoke-ApkInstall -Transport $transport }
    "smapi-install" { Invoke-SmapiInstall -Transport $transport }
    default {
        Write-Err "Unknown command: $Command"
        Write-Host "Run '.\sync.ps1 --help' for usage."
        exit 1
    }
}
