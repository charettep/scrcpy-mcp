# scrcpy MCP Server

Local MCP server that exposes scrcpy and ADB features as tools for MCP clients like Claude Code.

## Prerequisites

- Python 3.10+
- `adb` in PATH (from Android SDK platform-tools)
- `scrcpy` in PATH (for mirroring/recording sessions)
- An Android device with USB debugging enabled

## Install

```bash
cd /home/p/Desktop/scrcpy/mcp
pip install -r requirements.txt
```

Or with uv:

```bash
uv pip install -r requirements.txt
```

## Configure for Claude Code

Add to your project `.mcp.json`:

```json
{
  "mcpServers": {
    "scrcpy": {
      "command": "python3",
      "args": ["/home/p/Desktop/scrcpy/mcp/scrcpy_mcp.py"]
    }
  }
}
```

Or add to `~/.claude.json` for global access.

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

## Test

```bash
python3 scrcpy_mcp.py  # starts on stdio
```
