# scrcpy MCP Server

Local MCP server that exposes Android device control via `adb` and `scrcpy` as 22 tools for MCP clients like Claude Code and Codex CLI.

## Quick Start

```bash
git clone <repo-url> && cd scrcpy/mcp
./install.sh
```

The installer will:
1. Detect your OS and package manager (apt, dnf, pacman, brew)
2. Check for `adb` and `scrcpy` — offer to install if missing (prompts before sudo)
3. Find Python 3.10+ and install pip dependencies
4. Detect installed MCP clients (Claude Code, Codex CLI)
5. Ask where to register the server:
   - **Global** — injects config directly into `~/.claude.json` and/or `~/.codex/config.toml`
   - **Project** — generates a local `.mcp.json` file

## Prerequisites

- Python 3.10+
- `adb` (from Android SDK platform-tools)
- `scrcpy` (for mirroring/recording sessions)
- An Android device with USB debugging enabled

## Manual Install

If you prefer not to use the installer:

```bash
pip install -r requirements.txt
```

Then add to your project `.mcp.json`:

```json
{
  "mcpServers": {
    "scrcpy": {
      "command": "python3",
      "args": ["/absolute/path/to/scrcpy_mcp.py"],
      "env": {
        "SCRCPY_MCP_ADB_PATH": "/usr/bin/adb",
        "SCRCPY_MCP_SCRCPY_PATH": "/usr/bin/scrcpy"
      }
    }
  }
}
```

The `env` block is optional — without it, `adb` and `scrcpy` are resolved from PATH.

## Available Tools (22)

### Device Management
| Tool | Description |
|------|-------------|
| `scrcpy_list_devices` | List connected devices with status |
| `scrcpy_device_info` | Get model, Android version, screen resolution, battery, IP |
| `scrcpy_tcpip_connect` | Connect/disconnect device via wireless ADB |

### Input Injection
| Tool | Description |
|------|-------------|
| `scrcpy_tap` | Tap at x,y coordinates |
| `scrcpy_swipe` | Swipe from point A to B with duration |
| `scrcpy_key_event` | Send key event (BACK, HOME, POWER, etc.) |
| `scrcpy_input_text` | Type text string on device |
| `scrcpy_long_press` | Long press at coordinates |

### Screen & Display
| Tool | Description |
|------|-------------|
| `scrcpy_screenshot` | Capture screenshot and save locally |
| `scrcpy_screen_power` | Turn screen on/off/toggle |
| `scrcpy_rotation` | Get/set device rotation |
| `scrcpy_screen_record` | Record screen to mp4 file |

### App Management
| Tool | Description |
|------|-------------|
| `scrcpy_list_apps` | List installed packages |
| `scrcpy_start_app` | Launch app by package name |
| `scrcpy_stop_app` | Force stop an app |
| `scrcpy_install_apk` | Install APK file |

### Clipboard
| Tool | Description |
|------|-------------|
| `scrcpy_get_clipboard` | Read device clipboard |
| `scrcpy_set_clipboard` | Set device clipboard text |

### File Transfer
| Tool | Description |
|------|-------------|
| `scrcpy_push_file` | Push local file to device |
| `scrcpy_pull_file` | Pull file from device |

### Scrcpy Sessions
| Tool | Description |
|------|-------------|
| `scrcpy_start_mirror` | Start scrcpy mirroring with full options |
| `scrcpy_stop_session` | Stop a running scrcpy session |

## Multi-device Support

All tools accept an optional `serial` parameter. If omitted, adb uses the only connected device (or fails if multiple are connected).

```
scrcpy_tap(x=500, y=1000, serial="ABCD1234")
```

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `SCRCPY_MCP_ADB_PATH` | Absolute path to `adb` binary | `adb` (from PATH) |
| `SCRCPY_MCP_SCRCPY_PATH` | Absolute path to `scrcpy` binary | `scrcpy` (from PATH) |

These are set automatically by `install.sh` via the MCP config `env` block.

## Verify

```bash
python3 scrcpy_mcp.py  # starts on stdio
python3 -c "from scrcpy_mcp import mcp; print(len(mcp._tool_manager._tools))"  # should print 22
```
