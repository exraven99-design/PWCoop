# PWCoop — co-op mod for Project Wingman (source)

Unofficial fan mod. Written with AI assistance. Source of everything that ships in `PWCoop_Setup_*.zip`.

## What is in this repository
| Path | What it is |
|---|---|
| `Mods/PWCoop/Scripts/main.lua`, `ui.lua` | the mod itself: Lua scripts for UE4SS (plain text, runs inside the game) |
| `coop/steam_helper.py` | background helper: talks to Steam through the game's own `steam_api64.dll` (friends list, invites, P2P messages via Steam Networking Messages) and exchanges small text files with the Lua scripts (`Mods/PWCoop/io/`). No other network access, no admin rights. |
| `coop/installer.py` | installer: finds the game, copies UE4SS (if absent) and the mod, enables `PWCoop : 1` in `Mods/mods.txt` |
| `coop/build_installer.py` | build script (PyInstaller) that produces the zip |

UE4SS (https://github.com/UE4SS/UE4SS, v3.0.1) is bundled unmodified in the release zip (`UE4SS.dll`, `dwmapi.dll`); it is not part of this repository.

## Build steps
Requirements: Windows, Python 3.11+, `pip install pyinstaller psutil`, Project Wingman with UE4SS v3.0.1 installed (so that `UE4SS.dll`, `dwmapi.dll`, `UE4SS-settings.ini` exist in its `Win64` folder).

```
set PW_WIN64=C:\Program Files (x86)\Steam\steamapps\common\Project Wingman\ProjectWingman\Binaries\Win64
python coop/build_installer.py
```
Result: `dist_installer/PWCoop_Setup_0.2.0.zip` (the same files as the release). The helper and the installer are built with PyInstaller (`--onedir --noupx`, version info embedded).

## What data is sent
Only game state to your partner over the Steam relay while in a co-op session (aircraft position/health, shots, missiles, kill events, ready flags, nearby enemy positions from the host, Steam name). See the mod page for the full list. No servers of my own, no analytics.
