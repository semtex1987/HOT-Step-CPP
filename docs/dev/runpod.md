# RunPod Pod template

HOT-Step runs on a RunPod GPU Pod as one container: the Node server serves the UI on port 3001 and starts the C++ engine internally on port 8085. This is a Pod template, not a RunPod Serverless worker. The image contains code, binaries, and built-in Lua plugins. Model weights, generated audio, the SQLite database, adapters, and logs live on the Pod's `/workspace` volume.

## Build the image

Build from a recursive clone on an x86_64 Linux Docker host. On Apple Silicon, use `docker buildx build --platform linux/amd64` with an x86_64 builder; CUDA cross-compilation under emulation is very slow. The `engine/ggml` and `engine/vendor/vst3sdk` submodules must contain files before building.

```sh
git clone --recursive https://github.com/scragnog/HOT-Step-CPP.git
cd HOT-Step-CPP
docker buildx build --platform linux/amd64 --target runpod \
  --build-arg 'CUDA_ARCHS=75-virtual;80-virtual;86-real;89-real;90-real;120a-real' \
  --build-arg ENABLE_TRT=0 \
  -t YOUR_REGISTRY/hot-step-cpp:YOUR_VERSION --load .
```

Use an immutable version tag. `ENABLE_TRT=0` builds the GGML CUDA backend without the optional native TensorRT path; it avoids tying the RunPod image to a particular TensorRT package release. The model files are downloaded in the app's Model Manager after deployment, so they are not included in the image.

For a local GPU smoke test on an x86_64 Docker host:

```sh
docker run --rm --gpus all -p 3001:3001 \
  -v hot-step-workspace:/workspace \
  YOUR_REGISTRY/hot-step-cpp:YOUR_VERSION
curl -f http://localhost:3001/api/health
```

The health response should show an engine status other than `disconnected`. Build and smoke-test before pushing the image. Publishing an image or a RunPod template requires the registry and RunPod account owner's approval.

## Create the RunPod template

Push the verified image to your registry, then use **New Template** in the [RunPod console](https://console.runpod.io/user/templates). Enter these values:

| Setting | Value |
|---|---|
| Compute type | NVIDIA GPU |
| Container image | `YOUR_REGISTRY/hot-step-cpp:YOUR_VERSION` |
| Container start command | Leave blank; the image starts the app |
| HTTP ports | `3001` |
| TCP ports | None required by the app |
| Container disk | At least 20 GB; increase if image size requires it |
| Volume mount path | `/workspace` |
| Volume size | Enough for the model packs and audio you plan to keep; 100 GB is a starting point |

Deploy the template on a GPU supported by the CUDA architectures in the image. Attach a persistent volume at `/workspace`. A [RunPod network volume](https://docs.runpod.io/storage/network-volumes) is preferable if you expect to replace Pods, because it can be attached to a new Pod in the same data center. RunPod exposes the app at `https://<pod-id>-3001.proxy.runpod.net` when HTTP port 3001 is enabled. [RunPod's template guide](https://docs.runpod.io/pods/templates/create-custom-template) describes the console fields.

The app itself does not provide user authentication. Treat the HTTP proxy link as access to your library and generation API; use a private access layer before sharing it or exposing sensitive data.

## Persistent layout

The RunPod image links its usual local paths into `/workspace` at startup:

| Volume path | Content |
|---|---|
| `/workspace/models` | GGUF and optional ONNX model files |
| `/workspace/adapters` | LoRA and LoKr adapters |
| `/workspace/data` | SQLite database, generated audio, training data and application state |
| `/workspace/logs` | Per-session server, engine, generation and training logs |

The first launch works without preloaded models, but generation requires a model pack. Open the UI, go to Models, and download a compatible pack. If you already have model files, copy them to `/workspace/models` before starting. The entrypoint reports the number of GGUF files it finds.

Only port 3001 needs an HTTP proxy. The engine listens on loopback inside the container at 8085 and the UI reaches it through the Node server. For startup issues, inspect the Pod logs and `/workspace/logs`.
