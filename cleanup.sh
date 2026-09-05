#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# cleanup.sh: Remove local LLM setup to start fresh
#
# Removes all user-namespace installations from a previous setup.sh run:
# - Conda ollama environment
# - ~/.local/bin/ollama binary
# - ~/.cache/local-llm-expert/ cache
# - OpenCode config
# - Generated launcher scripts
# - Old processes
#
# Usage:
#   ./cleanup.sh              Interactive cleanup
#   ./cleanup.sh --all        Remove everything including models
#   ./cleanup.sh --help       Show help
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()    { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

prompt_yn() {
    local prompt="$1" default="${2:-y}"
    local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
    read -rp "$(echo -e "${BOLD}${prompt} ${hint}: ${NC}")" answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
cleanup.sh — Remove local LLM setup to start fresh

USAGE:
  ./cleanup.sh              Interactive cleanup (ask for each item)
  ./cleanup.sh --all        Remove everything including downloaded models
  ./cleanup.sh --help       Show this help

WHAT IT REMOVES:
  ✓ Conda 'ollama' environment
  ✓ ~/.local/bin/ollama binary
  ✓ ~/.cache/local-llm-expert/ cache
  ✓ OpenCode config (~/.config/opencode/)
  ✓ Setup logs (setup_*.log)
  ✓ Kill running ollama/vllm processes

WITH --all:
  ✓ Also remove downloaded models (~/.ollama/models/)
  ✓ vLLM environment

AFTER CLEANUP:
  You can run ./setup.sh again to set up a different provider or model.

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local remove_all=false
    [[ "${1:-}" == "--all" ]] && remove_all=true
    [[ "${1:-}" == "--help" ]] && { show_help; exit 0; }

    header "Cleanup: Remove Local LLM Setup"

    # Kill running processes
    info "Stopping any running processes..."
    pkill -f "ollama serve" 2>/dev/null || true
    pkill -f "vllm serve" 2>/dev/null || true
    sleep 1
    ok "Processes stopped"

    echo ""
    echo "Items to remove:"
    echo "  1. Conda 'ollama' environment"
    echo "  2. ~/.local/bin/ollama binary"
    echo "  3. ~/.cache/local-llm-expert/ cache"
    echo "  4. OpenCode config (~/.config/opencode/)"
    echo "  5. Setup logs"
    [[ "$remove_all" == "true" ]] && echo "  6. Downloaded models (~/.ollama/models/)"
    [[ "$remove_all" == "true" ]] && echo "  7. vLLM environment (~/vllm-env)"

    if [[ "$remove_all" == "false" ]]; then
        echo ""
        if ! prompt_yn "Proceed with cleanup?"; then
            warn "Cleanup cancelled"
            exit 0
        fi
    fi

    echo ""

    # 1. Remove conda environment
    if conda env list 2>/dev/null | grep -q "^ollama "; then
        info "Removing conda 'ollama' environment..."
        conda env remove -n ollama -y 2>/dev/null && ok "Conda environment removed" || warn "Failed to remove conda environment"
    fi

    # 2. Remove ~/.local/bin/ollama
    if [[ -f "$HOME/.local/bin/ollama" ]]; then
        info "Removing ~/.local/bin/ollama..."
        rm -f "$HOME/.local/bin/ollama" && ok "Binary removed" || warn "Failed to remove binary"
    fi

    # 3. Remove cache
    if [[ -d "$HOME/.cache/local-llm-expert" ]]; then
        info "Removing ~/.cache/local-llm-expert/..."
        rm -rf "$HOME/.cache/local-llm-expert" && ok "Cache removed" || warn "Failed to remove cache"
    fi

    # 4. Remove OpenCode config
    if [[ -d "$HOME/.config/opencode" ]]; then
        info "Removing ~/.config/opencode/..."
        rm -rf "$HOME/.config/opencode" && ok "OpenCode config removed" || warn "Failed to remove config"
    fi

    # 5. Remove logs
    info "Removing setup logs..."
    rm -f "$SCRIPT_DIR"/setup_*.log
    rm -f "$SCRIPT_DIR"/ollama_serve.log
    rm -f "$SCRIPT_DIR"/vllm.log
    ok "Logs removed"

    # 7. Remove models (if --all)
    if [[ "$remove_all" == "true" ]]; then
        if [[ -d "$HOME/.ollama/models" ]]; then
            info "Removing downloaded models (~/.ollama/models/)..."
            if prompt_yn "This will remove all downloaded models. Continue?"; then
                rm -rf "$HOME/.ollama/models" && ok "Models removed" || warn "Failed to remove models"
            fi
        fi

        # 8. Remove vLLM environment
        if [[ -d "$HOME/vllm-env" ]]; then
            info "Removing vLLM environment..."
            rm -rf "$HOME/vllm-env" && ok "vLLM environment removed" || warn "Failed to remove vLLM"
        fi
    fi

    echo ""
    header "Cleanup Complete!"
    echo "You can now run ./setup.sh again to set up a fresh environment."
    echo ""
}

main "$@"
