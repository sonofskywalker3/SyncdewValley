# SyncdewValley

A unified device sync tool for Stardew Valley modding on Android. Auto-detects ADB vs MTP transport, syncs saves/mods/configs/APKs between PC and Android devices running SMAPI.

Replaces the need for separate ADB scripts and MTP tools — one command handles everything regardless of which device is connected.

## Quick Start

```powershell
# See what's connected and what's synced
.\sync.ps1 status

# Pull everything from device
.\sync.ps1 pull-mods
.\sync.ps1 pull-saves
.\sync.ps1 pull-configs

# Check for mod updates
.\sync.ps1 check-updates

# Deploy your mod build and launch the game
.\sync.ps1 deploy

# Full bidirectional sync (saves + mods + configs)
.\sync.ps1
```

## Commands

| Command | Description |
|---------|-------------|
| `sync` | **Full sync** (default): check updates + bidirectional saves + push mods + sync configs |
| `status` | Show connected device, transport type, and local/device state |
| `check-updates` | Query SMAPI API for mod version updates |
| `update [name]` | Download and install mod update(s) via Nexus/GitHub |
| `saves` | Bidirectional save sync with automatic backup |
| `pull-saves` | Pull all saves from device |
| `push-saves` | Push all saves to device |
| `mods` | Push any local mods missing from device |
| `pull-mods` | Pull all mods from device |
| `push-mods` | Push all mods to device |
| `configs` | Sync configs (newer wins) |
| `pull-configs` | Pull all configs from device |
| `push-configs` | Push all configs to device |
| `deploy` | Push AndroidConsolizer DLL + manifest, restart game |
| `logs` | Pull SMAPI-latest.txt |
| `launch` | Force-stop + relaunch game |
| `apk-status` | Check if SDV + SMAPI Launcher are installed |
| `apk-pull` | Cache APKs from device (for installing on other devices) |
| `apk-install` | Install cached APKs to a new device |
| `smapi-install` | Push SMAPI installer zip + launch app |

## Flags

| Flag | Description |
|------|-------------|
| `-Force` | Skip confirmations (auto newer-wins for save sync) |
| `-DryRun` | Preview what would happen without making changes |

## Transport Auto-Detection

The tool automatically detects how to talk to the connected device:

1. **ADB with file access** — Used for devices without scoped storage restrictions (e.g., Ayaneo Pocket Air Mini). Fastest transport.
2. **MTP with ADB shell** — Used when ADB can't access `/Android/data/` due to scoped storage (e.g., Odin Pro). File transfers via Windows Shell COM, app control via ADB.
3. **MTP only** — Fallback when ADB isn't available at all.

## Data Layout

```
SyncdewValley/
  sync.ps1              # The tool
  sync/
    saves/              # Save game files
    mods/               # Mod folders with manifests
    configs/            # config.json per mod
    apks/
      stardew-valley/   # SDV split APK (3 parts)
      smapi-launcher/   # SMAPI Launcher APK
      smapi-install/    # SMAPI installer zip
    saves.bak/          # Rolling save backups (5 most recent)
    downloads/          # Temp dir for mod downloads
```

## Prerequisites

You'll need the game, SMAPI, and ADB installed before this tool is useful.

### Get the game and mods

| What | Where |
|------|-------|
| Stardew Valley | [Google Play Store](https://play.google.com/store/apps/details?id=com.chucklefish.stardewvalley) |
| SMAPI (Stardew Modding API) | [GitHub](https://github.com/Pathoschild/SMAPI) &mdash; [smapi.io](https://smapi.io/) |
| SMAPI Android Installer | [GitHub](https://github.com/ZaneYork/SMAPI-Android-Installer) |
| AndroidConsolizer (console-style controls) | [Nexus Mods](https://www.nexusmods.com/stardewvalley/mods/41869) &mdash; [GitHub](https://github.com/sonofskywalker3/AndroidConsolizer) |
| Mods in general | [Nexus Mods - Stardew Valley](https://www.nexusmods.com/stardewvalley) |

### System requirements

- Windows with PowerShell 5.1+
- [ADB (platform-tools)](https://developer.android.com/tools/releases/platform-tools) installed at `C:\Program Files\platform-tools\`
- USB connection to Android device in File Transfer mode
- For mod auto-download: Nexus API key at `~/.nexus_api_key` (optional, enables download for Premium users)

## Mod Update Checking

The `check-updates` command queries the [SMAPI mod compatibility API](https://smapi.io/) to compare your installed mod versions against the latest available. It reads `manifest.json` from each mod in `sync/mods/` and supports:

- Nexus Mods update keys
- GitHub release update keys
- Mods with JSON comments (GMCM, StardewUI)
- Nested sub-mods (SVE's `[CP]` and `[FTM]` folders)
