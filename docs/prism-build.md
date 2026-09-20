# Prism-ML Builds

This repository builds against the Prism-ML llama.cpp fork by default:

```text
Repository: https://github.com/Mintplex-Labs/prism-ml-llama.cpp.git
Commit:     520d93d8a8fd0ac84c0fa92d4568a68b14d495f0
```

The default compatibility settings are:

```text
OLLAMA_LLAMA_CPP_USE_PRISM_COMPAT_PATCH=ON
OLLAMA_LLAMA_CPP_SKIP_LAGUNA_METAL_PATCH=ON
```

The Laguna patch is skipped because the Prism fork does not contain
`src/models/laguna.cpp`.

## Prerequisites

Install CMake 3.22 or newer, Go, a C/C++ compiler, Git, and the backend
SDK required by the target. For ROCm, install the host ROCm/HIP stack and
ensure `cmake`, `hipcc`, and the ROCm libraries are available.

All commands below run from the repository root.

## Default Prism Build

The normal build uses Prism without repository arguments:

```sh
cmake -S . -B build
cmake --build build --parallel 8
./ollama serve
```

To build only the CPU payload:

```sh
cmake -S . -B build-cpu \
  -DOLLAMA_LLAMA_BACKENDS= \
  -DOLLAMA_MLX_BACKENDS=
cmake --build build-cpu --target ollama-local --parallel 8
```

## GPU Targets

GPU builds must select `OLLAMA_LLAMA_BACKENDS` explicitly. Clear MLX when it
is not needed.

### ROCm / HIP

Linux ROCm 7.2:

```sh
cmake -S . -B build-rocm \
  -DOLLAMA_LLAMA_BACKENDS=rocm_v7_2 \
  -DOLLAMA_MLX_BACKENDS= \
  -DAMDGPU_TARGETS=gfx1100 \
  -DCMAKE_PREFIX_PATH=/opt/rocm
cmake --build build-rocm --target ollama-llama-server-rocm_v7_2 --parallel 8
```

Replace `gfx1100` with the GPU architecture needed by the machine. Windows
uses `rocm_v7_1` instead of `rocm_v7_2`.

### CUDA

CUDA 12:

```sh
cmake -S . -B build-cuda12 \
  -DOLLAMA_LLAMA_BACKENDS=cuda_v12 \
  -DOLLAMA_MLX_BACKENDS= \
  -DCMAKE_CUDA_ARCHITECTURES=native
cmake --build build-cuda12 --target ollama-llama-server-cuda_v12 --parallel 8
```

CUDA 13:

```sh
cmake -S . -B build-cuda13 \
  -DOLLAMA_LLAMA_BACKENDS=cuda_v13 \
  -DOLLAMA_MLX_BACKENDS= \
  -DCMAKE_CUDA_ARCHITECTURES=native
cmake --build build-cuda13 --target ollama-llama-server-cuda_v13 --parallel 8
```

### Vulkan

```sh
cmake -S . -B build-vulkan \
  -DOLLAMA_LLAMA_BACKENDS=vulkan \
  -DOLLAMA_MLX_BACKENDS=
cmake --build build-vulkan --target ollama-llama-server-vulkan --parallel 8
```

### JetPack

JetPack targets are ARM64-only:

```sh
cmake -S . -B build-jetpack5 \
  -DOLLAMA_LLAMA_BACKENDS=cuda_jetpack5 \
  -DOLLAMA_MLX_BACKENDS=
cmake --build build-jetpack5 --target ollama-llama-server-cuda_jetpack5 --parallel 8
```

```sh
cmake -S . -B build-jetpack6 \
  -DOLLAMA_LLAMA_BACKENDS=cuda_jetpack6 \
  -DOLLAMA_MLX_BACKENDS=
cmake --build build-jetpack6 --target ollama-llama-server-cuda_jetpack6 --parallel 8
```

### MLX

MLX CUDA 13:

```sh
cmake -S . -B build-mlx \
  -DOLLAMA_LLAMA_BACKENDS= \
  -DOLLAMA_MLX_BACKENDS=cuda_v13
cmake --build build-mlx --target ollama-mlx-backends --parallel 8
```

On macOS arm64, Metal backends are selected automatically. To select them
explicitly:

```sh
cmake -S . -B build-mlx-metal \
  -DOLLAMA_LLAMA_BACKENDS= \
  -DOLLAMA_MLX_BACKENDS='metal_v3;metal_v4'
cmake --build build-mlx-metal --target ollama-mlx-backends --parallel 8
```

## Building Against Upstream llama.cpp

Upstream is no longer the default. Select every upstream override explicitly:

```sh
cmake -S . -B build-upstream \
  -DOLLAMA_LLAMA_CPP_REPOSITORY=https://github.com/ggml-org/llama.cpp.git \
  -DOLLAMA_LLAMA_CPP_GIT_TAG=b10969 \
  -DOLLAMA_LLAMA_CPP_USE_PRISM_COMPAT_PATCH=OFF \
  -DOLLAMA_LLAMA_CPP_SKIP_LAGUNA_METAL_PATCH=OFF
cmake --build build-upstream --parallel 8
```

Use a fresh build directory when switching between Prism and upstream. The
fetched source and CMake cache retain repository and patch-selection state.

## Local Source Overrides

To use a prepared local llama.cpp checkout instead of fetching Git:

```sh
OLLAMA_LLAMA_CPP_SOURCE=/path/to/llama.cpp \
  cmake -S . -B build-local
```

When `OLLAMA_LLAMA_CPP_SOURCE` is set, compatibility patching is intentionally
skipped so the local checkout can be modified independently.

## Docker Builds

Build the normal multi-architecture Linux archives:

```sh
./scripts/build_linux.sh
```

Build the Docker image locally, including the ROCm flavor:

```sh
./scripts/build_docker.sh
```

Build individual Docker payload stages:

```sh
docker buildx build --target publish-llama-server-cpu \
  --platform linux/amd64 --output type=local,dest=dist .

docker buildx build --target publish-llama-server-rocm_v7_2 \
  --platform linux/amd64 --output type=local,dest=dist .
```

The Docker build uses the same checked-in Prism ref through
`LLAMA_CPP_VERSION`. Docker build arguments for toolchain versions include:

```text
ROCMVERSION=7.2.1
CUDA12VERSION=12.8
CUDA13VERSION=13.0
VULKANVERSION=1.4.321.1
CMAKEVERSION=3.31.2
NINJAVERSION=1.12.1
```

## Local Archives and Installer

Linux archives use `.tar.zst`; the installer falls back to `.tgz`. macOS uses
`Ollama-darwin.zip`. After creating `dist/` archives, serve them locally:

```sh
python3 -m http.server 8000 --directory "$PWD/dist"
```

Install from that local server:

```sh
OLLAMA_DOWNLOAD_BASE_URL=http://127.0.0.1:8000 \
  OLLAMA_INSTALL_VARIANT=rocm \
  sh scripts/install.sh
```

The installer menu offers automatic detection, CPU-only, and ROCm. For
noninteractive installs:

```sh
OLLAMA_INSTALL_VARIANT=cpu sh scripts/install.sh
OLLAMA_INSTALL_VARIANT=rocm sh scripts/install.sh
OLLAMA_NONINTERACTIVE=1 sh scripts/install.sh
```

The installer downloads the Ollama payload and bundled backend libraries. It
does not install the host ROCm, CUDA, kernel, or GPU driver stack.

## Docs Branch CI

`.github/workflows/docs-build.yaml` runs on every push to the `docs` branch and
can also be started manually. It builds the default Prism CPU and ROCm targets
in containers, then uploads `.tar.zst` archives, the installer, and SHA-256
files as workflow artifacts for 14 days.

The workflow runs on GitHub-hosted Actions runners. It installs CMake 3.31.2
and the exact Go version declared in `go.mod`, rather than relying on the
container distribution versions.
