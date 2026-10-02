#!/bin/bash
# ============================================================================
# HOT-Step 9000 CPP — Docker Entrypoint
# Verifies GPU access and starts the Node.js server (which spawns ace-server)
# ============================================================================

set -e

# The RunPod target keeps generated data on its persistent /workspace volume.
# The regular runtime target leaves Compose bind mounts in place.
if [ -n "${HOT_STEP_DATA_ROOT:-}" ]; then
    mkdir -p "${HOT_STEP_DATA_ROOT}/models" "${HOT_STEP_DATA_ROOT}/adapters" \
        "${HOT_STEP_DATA_ROOT}/data" "${HOT_STEP_DATA_ROOT}/logs"
    for mapping in \
        "/app/models:${HOT_STEP_DATA_ROOT}/models" \
        "/app/adapters:${HOT_STEP_DATA_ROOT}/adapters" \
        "/app/server/data:${HOT_STEP_DATA_ROOT}/data" \
        "/app/logs:${HOT_STEP_DATA_ROOT}/logs"; do
        link=${mapping%%:*}
        target=${mapping#*:}
        if [ -d "$link" ] && [ ! -L "$link" ]; then
            rmdir "$link" 2>/dev/null || {
                echo "Cannot link non-empty $link to $target" >&2
                exit 1
            }
        fi
        ln -sfn "$target" "$link"
    done
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     HOT-Step 9000 ⚡ Docker             ║"
echo "║    High-Performance Music Generation     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Verify GPU access ───────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
    GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    echo "  GPU:    ${GPU_NAME} (${GPU_MEM})"
    echo "  Driver: ${GPU_DRIVER}"
else
    echo "  ⚠ nvidia-smi not found — GPU may not be available"
    echo "  Check that Docker has GPU access (--gpus=all or deploy.resources in compose)"
fi

# ── Verify engine binary exists ─────────────────────────────────────
if [ -f /app/engine/ace-server ]; then
    echo "  Engine: /app/engine/ace-server ✓"
else
    echo "  ⚠ ace-server binary not found at /app/engine/"
    echo "  The build may have failed — check Docker build logs"
fi

# ── Ensure data directories exist ───────────────────────────────────
mkdir -p /app/models /app/adapters /app/server/data

# ── Check for models ────────────────────────────────────────────────
MODEL_COUNT=$(find /app/models -name '*.gguf' 2>/dev/null | wc -l)
if [ "$MODEL_COUNT" -gt 0 ]; then
    echo "  Models: ${MODEL_COUNT} GGUF file(s) found"
else
    echo "  ⚠ No .gguf models found in /app/models"
    echo "  Download a model pack in the UI or place GGUF files in ${ACESTEPCPP_MODELS:-/app/models}"
fi

echo ""
echo "  Server:  http://localhost:${SERVER_PORT:-3001}"
echo "  Engine:  http://localhost:${ACESTEPCPP_PORT:-8085}"
echo ""
echo "  Starting server..."
echo ""

# ── Start the Node.js server ────────────────────────────────────────
# The server spawns ace-server as a child process automatically.
# Use exec to replace the shell — proper signal handling for graceful shutdown.
cd /app/server
exec node --import tsx/esm src/index.ts
