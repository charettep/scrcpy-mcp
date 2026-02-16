# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

scrcpy-mcp is a local MCP (Model Context Protocol) server that exposes Android device control via `adb` and `scrcpy` as 22 tools for MCP clients like Claude Code. Single-file Python server using FastMCP framework with stdio transport.

## Running

```bash
# Install dependencies (requires Python 3.10+)
pip install -r requirements.txt

# Start server (stdio transport, used by Claude Code)
python3.10 scrcpy_mcp.py

# Verify tool count
python3.10 -c "from scrcpy_mcp import mcp; print(len(mcp._tool_manager._tools))"
```

## Architecture

**Single file**: `scrcpy_mcp.py` contains everything — helpers, 22 tool functions, and entry point.

**Core pattern**: All device interaction goes through `_adb()` / `_adb_ok()` helpers which use `asyncio.create_subprocess_exec` (list-based, never shell) for safety. Every tool that touches a device accepts an optional `serial` parameter for multi-device support.

**Tool categories** (7 sections, marked with `═══` comment blocks):
1. Device Management — `adb devices`, device props, TCP/IP wireless
2. Input Injection — tap, swipe, key events, text input, long press
3. Screen & Display — screenshot (`exec-out screencap -p`), screen power, rotation, screenrecord
4. App Management — pm list, monkey launcher, am force-stop, install
5. Clipboard — am broadcast clipper.get/set with service call fallback
6. File Transfer — adb push/pull
7. Scrcpy Sessions — background `scrcpy` process management tracked in `_sessions` dict by PID

**Key conventions**:
- Tools are async functions decorated with `@mcp.tool`
- Tool names are unprefixed (e.g. `tap`, `screenshot`) — the MCP server name `scrcpy` already provides namespace
- `_adb_ok()` raises `RuntimeError` on non-zero exit — tools surface these as error messages to the client
- scrcpy sessions use SIGTERM with SIGKILL fallback after 5s timeout
- Screenshot uses `adb exec-out screencap -p` piped directly to local file (no temp file on device)
- Screen recording uses device-side `screenrecord` then `adb pull` + cleanup
