#!/bin/sh
# This script installs Ollama on Linux and macOS.
# It detects the current operating system architecture and installs the appropriate version of Ollama.

# Wrap script in main function so that a truncated partial download doesn't end
# up executing half a script.
main() {

set -eu

red="$( (/usr/bin/tput bold || :; /usr/bin/tput setaf 1 || :) 2>&-)"
plain="$( (/usr/bin/tput sgr0 || :) 2>&-)"

status() { echo ">>> $*" >&2; }
error() { echo "${red}ERROR:${plain} $*"; exit 1; }
warning() { echo "${red}WARNING:${plain} $*"; }

DRY_RUN=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --install) INSTALL=1 ;;
        *) error "Unknown option: $arg" ;;
    esac
done

if [ "$DRY_RUN" = 1 ] && [ "$INSTALL" = 1 ]; then
    error "Use --dry-run and --install as separate steps."
fi

TEMP_DIR=$(mktemp -d)
CLEANUP_SUDO=
cleanup() {
    if [ -n "$CLEANUP_SUDO" ]; then
        $CLEANUP_SUDO rm -rf "$TEMP_DIR"
    else
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

available() { command -v $1 >/dev/null; }
default_source_output() {
    if [ -n "${HOME:-}" ]; then
        printf '%s/dist\n' "$HOME"
    elif available getent; then
        USER_HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
        if [ -n "$USER_HOME" ]; then
            printf '%s/dist\n' "$USER_HOME"
            return
        fi
        printf '%s/dist\n' "$PWD"
    else
        printf '%s/dist\n' "$PWD"
    fi
}
require() {
    local MISSING=''
    for TOOL in $*; do
        if ! available $TOOL; then
            MISSING="$MISSING $TOOL"
        fi
    done

    echo $MISSING
}

OS="$(uname -s)"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac

build_from_source() {
    if [ "$OS" != "Linux" ]; then
        error "Source builds currently require Linux and Docker Buildx."
    fi
    for TOOL in git docker zstd; do
        if ! available "$TOOL"; then
            error "Source builds require '$TOOL' in PATH."
        fi
    done
    DOCKER_COMMAND=docker
    DOCKER_SUDO=
    if ! docker info >/dev/null 2>&1; then
        if available sudo && sudo docker info >/dev/null 2>&1; then
            DOCKER_USER="${SUDO_USER:-$(id -un)}"
            if getent group docker >/dev/null 2>&1; then
                if ! id -nG "$DOCKER_USER" | tr ' ' '\n' | grep -qx docker; then
                    status "Adding ${DOCKER_USER} to the docker group..."
                    sudo usermod -aG docker "$DOCKER_USER"
                    status "Docker group access will be available after starting a new login session."
                fi
            else
                warning "The docker group does not exist; continuing with sudo docker."
            fi
            DOCKER_SUDO=sudo
        else
            error "Cannot access Docker Buildx. Add your user to the docker group, start Docker, or run this command with sudo."
        fi
    fi
    CLEANUP_SUDO="$DOCKER_SUDO"

    SOURCE_REPOSITORY="${OLLAMA_SOURCE_REPOSITORY:-https://github.com/xInterlopeRx/ollama.git}"
    SOURCE_REF="${OLLAMA_SOURCE_REF:-main}"
    SOURCE_OUTPUT="${OLLAMA_SOURCE_OUTPUT:-$(default_source_output)}"
    SOURCE_PLATFORM="${OLLAMA_BUILD_PLATFORM:-linux/amd64}"
    SOURCE_VARIANT="${OLLAMA_SOURCE_VARIANT:-}"
    if [ -z "$SOURCE_VARIANT" ] && [ -z "${OLLAMA_NONINTERACTIVE:-}" ] && [ -r /dev/tty ]; then
        echo "Select source build variant:" > /dev/tty
        echo "  1) Automatic hardware support (full package matrix)" > /dev/tty
        echo "  2) ROCm only" > /dev/tty
        printf "Choice [1]: " > /dev/tty
        IFS= read -r SOURCE_VARIANT_CHOICE < /dev/tty || SOURCE_VARIANT_CHOICE=1
        case "$SOURCE_VARIANT_CHOICE" in
            2) SOURCE_VARIANT=rocm ;;
            *) SOURCE_VARIANT=full ;;
        esac
    fi
    SOURCE_VARIANT="${SOURCE_VARIANT:-full}"
    case "$SOURCE_VARIANT" in
        full|rocm) ;;
        *) error "Unsupported source build variant: $SOURCE_VARIANT (use full or rocm)" ;;
    esac
    SOURCE_DIR="$TEMP_DIR/ollama-source"

    status "Cloning Ollama source from ${SOURCE_REPOSITORY} (${SOURCE_REF})..."
    git clone --depth 1 --branch "$SOURCE_REF" "$SOURCE_REPOSITORY" "$SOURCE_DIR"
    mkdir -p "$SOURCE_OUTPUT"

    status "Building the ${SOURCE_VARIANT} local Linux payload with Docker Buildx..."
    (
        cd "$SOURCE_DIR"
        if [ "$SOURCE_VARIANT" = rocm ]; then
            DOCKER="$DOCKER_COMMAND" DOCKER_SUDO="$DOCKER_SUDO" PLATFORM="$SOURCE_PLATFORM" \
                OLLAMA_BUILD_TARGET=image-archive OLLAMA_BUILD_FLAVOR=rocm \
                ./scripts/build_linux.sh
        else
            DOCKER="$DOCKER_COMMAND" DOCKER_SUDO="$DOCKER_SUDO" PLATFORM="$SOURCE_PLATFORM" \
                ./scripts/build_linux.sh
        fi
    )

    cp "$SOURCE_DIR"/dist/ollama-linux-*.tar.zst "$SOURCE_OUTPUT/"
    cp "$SOURCE_DIR/scripts/install.sh" "$SOURCE_OUTPUT/install.sh"
    (cd "$SOURCE_OUTPUT" && sha256sum ollama-linux-*.tar.zst install.sh > sha256sum.txt)
    status "Source build complete. Artifacts are in ${SOURCE_OUTPUT}."
}

if [ "$DRY_RUN" = 1 ] || [ "${OLLAMA_BUILD_FROM_SOURCE:-0}" = 1 ]; then
    build_from_source
    exit 0
fi

VER_PARAM="${OLLAMA_VERSION:+?version=$OLLAMA_VERSION}"
OLLAMA_DOWNLOAD_BASE_URL="${OLLAMA_DOWNLOAD_BASE_URL:-https://ollama.com/download}"
if [ "$INSTALL" = 1 ]; then
    OLLAMA_DOWNLOAD_BASE_URL="${OLLAMA_INSTALL_SOURCE_OUTPUT:-${OLLAMA_SOURCE_OUTPUT:-$(default_source_output)}}"
    if [ ! -d "$OLLAMA_DOWNLOAD_BASE_URL" ]; then
        error "Local build output not found: $OLLAMA_DOWNLOAD_BASE_URL"
    fi
    status "Installing from local archives in $OLLAMA_DOWNLOAD_BASE_URL"
fi

###########################################
# macOS
###########################################

if [ "$OS" = "Darwin" ]; then
    NEEDS=$(require curl unzip)
    if [ -n "$NEEDS" ]; then
        status "ERROR: The following tools are required but missing:"
        for NEED in $NEEDS; do
            echo "  - $NEED"
        done
        exit 1
    fi

    DOWNLOAD_URL="${OLLAMA_DOWNLOAD_BASE_URL}/Ollama-darwin.zip${VER_PARAM}"

    if pgrep -x Ollama >/dev/null 2>&1; then
        status "Stopping running Ollama instance..."
        pkill -x Ollama 2>/dev/null || true
        sleep 2
    fi

    if [ -d "/Applications/Ollama.app" ]; then
        status "Removing existing Ollama installation..."
        rm -rf "/Applications/Ollama.app"
    fi

    status "Downloading Ollama for macOS..."
    curl --fail --show-error --location --progress-bar \
        -o "$TEMP_DIR/Ollama-darwin.zip" "$DOWNLOAD_URL"

    status "Installing Ollama to /Applications..."
    unzip -q "$TEMP_DIR/Ollama-darwin.zip" -d "$TEMP_DIR"
    mv "$TEMP_DIR/Ollama.app" "/Applications/"

    if [ ! -L "/usr/local/bin/ollama" ] || [ "$(readlink "/usr/local/bin/ollama")" != "/Applications/Ollama.app/Contents/Resources/ollama" ]; then
        status "Adding 'ollama' command to PATH (may require password)..."
        mkdir -p "/usr/local/bin" 2>/dev/null || sudo mkdir -p "/usr/local/bin"
        ln -sf "/Applications/Ollama.app/Contents/Resources/ollama" "/usr/local/bin/ollama" 2>/dev/null || \
            sudo ln -sf "/Applications/Ollama.app/Contents/Resources/ollama" "/usr/local/bin/ollama"
    fi

    if [ -z "${OLLAMA_NO_START:-}" ]; then
        status "Starting Ollama..."
        open -a Ollama --args hidden
    fi

    status "Install complete. You can now run 'ollama'."
    exit 0
fi

###########################################
# Linux
###########################################

[ "$OS" = "Linux" ] || error 'This script is intended to run on Linux and macOS only.'

IS_WSL2=false

KERN=$(uname -r)
case "$KERN" in
    *icrosoft*WSL2 | *icrosoft*wsl2) IS_WSL2=true;;
    *icrosoft) error "Microsoft WSL1 is not currently supported. Please use WSL2 with 'wsl --set-version <distro> 2'" ;;
    *) ;;
esac

SUDO=
if [ "$(id -u)" -ne 0 ]; then
    # Running as root, no need for sudo
    if ! available sudo; then
        error "This script requires superuser permissions. Please re-run as root."
    fi

    SUDO="sudo"
fi

NEEDS=$(require curl awk grep sed tee xargs)
if [ -n "$NEEDS" ]; then
    status "ERROR: The following tools are required but missing:"
    for NEED in $NEEDS; do
        echo "  - $NEED"
    done
    exit 1
fi

# Function to download and extract with fallback from zst to tgz
download_and_extract() {
    local url_base="$1"
    local dest_dir="$2"
    local filename="$3"

    case "$url_base" in
        file://*) url_base="${url_base#file://}" ;;
    esac

    if [ -d "$url_base" ]; then
        if [ -f "$url_base/${filename}.tar.zst" ]; then
            if ! available zstd; then
                error "This local archive requires zstd for extraction. Please install zstd and try again."
            fi
            status "Using local ${filename}.tar.zst"
            zstd -d -c "$url_base/${filename}.tar.zst" | $SUDO tar -xf - -C "$dest_dir"
            return 0
        fi
        if [ -f "$url_base/${filename}.tgz" ]; then
            status "Using local ${filename}.tgz"
            $SUDO tar -xzf "$url_base/${filename}.tgz" -C "$dest_dir"
            return 0
        fi
        error "Local archive not found for ${filename} in ${url_base}"
    fi

    # Check if .tar.zst is available
    if curl --fail --silent --head --location "${url_base}/${filename}.tar.zst${VER_PARAM}" >/dev/null 2>&1; then
        # zst file exists - check if we have zstd tool
        if ! available zstd; then
            error "This version requires zstd for extraction. Please install zstd and try again:
  - Debian/Ubuntu: sudo apt-get install zstd
  - RHEL/CentOS/Fedora: sudo dnf install zstd
  - Arch: sudo pacman -S zstd"
        fi

        status "Downloading ${filename}.tar.zst"
        curl --fail --show-error --location --progress-bar \
            "${url_base}/${filename}.tar.zst${VER_PARAM}" | \
            zstd -d | $SUDO tar -xf - -C "${dest_dir}"
        return 0
    fi

    # Fall back to .tgz for older versions
    status "Downloading ${filename}.tgz"
    curl --fail --show-error --location --progress-bar \
        "${url_base}/${filename}.tgz${VER_PARAM}" | \
        $SUDO tar -xzf - -C "${dest_dir}"
}

for BINDIR in /usr/local/bin /usr/bin /bin; do
    echo $PATH | grep -q $BINDIR && break || continue
done
OLLAMA_INSTALL_DIR=$(dirname ${BINDIR})

if [ -d "$OLLAMA_INSTALL_DIR/lib/ollama" ] ; then
    status "Cleaning up old version at $OLLAMA_INSTALL_DIR/lib/ollama"
    $SUDO rm -rf "$OLLAMA_INSTALL_DIR/lib/ollama"
fi
status "Installing ollama to $OLLAMA_INSTALL_DIR"
$SUDO install -o0 -g0 -m755 -d $BINDIR
$SUDO install -o0 -g0 -m755 -d "$OLLAMA_INSTALL_DIR/lib/ollama"
download_and_extract "$OLLAMA_DOWNLOAD_BASE_URL" "$OLLAMA_INSTALL_DIR" "ollama-linux-${ARCH}"

OLLAMA_INSTALL_VARIANT="${OLLAMA_INSTALL_VARIANT:-}"
if [ -z "$OLLAMA_INSTALL_VARIANT" ] && [ -z "${OLLAMA_NONINTERACTIVE:-}" ] && [ -r /dev/tty ]; then
    echo "Select Ollama installation variant:" > /dev/tty
    echo "  1) Automatic hardware detection" > /dev/tty
    echo "  2) CPU only" > /dev/tty
    echo "  3) ROCm" > /dev/tty
    printf "Choice [1]: " > /dev/tty
    IFS= read -r OLLAMA_INSTALL_CHOICE < /dev/tty || OLLAMA_INSTALL_CHOICE=1
    case "$OLLAMA_INSTALL_CHOICE" in
        2) OLLAMA_INSTALL_VARIANT=cpu ;;
        3) OLLAMA_INSTALL_VARIANT=rocm ;;
        *) OLLAMA_INSTALL_VARIANT=auto ;;
    esac
fi
OLLAMA_INSTALL_VARIANT="${OLLAMA_INSTALL_VARIANT:-auto}"

if [ "$OLLAMA_INSTALL_DIR/bin/ollama" != "$BINDIR/ollama" ] ; then
    status "Making ollama accessible in the PATH in $BINDIR"
    $SUDO ln -sf "$OLLAMA_INSTALL_DIR/ollama" "$BINDIR/ollama"
fi

# Check for NVIDIA JetPack systems with additional downloads
if [ -f /etc/nv_tegra_release ] ; then
    if grep R36 /etc/nv_tegra_release > /dev/null ; then
        download_and_extract "$OLLAMA_DOWNLOAD_BASE_URL" "$OLLAMA_INSTALL_DIR" "ollama-linux-${ARCH}-jetpack6"
    elif grep R35 /etc/nv_tegra_release > /dev/null ; then
        download_and_extract "$OLLAMA_DOWNLOAD_BASE_URL" "$OLLAMA_INSTALL_DIR" "ollama-linux-${ARCH}-jetpack5"
    else
        warning "Unsupported JetPack version detected.  GPU may not be supported"
    fi
fi

install_success() {
    status 'The Ollama API is now available at 127.0.0.1:11434.'
    status 'Install complete. Run "ollama" from the command line.'
}
trap install_success EXIT

# Everything from this point onwards is optional.

configure_systemd() {
    if ! id ollama >/dev/null 2>&1; then
        status "Creating ollama user..."
        $SUDO useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
    fi
    if getent group render >/dev/null 2>&1; then
        status "Adding ollama user to render group..."
        $SUDO usermod -a -G render ollama
    fi
    if getent group video >/dev/null 2>&1; then
        status "Adding ollama user to video group..."
        $SUDO usermod -a -G video ollama
    fi

    status "Adding current user to ollama group..."
    $SUDO usermod -a -G ollama $(whoami)

    status "Creating ollama systemd service..."
    cat <<EOF | $SUDO tee /etc/systemd/system/ollama.service >/dev/null
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=$BINDIR/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=$PATH"

[Install]
WantedBy=default.target
EOF
    SYSTEMCTL_RUNNING="$(systemctl is-system-running || true)"
    case $SYSTEMCTL_RUNNING in
        running|degraded)
            status "Enabling and starting ollama service..."
            $SUDO systemctl daemon-reload
            $SUDO systemctl enable ollama

            start_service() { $SUDO systemctl restart ollama; }
            trap start_service EXIT
            ;;
        *)
            warning "systemd is not running"
            if [ "$IS_WSL2" = true ]; then
                warning "see https://learn.microsoft.com/en-us/windows/wsl/systemd#how-to-enable-systemd to enable it"
            fi
            ;;
    esac
}

if available systemctl; then
    configure_systemd
fi

# WSL2 only supports GPUs via nvidia passthrough
# so check for nvidia-smi to determine if GPU is available
if [ "$IS_WSL2" = true ]; then
    if available nvidia-smi && [ -n "$(nvidia-smi | grep -o "CUDA Version: [0-9]*\.[0-9]*")" ]; then
        status "Nvidia GPU detected."
    fi
    install_success
    exit 0
fi

# Don't attempt to install drivers on Jetson systems
if [ -f /etc/nv_tegra_release ] ; then
    status "NVIDIA JetPack ready."
    install_success
    exit 0
fi

# Install GPU dependencies on Linux
if ! available lspci && ! available lshw; then
    warning "Unable to detect NVIDIA/AMD GPU. Install lspci or lshw to automatically detect and install GPU dependencies."
    exit 0
fi

check_gpu() {
    # Look for devices based on vendor ID for NVIDIA and AMD
    case $1 in
        lspci)
            case $2 in
                nvidia) available lspci && lspci -d '10de:' | grep -q 'NVIDIA' || return 1 ;;
                amdgpu) available lspci && lspci -d '1002:' | grep -q 'AMD' || return 1 ;;
            esac ;;
        lshw)
            case $2 in
                nvidia) available lshw && $SUDO lshw -c display -numeric -disable network | grep -q 'vendor: .* \[10DE\]' || return 1 ;;
                amdgpu) available lshw && $SUDO lshw -c display -numeric -disable network | grep -q 'vendor: .* \[1002\]' || return 1 ;;
            esac ;;
        nvidia-smi) available nvidia-smi || return 1 ;;
    esac
}

if [ "$OLLAMA_INSTALL_VARIANT" = cpu ]; then
    install_success
    status "CPU-only installation selected."
    exit 0
fi

if [ "$OLLAMA_INSTALL_VARIANT" = rocm ]; then
    download_and_extract "$OLLAMA_DOWNLOAD_BASE_URL" "$OLLAMA_INSTALL_DIR" "ollama-linux-${ARCH}-rocm"
    install_success
    status "ROCm installation selected."
    exit 0
fi

if check_gpu nvidia-smi; then
    status "NVIDIA GPU installed."
    exit 0
fi

if ! check_gpu lspci nvidia && ! check_gpu lshw nvidia && ! check_gpu lspci amdgpu && ! check_gpu lshw amdgpu; then
    install_success
    warning "No NVIDIA/AMD GPU detected. Ollama will run in CPU-only mode."
    exit 0
fi

if check_gpu lspci amdgpu || check_gpu lshw amdgpu; then
    download_and_extract "$OLLAMA_DOWNLOAD_BASE_URL" "$OLLAMA_INSTALL_DIR" "ollama-linux-${ARCH}-rocm"

    install_success
    status "AMD GPU ready."
    exit 0
fi

CUDA_REPO_ERR_MSG="NVIDIA GPU detected, but your OS and Architecture are not supported by NVIDIA.  Please install the CUDA driver manually https://docs.nvidia.com/cuda/cuda-installation-guide-linux/"
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-7-centos-7
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-8-rocky-8
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#rhel-9-rocky-9
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#fedora
install_cuda_driver_yum() {
    status 'Installing NVIDIA repository...'
    
    case $PACKAGE_MANAGER in
        yum)
            $SUDO $PACKAGE_MANAGER -y install yum-utils
            if curl -I --silent --fail --location "https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m | sed -e 's/aarch64/sbsa/')/cuda-$1$2.repo" >/dev/null ; then
                $SUDO $PACKAGE_MANAGER-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m | sed -e 's/aarch64/sbsa/')/cuda-$1$2.repo
            else
                error $CUDA_REPO_ERR_MSG
            fi
            ;;
        dnf)
            if curl -I --silent --fail --location "https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m | sed -e 's/aarch64/sbsa/')/cuda-$1$2.repo" >/dev/null ; then
                $SUDO $PACKAGE_MANAGER config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m | sed -e 's/aarch64/sbsa/')/cuda-$1$2.repo
            else
                error $CUDA_REPO_ERR_MSG
            fi
            ;;
    esac

    case $1 in
        rhel)
            status 'Installing EPEL repository...'
            # EPEL is required for third-party dependencies such as dkms and libvdpau
            $SUDO $PACKAGE_MANAGER -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-$2.noarch.rpm || true
            ;;
    esac

    status 'Installing CUDA driver...'

    if [ "$1" = 'centos' ] || [ "$1$2" = 'rhel7' ]; then
        $SUDO $PACKAGE_MANAGER -y install nvidia-driver-latest-dkms
    fi

    $SUDO $PACKAGE_MANAGER -y install cuda-drivers
}

# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#ubuntu
# ref: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#debian
install_cuda_driver_apt() {
    status 'Installing NVIDIA repository...'
    if curl -I --silent --fail --location "https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m | sed -e 's/aarch64/sbsa/')/cuda-keyring_1.1-1_all.deb" >/dev/null ; then
        curl -fsSL -o $TEMP_DIR/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/$1$2/$(uname -m | sed -e 's/aarch64/sbsa/')/cuda-keyring_1.1-1_all.deb
    else
        error $CUDA_REPO_ERR_MSG
    fi

    case $1 in
        debian)
            status 'Enabling contrib sources...'
            $SUDO sed 's/main/contrib/' < /etc/apt/sources.list | $SUDO tee /etc/apt/sources.list.d/contrib.list > /dev/null
            if [ -f "/etc/apt/sources.list.d/debian.sources" ]; then
                $SUDO sed 's/main/contrib/' < /etc/apt/sources.list.d/debian.sources | $SUDO tee /etc/apt/sources.list.d/contrib.sources > /dev/null
            fi
            ;;
    esac

    status 'Installing CUDA driver...'
    $SUDO dpkg -i $TEMP_DIR/cuda-keyring.deb
    $SUDO apt-get update

    [ -n "$SUDO" ] && SUDO_E="$SUDO -E" || SUDO_E=
    DEBIAN_FRONTEND=noninteractive $SUDO_E apt-get -y install cuda-drivers -q
}

if [ ! -f "/etc/os-release" ]; then
    error "Unknown distribution. Skipping CUDA installation."
fi

. /etc/os-release

OS_NAME=$ID
OS_VERSION=$VERSION_ID

PACKAGE_MANAGER=
for PACKAGE_MANAGER in dnf yum apt-get; do
    if available $PACKAGE_MANAGER; then
        break
    fi
done

if [ -z "$PACKAGE_MANAGER" ]; then
    error "Unknown package manager. Skipping CUDA installation."
fi

if ! check_gpu nvidia-smi || [ -z "$(nvidia-smi | grep -o "CUDA Version: [0-9]*\.[0-9]*")" ]; then
    case $OS_NAME in
        centos|rhel) install_cuda_driver_yum 'rhel' $(echo $OS_VERSION | cut -d '.' -f 1) ;;
        rocky) install_cuda_driver_yum 'rhel' $(echo $OS_VERSION | cut -c1) ;;
        fedora) [ $OS_VERSION -lt '39' ] && install_cuda_driver_yum $OS_NAME $OS_VERSION || install_cuda_driver_yum $OS_NAME '39';;
        amzn) install_cuda_driver_yum 'fedora' '37' ;;
        debian) install_cuda_driver_apt $OS_NAME $OS_VERSION ;;
        ubuntu) install_cuda_driver_apt $OS_NAME $(echo $OS_VERSION | sed 's/\.//') ;;
        *) exit ;;
    esac
fi

if ! lsmod | grep -q nvidia || ! lsmod | grep -q nvidia_uvm; then
    KERNEL_RELEASE="$(uname -r)"
    case $OS_NAME in
        rocky) $SUDO $PACKAGE_MANAGER -y install kernel-devel kernel-headers ;;
        centos|rhel|amzn) $SUDO $PACKAGE_MANAGER -y install kernel-devel-$KERNEL_RELEASE kernel-headers-$KERNEL_RELEASE ;;
        fedora) $SUDO $PACKAGE_MANAGER -y install kernel-devel-$KERNEL_RELEASE ;;
        debian|ubuntu) $SUDO apt-get -y install linux-headers-$KERNEL_RELEASE ;;
        *) exit ;;
    esac

    NVIDIA_CUDA_VERSION=$($SUDO dkms status | awk -F: '/added/ { print $1 }')
    if [ -n "$NVIDIA_CUDA_VERSION" ]; then
        $SUDO dkms install $NVIDIA_CUDA_VERSION
    fi

    if lsmod | grep -q nouveau; then
        status 'Reboot to complete NVIDIA CUDA driver install.'
        exit 0
    fi

    $SUDO modprobe nvidia
    $SUDO modprobe nvidia_uvm
fi

# make sure the NVIDIA modules are loaded on boot with nvidia-persistenced
if available nvidia-persistenced; then
    $SUDO touch /etc/modules-load.d/nvidia.conf
    MODULES="nvidia nvidia-uvm"
    for MODULE in $MODULES; do
        if ! grep -qxF "$MODULE" /etc/modules-load.d/nvidia.conf; then
            echo "$MODULE" | $SUDO tee -a /etc/modules-load.d/nvidia.conf > /dev/null
        fi
    done
fi

status "NVIDIA GPU ready."
install_success
}

main "$@"
