#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# local-llm-expert: One-stop setup for local LLM + OpenCode on any machine.
#
# Supports: Linux (NVIDIA/AMD/CPU), macOS (Apple Silicon/Intel), WSL2
# Providers: Ollama, vLLM, LM Studio
# Usage:
#   ./setup.sh              Interactive setup
#   ./setup.sh --status     Show current setup status
#   ./setup.sh --uninstall  Remove provider + config
#   ./setup.sh --help       Show help
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
USED_CONDA_INSTALL=false

# ── Colors (disabled if not a terminal) ──────────────────────────────────────
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
die()    { err "$*"; exit 1; }

prompt_choice() {
    local prompt="$1"; shift
    local options=("$@")
    echo -e "\n${BOLD}${prompt}${NC}"
    for i in "${!options[@]}"; do
        echo -e "  ${CYAN}$((i+1)))${NC} ${options[$i]}"
    done
    while true; do
        read -rp "$(echo -e "${BOLD}> Choose [1-${#options[@]}]: ${NC}")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            CHOICE_RESULT=$((choice - 1))
            return 0
        fi
        echo -e "${RED}  Invalid choice.${NC}"
    done
}

prompt_yn() {
    local prompt="$1" default="${2:-y}"
    local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
    read -rp "$(echo -e "${BOLD}${prompt} ${hint}: ${NC}")" answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" ]]
}

# ── Prerequisite checks ─────────────────────────────────────────────────────
require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is required but not found. $2"
}

bytes_to_human() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then echo "$((bytes / 1073741824)) GB"
    elif (( bytes >= 1048576 )); then echo "$((bytes / 1048576)) MB"
    else echo "${bytes} B"; fi
}

# ═════════════════════════════════════════════════════════════════════════════
# DETECT: OS, CPU, GPU, Memory, Disk
# ═════════════════════════════════════════════════════════════════════════════
detect_system() {
    # ── OS ────────────────────────────────────────────────────────────────
    OS="unknown"; IS_WSL=false; HAS_SYSTEMD=false; PKG_MGR=""
    case "$(uname -s)" in
        Linux*)
            OS="linux"
            [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true
            # systemd detection
            if pidof systemd &>/dev/null || [[ -d /run/systemd/system ]]; then
                HAS_SYSTEMD=true
            fi
            # package manager
            if   command -v apt-get &>/dev/null; then PKG_MGR="apt"
            elif command -v dnf     &>/dev/null; then PKG_MGR="dnf"
            elif command -v yum     &>/dev/null; then PKG_MGR="yum"
            elif command -v pacman  &>/dev/null; then PKG_MGR="pacman"
            elif command -v zypper  &>/dev/null; then PKG_MGR="zypper"
            fi
            ;;
        Darwin*)
            OS="macos"
            command -v brew &>/dev/null && PKG_MGR="brew"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            OS="windows"
            ;;
    esac

    # ── CPU architecture ──────────────────────────────────────────────────
    ARCH="$(uname -m)"  # x86_64, aarch64, arm64

    # ── Apple Silicon detection ───────────────────────────────────────────
    IS_APPLE_SILICON=false
    if [[ "$OS" == "macos" && ("$ARCH" == "arm64" || "$ARCH" == "aarch64") ]]; then
        IS_APPLE_SILICON=true
    fi

    # ── RAM ───────────────────────────────────────────────────────────────
    TOTAL_RAM_MB=0
    if [[ "$OS" == "linux" ]]; then
        TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    elif [[ "$OS" == "macos" ]]; then
        TOTAL_RAM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
    fi

    # ── Disk (free space in project dir) ──────────────────────────────────
    FREE_DISK_MB=0
    if command -v df &>/dev/null; then
        # Use home dir for disk check (where models are stored)
        FREE_DISK_MB=$(df -m "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    fi

    # ── GPU detection ─────────────────────────────────────────────────────
    HAS_NVIDIA=false; HAS_AMD=false; HAS_METAL=false; HAS_GPU=false
    GPU_COUNT=0; CUDA_VERSION=""; ROCM_VERSION=""
    declare -g -a GPU_NAMES=() GPU_VRAM_MB=() GPU_UUIDS=() GPU_MEM_USED_MB=()

    # NVIDIA
    if command -v nvidia-smi &>/dev/null; then
        local gpu_csv
        gpu_csv=$(nvidia-smi --query-gpu=index,name,memory.total,uuid,memory.used \
            --format=csv,noheader,nounits 2>/dev/null || true)
        if [[ -n "$gpu_csv" ]]; then
            HAS_NVIDIA=true; HAS_GPU=true
            while IFS=',' read -r idx name vram uuid used; do
                idx=$(echo "$idx" | xargs)
                name=$(echo "$name" | xargs)
                vram=$(echo "$vram" | xargs)
                uuid=$(echo "$uuid" | xargs)
                used=$(echo "$used" | xargs)

                # Handle MIG (Multi-Instance GPU) restrictions: [Insufficient Permissions]
                # In MIG mode, we can't query memory.total but we can parse MIG device info
                if [[ "$vram" == "[Insufficient Permissions]" ]]; then
                    # Try to get MIG device memory from nvidia-smi -L output
                    local mig_mem
                    mig_mem=$(nvidia-smi -L 2>/dev/null | grep -oP "MIG.*?\K[0-9]+(?=gb)" | head -1 || echo "")
                    if [[ -n "$mig_mem" ]]; then
                        vram=$((mig_mem * 1024))  # Convert GB to MB
                        warn "Running in MIG mode — detected $mig_mem GB allocated"
                    else
                        warn "Running in restricted GPU mode (MIG?) — cannot detect memory. Defaulting to 71GB"
                        vram=$((71 * 1024))  # Reasonable default for H200 MIG partition
                    fi
                fi

                # Handle [Insufficient Permissions] in memory.used field
                if [[ "$used" == "[Insufficient Permissions]" ]] || [[ ! "$used" =~ ^[0-9]+$ ]]; then
                    used=0
                fi

                GPU_NAMES+=("$name")
                GPU_VRAM_MB+=("$vram")
                GPU_UUIDS+=("$uuid")
                GPU_MEM_USED_MB+=("$used")
                GPU_COUNT=$((GPU_COUNT + 1))
            done <<< "$gpu_csv"

            CUDA_VERSION=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA (UMD )?Version: \K[0-9]+\.[0-9]+' || echo "unknown")
        fi
    fi

    # AMD ROCm
    if ! $HAS_NVIDIA && command -v rocm-smi &>/dev/null; then
        if rocm-smi --showid &>/dev/null; then
            HAS_AMD=true; HAS_GPU=true
            ROCM_VERSION=$(rocm-smi --showversion 2>/dev/null | grep -oP 'ROCm version: \K.*' || echo "unknown")
            local amd_count
            amd_count=$(rocm-smi --showid 2>/dev/null | grep -c "GPU\[" || echo 0)
            GPU_COUNT=$amd_count
            for i in $(seq 0 $((amd_count - 1))); do
                GPU_NAMES+=("AMD GPU $i")
                local vram
                vram=$(rocm-smi -d "$i" --showmeminfo vram 2>/dev/null | grep "Total" | awk '{print int($NF/1048576)}' || echo 0)
                GPU_VRAM_MB+=("$vram")
                GPU_UUIDS+=("amd-$i")
                GPU_MEM_USED_MB+=("0")
            done
        fi
    fi

    # Apple Metal (unified memory = RAM)
    if $IS_APPLE_SILICON; then
        HAS_METAL=true; HAS_GPU=true
        GPU_COUNT=1
        GPU_NAMES+=("Apple Silicon (Metal)")
        GPU_VRAM_MB+=("$TOTAL_RAM_MB")  # unified memory
        GPU_UUIDS+=("metal-0")
        GPU_MEM_USED_MB+=("0")
    fi
}

print_system_info() {
    header "System Information"
    echo -e "  ${BOLD}OS:${NC}           ${OS}$(${IS_WSL} && echo ' (WSL2)')$(${IS_APPLE_SILICON} && echo ' (Apple Silicon)')"
    echo -e "  ${BOLD}Arch:${NC}         ${ARCH}"
    echo -e "  ${BOLD}RAM:${NC}          $((TOTAL_RAM_MB / 1024)) GB"
    echo -e "  ${BOLD}Free disk:${NC}    $((FREE_DISK_MB / 1024)) GB (home partition)"
    echo -e "  ${BOLD}systemd:${NC}      ${HAS_SYSTEMD}"
    echo -e "  ${BOLD}Pkg manager:${NC}  ${PKG_MGR:-none detected}"
    echo ""

    if $HAS_GPU; then
        local gpu_type="NVIDIA (CUDA ${CUDA_VERSION})"
        $HAS_AMD && gpu_type="AMD (ROCm ${ROCM_VERSION})"
        $HAS_METAL && gpu_type="Apple Metal (unified memory)"
        echo -e "  ${BOLD}GPU type:${NC}     ${gpu_type}"
        echo -e "  ${BOLD}GPU count:${NC}    ${GPU_COUNT}"
        echo ""

        if ! $HAS_METAL; then
            printf "  ${BOLD}%-5s %-28s %-10s %-10s %s${NC}\n" "Idx" "Name" "VRAM" "Used" "UUID"
            for i in $(seq 0 $((GPU_COUNT - 1))); do
                printf "  %-5s %-28s %-10s %-10s %s\n" \
                    "$i" "${GPU_NAMES[$i]}" \
                    "$((GPU_VRAM_MB[$i] / 1024))GB" \
                    "$((GPU_MEM_USED_MB[$i] / 1024))GB" \
                    "${GPU_UUIDS[$i]:0:24}..."
            done
        else
            echo -e "  GPU 0: ${GPU_NAMES[0]} — ${BOLD}$((TOTAL_RAM_MB / 1024)) GB${NC} unified memory"
            echo -e "  ${YELLOW}Note: On Apple Silicon, GPU memory = system RAM. Budget ~60-70% for models.${NC}"
        fi
    else
        echo -e "  ${YELLOW}No GPU detected. CPU-only mode.${NC}"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# MODEL DATABASE
# ═════════════════════════════════════════════════════════════════════════════
# Each model: name|ollama_tag|hf_id|min_vram_mb|min_disk_mb|description|tier
# Tiers: cpu, small (8GB), medium (16-24GB), large (48GB+)
declare -a ALL_MODELS=()

init_models() {
    ALL_MODELS=(
        # Large GPU models (48GB+)
        "Qwen3-Coder-Next 80B (MoE, 3B active)|qwen3-coder-next:q4_K_M|Qwen/Qwen3-Coder-Next|52000|35000|#1 SWE-bench, 256K ctx, best coding model|large"
        "Qwen3-Next 80B A3B Instruct (MoE, 3B active)|qwen3-next:80b|Qwen/Qwen3-Next-80B-A3B-Instruct|52000|35000|General-purpose 80B MoE, 256K ctx|large"
        "Qwen3-Coder-Next 80B (FP8, best quality)|qwen3-coder-next:fp8|Qwen/Qwen3-Coder-Next-FP8|92000|85000|Full quality FP8, needs 96GB+ VRAM|xlarge"

        # Medium GPU models (16-24GB)
        "Qwen3.8-27B|qwen3.8:27b|Qwen/Qwen3.8-27B-Instruct|17000|18000|Latest Qwen 27B, strong coding + reasoning|medium"
        "Qwen3.6-27B|qwen3.6:27b|Qwen/Qwen3.6-27B-Instruct|17000|18000|Strong all-rounder, 256K ctx|medium"
        "Qwen3-Coder 30B (MoE, 3B active)|qwen3-coder:30b|Qwen/Qwen3-Coder-30B-A3B-Instruct|19000|20000|Best coding model under 24GB|medium"
        "Qwen2.5-Coder-32B|qwen2.5-coder:32b|Qwen/Qwen2.5-Coder-32B-Instruct|20000|21000|Proven coding model, near GPT-4o|medium"
        "DeepSeek-R1-Distill-Qwen-32B|deepseek-r1:32b|deepseek-ai/DeepSeek-R1-Distill-Qwen-32B|20000|21000|Strong reasoning, 128K ctx|medium"

        # Small GPU models (8-12GB)
        "Qwen2.5-Coder-14B|qwen2.5-coder:14b|Qwen/Qwen2.5-Coder-14B-Instruct|9000|10000|Solid coding, fits 12-16GB GPU|small"
        "DeepSeek-R1-Distill-Qwen-14B|deepseek-r1:14b|deepseek-ai/DeepSeek-R1-Distill-Qwen-14B|9000|10000|Good reasoning, 128K ctx|small"
        "Qwen2.5-Coder-7B|qwen2.5-coder:7b|Qwen/Qwen2.5-Coder-7B-Instruct|5000|5000|Good for 8GB GPUs, 72% HumanEval|small"
        "DeepSeek-R1-Distill-Qwen-7B|deepseek-r1:8b|deepseek-ai/DeepSeek-R1-Distill-Qwen-7B|5200|5200|Reasoning model, 128K ctx|small"

        # CPU models (no GPU required — need enough RAM)
        "Qwen3.8-27B (CPU)|qwen3.8:27b|Qwen/Qwen3.8-27B-Instruct|0|18000|Latest 27B, ~20GB RAM, slow but capable|cpu"
        "Qwen3.6-27B (CPU)|qwen3.6:27b|Qwen/Qwen3.6-27B-Instruct|0|18000|Strong 27B, ~20GB RAM, slow but capable|cpu"
        "Qwen2.5-Coder-7B (CPU)|qwen2.5-coder:7b|Qwen/Qwen2.5-Coder-7B-Instruct|0|5000|Best small coding model, ~8GB RAM|cpu"
        "DeepSeek-R1-Distill-Qwen-7B (CPU)|deepseek-r1:8b|deepseek-ai/DeepSeek-R1-Distill-Qwen-7B|0|5200|Reasoning model, ~8GB RAM|cpu"
    )
}

# Parse a model entry by index → sets MODEL_* globals
parse_model() {
    local idx=$1
    IFS='|' read -r MODEL_NAME MODEL_OLLAMA MODEL_HF MODEL_MIN_VRAM MODEL_MIN_DISK MODEL_DESC MODEL_TIER \
        <<< "${ALL_MODELS[$idx]}"
}

# ═════════════════════════════════════════════════════════════════════════════
# PROVIDER: Ollama
# ═════════════════════════════════════════════════════════════════════════════
ollama_install() {
    if command -v ollama &>/dev/null; then
        ok "Ollama already installed: $(ollama --version 2>/dev/null)"
        return 0
    fi

    info "Installing Ollama..."

    # Check if sudo is available
    local has_sudo=false
    sudo -n true 2>/dev/null && has_sudo=true

    if [[ "$OS" == "macos" ]] && [[ "$PKG_MGR" == "brew" ]]; then
        brew install ollama
        ok "Ollama installed: $(ollama --version 2>/dev/null)"
    elif [[ "$OS" == "linux" ]]; then
        if $has_sudo; then
            # System-wide installation
            curl -fsSL https://ollama.com/install.sh | sh
            ok "Ollama installed system-wide: $(ollama --version 2>/dev/null)"
        else
            # No sudo — check for conda first
            local has_conda=false
            command -v conda &>/dev/null && has_conda=true

            # Check for conda/mamba
            local has_mamba=false
            command -v mamba &>/dev/null && has_mamba=true

            if $has_conda || $has_mamba; then
                header "Install Ollama via Conda/Mamba"

                # Offer choice between conda and mamba
                local pkg_mgr_options=()
                [[ "$has_conda" == "true" ]] && pkg_mgr_options+=("Conda (slower, but standard)")
                [[ "$has_mamba" == "true" ]] && pkg_mgr_options+=("Mamba (faster alternative to conda)")

                if (( ${#pkg_mgr_options[@]} > 1 )); then
                    prompt_choice "Which package manager do you prefer?" "${pkg_mgr_options[@]}"
                    if (( CHOICE_RESULT == 0 )); then
                        PKG_MGR_CMD="conda"
                    else
                        PKG_MGR_CMD="mamba"
                    fi
                elif $has_mamba; then
                    PKG_MGR_CMD="mamba"
                else
                    PKG_MGR_CMD="conda"
                fi

                info "Creating conda environment and installing Ollama via ${PKG_MGR_CMD}..."
                echo ""
                echo "Running: ${PKG_MGR_CMD} create -y -n ollama"
                echo "Then:    ${PKG_MGR_CMD} install -y -n ollama ollama"
                echo ""

                if ${PKG_MGR_CMD} create -y -n ollama &>/dev/null && \
                   ${PKG_MGR_CMD} install -y -n ollama ollama &>/dev/null; then
                    ok "Ollama installed in 'ollama' environment"
                    USED_CONDA_INSTALL=true

                    # Start Ollama within the conda environment
                    info "Starting Ollama from conda environment..."
                    local conda_activation_cmd="eval \"\$(${PKG_MGR_CMD} shell.bash hook 2>/dev/null)\" && ${PKG_MGR_CMD} activate ollama 2>/dev/null && ollama serve"
                    nohup bash -c "$conda_activation_cmd" > "${SCRIPT_DIR}/ollama_serve.log" 2>&1 &
                    OLLAMA_PID=$!
                    sleep 3
                    if curl -s --max-time 3 http://localhost:11434/api/tags &>/dev/null; then
                        ok "Ollama started from conda environment (PID: ${OLLAMA_PID})"
                        return 0
                    else
                        ok "Ollama started (PID: ${OLLAMA_PID}) — still loading, check log: ${SCRIPT_DIR}/ollama_serve.log"
                        return 0
                    fi
                else
                    warn "Installation failed. Falling back to binary download..."
                fi
            fi

            # No conda or conda install failed — offer choices
            header "Ollama Installation Options (No sudo)"
            echo "This appears to be an HPC/SLURM environment without sudo access."
            echo ""

            prompt_choice "How would you like to install Ollama?" \
                "Install locally to ~/.local/bin (requires network)" \
                "Ask your admin to install system-wide (recommended)"

            case $CHOICE_RESULT in
                0)
                    # Local installation
                    info "Installing Ollama to ~/.local/bin..."
                    mkdir -p ~/.local/bin
                    local tarball="${SCRIPT_DIR}/ollama-linux-x86_64.tar.gz"

                    # Try downloading with multiple fallbacks
                    local download_urls=(
                        "https://ollama.com/download/ollama-linux-x86_64.tar.gz"
                        "https://github.com/ollama/ollama/releases/download/v0.33.3/ollama-linux-x86_64.tar.gz"
                    )

                    local downloaded=false
                    for url in "${download_urls[@]}"; do
                        info "Attempting download from: $url"
                        if curl -sL --max-time 30 -o "$tarball" "$url" 2>/dev/null; then
                            # Verify it's actually a tar file
                            if tar -tzf "$tarball" &>/dev/null; then
                                downloaded=true
                                break
                            fi
                        fi
                    done

                    if $downloaded; then
                        if tar -xz -C ~/.local/bin -f "$tarball"; then
                            rm -f "$tarball"
                            ok "Ollama installed to ~/.local/bin: $(~/.local/bin/ollama --version 2>/dev/null)"
                            if command -v ollama &>/dev/null; then
                                ok "Ollama is in PATH"
                            else
                                warn "Add to ~/.bashrc or ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\""
                            fi
                        else
                            die "Failed to extract Ollama"
                        fi
                    else
                        err "Failed to download Ollama from any source."
                        err "This may be a network/proxy issue on your HPC environment."
                        echo ""
                        echo "Alternative options:"
                        echo "  1. Check if Ollama is already installed system-wide:"
                        echo "     ollama --version"
                        echo ""
                        echo "  2. Ask your admin to install it:"
                        echo "     curl -fsSL https://ollama.com/install.sh | sudo sh"
                        echo ""
                        echo "  3. Try installing from conda (if available):"
                        echo "     conda install -c conda-forge ollama"
                        die "Cannot proceed without Ollama"
                    fi
                    ;;
                1)
                    # Admin install
                    warn "System-wide installation requires sudo."
                    echo ""
                    echo "Ask your administrator to run:"
                    echo "  curl -fsSL https://ollama.com/install.sh | sudo sh"
                    echo ""
                    die "Cannot proceed without Ollama. Please contact your admin."
                    ;;
            esac
        fi
    else
        die "Cannot auto-install Ollama on ${OS}. Install manually from https://ollama.com/download"
    fi
}

ollama_ensure_running() {
    # Check if already running
    if curl -s --max-time 3 http://localhost:11434/api/tags &>/dev/null; then
        ok "Ollama is already running"
        return 0
    fi

    if $HAS_SYSTEMD && [[ -f /etc/systemd/system/ollama.service ]]; then
        sudo systemctl start ollama 2>/dev/null || true
        sleep 2
        if curl -s --max-time 5 http://localhost:11434/api/tags &>/dev/null; then
            ok "Ollama started via systemd"
            return 0
        fi
    fi

    # macOS: check for brew service or launchd
    if [[ "$OS" == "macos" ]]; then
        brew services start ollama 2>/dev/null || true
        sleep 2
        if curl -s --max-time 5 http://localhost:11434/api/tags &>/dev/null; then
            ok "Ollama started via brew services"
            return 0
        fi
    fi

    # Fallback: start manually in background
    warn "Starting Ollama manually in background..."
    nohup ollama serve > "${SCRIPT_DIR}/ollama_serve.log" 2>&1 &
    local pid=$!
    for i in $(seq 1 15); do
        if curl -s --max-time 2 http://localhost:11434/api/tags &>/dev/null; then
            ok "Ollama started (PID: ${pid})"
            return 0
        fi
        sleep 1
    done
    die "Failed to start Ollama. Check ${SCRIPT_DIR}/ollama_serve.log"
}

ollama_pin_gpu() {
    local gpu_uuid="$1"
    local gpu_idx="$2"

    # Detect correct CUDA library for Ollama
    local ollama_lib=""
    if $HAS_NVIDIA; then
        local cuda_major="${CUDA_VERSION%%.*}"
        for candidate in "/usr/local/lib/ollama/cuda_v${cuda_major}" "/usr/local/lib/ollama/cuda_v12"; do
            if [[ -d "$candidate" ]]; then
                ollama_lib="$(basename "$candidate")"
                break
            fi
        done
    fi

    if $HAS_SYSTEMD && [[ -f /etc/systemd/system/ollama.service ]]; then
        info "Configuring Ollama systemd service for GPU ${gpu_idx}..."

        # Clean existing GPU config lines
        sudo sed -i '/^Environment="CUDA_VISIBLE_DEVICES/d' /etc/systemd/system/ollama.service 2>/dev/null || true
        sudo sed -i '/^Environment="OLLAMA_LLM_LIBRARY/d' /etc/systemd/system/ollama.service 2>/dev/null || true
        sudo sed -i '/^Environment="ROCR_VISIBLE_DEVICES/d' /etc/systemd/system/ollama.service 2>/dev/null || true
        sudo sed -i '/^Environment="HIP_VISIBLE_DEVICES/d' /etc/systemd/system/ollama.service 2>/dev/null || true

        # Find insertion point
        local insert_pattern="ExecStart="
        grep -q '^Environment="PATH=' /etc/systemd/system/ollama.service && insert_pattern='Environment="PATH='

        if $HAS_NVIDIA; then
            # Use GPU UUID — numeric indices are unreliable across reboots.
            # OLLAMA_LLM_LIBRARY is required — without it Ollama falls back to
            # Vulkan and ignores CUDA_VISIBLE_DEVICES entirely (known bug).
            sudo sed -i "/${insert_pattern}/a Environment=\"CUDA_VISIBLE_DEVICES=${gpu_uuid}\"" \
                /etc/systemd/system/ollama.service
            if [[ -n "$ollama_lib" ]]; then
                sudo sed -i "/CUDA_VISIBLE_DEVICES/a Environment=\"OLLAMA_LLM_LIBRARY=${ollama_lib}\"" \
                    /etc/systemd/system/ollama.service
            fi
        elif $HAS_AMD; then
            sudo sed -i "/${insert_pattern}/a Environment=\"ROCR_VISIBLE_DEVICES=${gpu_idx}\"" \
                /etc/systemd/system/ollama.service
            sudo sed -i "/${insert_pattern}/a Environment=\"HIP_VISIBLE_DEVICES=${gpu_idx}\"" \
                /etc/systemd/system/ollama.service
        fi

        sudo systemctl daemon-reload
        sudo systemctl restart ollama
        sleep 3

        if systemctl is-active ollama &>/dev/null; then
            ok "Ollama restarted, pinned to GPU ${gpu_idx}"
        else
            warn "Ollama may have failed to restart. Checking logs..."
            sudo journalctl -u ollama --no-pager -n 5 2>/dev/null || true
        fi
    else
        # No systemd — print env vars for manual use
        warn "No systemd detected. Set these env vars before 'ollama serve':"
        if $HAS_NVIDIA; then
            echo "  export CUDA_VISIBLE_DEVICES=\"${gpu_uuid}\""
            [[ -n "$ollama_lib" ]] && echo "  export OLLAMA_LLM_LIBRARY=\"${ollama_lib}\""
        elif $HAS_AMD; then
            echo "  export ROCR_VISIBLE_DEVICES=${gpu_idx}"
            echo "  export HIP_VISIBLE_DEVICES=${gpu_idx}"
        fi

        # Write a launcher script as fallback
        local launcher="${SCRIPT_DIR}/start_ollama.sh"
        {
            echo "#!/usr/bin/env bash"
            echo "# Auto-generated Ollama launcher — pinned to GPU ${gpu_idx}"
            if $HAS_NVIDIA; then
                echo "export CUDA_VISIBLE_DEVICES=\"${gpu_uuid}\""
                [[ -n "$ollama_lib" ]] && echo "export OLLAMA_LLM_LIBRARY=\"${ollama_lib}\""
            elif $HAS_AMD; then
                echo "export ROCR_VISIBLE_DEVICES=${gpu_idx}"
                echo "export HIP_VISIBLE_DEVICES=${gpu_idx}"
            fi
            echo "exec ollama serve"
        } > "$launcher"
        chmod +x "$launcher"
        ok "Launcher script: ${launcher}"
    fi
}

ollama_pull_and_warmup() {
    local model_tag="$1"
    info "Pulling ${model_tag} (this may take a while on first run)..."

    # If we installed via conda, run pull within the conda environment
    local pull_output
    local pull_exit_code=0
    if [[ "$USED_CONDA_INSTALL" == "true" ]]; then
        # Use 'conda run' which properly activates the environment
        pull_output=$(${PKG_MGR_CMD} run -n ollama ollama pull "$model_tag" 2>&1) || pull_exit_code=$?
        if [[ $pull_exit_code -ne 0 && -z "$pull_output" ]]; then
            err "Failed to run ollama pull in conda environment. Trying direct pull..."
            # Fall back to using system ollama if conda pull fails
            pull_output=$(ollama pull "$model_tag" 2>&1) || pull_exit_code=$?
        fi
    else
        pull_output=$(ollama pull "$model_tag" 2>&1) || pull_exit_code=$?
    fi

    # Check if Ollama version is too old
    if echo "$pull_output" | grep -q "requires a newer version of Ollama"; then
        warn "Ollama version is outdated. Model requires a newer version."
        warn "Try upgrading Ollama manually or use a pre-built binary version."
        echo ""
        echo "To upgrade Ollama:"
        echo "  1. Download from: https://github.com/ollama/ollama/releases"
        echo "  2. Or use your package manager:"
        echo "     - Ubuntu/Debian: apt-get install ollama"
        echo "     - RHEL/CentOS: dnf install ollama"
        echo "     - macOS: brew install ollama"
        echo ""
        echo "After upgrading, run: ./setup.sh again"
        die "Please upgrade Ollama to support this model"
    else
        # Print pull output (normally empty on success)
        [[ -n "$pull_output" ]] && echo "$pull_output"
    fi

    # Verify model was actually pulled
    # Try multiple times since Ollama may be starting up
    local max_retries=3
    local retry=0
    while (( retry < max_retries )); do
        if ollama list 2>/dev/null | grep -q "^${model_tag%:*}"; then
            ok "Model pulled: ${model_tag}"
            return 0
        fi
        retry=$((retry + 1))
        if (( retry < max_retries )); then
            warn "Model not found yet (attempt $retry/$max_retries). Waiting..."
            sleep 5
        fi
    done

    # If we still don't have it, show error
    err "Model pull failed. Error output:"
    echo "$pull_output"
    die "Unable to pull ${model_tag}"
    ok "Model pulled: ${model_tag}"

    info "Warming up model (first load is slow)..."
    local resp
    resp=$(curl -s --max-time 180 http://localhost:11434/api/chat \
        -d "{\"model\":\"${model_tag}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"stream\":false}" 2>&1)

    if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['message']['content'][:50])" 2>/dev/null; then
        ok "Model loaded and responding"
    else
        warn "Warmup response was unexpected. Model may still be loading."
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# PROVIDER: vLLM
# ═════════════════════════════════════════════════════════════════════════════
vllm_install() {
    if ! $HAS_GPU || $HAS_METAL; then
        die "vLLM requires an NVIDIA or AMD GPU. Use Ollama for CPU or Apple Silicon."
    fi

    local venv_dir="${HOME}/vllm-env"
    if [[ -d "$venv_dir" ]] && "${venv_dir}/bin/python3" -c "import vllm" &>/dev/null; then
        ok "vLLM already installed in ${venv_dir}"
        return 0
    fi

    info "Installing vLLM in ${venv_dir}..."
    if command -v uv &>/dev/null; then
        uv venv "$venv_dir" 2>/dev/null
        (source "${venv_dir}/bin/activate" && uv pip install vllm --torch-backend=auto)
    elif command -v python3 &>/dev/null; then
        python3 -m venv "$venv_dir"
        (source "${venv_dir}/bin/activate" && pip install vllm)
    else
        die "Python 3.10+ required. Install it first."
    fi
    ok "vLLM installed in ${venv_dir}"
}

vllm_create_launcher() {
    local model_hf="$1" model_name="$2" gpu_uuid="$3" gpu_idx="$4"
    local venv_dir="${HOME}/vllm-env"
    local launcher="${SCRIPT_DIR}/start_vllm.sh"

    local cuda_env=""
    if $HAS_NVIDIA && [[ -n "$gpu_uuid" ]]; then
        cuda_env="export CUDA_VISIBLE_DEVICES=\"${gpu_uuid}\""
    elif $HAS_AMD && [[ -n "$gpu_idx" ]]; then
        cuda_env="export ROCR_VISIBLE_DEVICES=${gpu_idx}"
    fi

    cat > "$launcher" << VEOF
#!/usr/bin/env bash
set -euo pipefail
# Auto-generated vLLM launcher — GPU ${gpu_idx}
source "${venv_dir}/bin/activate"
${cuda_env}
echo "Starting vLLM..."
echo "  Model:    ${model_hf}"
echo "  GPU:      ${gpu_idx}"
echo "  API:      http://localhost:8000/v1"
echo ""
exec vllm serve "${model_hf}" \\
    --port 8000 --host 0.0.0.0 \\
    --served-model-name "${model_name}" \\
    --tensor-parallel-size 1 \\
    --gpu-memory-utilization 0.90 \\
    --max-model-len 32768
VEOF
    chmod +x "$launcher"
    ok "vLLM launcher: ${launcher}"

    # Optionally create a systemd service
    if $HAS_SYSTEMD && prompt_yn "Create a systemd service for vLLM (auto-start on boot)?"; then
        sudo tee /etc/systemd/system/vllm.service > /dev/null << SVCEOF
[Unit]
Description=vLLM Model Server
After=network-online.target

[Service]
Type=simple
ExecStart=${launcher}
User=$(whoami)
Restart=on-failure
RestartSec=10
Environment="HOME=${HOME}"

[Install]
WantedBy=multi-user.target
SVCEOF
        sudo systemctl daemon-reload
        sudo systemctl enable vllm
        ok "Systemd service created: vllm.service"
        if prompt_yn "Start vLLM now?"; then
            sudo systemctl start vllm
            info "Waiting for vLLM to be ready (may take minutes for first download)..."
            for i in $(seq 1 120); do
                if curl -s --max-time 3 http://localhost:8000/health &>/dev/null; then
                    ok "vLLM is ready!"
                    return 0
                fi
                sleep 5
                printf "\r  Waiting... %ds" $((i * 5))
            done
            echo ""
            warn "vLLM may still be downloading. Check: journalctl -u vllm -f"
        fi
    else
        echo ""
        echo -e "${YELLOW}Start vLLM manually before using OpenCode:${NC}"
        echo "  ${launcher}"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# OPENCODE
# ═════════════════════════════════════════════════════════════════════════════
opencode_install() {
    local bin=""

    # Check if already installed
    for candidate in \
        "$(command -v opencode 2>/dev/null || true)" \
        "${HOME}/.opencode/bin/opencode" \
        "${HOME}/.local/bin/opencode" \
        "/usr/local/bin/opencode"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            bin="$candidate"
            break
        fi
    done

    if [[ -n "$bin" ]]; then
        ok "OpenCode already installed: ${bin} ($($bin --version 2>/dev/null || echo '?'))"
        OPENCODE_BIN="$bin"
        return 0
    fi

    info "Installing OpenCode..."

    # Try official installer first
    if curl -fsSL https://opencode.ai/install 2>/dev/null | sh 2>/dev/null; then
        : # ok
    # Try brew on macOS
    elif [[ "$OS" == "macos" && "$PKG_MGR" == "brew" ]]; then
        brew install anomalyco/tap/opencode 2>/dev/null || true
    # Try npm
    elif command -v npm &>/dev/null; then
        npm i -g opencode-ai@latest 2>/dev/null || \
        npm i --prefix "${HOME}/.local" opencode-ai@latest 2>/dev/null || true
    fi

    # Find it again
    for candidate in \
        "$(command -v opencode 2>/dev/null || true)" \
        "${HOME}/.opencode/bin/opencode" \
        "${HOME}/.local/bin/opencode" \
        "/usr/local/bin/opencode"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            bin="$candidate"
            break
        fi
    done

    if [[ -z "$bin" ]]; then
        die "Could not install OpenCode. Install manually: curl -fsSL https://opencode.ai/install | sh"
    fi

    OPENCODE_BIN="$bin"
    ok "OpenCode installed: ${OPENCODE_BIN}"

    # Add to PATH if not already there
    local oc_dir
    oc_dir=$(dirname "$OPENCODE_BIN")
    if ! echo "$PATH" | tr ':' '\n' | grep -qxF "$oc_dir"; then
        local rc="${HOME}/.bashrc"
        [[ -f "${HOME}/.zshrc" ]] && rc="${HOME}/.zshrc"
        if ! grep -qF "$oc_dir" "$rc" 2>/dev/null; then
            echo "export PATH=\"${oc_dir}:\$PATH\"" >> "$rc"
            info "Added ${oc_dir} to PATH in ${rc}"
        fi
        export PATH="${oc_dir}:${PATH}"
    fi
}

opencode_configure() {
    local project_dir="$1" provider_key="$2" api_base="$3" model_string="$4"
    local config_file="${project_dir}/opencode.json"

    # Backup existing config
    if [[ -f "$config_file" ]]; then
        local backup
        backup="${config_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup"
        info "Existing config backed up to: ${backup}"
    fi

    # Write config
    cat > "$config_file" << CFGEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "${provider_key}": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "${api_base}"
      }
    }
  },
  "model": "${model_string}"
}
CFGEOF
    ok "Config written: ${config_file}"

    # Write auth (placeholder for local providers)
    local auth_dir="${HOME}/.local/share/opencode"
    mkdir -p "$auth_dir"
    cat > "${auth_dir}/auth.json" << AEOF
{
  "${provider_key}": {
    "type": "api_key",
    "token": "${provider_key}"
  }
}
AEOF
    ok "Auth written: ${auth_dir}/auth.json"
}

# ═════════════════════════════════════════════════════════════════════════════
# PORT CHECKS
# ═════════════════════════════════════════════════════════════════════════════
check_port() {
    local port=$1 name=$2
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            local pid
            pid=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1 || echo "?")
            warn "Port ${port} is already in use (PID: ${pid}). ${name} may conflict."
            return 1
        fi
    elif command -v lsof &>/dev/null; then
        if lsof -i ":${port}" &>/dev/null; then
            warn "Port ${port} is already in use. ${name} may conflict."
            return 1
        fi
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# VERIFY
# ═════════════════════════════════════════════════════════════════════════════
verify_setup() {
    local api_base="$1" model_tag="$2" provider_key="$3"
    header "Verification"

    info "Testing API endpoint: ${api_base}/chat/completions"
    local resp
    resp=$(curl -s --max-time 60 "${api_base}/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${provider_key}" \
        -d "{
            \"model\": \"${model_tag}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Reply with just the word OK\"}],
            \"stream\": false
        }" 2>&1)

    if echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg = d.get('choices', [{}])[0].get('message', {}).get('content', '')
print(f'  Model response: {msg.strip()[:80]}')
" 2>/dev/null; then
        ok "API working, model responding"
    else
        warn "Unexpected API response. The model may still be loading."
        echo "  Response: ${resp:0:200}"
    fi

    if $HAS_GPU && $HAS_NVIDIA; then
        echo ""
        info "GPU memory usage:"
        nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# STATUS COMMAND
# ═════════════════════════════════════════════════════════════════════════════
cmd_status() {
    header "Current Setup Status"

    # Ollama
    echo -e "${BOLD}Ollama:${NC}"
    if command -v ollama &>/dev/null; then
        echo "  Installed: $(ollama --version 2>/dev/null)"
        if curl -s --max-time 3 http://localhost:11434/api/tags &>/dev/null; then
            echo -e "  Status: ${GREEN}running${NC}"
            echo "  Models:"
            ollama list 2>/dev/null | sed 's/^/    /'
        else
            echo -e "  Status: ${RED}not running${NC}"
        fi
    else
        echo -e "  ${YELLOW}Not installed${NC}"
    fi

    # vLLM
    echo ""
    echo -e "${BOLD}vLLM:${NC}"
    if [[ -d "${HOME}/vllm-env" ]]; then
        echo "  Installed: ${HOME}/vllm-env"
        if curl -s --max-time 3 http://localhost:8000/health &>/dev/null; then
            echo -e "  Status: ${GREEN}running${NC}"
        else
            echo -e "  Status: ${RED}not running${NC}"
        fi
    else
        echo -e "  ${YELLOW}Not installed${NC}"
    fi

    # OpenCode
    echo ""
    echo -e "${BOLD}OpenCode:${NC}"
    local oc
    oc=$(command -v opencode 2>/dev/null || echo "${HOME}/.opencode/bin/opencode")
    if [[ -x "$oc" ]]; then
        echo "  Installed: ${oc} ($($oc --version 2>/dev/null || echo '?'))"
    else
        echo -e "  ${YELLOW}Not installed${NC}"
    fi

    # Config files
    echo ""
    echo -e "${BOLD}Config:${NC}"
    for loc in "${HOME}/.config/opencode/opencode.json" "./opencode.json"; do
        if [[ -f "$loc" ]]; then
            echo "  Found: $(realpath "$loc")"
            cat "$loc" | sed 's/^/    /'
        fi
    done

    # GPUs
    echo ""
    if command -v nvidia-smi &>/dev/null; then
        echo -e "${BOLD}GPUs:${NC}"
        nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader | sed 's/^/  /'
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# UNINSTALL COMMAND
# ═════════════════════════════════════════════════════════════════════════════
cmd_uninstall() {
    header "Uninstall"

    echo -e "${YELLOW}This will remove provider configs and OpenCode settings.${NC}"
    echo -e "${YELLOW}Model files are large — you can choose to keep them.${NC}"
    echo ""

    if ! prompt_yn "Proceed with uninstall?" "n"; then
        echo "Cancelled."
        exit 0
    fi

    # Stop services
    if $HAS_SYSTEMD; then
        sudo systemctl stop ollama 2>/dev/null || true
        sudo systemctl stop vllm 2>/dev/null || true
    fi

    # Remove GPU pinning from Ollama service
    if [[ -f /etc/systemd/system/ollama.service ]]; then
        sudo sed -i '/^Environment="CUDA_VISIBLE_DEVICES/d' /etc/systemd/system/ollama.service 2>/dev/null || true
        sudo sed -i '/^Environment="OLLAMA_LLM_LIBRARY/d' /etc/systemd/system/ollama.service 2>/dev/null || true
        sudo sed -i '/^Environment="ROCR_VISIBLE_DEVICES/d' /etc/systemd/system/ollama.service 2>/dev/null || true
        sudo sed -i '/^Environment="HIP_VISIBLE_DEVICES/d' /etc/systemd/system/ollama.service 2>/dev/null || true
        sudo systemctl daemon-reload 2>/dev/null || true
        ok "Cleaned Ollama systemd config"
    fi

    # Remove vLLM service
    if [[ -f /etc/systemd/system/vllm.service ]]; then
        sudo systemctl disable vllm 2>/dev/null || true
        sudo rm /etc/systemd/system/vllm.service
        sudo systemctl daemon-reload 2>/dev/null || true
        ok "Removed vLLM systemd service"
    fi

    # Remove OpenCode configs
    for f in "./opencode.json" "${HOME}/.local/share/opencode/auth.json"; do
        [[ -f "$f" ]] && rm -f "$f" && ok "Removed ${f}"
    done

    # Remove generated scripts
    for f in "${SCRIPT_DIR}/start_vllm.sh" "${SCRIPT_DIR}/start_ollama.sh"; do
        [[ -f "$f" ]] && rm -f "$f" && ok "Removed ${f}"
    done

    # Optional: remove vLLM venv
    if [[ -d "${HOME}/vllm-env" ]]; then
        if prompt_yn "Remove vLLM virtual environment (~2-5GB)?"; then
            rm -rf "${HOME}/vllm-env"
            ok "Removed ${HOME}/vllm-env"
        fi
    fi

    # Optional: remove Ollama models
    if command -v ollama &>/dev/null; then
        local models
        models=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')
        if [[ -n "$models" ]]; then
            echo ""
            echo "Installed Ollama models:"
            echo "$models" | sed 's/^/  /'
            if prompt_yn "Remove all Ollama models (frees disk space)?" "n"; then
                while IFS= read -r model; do
                    ollama rm "$model" 2>/dev/null && ok "Removed model: ${model}"
                done <<< "$models"
            fi
        fi
    fi

    ok "Uninstall complete. Ollama and OpenCode binaries were kept (remove manually if wanted)."
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN SETUP FLOW
# ═════════════════════════════════════════════════════════════════════════════
cmd_setup() {
    # Start logging
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "${BOLD}local-llm-expert v${VERSION}${NC}"
    echo "Log: ${LOG_FILE}"

    # ── Phase 1: Detect system ────────────────────────────────────────────
    detect_system
    print_system_info
    init_models

    # ── Disk space gate ───────────────────────────────────────────────────
    if (( FREE_DISK_MB < 5000 )); then
        die "Less than 5GB free disk space ($((FREE_DISK_MB / 1024))GB). Free up space first."
    fi

    # ── Phase 2: Choose provider ──────────────────────────────────────────
    header "Choose Provider"

    declare -a provider_opts=()
    provider_opts+=("Ollama   — Easiest setup, all platforms, recommended")
    if $HAS_GPU && ! $HAS_METAL; then
        provider_opts+=("vLLM     — Best throughput, NVIDIA/AMD only, production-grade")
    fi
    provider_opts+=("LM Studio — GUI app, all platforms (install from lmstudio.ai)")

    prompt_choice "Which inference provider?" "${provider_opts[@]}"
    local pidx=$CHOICE_RESULT

    # Map choice back to provider name (since vLLM may be absent)
    PROVIDER=""
    case "${provider_opts[$pidx]}" in
        Ollama*)    PROVIDER="ollama" ;;
        vLLM*)      PROVIDER="vllm" ;;
        *Studio*)   PROVIDER="lmstudio" ;;
    esac
    ok "Provider: ${PROVIDER}"

    # ── Phase 3: Choose model ─────────────────────────────────────────────
    header "Choose Model"

    # Compute available memory for model selection
    local avail_vram=0
    if $HAS_GPU; then
        for v in "${GPU_VRAM_MB[@]}"; do
            (( v > avail_vram )) && avail_vram=$v
        done
        $HAS_METAL && avail_vram=$((TOTAL_RAM_MB * 70 / 100))  # ~70% of unified memory
        echo -e "Available VRAM for models: ${BOLD}$((avail_vram / 1024)) GB${NC}"
    else
        echo -e "${YELLOW}No GPU — showing CPU-compatible models only.${NC}"
        echo -e "Available RAM: ${BOLD}$((TOTAL_RAM_MB / 1024)) GB${NC}"
    fi
    echo ""

    # Filter models that fit
    declare -a fit_indices=()
    for i in "${!ALL_MODELS[@]}"; do
        parse_model "$i"
        # CPU-only: show only cpu tier
        if ! $HAS_GPU && [[ "$MODEL_TIER" != "cpu" ]]; then
            continue
        fi
        # GPU: skip cpu tier, check VRAM + disk
        if $HAS_GPU; then
            [[ "$MODEL_TIER" == "cpu" ]] && continue
            (( MODEL_MIN_VRAM > avail_vram )) && continue
        fi
        # Disk check
        (( MODEL_MIN_DISK > FREE_DISK_MB )) && continue
        fit_indices+=("$i")
    done

    if (( ${#fit_indices[@]} == 0 )); then
        die "No models fit your hardware (VRAM: $((avail_vram/1024))GB, Disk: $((FREE_DISK_MB/1024))GB). Free up resources."
    fi

    declare -a model_choices=()
    for idx in "${fit_indices[@]}"; do
        parse_model "$idx"
        model_choices+=("${MODEL_NAME}  — ${MODEL_DESC}")
    done
    prompt_choice "Select a model:" "${model_choices[@]}"
    local midx=${fit_indices[$CHOICE_RESULT]}
    parse_model "$midx"

    ok "Model: ${MODEL_NAME}"
    info "Ollama tag: ${MODEL_OLLAMA} | HF: ${MODEL_HF}"
    info "Requires: ~$((MODEL_MIN_VRAM / 1024))GB VRAM, ~$((MODEL_MIN_DISK / 1024))GB disk"

    # ── Phase 4: Choose GPU ───────────────────────────────────────────────
    SELECTED_GPU_IDX=""
    SELECTED_GPU_UUID=""

    if $HAS_GPU && (( GPU_COUNT > 1 )) && ! $HAS_METAL; then
        header "Select GPU"
        echo -e "${BOLD}Current GPU utilization:${NC}"
        echo ""
        for i in $(seq 0 $((GPU_COUNT - 1))); do
            local status="${GREEN}free${NC}"
            (( GPU_MEM_USED_MB[$i] > 500 )) && status="${YELLOW}in use (${GPU_MEM_USED_MB[$i]}MB)${NC}"
            printf "  GPU %-3s  %-28s  %sGB / %sGB  %b\n" \
                "$i" "${GPU_NAMES[$i]}" \
                "$((GPU_MEM_USED_MB[$i] / 1024))" "$((GPU_VRAM_MB[$i] / 1024))" \
                "$status"
        done
        echo ""

        declare -a gpu_choices=()
        for i in $(seq 0 $((GPU_COUNT - 1))); do
            gpu_choices+=("GPU ${i} — ${GPU_NAMES[$i]}, $((GPU_VRAM_MB[$i] / 1024))GB")
        done
        prompt_choice "Which GPU?" "${gpu_choices[@]}"
        SELECTED_GPU_IDX=$CHOICE_RESULT
        SELECTED_GPU_UUID="${GPU_UUIDS[$SELECTED_GPU_IDX]}"
        ok "GPU ${SELECTED_GPU_IDX} selected"

    elif $HAS_GPU && (( GPU_COUNT == 1 )) && ! $HAS_METAL; then
        SELECTED_GPU_IDX=0
        SELECTED_GPU_UUID="${GPU_UUIDS[0]}"
        info "Single GPU detected — using GPU 0"
    fi

    # ── Phase 5: Config location ─────────────────────────────────────────
    header "Config Location"

    local global_dir="${HOME}/.config/opencode"
    echo -e "OpenCode looks for ${BOLD}opencode.json${NC} in two places (in order):"
    echo -e "  1. ${BOLD}Current project directory${NC}  — per-project override"
    echo -e "  2. ${BOLD}${global_dir}/${NC}             — global default (works everywhere)"
    echo ""

    prompt_choice "Where should the config go?" \
        "Global (recommended) — works from any directory" \
        "Current directory (${PWD}) — only works when you cd here"
    case $CHOICE_RESULT in
        0) PROJECT_DIR="$global_dir" ;;
        1) PROJECT_DIR="$PWD" ;;
    esac
    mkdir -p "$PROJECT_DIR"

    # ── Phase 6: Check ports ──────────────────────────────────────────────
    header "Pre-flight Checks"

    case "$PROVIDER" in
        ollama)   check_port 11434 "Ollama" || true ;;
        vllm)     check_port 8000  "vLLM"   || true ;;
        lmstudio) check_port 1234  "LM Studio" || true ;;
    esac

    # ── Phase 7: Install and configure ────────────────────────────────────
    header "Installing ${PROVIDER}"

    case "$PROVIDER" in
        ollama)
            ollama_install
            ollama_ensure_running

            # Pin GPU if multi-GPU
            if [[ -n "$SELECTED_GPU_UUID" ]]; then
                ollama_pin_gpu "$SELECTED_GPU_UUID" "$SELECTED_GPU_IDX"
                ollama_ensure_running
            fi

            ollama_pull_and_warmup "$MODEL_OLLAMA"

            API_BASE="http://localhost:11434/v1"
            PROVIDER_KEY="ollama"
            MODEL_STRING="ollama:${MODEL_OLLAMA}"
            ;;

        vllm)
            vllm_install
            vllm_create_launcher "$MODEL_HF" "${MODEL_OLLAMA%%:*}" \
                "${SELECTED_GPU_UUID:-}" "${SELECTED_GPU_IDX:-0}"

            API_BASE="http://localhost:8000/v1"
            PROVIDER_KEY="vllm"
            MODEL_STRING="vllm:${MODEL_OLLAMA%%:*}"
            ;;

        lmstudio)
            echo -e "${BOLD}LM Studio Setup:${NC}"
            echo "  1. Download from https://lmstudio.ai/download"
            echo "  2. Search for and download: ${MODEL_HF}"
            echo "  3. Go to Developer tab → Start Server (port 1234)"
            echo ""
            read -rp "$(echo -e "${BOLD}Press Enter when LM Studio is running...${NC}")"

            API_BASE="http://localhost:1234/v1"
            PROVIDER_KEY="lmstudio"
            MODEL_STRING="lmstudio:${MODEL_OLLAMA%%:*}"
            ;;
    esac

    # ── Phase 8: Install OpenCode ─────────────────────────────────────────
    header "Installing OpenCode"
    opencode_install

    # ── Phase 9: Configure OpenCode ───────────────────────────────────────
    header "Configuring OpenCode"
    opencode_configure "$PROJECT_DIR" "$PROVIDER_KEY" "$API_BASE" "$MODEL_STRING"

    # ── Phase 10: Verify ──────────────────────────────────────────────────
    if [[ "$PROVIDER" != "vllm" ]] || curl -s --max-time 3 http://localhost:8000/health &>/dev/null; then
        verify_setup "$API_BASE" "$MODEL_OLLAMA" "$PROVIDER_KEY"
    else
        warn "Skipping verification — vLLM is not running yet. Start it first."
    fi

    # ── Done ──────────────────────────────────────────────────────────────
    header "Setup Complete!"
    echo -e "  ${BOLD}Provider:${NC}  ${PROVIDER}"
    echo -e "  ${BOLD}Model:${NC}     ${MODEL_NAME}"
    if [[ -n "$SELECTED_GPU_IDX" ]]; then
        echo -e "  ${BOLD}GPU:${NC}       GPU ${SELECTED_GPU_IDX} (${GPU_NAMES[$SELECTED_GPU_IDX]})"
    fi
    echo -e "  ${BOLD}API:${NC}       ${API_BASE}"
    echo -e "  ${BOLD}Config:${NC}    ${PROJECT_DIR}/opencode.json"
    echo ""
    echo -e "${BOLD}To start:${NC}"
    if [[ "$PROJECT_DIR" == "${HOME}/.config/opencode" ]]; then
        echo "  cd your-project && opencode    # works from any directory"
    else
        echo "  cd ${PROJECT_DIR}"
        echo "  opencode"
    fi

    if [[ "$PROVIDER" == "ollama" && "$USED_CONDA_INSTALL" == "true" ]]; then
        echo ""
        echo -e "${BOLD}To restart Ollama next time:${NC}"
        echo "  conda activate ollama  (or: mamba activate ollama)"
        echo "  ollama serve"
    fi
    echo ""
    [[ "$PROVIDER" == "vllm" ]] && echo -e "${YELLOW}Start vLLM first: ${SCRIPT_DIR}/start_vllm.sh${NC}"
    [[ "$PROVIDER" == "lmstudio" ]] && echo -e "${YELLOW}Keep LM Studio server running.${NC}"
    echo ""
    echo "Log: ${LOG_FILE}"
}

# ═════════════════════════════════════════════════════════════════════════════
# HELP
# ═════════════════════════════════════════════════════════════════════════════
cmd_help() {
    cat << 'HELPEOF'
local-llm-expert — One-stop local LLM + OpenCode setup

USAGE:
  ./setup.sh              Interactive setup wizard
  ./setup.sh --status     Show what's currently installed and running
  ./setup.sh --uninstall  Remove configs, services, and optionally models
  ./setup.sh --help       This help message

SUPPORTED PLATFORMS:
  Linux   — NVIDIA (CUDA), AMD (ROCm), CPU-only
  macOS   — Apple Silicon (Metal), Intel (CPU-only)
  WSL2    — NVIDIA GPU passthrough

PROVIDERS:
  Ollama     All platforms, easiest setup
  vLLM       NVIDIA/AMD, best throughput
  LM Studio  All platforms, GUI app

MODELS (auto-filtered by your hardware):
  Large  (48GB+)  Qwen3-Coder-Next 80B
  Medium (16-24GB) Qwen3.6-27B, Qwen3-Coder-30B, Qwen2.5-Coder-32B
  Small  (8-12GB)  Qwen2.5-Coder-14B/7B, DeepSeek-R1-7B/14B
  CPU              Qwen3.8-27B, Qwen3.6-27B, Qwen2.5-Coder-7B, DeepSeek-R1-7B

KNOWN WORKAROUNDS APPLIED:
  - Ollama ignores CUDA_VISIBLE_DEVICES without OLLAMA_LLM_LIBRARY set
    (bug: github.com/ollama/ollama/issues/9722). Script detects CUDA
    version and sets the correct library path automatically.
  - GPU UUIDs used instead of numeric indices for reliable pinning.
  - OpenCode auth placeholder for local providers (no real key needed).

HELPEOF
}

# ═════════════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═════════════════════════════════════════════════════════════════════════════
main() {
    case "${1:-}" in
        --help|-h)      cmd_help ;;
        --status|-s)    detect_system; cmd_status ;;
        --uninstall|-u) detect_system; cmd_uninstall ;;
        "")             cmd_setup ;;
        *)              err "Unknown option: $1"; cmd_help; exit 1 ;;
    esac
}

main "$@"
