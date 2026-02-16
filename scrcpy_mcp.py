#!/usr/bin/env python3.10
"""scrcpy MCP Server — Expose scrcpy and ADB features as MCP tools."""

import asyncio
import os
import shlex
import signal
import time
from pathlib import Path
from typing import Optional

from fastmcp import FastMCP

mcp = FastMCP("scrcpy")

# ── Configurable binary paths (set by install.sh via .mcp.json env block) ──
ADB = os.environ.get("SCRCPY_MCP_ADB_PATH", "adb")
SCRCPY = os.environ.get("SCRCPY_MCP_SCRCPY_PATH", "scrcpy")

# ── Active scrcpy session tracking ──────────────────────────────────────────

_sessions: dict[int, dict] = {}  # pid -> {process, serial, started, opts}


# ── Helpers ─────────────────────────────────────────────────────────────────

async def _adb(
    *args: str,
    serial: Optional[str] = None,
    timeout: float = 15.0,
) -> tuple[int, str, str]:
    """Run an adb command and return (returncode, stdout, stderr).

    Uses asyncio.create_subprocess_exec (not shell) to avoid injection.
    All arguments are passed as a list, never through a shell.
    """
    cmd = [ADB]
    if serial:
        cmd += ["-s", serial]
    cmd += list(args)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.communicate()
        return -1, "", f"adb command timed out after {timeout}s"
    return proc.returncode, stdout.decode(errors="replace"), stderr.decode(errors="replace")


async def _adb_ok(
    *args: str,
    serial: Optional[str] = None,
    timeout: float = 15.0,
) -> str:
    """Run adb, raise on failure, return stdout."""
    rc, out, err = await _adb(*args, serial=serial, timeout=timeout)
    if rc != 0:
        raise RuntimeError(f"adb {' '.join(args)} failed (rc={rc}): {err.strip()}")
    return out


def _require_serial(serial: Optional[str]) -> Optional[str]:
    """Pass-through; exists so tools document the parameter consistently."""
    return serial or None


# ═══════════════════════════════════════════════════════════════════════════
# 1. DEVICE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════

@mcp.tool
async def scrcpy_list_devices() -> str:
    """List connected Android devices with status and transport info.

    Returns the output of `adb devices -l` showing serial, state,
    and connection details for every attached device.
    """
    return await _adb_ok("devices", "-l")


@mcp.tool
async def scrcpy_device_info(serial: Optional[str] = None) -> str:
    """Get detailed device information.

    Returns model name, Android version, SDK level, screen resolution,
    battery level, and IP address.

    Args:
        serial: Device serial number (optional if only one device connected).
    """
    serial = _require_serial(serial)
    props = {
        "Model": "ro.product.model",
        "Manufacturer": "ro.product.manufacturer",
        "Android Version": "ro.build.version.release",
        "SDK Level": "ro.build.version.sdk",
        "Build": "ro.build.display.id",
    }
    lines = []
    for label, prop in props.items():
        val = (await _adb_ok("shell", "getprop", prop, serial=serial)).strip()
        lines.append(f"{label}: {val}")

    # Screen resolution
    size = (await _adb_ok("shell", "wm", "size", serial=serial)).strip()
    lines.append(f"Screen: {size}")

    # Battery level
    battery = await _adb_ok("shell", "dumpsys", "battery", serial=serial)
    for bline in battery.splitlines():
        if "level" in bline.lower():
            lines.append(f"Battery {bline.strip()}")
            break

    # IP address via ip addr (no shell piping)
    try:
        ip_out = await _adb_ok("shell", "ip", "route", serial=serial)
        for route_line in ip_out.splitlines():
            if "src" in route_line:
                parts = route_line.split("src")
                if len(parts) > 1:
                    lines.append(f"IP: {parts[1].strip().split()[0]}")
                    break
    except RuntimeError:
        pass

    return "\n".join(lines)


@mcp.tool
async def scrcpy_tcpip_connect(
    action: str = "connect",
    ip: str = "",
    port: int = 5555,
    serial: Optional[str] = None,
) -> str:
    """Connect or disconnect a device via TCP/IP (wireless ADB).

    Args:
        action: "connect", "disconnect", or "setup" (switches device to tcpip mode).
        ip: Device IP address (required for connect/disconnect).
        port: TCP port (default 5555).
        serial: Device serial (needed for "setup" action).
    """
    serial = _require_serial(serial)
    if action == "setup":
        return await _adb_ok("tcpip", str(port), serial=serial)
    elif action == "connect":
        if not ip:
            raise ValueError("ip is required for connect action")
        return await _adb_ok("connect", f"{ip}:{port}")
    elif action == "disconnect":
        target = f"{ip}:{port}" if ip else ""
        args = ["disconnect"]
        if target:
            args.append(target)
        return await _adb_ok(*args)
    else:
        raise ValueError(f"Unknown action: {action}. Use 'connect', 'disconnect', or 'setup'.")


# ═══════════════════════════════════════════════════════════════════════════
# 2. INPUT INJECTION
# ═══════════════════════════════════════════════════════════════════════════

@mcp.tool
async def scrcpy_tap(
    x: int,
    y: int,
    serial: Optional[str] = None,
) -> str:
    """Tap at screen coordinates.

    Args:
        x: X coordinate (pixels).
        y: Y coordinate (pixels).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    return await _adb_ok("shell", "input", "tap", str(x), str(y), serial=serial)


@mcp.tool
async def scrcpy_swipe(
    x1: int,
    y1: int,
    x2: int,
    y2: int,
    duration_ms: int = 300,
    serial: Optional[str] = None,
) -> str:
    """Swipe from one point to another.

    Args:
        x1: Start X coordinate.
        y1: Start Y coordinate.
        x2: End X coordinate.
        y2: End Y coordinate.
        duration_ms: Swipe duration in milliseconds (default 300).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    return await _adb_ok(
        "shell", "input", "swipe",
        str(x1), str(y1), str(x2), str(y2), str(duration_ms),
        serial=serial,
    )


@mcp.tool
async def scrcpy_key_event(
    key: str,
    serial: Optional[str] = None,
) -> str:
    """Send a key event to the device.

    Args:
        key: Key name (BACK, HOME, POWER, VOLUME_UP, VOLUME_DOWN, ENTER,
             MENU, APP_SWITCH, CAMERA, SEARCH) or numeric keycode.
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    key_map = {
        "HOME": "3", "BACK": "4", "POWER": "26", "MENU": "82",
        "VOLUME_UP": "24", "VOLUME_DOWN": "25", "ENTER": "66",
        "APP_SWITCH": "187", "CAMERA": "27", "SEARCH": "84",
        "DELETE": "67", "TAB": "61", "ESCAPE": "111",
        "DPAD_UP": "19", "DPAD_DOWN": "20", "DPAD_LEFT": "21",
        "DPAD_RIGHT": "22", "DPAD_CENTER": "23",
    }
    code = key_map.get(key.upper(), key)
    return await _adb_ok("shell", "input", "keyevent", code, serial=serial)


@mcp.tool
async def scrcpy_input_text(
    text: str,
    serial: Optional[str] = None,
) -> str:
    """Type text on the device (requires a focused text field).

    Spaces are encoded as %s for adb shell input text compatibility.

    Args:
        text: The text string to type.
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    # adb shell input text treats %s as space
    encoded = text.replace(" ", "%s")
    return await _adb_ok("shell", "input", "text", encoded, serial=serial)


@mcp.tool
async def scrcpy_long_press(
    x: int,
    y: int,
    duration_ms: int = 1000,
    serial: Optional[str] = None,
) -> str:
    """Long press at screen coordinates (swipe with zero distance).

    Args:
        x: X coordinate.
        y: Y coordinate.
        duration_ms: Hold duration in milliseconds (default 1000).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    return await _adb_ok(
        "shell", "input", "swipe",
        str(x), str(y), str(x), str(y), str(duration_ms),
        serial=serial,
    )


# ═══════════════════════════════════════════════════════════════════════════
# 3. SCREEN & DISPLAY
# ═══════════════════════════════════════════════════════════════════════════

@mcp.tool
async def scrcpy_screenshot(
    output_path: str = "",
    serial: Optional[str] = None,
) -> str:
    """Capture a screenshot and save it locally.

    Args:
        output_path: Local path to save the PNG (default: /tmp/scrcpy_screenshot_<ts>.png).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    if not output_path:
        output_path = f"/tmp/scrcpy_screenshot_{int(time.time())}.png"
    output_path = os.path.expanduser(output_path)

    cmd = [ADB]
    if serial:
        cmd += ["-s", serial]
    cmd += ["exec-out", "screencap", "-p"]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=15.0)
    if proc.returncode != 0:
        raise RuntimeError(f"screencap failed: {stderr.decode(errors='replace')}")
    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_path).write_bytes(stdout)
    return f"Screenshot saved to {output_path} ({len(stdout)} bytes)"


@mcp.tool
async def scrcpy_screen_power(
    action: str = "toggle",
    serial: Optional[str] = None,
) -> str:
    """Control the screen power state.

    Args:
        action: "on", "off", or "toggle" (sends POWER key event).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    if action == "toggle":
        return await _adb_ok("shell", "input", "keyevent", "26", serial=serial)

    # Check current screen state
    dumpsys = await _adb_ok("shell", "dumpsys", "power", serial=serial)
    is_on = "Display Power: state=ON" in dumpsys or "mScreenOn=true" in dumpsys

    if (action == "on" and not is_on) or (action == "off" and is_on):
        await _adb_ok("shell", "input", "keyevent", "26", serial=serial)
        return f"Screen turned {action}"
    return f"Screen already {action}"


@mcp.tool
async def scrcpy_rotation(
    set_to: Optional[int] = None,
    serial: Optional[str] = None,
) -> str:
    """Get or set device screen rotation.

    Args:
        set_to: Rotation value (0=natural, 1=90, 2=180, 3=270). Omit to query current.
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    if set_to is not None:
        if set_to not in (0, 1, 2, 3):
            raise ValueError("Rotation must be 0, 1, 2, or 3")
        await _adb_ok("shell", "settings", "put", "system",
                       "accelerometer_rotation", "0", serial=serial)
        await _adb_ok("shell", "settings", "put", "system",
                       "user_rotation", str(set_to), serial=serial)
        labels = {0: "0 (natural)", 1: "90", 2: "180", 3: "270"}
        return f"Rotation set to {labels[set_to]}"
    else:
        val = (await _adb_ok("shell", "settings", "get", "system",
                              "user_rotation", serial=serial)).strip()
        auto = (await _adb_ok("shell", "settings", "get", "system",
                               "accelerometer_rotation", serial=serial)).strip()
        return f"Rotation: {val} (auto-rotate: {'on' if auto == '1' else 'off'})"


@mcp.tool
async def scrcpy_screen_record(
    output_path: str = "",
    duration: int = 30,
    serial: Optional[str] = None,
) -> str:
    """Record the device screen using adb screenrecord.

    Recording runs synchronously for the specified duration.

    Args:
        output_path: Local path to save the mp4 (default: /tmp/scrcpy_record_<ts>.mp4).
        duration: Max recording duration in seconds (default 30, max 180).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    if not output_path:
        output_path = f"/tmp/scrcpy_record_{int(time.time())}.mp4"
    output_path = os.path.expanduser(output_path)

    duration = min(max(duration, 1), 180)
    remote_path = f"/sdcard/scrcpy_record_{int(time.time())}.mp4"

    cmd = [ADB]
    if serial:
        cmd += ["-s", serial]
    cmd += ["shell", "screenrecord", "--time-limit", str(duration), remote_path]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    await asyncio.wait_for(proc.communicate(), timeout=duration + 10)

    # Pull the file locally
    await _adb_ok("pull", remote_path, output_path, serial=serial)
    await _adb_ok("shell", "rm", remote_path, serial=serial)
    return f"Recording saved to {output_path} ({duration}s)"


# ═══════════════════════════════════════════════════════════════════════════
# 4. APP MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════

@mcp.tool
async def scrcpy_list_apps(
    filter: str = "",
    third_party_only: bool = True,
    serial: Optional[str] = None,
) -> str:
    """List installed packages on the device.

    Args:
        filter: Optional substring to filter package names.
        third_party_only: If True (default), only show third-party apps.
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    args = ["shell", "pm", "list", "packages"]
    if third_party_only:
        args.append("-3")
    out = await _adb_ok(*args, serial=serial)
    packages = sorted(line.replace("package:", "") for line in out.strip().splitlines() if line)
    if filter:
        packages = [p for p in packages if filter.lower() in p.lower()]
    return "\n".join(packages) if packages else "No matching packages found."


@mcp.tool
async def scrcpy_start_app(
    package: str,
    activity: str = "",
    serial: Optional[str] = None,
) -> str:
    """Launch an app by package name.

    Args:
        package: Package name (e.g. com.android.settings).
        activity: Specific activity to launch (optional; uses launcher activity by default).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    if activity:
        return await _adb_ok("shell", "am", "start", "-n",
                              f"{package}/{activity}", serial=serial)
    else:
        return await _adb_ok(
            "shell", "monkey", "-p", package,
            "-c", "android.intent.category.LAUNCHER", "1",
            serial=serial,
        )


@mcp.tool
async def scrcpy_stop_app(
    package: str,
    serial: Optional[str] = None,
) -> str:
    """Force stop an app.

    Args:
        package: Package name to stop.
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    return await _adb_ok("shell", "am", "force-stop", package, serial=serial)


@mcp.tool
async def scrcpy_install_apk(
    apk_path: str,
    serial: Optional[str] = None,
) -> str:
    """Install an APK file to the device.

    Args:
        apk_path: Local path to the APK file.
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    apk_path = os.path.expanduser(apk_path)
    if not os.path.isfile(apk_path):
        raise FileNotFoundError(f"APK not found: {apk_path}")
    return await _adb_ok("install", "-r", apk_path, serial=serial, timeout=120.0)


# ═══════════════════════════════════════════════════════════════════════════
# 5. CLIPBOARD
# ═══════════════════════════════════════════════════════════════════════════

@mcp.tool
async def scrcpy_get_clipboard(serial: Optional[str] = None) -> str:
    """Read the device clipboard content.

    Note: Requires Android 10+ or a running scrcpy session for full support.

    Args:
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    out = await _adb_ok("shell", "am", "broadcast",
                         "-a", "clipper.get", serial=serial)
    if "result=" not in out.lower():
        out = await _adb_ok("shell", "service", "call", "clipboard", "2",
                             "s16", "com.android.shell", serial=serial)
    return out.strip()


@mcp.tool
async def scrcpy_set_clipboard(
    text: str,
    serial: Optional[str] = None,
) -> str:
    """Set the device clipboard text.

    Args:
        text: Text to copy to clipboard.
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    return await _adb_ok("shell", "am", "broadcast",
                          "-a", "clipper.set", "-e", "text", text,
                          serial=serial)


# ═══════════════════════════════════════════════════════════════════════════
# 6. FILE TRANSFER
# ═══════════════════════════════════════════════════════════════════════════

@mcp.tool
async def scrcpy_push_file(
    local_path: str,
    remote_path: str,
    serial: Optional[str] = None,
) -> str:
    """Push a local file to the device.

    Args:
        local_path: Path to the local file.
        remote_path: Destination path on device (e.g. /sdcard/Download/file.txt).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    local_path = os.path.expanduser(local_path)
    if not os.path.exists(local_path):
        raise FileNotFoundError(f"Local file not found: {local_path}")
    return await _adb_ok("push", local_path, remote_path, serial=serial, timeout=120.0)


@mcp.tool
async def scrcpy_pull_file(
    remote_path: str,
    local_path: str = "",
    serial: Optional[str] = None,
) -> str:
    """Pull a file from the device to local filesystem.

    Args:
        remote_path: Path on the device (e.g. /sdcard/DCIM/photo.jpg).
        local_path: Local destination path (default: /tmp/<filename>).
        serial: Device serial (optional).
    """
    serial = _require_serial(serial)
    if not local_path:
        local_path = f"/tmp/{Path(remote_path).name}"
    local_path = os.path.expanduser(local_path)
    Path(local_path).parent.mkdir(parents=True, exist_ok=True)
    return await _adb_ok("pull", remote_path, local_path, serial=serial, timeout=120.0)


# ═══════════════════════════════════════════════════════════════════════════
# 7. SCRCPY SESSIONS
# ═══════════════════════════════════════════════════════════════════════════

@mcp.tool
async def scrcpy_start_mirror(
    serial: Optional[str] = None,
    max_size: int = 0,
    video_bit_rate: str = "8M",
    max_fps: int = 0,
    video_codec: str = "h264",
    audio: bool = True,
    audio_codec: str = "opus",
    crop: str = "",
    rotation: int = -1,
    no_video: bool = False,
    no_audio: bool = False,
    record: str = "",
    window_title: str = "",
    window_x: int = -1,
    window_y: int = -1,
    window_width: int = 0,
    window_height: int = 0,
    borderless: bool = False,
    always_on_top: bool = False,
    fullscreen: bool = False,
    stay_awake: bool = False,
    turn_screen_off: bool = False,
    no_control: bool = False,
    show_touches: bool = False,
    camera: bool = False,
    camera_id: str = "",
    camera_facing: str = "",
    camera_size: str = "",
    virtual_display: str = "",
    no_window: bool = False,
    time_limit: int = 0,
    extra_args: str = "",
) -> str:
    """Start a scrcpy mirroring/recording session with full option support.

    Args:
        serial: Device serial (optional).
        max_size: Limit both width and height to this value (0 = no limit).
        video_bit_rate: Video bitrate (default "8M").
        max_fps: Max framerate (0 = no limit).
        video_codec: Video codec: h264, h265, av1.
        audio: Enable audio forwarding (default True).
        audio_codec: Audio codec: opus, aac, flac, raw.
        crop: Crop rectangle as "W:H:X:Y" (e.g. "1080:1920:0:0").
        rotation: Lock rotation (0-3, -1 = don't lock).
        no_video: Disable video (audio only).
        no_audio: Disable audio forwarding.
        record: Record to file (provide local file path, e.g. "recording.mp4").
        window_title: Custom window title.
        window_x: Window X position (-1 = default).
        window_y: Window Y position (-1 = default).
        window_width: Window width (0 = default).
        window_height: Window height (0 = default).
        borderless: Remove window decorations.
        always_on_top: Keep window on top.
        fullscreen: Start in fullscreen mode.
        stay_awake: Keep device awake while connected.
        turn_screen_off: Turn off device screen while mirroring.
        no_control: Disable device control (view only).
        show_touches: Show touch indicators on device.
        camera: Mirror camera instead of display.
        camera_id: Specific camera ID to use.
        camera_facing: Camera facing: front, back, external.
        camera_size: Camera capture size as "WxH".
        virtual_display: Create virtual display with given resolution (e.g. "1920x1080").
        no_window: Don't show a window (useful with --record).
        time_limit: Stop after N seconds (0 = no limit).
        extra_args: Additional scrcpy CLI arguments as a string.
    """
    cmd = [SCRCPY]

    if serial:
        cmd += ["-s", serial]
    if max_size > 0:
        cmd += ["-m", str(max_size)]
    if video_bit_rate != "8M":
        cmd += ["--video-bit-rate", video_bit_rate]
    if max_fps > 0:
        cmd += ["--max-fps", str(max_fps)]
    if video_codec != "h264":
        cmd += ["--video-codec", video_codec]
    if not audio or no_audio:
        cmd.append("--no-audio")
    elif audio_codec != "opus":
        cmd += ["--audio-codec", audio_codec]
    if crop:
        cmd += ["--crop", crop]
    if rotation >= 0:
        cmd += ["--lock-video-orientation", str(rotation)]
    if no_video:
        cmd.append("--no-video")
    if record:
        cmd += ["--record", os.path.expanduser(record)]
    if window_title:
        cmd += ["--window-title", window_title]
    if window_x >= 0:
        cmd += ["--window-x", str(window_x)]
    if window_y >= 0:
        cmd += ["--window-y", str(window_y)]
    if window_width > 0:
        cmd += ["--window-width", str(window_width)]
    if window_height > 0:
        cmd += ["--window-height", str(window_height)]
    if borderless:
        cmd.append("--window-borderless")
    if always_on_top:
        cmd.append("--always-on-top")
    if fullscreen:
        cmd.append("--fullscreen")
    if stay_awake:
        cmd.append("--stay-awake")
    if turn_screen_off:
        cmd.append("--turn-screen-off")
    if no_control:
        cmd.append("--no-control")
    if show_touches:
        cmd.append("--show-touches")
    if camera:
        cmd.append("--video-source=camera")
    if camera_id:
        cmd += ["--camera-id", camera_id]
    if camera_facing:
        cmd += ["--camera-facing", camera_facing]
    if camera_size:
        cmd += ["--camera-size", camera_size]
    if virtual_display:
        cmd += ["--new-display", virtual_display]
    if no_window:
        cmd.append("--no-window")
    if time_limit > 0:
        cmd += ["--time-limit", str(time_limit)]
    if extra_args:
        cmd += shlex.split(extra_args)

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    # Give it a moment to fail fast if there's an immediate error
    await asyncio.sleep(0.5)
    if proc.returncode is not None:
        _, stderr = await proc.communicate()
        raise RuntimeError(f"scrcpy exited immediately: {stderr.decode(errors='replace')}")

    _sessions[proc.pid] = {
        "process": proc,
        "serial": serial or "default",
        "started": time.time(),
        "cmd": " ".join(cmd),
    }
    return (
        f"scrcpy session started (PID {proc.pid})\n"
        f"Command: {' '.join(cmd)}\n"
        f"Use scrcpy_stop_session(pid={proc.pid}) to stop."
    )


@mcp.tool
async def scrcpy_stop_session(pid: int = 0) -> str:
    """Stop a running scrcpy session.

    Args:
        pid: Process ID of the scrcpy session (0 = stop all sessions).
    """
    if pid == 0 and not _sessions:
        return "No active scrcpy sessions."

    stopped = []

    if pid == 0:
        for spid in list(_sessions.keys()):
            info = _sessions.pop(spid)
            try:
                info["process"].send_signal(signal.SIGTERM)
                await asyncio.wait_for(info["process"].wait(), timeout=5.0)
            except (ProcessLookupError, asyncio.TimeoutError):
                try:
                    info["process"].kill()
                except ProcessLookupError:
                    pass
            stopped.append(str(spid))
        return f"Stopped all sessions: PID {', '.join(stopped)}"
    else:
        if pid not in _sessions:
            return f"No active session with PID {pid}. Active PIDs: {list(_sessions.keys())}"
        info = _sessions.pop(pid)
        try:
            info["process"].send_signal(signal.SIGTERM)
            await asyncio.wait_for(info["process"].wait(), timeout=5.0)
        except (ProcessLookupError, asyncio.TimeoutError):
            try:
                info["process"].kill()
            except ProcessLookupError:
                pass
        return f"Stopped scrcpy session PID {pid}"


# ── Entry point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    mcp.run()
