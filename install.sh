#!/usr/bin/env bash
# install.sh — One-click installer for scrcpy-mcp
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/charettep/scrcpy-mcp/main/install.sh | bash
#   # — or from a local clone —
#   ./install.sh
#
# Detects OS, installs system dependencies (adb, scrcpy), finds Python 3.10+,
# clones the repo if needed, installs pip deps, detects MCP clients (Claude Code,
# Codex CLI), and wires config into the chosen scope (global or project-local).
set -euo pipefail

REPO_URL="https://github.com/charettep/scrcpy-mcp.git"
DEFAULT_INSTALL_DIR="$HOME/mcp/scrcpy-mcp"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ── TTY-safe read (works when piped from curl) ────────────────────────────
# When running via `curl | bash`, stdin is the script itself.
# All interactive reads must come from /dev/tty instead.
prompt() {
    local varname="$1" message="$2"
    if [ -t 0 ]; then
        read -rp "$message" "$varname"
    else
        read -rp "$message" "$varname" </dev/tty
    fi
}

# ── Detect platform ────────────────────────────────────────────────────────
detect_platform() {
    case "$(uname -s)" in
        Linux)
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                case "$ID" in
                    ubuntu|debian|pop|linuxmint|elementary) PLATFORM="apt" ;;
                    fedora)                                  PLATFORM="dnf" ;;
                    arch|manjaro|endeavouros)                PLATFORM="pacman" ;;
                    *)
                        if command -v apt-get &>/dev/null; then PLATFORM="apt"
                        elif command -v dnf &>/dev/null; then PLATFORM="dnf"
                        elif command -v pacman &>/dev/null; then PLATFORM="pacman"
                        else fail "Unsupported Linux distro: $ID"
                        fi ;;
                esac
            else
                fail "Cannot detect Linux distro (no /etc/os-release)"
            fi ;;
        Darwin) PLATFORM="brew" ;;
        *)      fail "Unsupported OS: $(uname -s). Only Linux and macOS are supported." ;;
    esac
    info "Detected platform: $PLATFORM"
}

# ── Prompt before sudo ─────────────────────────────────────────────────────
ask_install() {
    local pkg="$1" mgr="$2"
    echo ""
    warn "$pkg is not installed."
    local ans=""
    prompt ans "  Install $pkg via $mgr? [y/N] "
    case "$ans" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

do_install() {
    local pkg="$1"
    case "$PLATFORM" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y "$pkg" ;;
        dnf)    sudo dnf install -y "$pkg" ;;
        pacman) sudo pacman -S --noconfirm "$pkg" ;;
        brew)   brew install "$pkg" ;;
    esac
}

# ── Check / install git ──────────────────────────────────────────────────
ensure_git() {
    if command -v git &>/dev/null; then
        return
    fi
    local pkg="git"
    if ask_install "git" "$PLATFORM ($pkg)"; then
        do_install "$pkg"
        command -v git &>/dev/null || fail "git still not found after install"
        ok "git installed: $(command -v git)"
    else
        fail "git is required to download scrcpy-mcp. Install it manually and re-run."
    fi
}

# ── Check / install scrcpy + adb (GitHub release bundles both) ────────────
ensure_scrcpy_and_adb() {
    local need_scrcpy=false need_adb=false

    if command -v scrcpy &>/dev/null; then
        ok "scrcpy found: $(command -v scrcpy)"
    else
        need_scrcpy=true
    fi

    if command -v adb &>/dev/null; then
        ok "adb found: $(command -v adb)"
    else
        need_adb=true
    fi

    # Nothing to do if both exist
    if ! $need_scrcpy && ! $need_adb; then return; fi

    local missing=""
    if $need_scrcpy && $need_adb; then missing="scrcpy + adb"
    elif $need_scrcpy; then missing="scrcpy"
    else missing="adb"
    fi

    if ! ask_install "$missing" "scrcpy GitHub release (latest)"; then
        if $need_adb; then fail "adb is required. Install it manually and re-run."; fi
        warn "scrcpy not installed — mirroring tools won't work, but adb tools will."
        return
    fi

    # Determine asset name for this platform
    local os_arch=""
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64)  os_arch="linux-x86_64" ;;
        Darwin-arm64)  os_arch="macos-aarch64" ;;
        Darwin-x86_64) os_arch="macos-x86_64" ;;
        *) fail "No pre-built scrcpy binary for $(uname -s)-$(uname -m)" ;;
    esac

    # Get latest release tag from GitHub API
    info "Fetching latest scrcpy release..."
    local tag
    tag="$(curl -fsSL https://api.github.com/repos/Genymobile/scrcpy/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4)"
    [ -n "$tag" ] || fail "Could not determine latest scrcpy version"

    local tarball="scrcpy-${os_arch}-${tag}.tar.gz"
    local url="https://github.com/Genymobile/scrcpy/releases/download/${tag}/${tarball}"

    info "Downloading scrcpy ${tag} (includes adb)..."
    local tmp_tar="/tmp/scrcpy-$$.tar.gz"
    curl -fsSL -o "$tmp_tar" "$url"
    sudo mkdir -p /opt/scrcpy
    sudo tar xzf "$tmp_tar" -C /opt/scrcpy --strip-components=1
    rm -f "$tmp_tar"

    # Symlink whichever binaries were missing
    if $need_scrcpy; then
        sudo ln -sf /opt/scrcpy/scrcpy /usr/local/bin/scrcpy
        command -v scrcpy &>/dev/null || fail "scrcpy still not found after install"
        ok "scrcpy installed: /usr/local/bin/scrcpy (${tag})"
    fi
    if $need_adb; then
        sudo ln -sf /opt/scrcpy/adb /usr/local/bin/adb
        command -v adb &>/dev/null || fail "adb still not found after install"
        ok "adb installed: /usr/local/bin/adb (bundled with scrcpy ${tag})"
    fi
}

# ── Find Python 3.10+ ─────────────────────────────────────────────────────
find_python() {
    local candidates=("python3.13" "python3.12" "python3.11" "python3.10" "python3")
    for py in "${candidates[@]}"; do
        if command -v "$py" &>/dev/null; then
            local ver major
            ver="$("$py" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null)" || continue
            major="$("$py" -c 'import sys; print(sys.version_info.major)' 2>/dev/null)" || continue
            if [ "$major" -eq 3 ] && [ "$ver" -ge 10 ]; then
                PYTHON_PATH="$(command -v "$py")"
                ok "Python found: $PYTHON_PATH ($("$PYTHON_PATH" --version))"
                return
            fi
        fi
    done
    fail "Python 3.10+ is required but not found. Install it and re-run."
}

# ── Ensure repo is available locally ──────────────────────────────────────
# Detects if running from a clone (scrcpy_mcp.py exists next to us) or from
# a curl pipe (no local files). Clones the repo if needed.
ensure_repo() {
    # Case 1: running from an existing clone — BASH_SOURCE is valid
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "bash" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "$script_dir/scrcpy_mcp.py" ] && [ -f "$script_dir/requirements.txt" ]; then
            INSTALL_DIR="$script_dir"
            ok "Running from local clone: $INSTALL_DIR"
            return
        fi
    fi

    # Case 2: piped from curl — clone the repo
    info "Downloading scrcpy-mcp..."
    ensure_git
    if [ -d "$DEFAULT_INSTALL_DIR/.git" ]; then
        info "Existing install found at $DEFAULT_INSTALL_DIR, updating..."
        git -C "$DEFAULT_INSTALL_DIR" pull --quiet
    else
        mkdir -p "$(dirname "$DEFAULT_INSTALL_DIR")"
        git clone --quiet "$REPO_URL" "$DEFAULT_INSTALL_DIR"
    fi
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    ok "Repository ready: $INSTALL_DIR"
}

# ── Check / install uv ────────────────────────────────────────────────────
ensure_uv() {
    if command -v uv &>/dev/null; then
        ok "uv found: $(command -v uv)"
        return
    fi
    info "Installing uv (Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Add uv to PATH for this session (installer puts it in ~/.local/bin)
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    command -v uv &>/dev/null || fail "uv still not found after install"
    ok "uv installed: $(command -v uv)"
}

# ── Create venv and install dependencies ──────────────────────────────────
# Uses uv to create an isolated venv and install deps.
# After this, PYTHON_PATH points to the venv's python.
install_deps() {
    local venv_dir="$INSTALL_DIR/.venv"

    info "Creating venv with uv..."
    uv venv --quiet --python "$PYTHON_PATH" "$venv_dir"
    info "Installing Python dependencies..."
    uv pip install --quiet --python "$venv_dir/bin/python" -r "$INSTALL_DIR/requirements.txt"

    # All config output uses the venv python so MCP clients launch with deps available
    PYTHON_PATH="$venv_dir/bin/python"
    ok "Dependencies installed: $venv_dir"
}

# ── Detect MCP clients ────────────────────────────────────────────────────
HAS_CLAUDE=false
HAS_CODEX=false

detect_clients() {
    if [ -f "$HOME/.claude.json" ]; then
        HAS_CLAUDE=true
        ok "Claude Code detected (~/.claude.json)"
    fi
    if [ -f "$HOME/.codex/config.toml" ]; then
        HAS_CODEX=true
        ok "Codex CLI detected (~/.codex/config.toml)"
    fi
    if ! $HAS_CLAUDE && ! $HAS_CODEX; then
        warn "Neither Claude Code nor Codex CLI config found."
        info "A local .mcp.json will be generated instead."
    fi
}

# ── Scope prompt ──────────────────────────────────────────────────────────
INSTALL_SCOPE=""  # "global" or "project"

ask_scope() {
    # If no global clients detected, default to project-only
    if ! $HAS_CLAUDE && ! $HAS_CODEX; then
        INSTALL_SCOPE="project"
        return
    fi

    echo ""
    info "Where should the MCP server be registered?"
    echo ""
    echo "  (g) Global  — write config into:"
    if $HAS_CLAUDE; then echo "        ~/.claude.json (Claude Code)"; fi
    if $HAS_CODEX;  then echo "        ~/.codex/config.toml (Codex CLI)"; fi
    echo "  (p) Project — generate .mcp.json in this directory only"
    echo ""
    local scope_ans=""
    prompt scope_ans "  Scope [g/p]: "
    case "$scope_ans" in
        [gG]) INSTALL_SCOPE="global" ;;
        *)    INSTALL_SCOPE="project" ;;
    esac
}

# ── Resolve binary paths ─────────────────────────────────────────────────
resolve_paths() {
    ADB_PATH="$(command -v adb 2>/dev/null || echo "adb")"
    SCRCPY_PATH="$(command -v scrcpy 2>/dev/null || echo "scrcpy")"
}

# ── Generate project-local .mcp.json ─────────────────────────────────────
generate_mcp_json() {
    local mcp_file="$INSTALL_DIR/.mcp.json"
    cat > "$mcp_file" <<MCPEOF
{
  "mcpServers": {
    "scrcpy": {
      "command": "$PYTHON_PATH",
      "args": ["$INSTALL_DIR/scrcpy_mcp.py"],
      "env": {
        "SCRCPY_MCP_ADB_PATH": "$ADB_PATH",
        "SCRCPY_MCP_SCRCPY_PATH": "$SCRCPY_PATH"
      }
    }
  }
}
MCPEOF
    ok "Generated $mcp_file"
}

# ── Inject into Claude Code ~/.claude.json ────────────────────────────────
inject_claude_code() {
    local claude_json="$HOME/.claude.json"

    # Pass values via sys.argv to avoid shell quoting issues in inline Python
    "$PYTHON_PATH" - "$claude_json" "$PYTHON_PATH" "$INSTALL_DIR/scrcpy_mcp.py" "$ADB_PATH" "$SCRCPY_PATH" <<'PYEOF'
import json, sys

config_path, py_path, script_path, adb_path, scrcpy_path = sys.argv[1:6]

try:
    with open(config_path, 'r') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

if 'mcpServers' not in data or not isinstance(data['mcpServers'], dict):
    data['mcpServers'] = {}

data['mcpServers']['scrcpy'] = {
    'type': 'stdio',
    'command': py_path,
    'args': [script_path],
    'env': {
        'SCRCPY_MCP_ADB_PATH': adb_path,
        'SCRCPY_MCP_SCRCPY_PATH': scrcpy_path
    }
}

with open(config_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF
    ok "Injected scrcpy server into $claude_json"
}

# ── Inject into Codex ~/.codex/config.toml ────────────────────────────────
inject_codex() {
    local codex_toml="$HOME/.codex/config.toml"

    # Remove existing scrcpy block if present (idempotent re-runs)
    if grep -q '^\[mcp_servers\.scrcpy\]' "$codex_toml" 2>/dev/null; then
        "$PYTHON_PATH" - "$codex_toml" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Remove [mcp_servers.scrcpy] and its sub-tables (e.g. .env)
# Match from the table header through to the next unrelated table header or EOF
content = re.sub(
    r'\n*\[mcp_servers\.scrcpy\].*?(?=\n\[(?!mcp_servers\.scrcpy)|$)',
    '',
    content,
    flags=re.DOTALL
)

with open(path, 'w') as f:
    f.write(content.rstrip('\n') + '\n')
PYEOF
        info "Removed existing scrcpy entry from $codex_toml"
    fi

    # Append the new scrcpy MCP server block
    cat >> "$codex_toml" <<TOMLEOF

[mcp_servers.scrcpy]
command = "$PYTHON_PATH"
args = ["$INSTALL_DIR/scrcpy_mcp.py"]

[mcp_servers.scrcpy.env]
SCRCPY_MCP_ADB_PATH = "$ADB_PATH"
SCRCPY_MCP_SCRCPY_PATH = "$SCRCPY_PATH"
TOMLEOF
    ok "Injected scrcpy server into $codex_toml"
}

# ── Android device setup wizard (Linux only) ─────────────────────────────
# Guides the user through first-time USB debugging setup, polls for device
# authorization, auto-detects USB vendor ID, and writes a udev rule.
setup_android_device() {
    # Skip on macOS — no udev needed
    if [ "$(uname -s)" != "Linux" ]; then return; fi

    echo ""
    echo "── Android Device Setup ────────────────────────"
    echo ""
    local ans=""
    prompt ans "  Set up an Android device now? [y/N] "
    case "$ans" in
        [yY]|[yY][eE][sS]) ;;
        *) info "Skipping device setup. You can re-run install.sh later."; return ;;
    esac

    # Ensure adb is on PATH for this session (in case we just installed it)
    export PATH="/usr/local/bin:$PATH"
    hash -r 2>/dev/null

    # Start adb daemon
    info "Starting adb daemon..."
    adb start-server 2>/dev/null

    echo ""
    echo "  Follow these steps on your Android device:"
    echo ""
    echo "  1. Plug your Android device into a USB port"
    echo "  2. Enable Developer Options:"
    echo "     Settings > About Phone > tap Build Number 7 times quickly"
    echo "  3. Enable USB Debugging:"
    echo "     Settings > System > Developer Options > toggle USB Debugging"
    echo "  4. Accept the RSA fingerprint prompt on the phone when asked"
    echo ""

    # ── Poll for device connection ────────────────────────────────────────
    info "Waiting for device to appear on USB..."
    local device_line="" serial="" state="" attempts=0 max_attempts=60

    while [ $attempts -lt $max_attempts ]; do
        device_line="$(adb devices 2>/dev/null | grep -E '\s(device|unauthorized|no permissions)' | head -1)"
        if [ -n "$device_line" ]; then
            serial="$(echo "$device_line" | awk '{print $1}')"
            state="$(echo "$device_line" | awk '{print $2}')"
            break
        fi
        sleep 2
        attempts=$((attempts + 1))
        # Print a dot every 10 seconds so user knows we're still waiting
        if [ $((attempts % 5)) -eq 0 ]; then
            echo -ne "  ... still waiting (${attempts}/${max_attempts})\r"
        fi
    done

    if [ -z "$serial" ]; then
        warn "No device detected after 2 minutes. Skipping device setup."
        info "Plug in your device and run: adb devices"
        return
    fi

    ok "Device detected: $serial (state: $state)"

    # ── Wait for authorization if needed ──────────────────────────────────
    if [ "$state" = "unauthorized" ] || [ "$state" = "no" ]; then
        echo ""
        info "Device is connected but not authorized."
        info "Accept the RSA fingerprint prompt on your phone now..."
        echo ""

        attempts=0
        while [ $attempts -lt 30 ]; do
            state="$(adb devices 2>/dev/null | grep "$serial" | awk '{print $2}')"
            if [ "$state" = "device" ]; then
                break
            fi
            sleep 2
            attempts=$((attempts + 1))
        done

        if [ "$state" != "device" ]; then
            warn "Device still unauthorized after 60s. Skipping udev rule."
            info "Accept the RSA prompt and run: adb devices"
            return
        fi
        ok "Device authorized!"
    fi

    # ── Auto-detect USB vendor ID and write udev rule ─────────────────────
    info "Detecting USB vendor ID..."
    local vendor_id=""

    # Try to get vendor ID from adb usb device path
    # lsusb lists all USB devices; we look for known Android vendor IDs
    # or match the device serial against usb-devices output
    if command -v lsusb &>/dev/null; then
        # Get the device's USB vendor ID via adb and cross-reference with lsusb
        # adb devices -l shows transport_id; we can also use getprop
        local usb_vid
        usb_vid="$(adb -s "$serial" shell getprop ro.boot.usb.vid 2>/dev/null | tr -d '[:space:]')"

        if [ -z "$usb_vid" ] || [ "$usb_vid" = "" ]; then
            # Fallback: scan lsusb for known Android vendors or recently added devices
            # Get manufacturer from device, match against lsusb
            local manufacturer
            manufacturer="$(adb -s "$serial" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

            if [ -n "$manufacturer" ]; then
                vendor_id="$(lsusb | grep -i "$manufacturer" | head -1 | grep -oP 'ID \K[0-9a-f]{4}' || true)"
            fi
        else
            vendor_id="$usb_vid"
        fi

        # Last resort: show lsusb and let the user see what we picked
        if [ -z "$vendor_id" ]; then
            # Parse all lsusb vendor IDs and exclude common non-Android ones (hubs, etc.)
            # Pick the first one that's not a Linux Foundation hub (1d6b)
            vendor_id="$(lsusb | grep -v '1d6b:' | grep -v 'Hub' | head -1 | grep -oP 'ID \K[0-9a-f]{4}' || true)"
        fi
    fi

    if [ -z "$vendor_id" ]; then
        warn "Could not auto-detect USB vendor ID."
        info "Run 'lsusb' to find your device's vendor ID, then create:"
        info "  /etc/udev/rules.d/51-android.rules"
        return
    fi

    ok "USB vendor ID: $vendor_id"

    # Check if rule already exists
    if grep -qs "idVendor.*$vendor_id" /etc/udev/rules.d/51-android.rules 2>/dev/null; then
        ok "udev rule for vendor $vendor_id already exists"
    else
        info "Adding udev rule for vendor $vendor_id..."
        sudo tee /etc/udev/rules.d/51-android.rules >/dev/null <<UDEVEOF
SUBSYSTEM=="usb", ATTR{idVendor}=="$vendor_id", MODE="0666", GROUP="plugdev"
UDEVEOF
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        ok "udev rule written to /etc/udev/rules.d/51-android.rules"
    fi

    # Restart adb to pick up new permissions
    info "Restarting adb server..."
    adb kill-server
    adb start-server
    echo ""
    info "Connected devices:"
    adb devices -l
    echo ""
    ok "Android device setup complete!"
}

# ── Generate .env ─────────────────────────────────────────────────────────
generate_env() {
    local env_file="$INSTALL_DIR/.env"
    cat > "$env_file" <<ENVEOF
# Generated by install.sh — absolute paths for scrcpy-mcp
SCRCPY_MCP_ADB_PATH=$ADB_PATH
SCRCPY_MCP_SCRCPY_PATH=$SCRCPY_PATH
ENVEOF
    ok "Generated $env_file"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  scrcpy-mcp installer"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    detect_platform
    ensure_repo
    ensure_scrcpy_and_adb
    # Refresh PATH so newly symlinked binaries are found immediately
    export PATH="/usr/local/bin:$PATH"
    hash -r 2>/dev/null
    find_python
    ensure_uv
    install_deps
    resolve_paths
    generate_env

    echo ""
    echo "── MCP Client Detection ──────────────────────"
    detect_clients
    ask_scope

    if [ "$INSTALL_SCOPE" = "global" ]; then
        if $HAS_CLAUDE; then inject_claude_code; fi
        if $HAS_CODEX;  then inject_codex; fi
    else
        generate_mcp_json
    fi

    setup_android_device

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ok "Installation complete!"
    echo ""
    info "Installed to: $INSTALL_DIR"
    if [ "$INSTALL_SCOPE" = "global" ]; then
        info "scrcpy MCP server registered globally."
        info "Restart Claude Code / Codex to pick up the new server."
    else
        info "Generated .mcp.json in $INSTALL_DIR"
        info "Copy it to your project or ~/.claude.json for wider access."
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
