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

### Curl-to-local-source-build

The installer can act as a source-build bootstrapper. This clones your Ollama
repository, pulls the pinned Prism source during the Docker build, and runs the
full local Linux packaging pipeline. It does not use GitHub Actions and does
not install files into `/usr/local`.

From any Linux machine with Docker Buildx and permission to access the Docker
daemon:

```sh
curl -fsSL https://raw.githubusercontent.com/xInterlopeRx/ollama/main/scripts/install.sh | \
  sh -s -- --dry-run
```

Artifacts are written to `./dist` in the directory where the command runs.
When run interactively, the source build prompts for automatic/full package
support or ROCm-only before starting Docker. Set `OLLAMA_SOURCE_VARIANT=rocm`
to skip the prompt and build only the ROCm image.
Use these variables to select the source and output location:

```sh
curl -fsSL https://raw.githubusercontent.com/xInterlopeRx/ollama/main/scripts/install.sh | \
  OLLAMA_BUILD_FROM_SOURCE=1 \
  OLLAMA_SOURCE_REPOSITORY=https://github.com/xInterlopeRx/ollama.git \
  OLLAMA_SOURCE_REF=main \
  OLLAMA_BUILD_PLATFORM=linux/amd64 \
  OLLAMA_SOURCE_OUTPUT="$PWD/dist" sh
```

The equivalent explicit form using the flag is:

```sh
curl -fsSL https://raw.githubusercontent.com/xInterlopeRx/ollama/main/scripts/install.sh | \
  OLLAMA_SOURCE_REPOSITORY=https://github.com/xInterlopeRx/ollama.git \
  OLLAMA_SOURCE_REF=main \
  OLLAMA_BUILD_PLATFORM=linux/amd64 \
  sh -s -- --dry-run
```

The build produces the Linux `.tar.zst` bundles generated by
`scripts/build_linux.sh`, including CPU and ROCm payloads for `linux/amd64`.
Set `OLLAMA_BUILD_PLATFORM=linux/arm64` or a comma-separated Buildx platform
list when the host and Docker builder support it.

The source build automatically uses all configured CPUs reported by the host.
To cap parallel compilation on a shared machine, set `OLLAMA_BUILD_JOBS`, for
example `OLLAMA_BUILD_JOBS=8`.

The full archive target builds the CPU, CUDA, Vulkan, MLX, and ROCm matrix and
can require substantial Docker storage. The source clone is temporary; only
the generated archives, installer, and checksum file remain in
`OLLAMA_SOURCE_OUTPUT`.

After a successful dry-run, complete the host installation from those local
archives with:

```sh
curl -fsSL https://raw.githubusercontent.com/xInterlopeRx/ollama/main/scripts/install.sh | \
  sh -s -- --install
```

This uses `./dist` by default, or `OLLAMA_INSTALL_SOURCE_OUTPUT` when the
archives were written elsewhere. It does not download the Ollama payload.

If the Docker builder does not have enough storage for the full Vulkan, CUDA,
MLX, and ROCm matrix, build only the CPU+ROCm image:

```sh
curl -fsSL https://raw.githubusercontent.com/xInterlopeRx/ollama/main/scripts/install.sh | \
  OLLAMA_BUILD_FROM_SOURCE=1 \
  OLLAMA_SOURCE_VARIANT=rocm \
  OLLAMA_BUILD_PLATFORM=linux/amd64 sh
```

This uses the Docker `image-archive` target with `FLAVOR=rocm`, so it avoids
the Vulkan SDK stage that is required by the full `archive` target.

If Docker access is restricted, add the user to the Docker group and start a
new login session:

```sh
sudo usermod -aG docker "$USER"
newgrp docker
```

The bootstrapper also falls back to `sudo docker` when passwordless Docker
access is unavailable but `sudo docker info` works.

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

To use the archives directly without starting a web server, point the
installer at the local `dist` directory:

```sh
OLLAMA_DOWNLOAD_BASE_URL="$PWD/dist" \
  OLLAMA_INSTALL_VARIANT=rocm \
  sh scripts/install.sh
```

The installer also accepts the equivalent `file://` form. It uses a matching
local `.tar.zst` or `.tgz` archive and does not invoke `curl`.

The installer menu offers automatic detection, CPU-only, and ROCm. For
noninteractive installs:

```sh
OLLAMA_INSTALL_VARIANT=cpu sh scripts/install.sh
OLLAMA_INSTALL_VARIANT=rocm sh scripts/install.sh
OLLAMA_NONINTERACTIVE=1 sh scripts/install.sh
```

The installer downloads the Ollama payload and bundled backend libraries. It
does not install the host ROCm, CUDA, kernel, or GPU driver stack.

## GitHub Actions

`.github/workflows/docs-build.yaml` runs on every push to `main` and can also be
started manually. It builds the default Prism CPU and ROCm targets in
containers, then uploads `.tar.zst` archives, the installer, and SHA-256 files
as workflow artifacts for 14 days. The curl source-build mode above is the
local alternative and does not depend on GitHub Actions.

The workflow runs on GitHub-hosted Actions runners. It installs CMake 3.31.2
and the exact Go version declared in `go.mod`, rather than relying on the
container distribution versions.
