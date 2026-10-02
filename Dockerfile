# ============================================================================
# HOT-Step 9000 CPP — Docker Build
# Multi-stage: Engine (CUDA) → UI (Vite) → Server deps → Runtime
#
# Usage:
#   docker compose build                              # Dev build (Blackwell only)
#   docker compose build --build-arg CUDA_ARCHS="75;80;86;89;90;120a"  # Distribution
# ============================================================================

# ── Stage 1: Engine Builder ─────────────────────────────────────────
# CUDA devel image: has nvcc, CUDA headers, cuDNN for building
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04 AS engine-builder

# Local Compose overrides this to Blackwell. The RunPod build uses a wider
# architecture list so one published image can run on different GPU types.
ARG CUDA_ARCHS="120a"
ARG ENABLE_TRT=1
ARG BUILD_JOBS

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake ninja-build build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# TensorRT SDK for DiT/LM acceleration (native TRT API)
RUN if [ "$ENABLE_TRT" = 1 ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        libnvinfer-dev libnvinfer-plugin-dev libnvonnxparsers-dev \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Download ONNX Runtime GPU SDK (Linux x64) for SuperSep stem separation
ARG ORT_VERSION=1.25.1
RUN curl -L "https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-linux-x64-gpu-${ORT_VERSION}.tgz" \
    | tar xz -C /opt \
    && mv "/opt/onnxruntime-linux-x64-gpu-${ORT_VERSION}" /opt/onnxruntime

WORKDIR /build/engine
COPY engine/ .
RUN test -f ggml/CMakeLists.txt && test -f vendor/vst3sdk/CMakeLists.txt || \
    (echo 'Initialize submodules first: git submodule update --init --recursive' >&2; exit 1)

# Build the C++ engine with CUDA + ONNX Runtime
RUN cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CUDA=ON \
    -DGGML_CUDA_GRAPHS=ON \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ALL_VARIANTS=ON \
    -DGGML_BACKEND_DL=ON \
    -DORT_ROOT=/opt/onnxruntime \
    && cmake --build build --config Release -j"${BUILD_JOBS:-$(nproc)}"

# Stage all binaries + shared libs into /staging for clean COPY
RUN mkdir -p /staging/engine \
    && for bin in ace-server ace-synth ace-lm ace-understand ace-train ace-caption ace-midi neural-codec quantize mastering mp3-codec vst-host; do \
         test -f "build/${bin}" || { echo "Missing engine binary: ${bin}" >&2; exit 1; }; \
         cp "build/${bin}" /staging/engine/; \
       done \
    && find build/ -maxdepth 1 -name '*.so' -exec cp {} /staging/engine/ \; \
    && find build/ -maxdepth 1 -name '*.so.*' -exec cp {} /staging/engine/ \; \
    && cp /opt/onnxruntime/lib/libonnxruntime*.so* /staging/engine/


# ── Stage 2: UI Builder ─────────────────────────────────────────────
FROM node:22-slim AS ui-builder

WORKDIR /build/ui
COPY ui/package*.json ./
RUN npm ci
COPY ui/ .
RUN npx vite build


# ── Stage 3: Server Dependencies ────────────────────────────────────
# Build native Node modules against the same Ubuntu/glibc as the runtime.
FROM ubuntu:22.04 AS server-deps
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates python3 make g++ \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build/server
COPY server/package*.json ./
# Install production deps. tsx is in both devDependencies and optionalDependencies,
# but npm --omit=dev deduplicates and skips it. Install explicitly.
RUN npm ci --omit=dev && npm install --no-save --no-package-lock tsx


# ── Stage 4: Runtime ────────────────────────────────────────────────
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04 AS runtime
ARG ENABLE_TRT=1

# Install Node.js 22 (LTS) + runtime libraries the engine needs
# TensorRT 11 runtime libraries for native DiT/LM acceleration (dit-trt.h)
# Note: ORT TRT EP needs TRT 10 (libnvinfer.so.10) but segfaults due to
# version mismatch with CUDA 12.8. ORT falls back to CUDA EP gracefully
# which is fine for the small text/cond encoders. Native TRT 11 handles DiT.
RUN if [ "$ENABLE_TRT" = 1 ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        libnvinfer11 libnvinfer-plugin11 libnvonnxparsers11 \
        && rm -rf /var/lib/apt/lists/*; \
    fi

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates libgomp1 \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Engine binaries + shared libraries (GGML backends, ORT, cuDNN)
COPY --from=engine-builder /staging/engine/ /app/engine/
COPY engine/plugins/ /app/engine/plugins/
COPY plugins/ /app/plugins/

# Server source code + production dependencies
COPY server/ /app/server/
COPY --from=server-deps /build/server/node_modules/ /app/server/node_modules/

# UI static files (production build)
COPY --from=ui-builder /build/ui/dist/ /app/ui/dist/

# Noise samples (small WAV files for noise profiling, baked into image)
COPY noise_samples/ /app/noise_samples/

# Entrypoint script
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# GGML backends + ORT need to find their .so files
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:/app/engine:${LD_LIBRARY_PATH}
ENV NODE_ENV=production
ENV ACESTEPCPP_EXE=/app/engine/ace-server \
    ACESTEPCPP_MODELS=/app/models \
    ACESTEPCPP_ADAPTERS=/app/adapters \
    ACESTEPCPP_HOST=127.0.0.1 \
    ACESTEPCPP_PORT=8085 \
    SERVER_HOST=0.0.0.0 \
    SERVER_PORT=3001 \
    DATA_DIR=/app/server/data

EXPOSE 3001

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3001/api/health >/dev/null || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]

# Build with --target runpod. RunPod mounts persistent storage at /workspace.
FROM runtime AS runpod
ENV HOT_STEP_DATA_ROOT=/workspace \
    ACESTEPCPP_MODELS=/workspace/models \
    ACESTEPCPP_ADAPTERS=/workspace/adapters \
    DATA_DIR=/workspace/data
