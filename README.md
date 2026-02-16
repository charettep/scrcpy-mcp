# scrcpy MCP Server

Local MCP server that exposes Android device control via `adb` and `scrcpy` as 22 tools for MCP clients like Claude Code and Codex CLI.

## Quick Start

One command — no prerequisites needed (the installer handles everything):

```bash
curl -fsSL https://raw.githubusercontent.com/charettep/scrcpy-mcp/main/install.sh | bash
```

Or from a local clone:

```bash
git clone https://github.com/charettep/scrcpy-mcp.git && cd scrcpy-mcp
./install.sh
```

The installer will:
1. Detect your OS and package manager (apt, dnf, pacman, brew)
2. Download the repo to `~/mcp/scrcpy-mcp` (if running via curl)
3. Check for `adb`, `scrcpy`, and `uv` — install any that are missing
4. Find Python 3.10+ and create an isolated venv with dependencies
5. Detect installed MCP clients (Claude Code, Codex CLI)
6. Ask where to register the server:
   - **Global** — injects config directly into `~/.claude.json` and/or `~/.codex/config.toml`
   - **Project** — generates a local `.mcp.json` file

Re-running the installer is safe — it updates the existing install and overwrites old config entries.

## Prerequisites

- Python 3.10+
- `adb` (from Android SDK platform-tools)
- `scrcpy` (for mirroring/recording sessions)
- An Android device with USB debugging enabled

The installer handles all of the above automatically.

## Manual Install

If you prefer not to use the installer:

```bash
uv venv .venv && uv pip install -r requirements.txt
```

Then add to your project `.mcp.json`:

```json
{
  "mcpServers": {
    "scrcpy": {
      "command": "/path/to/.venv/bin/python",
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
| `list_devices` | List connected devices with status |
| `device_info` | Get model, Android version, screen resolution, battery, IP |
| `tcpip_connect` | Connect/disconnect device via wireless ADB |

### Input Injection
| Tool | Description |
|------|-------------|
| `tap` | Tap at x,y coordinates |
| `swipe` | Swipe from point A to B with duration |
| `key_event` | Send key event (BACK, HOME, POWER, etc.) |
| `input_text` | Type text string on device |
| `long_press` | Long press at coordinates |

### Screen & Display
| Tool | Description |
|------|-------------|
| `screenshot` | Capture screenshot and save locally |
| `screen_power` | Turn screen on/off/toggle |
| `rotation` | Get/set device rotation |
| `screen_record` | Record screen to mp4 file |

### App Management
| Tool | Description |
|------|-------------|
| `list_apps` | List installed packages |
| `start_app` | Launch app by package name |
| `stop_app` | Force stop an app |
| `install_apk` | Install APK file |

### Clipboard
| Tool | Description |
|------|-------------|
| `get_clipboard` | Read device clipboard |
| `set_clipboard` | Set device clipboard text |

### File Transfer
| Tool | Description |
|------|-------------|
| `push_file` | Push local file to device |
| `pull_file` | Pull file from device |

### Scrcpy Sessions
| Tool | Description |
|------|-------------|
| `start_mirror` | Start scrcpy mirroring with full options |
| `stop_session` | Stop a running scrcpy session |

## Multi-device Support

All tools accept an optional `serial` parameter. If omitted, adb uses the only connected device (or fails if multiple are connected).

```
tap(x=500, y=1000, serial="ABCD1234")
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
