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
DEFAULT_INSTALL_DIR="$HOME/.local/share/scrcpy-mcp"

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

# ── Check / install adb ───────────────────────────────────────────────────
ensure_adb() {
    if command -v adb &>/dev/null; then
        ok "adb found: $(command -v adb)"
        return
    fi
    local pkg
    case "$PLATFORM" in
        apt)    pkg="adb" ;;
        dnf)    pkg="android-tools" ;;
        pacman) pkg="android-tools" ;;
        brew)   pkg="android-platform-tools" ;;
    esac
    if ask_install "adb" "$PLATFORM ($pkg)"; then
        do_install "$pkg"
        command -v adb &>/dev/null || fail "adb still not found after install"
        ok "adb installed: $(command -v adb)"
    else
        fail "adb is required. Install it manually and re-run."
    fi
}

# ── Check / install scrcpy ────────────────────────────────────────────────
ensure_scrcpy() {
    if command -v scrcpy &>/dev/null; then
        ok "scrcpy found: $(command -v scrcpy)"
        return
    fi
    local pkg="scrcpy"
    local mgr="$PLATFORM ($pkg)"
    # On apt-based systems, snap is a fallback if the apt package is unavailable
    if [ "$PLATFORM" = "apt" ] && ! apt-cache show scrcpy &>/dev/null 2>&1; then
        if command -v snap &>/dev/null; then
            mgr="snap"
        fi
    fi
    if ask_install "scrcpy" "$mgr"; then
        if [ "$mgr" = "snap" ]; then
            sudo snap install scrcpy
        else
            do_install "$pkg"
        fi
        command -v scrcpy &>/dev/null || fail "scrcpy still not found after install"
        ok "scrcpy installed: $(command -v scrcpy)"
    else
        warn "scrcpy not installed — mirroring tools won't work, but adb tools will."
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

# ── Create venv and install dependencies ──────────────────────────────────
# Uses uv if available (fast, handles PEP 668), falls back to stdlib venv + pip.
# After this, PYTHON_PATH points to the venv's python.
install_deps() {
    local venv_dir="$INSTALL_DIR/.venv"

    if command -v uv &>/dev/null; then
        info "Creating venv with uv..."
        uv venv --quiet --python "$PYTHON_PATH" "$venv_dir"
        info "Installing Python dependencies with uv..."
        uv pip install --quiet --python "$venv_dir/bin/python" -r "$INSTALL_DIR/requirements.txt"
    else
        info "Creating venv..."
        "$PYTHON_PATH" -m venv "$venv_dir"
        info "Installing Python dependencies..."
        "$venv_dir/bin/python" -m pip install --quiet -r "$INSTALL_DIR/requirements.txt"
    fi

    # All config output uses the venv python so MCP clients launch with deps available
    PYTHON_PATH="$venv_dir/bin/python"
    ok "venv ready: $venv_dir"
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
    ensure_adb
    ensure_scrcpy
    find_python
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
