# local-llm-expert

One-stop setup script to run a local LLM and wire it to [OpenCode](https://opencode.ai) on any machine.

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/local-llm-expert.git
cd local-llm-expert
chmod +x setup.sh
./setup.sh
```

The wizard detects your hardware, walks you through provider and model selection, installs everything, and verifies the setup end to end.

## What It Does

1. **Detects hardware** — OS, CPU arch, GPU (NVIDIA/AMD/Apple Silicon), VRAM, RAM, disk space
2. **Asks you to pick a provider** — Ollama, vLLM, or LM Studio
3. **Shows models that fit your hardware** — filters by VRAM and disk automatically
4. **Lets you pin to a specific GPU** — with workarounds for known driver bugs
5. **Installs the provider + pulls the model**
6. **Installs and configures OpenCode** — writes `opencode.json` and auth
7. **Verifies everything works** — end-to-end API test

## Supported Platforms

| Platform | GPU | Provider Support |
|----------|-----|-----------------|
| Linux x86_64 | NVIDIA (CUDA) | Ollama, vLLM, LM Studio |
| Linux x86_64 | AMD (ROCm) | Ollama, vLLM |
| Linux x86_64 | CPU only | Ollama, LM Studio |
| macOS arm64 | Apple Silicon (Metal) | Ollama, LM Studio |
| macOS x86_64 | Intel (CPU) | Ollama, LM Studio |
| WSL2 | NVIDIA passthrough | Ollama, vLLM |

## Available Models

Auto-filtered by your hardware. You only see what fits.

| Model | VRAM | Disk | Best For |
|-------|------|------|----------|
| Qwen3-Coder-Next 80B (MoE) | 52 GB | 35 GB | Coding (SWE-bench #1) |
| Qwen3-Next 80B A3B Instruct | 52 GB | 35 GB | General-purpose (80B MoE) |
| Qwen3-Coder-Next 80B (FP8) | 92 GB | 85 GB | Coding (full quality) |
| Qwen3.8-27B | 17 GB | 18 GB | Coding + reasoning (latest) |
| Qwen3.6-27B | 17 GB | 18 GB | General + coding |
| Qwen3-Coder 30B (MoE) | 19 GB | 20 GB | Coding (best under 24GB) |
| Qwen2.5-Coder-32B | 20 GB | 21 GB | Coding (proven) |
| DeepSeek-R1-Distill-32B | 20 GB | 21 GB | Reasoning + research |
| Qwen2.5-Coder-14B | 9 GB | 10 GB | Coding (12-16GB GPU) |
| DeepSeek-R1-Distill-14B | 9 GB | 10 GB | Reasoning |
| Qwen2.5-Coder-7B | 5 GB | 5 GB | Coding (8GB GPU / CPU) |
| DeepSeek-R1-Distill-7B | 5 GB | 5 GB | Reasoning (8GB GPU / CPU) |

CPU-only machines also get Qwen3.8-27B and Qwen3.6-27B as options (~20GB RAM needed, slower but capable).

## Commands

```bash
./setup.sh              # Interactive setup wizard
./setup.sh --status     # Check what's installed and running
./setup.sh --uninstall  # Remove configs, services, models
./setup.sh --help       # Show help
```

## Known Workarounds

The script handles these known issues automatically:

- **Ollama ignores `CUDA_VISIBLE_DEVICES`** without `OLLAMA_LLM_LIBRARY` set ([ollama/ollama#9722](https://github.com/ollama/ollama/issues/9722)). The script detects your CUDA version and sets the correct library path.
- **GPU index mismatch** between `nvidia-smi` and CUDA. The script uses GPU UUIDs instead of numeric indices for reliable pinning.
- **OpenCode auth for local providers** — local servers don't need real API keys, but OpenCode requires a non-empty token. The script writes a placeholder.

## After Setup

```bash
cd your-project-directory
opencode
```

OpenCode will use the local model automatically. All inference stays on your machine.

## Requirements

- bash 4+
- curl
- python3 (for JSON parsing in verification)
- sudo access (for systemd service configuration, optional)

## License

MIT
