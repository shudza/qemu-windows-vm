#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults (overridden by .env, then CLI args) ─────────────────
SMP="cores=4,threads=1,sockets=1"
MEM="8G"
HUGEPAGES_COUNT=4096
CPU_PINNING="0-3"
CPU_ARGS=""
SMB_PATH=""
VIRTIOFS_SHARED="$SCRIPT_DIR/shared"
HOST_FORWARDS=""
DISK_SIZE="100G"
OVMF_CODE=""
OVMF_VARS_TEMPLATE=""
VIRTIOFSD_BIN=""

# ── Derived paths (set after load_env) ────────────────────────────
VM_DIR="$SCRIPT_DIR/windows"
RUN_DIR="/run/windows-vm"
PID_FILE="$RUN_DIR/qemu.pid"
LOG_FILE="$RUN_DIR/vm.log"
SPICE_SOCK="$RUN_DIR/spice.sock"
VIRTIOFS_SOCK="$RUN_DIR/virtiofs.sock"
MONITOR_SOCK="$RUN_DIR/monitor.sock"
AGENT_SOCK="$RUN_DIR/agent.sock"
SERIAL_SOCK="$RUN_DIR/serial.sock"
OVMF_VARS="$VM_DIR/OVMF_VARS.4m.fd"
DISK="$VM_DIR/disk.qcow2"

# ── Runtime state ─────────────────────────────────────────────────
HEADLESS=0
QEMU_STARTED=0
VIRTIOFSD_PID=""
ISO_PATH=""
VIRTIO_ISO=""
# Real user — for socket ownership (works through sudo and systemd)
REAL_USER="${SUDO_USER:-$(stat -c %U "$HOME")}"

# ── Functions ─────────────────────────────────────────────────────

# Run command with sudo only if not already root
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

load_env() {
    if [ -f "$SCRIPT_DIR/.env" ]; then
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/.env"
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --headless)
                HEADLESS=1
                shift
                ;;
            --install-desktop)
                install_desktop
                echo "Desktop file installed."
                exit 0
                ;;
            --systemd)
                install_systemd
                exit 0
                ;;
            --help|-h)
                cat <<'USAGE'
Usage: start.sh [OPTIONS] [windows.iso] [virtio-win.iso]

Options:
  --headless          Launch VM without SPICE viewer
  --install-desktop   Install .desktop file and exit
  --systemd           Install systemd service and exit
  --help, -h          Show this help

First run:   ./start.sh /path/to/windows.iso [/path/to/virtio-win.iso]
Later runs:  ./start.sh
USAGE
                exit 0
                ;;
            -*)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
            *)
                if [ -z "$ISO_PATH" ]; then
                    ISO_PATH="$1"
                elif [ -z "$VIRTIO_ISO" ]; then
                    VIRTIO_ISO="$1"
                else
                    echo "Too many positional arguments" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

detect_paths() {
    # OVMF_CODE
    if [ -z "$OVMF_CODE" ]; then
        local code_candidates=(
            /usr/share/edk2/x64/OVMF_CODE.4m.fd
            /usr/share/OVMF/x64/OVMF_CODE.4m.fd
            /usr/share/edk2/ovmf/OVMF_CODE.fd
            /usr/share/OVMF/OVMF_CODE_4M.fd
            /usr/share/OVMF/OVMF_CODE.fd
        )
        for candidate in "${code_candidates[@]}"; do
            if [ -f "$candidate" ]; then
                OVMF_CODE="$candidate"
                break
            fi
        done
        if [ -z "$OVMF_CODE" ]; then
            echo "Error: OVMF_CODE not found. Searched:" >&2
            printf "  %s\n" "${code_candidates[@]}" >&2
            echo "Set OVMF_CODE in .env to specify the path manually." >&2
            exit 1
        fi
    fi

    # OVMF_VARS_TEMPLATE
    if [ -z "$OVMF_VARS_TEMPLATE" ]; then
        local vars_candidates=(
            /usr/share/edk2/x64/OVMF_VARS.4m.fd
            /usr/share/OVMF/x64/OVMF_VARS.4m.fd
            /usr/share/edk2/ovmf/OVMF_VARS.fd
            /usr/share/OVMF/OVMF_VARS_4M.fd
            /usr/share/OVMF/OVMF_VARS.fd
        )
        for candidate in "${vars_candidates[@]}"; do
            if [ -f "$candidate" ]; then
                OVMF_VARS_TEMPLATE="$candidate"
                break
            fi
        done
        if [ -z "$OVMF_VARS_TEMPLATE" ]; then
            echo "Error: OVMF_VARS_TEMPLATE not found. Searched:" >&2
            printf "  %s\n" "${vars_candidates[@]}" >&2
            echo "Set OVMF_VARS_TEMPLATE in .env to specify the path manually." >&2
            exit 1
        fi
    fi

    # VIRTIOFSD_BIN
    if [ -z "$VIRTIOFSD_BIN" ]; then
        local vfs_candidates=(
            /usr/lib/virtiofsd
            /usr/libexec/virtiofsd
            /usr/lib/kvm/virtiofsd
        )
        for candidate in "${vfs_candidates[@]}"; do
            if [ -x "$candidate" ]; then
                VIRTIOFSD_BIN="$candidate"
                break
            fi
        done
        if [ -z "$VIRTIOFSD_BIN" ]; then
            echo "Error: virtiofsd not found. Searched:" >&2
            printf "  %s\n" "${vfs_candidates[@]}" >&2
            echo "Set VIRTIOFSD_BIN in .env to specify the path manually." >&2
            exit 1
        fi
    fi
}

check_deps() {
    local missing=()

    # Required binaries
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        missing+=("qemu-system-x86_64")
    else
        local qemu_version
        qemu_version=$(qemu-system-x86_64 --version | head -1 | grep -oP '\d+' | head -1)
        if [ "${qemu_version:-0}" -lt 10 ]; then
            echo "Warning: QEMU version $qemu_version detected, >= 10 recommended." >&2
        fi
    fi

    if ! command -v socat &>/dev/null; then
        missing+=("socat")
    fi

    if [ ! -x "$VIRTIOFSD_BIN" ]; then
        missing+=("virtiofsd (at $VIRTIOFSD_BIN)")
    fi

    # Conditional
    if [ "$HEADLESS" -eq 0 ] && ! command -v remote-viewer &>/dev/null; then
        missing+=("remote-viewer (needed unless --headless)")
    fi

    if [ -n "$CPU_PINNING" ] && ! command -v taskset &>/dev/null; then
        missing+=("taskset (needed for CPU_PINNING)")
    fi

    # Firmware files
    if [ ! -f "$OVMF_CODE" ]; then
        missing+=("OVMF_CODE (not found at $OVMF_CODE)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing dependencies:" >&2
        printf "  - %s\n" "${missing[@]}" >&2
        exit 1
    fi
}

setup_hugepages() {
    local current
    current=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    if [ "$current" -lt "$HUGEPAGES_COUNT" ]; then
        echo "Allocating $HUGEPAGES_COUNT hugepages..."
        echo "$HUGEPAGES_COUNT" | as_root tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
        local actual
        actual=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
        if [ "$actual" -lt "$HUGEPAGES_COUNT" ]; then
            echo "Warning: Only got $actual/$HUGEPAGES_COUNT hugepages. Continuing without hugepages."
            USE_HUGEPAGES=0
        else
            USE_HUGEPAGES=1
        fi
    else
        USE_HUGEPAGES=1
    fi
}

start_virtiofsd() {
    mkdir -p "$VIRTIOFS_SHARED"
    rm -f "$VIRTIOFS_SOCK"
    as_root "$VIRTIOFSD_BIN" \
        --socket-path="$VIRTIOFS_SOCK" \
        --shared-dir="$VIRTIOFS_SHARED" \
        --cache=always \
        --announce-submounts \
        --inode-file-handles=mandatory &
    VIRTIOFSD_PID=$!

    local i
    for i in $(seq 20); do
        [ -S "$VIRTIOFS_SOCK" ] && break
        sleep 0.25
    done
    if [ ! -S "$VIRTIOFS_SOCK" ]; then
        echo "Error: virtiofsd socket not found after 5s"
        as_root kill "$VIRTIOFSD_PID" 2>/dev/null || true
        exit 1
    fi
    as_root chmod 666 "$VIRTIOFS_SOCK"
}

build_qemu_cmd() {
    QEMU_ARGS=(
        -name windows,process=windows
        -machine q35,hpet=off,smm=off,vmport=off,accel=kvm
        -global kvm-pit.lost_tick_policy=discard
        -global ICH9-LPC.disable_s3=1
        -cpu ${CPU_ARGS:-host,+hypervisor,+invtsc,l3-cache=on,migratable=no,hv_passthrough}
        -smp "$SMP"
    )

    # Memory args
    if [ "$USE_HUGEPAGES" -eq 1 ]; then
        QEMU_ARGS+=(
            -m "$MEM"
            -object "memory-backend-file,id=mem,size=$MEM,mem-path=/dev/hugepages,share=on,prealloc=on"
            -numa node,memdev=mem
        )
    else
        QEMU_ARGS+=(
            -m "$MEM"
            -object "memory-backend-memfd,id=mem,size=$MEM,share=on"
            -numa node,memdev=mem
        )
    fi

    QEMU_ARGS+=(
        -pidfile "$PID_FILE"
        -rtc base=localtime,clock=host,driftfix=slew
        -object iothread,id=iothread0

        # Display
        -device qxl-vga,ram_size_mb=64,vgamem_mb=16,vram_size_mb=64,max_outputs=1
        -spice "unix=on,addr=$SPICE_SOCK,disable-ticketing=on,image-compression=off,gl=off,streaming-video=off"
        -display none

        # Virtio serial + SPICE agents
        -device virtio-serial-pci
        -chardev "socket,id=agent0,path=$AGENT_SOCK,server=on,wait=off"
        -device virtserialport,chardev=agent0,name=org.qemu.guest_agent.0
        -chardev spicevmc,id=vdagent0,name=vdagent
        -device virtserialport,chardev=vdagent0,name=com.redhat.spice.0
        -chardev spiceport,id=webdav0,name=org.spice-space.webdav.0
        -device virtserialport,chardev=webdav0,name=org.spice-space.webdav.0

        # RNG
        -device virtio-rng-pci,rng=rng0
        -object rng-random,id=rng0,filename=/dev/urandom

        # USB passthrough
        -device qemu-xhci,id=spicepass
        -chardev spicevmc,id=usbredirchardev1,name=usbredir
        -device usb-redir,chardev=usbredirchardev1,id=usbredirdev1
        -chardev spicevmc,id=usbredirchardev2,name=usbredir
        -device usb-redir,chardev=usbredirchardev2,id=usbredirdev2
        -chardev spicevmc,id=usbredirchardev3,name=usbredir
        -device usb-redir,chardev=usbredirchardev3,id=usbredirdev3

        # Smartcard
        -device pci-ohci,id=smartpass
        -device usb-ccid
        -chardev spicevmc,id=ccid,name=smartcard
        -device ccid-card-passthru,chardev=ccid

        # Input
        -device usb-ehci,id=input
        -device usb-kbd,bus=input.0
        -k en-us
        -device usb-tablet,bus=input.0

        # Audio
        -audiodev spice,id=audio0
        -device intel-hda
        -device hda-micro,audiodev=audio0

        # Network
        -device virtio-net,netdev=nic
    )

    # Build netdev string conditionally
    local netdev="user,hostname=windows,id=nic"
    if [ -n "$HOST_FORWARDS" ]; then
        netdev+=",${HOST_FORWARDS}"
    fi
    if [ -n "$SMB_PATH" ]; then
        netdev+=",smb=$SMB_PATH"
    fi
    QEMU_ARGS+=(-netdev "$netdev"

        # VirtioFS
        -chardev "socket,id=virtiofs0,path=$VIRTIOFS_SOCK"
        -device vhost-user-fs-pci,queue-size=1024,chardev=virtiofs0,tag=shared

        # Firmware
        -drive "if=pflash,format=raw,unit=0,file=$OVMF_CODE,readonly=on"
        -drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS"

        # Disk
        -device virtio-scsi-pci,id=scsi0,iothread=iothread0
        -device scsi-hd,drive=SystemDisk,bus=scsi0.0,rotation_rate=1
        -drive "id=SystemDisk,if=none,format=qcow2,file=$DISK,cache=writeback,aio=io_uring,discard=unmap,detect-zeroes=unmap"
    )

    # CD-ROM for fresh install
    if [ "$FRESH_INSTALL" -eq 1 ]; then
        QEMU_ARGS+=(-cdrom "$ISO_PATH")
        if [ -n "$VIRTIO_ISO" ]; then
            QEMU_ARGS+=(-drive "file=$VIRTIO_ISO,media=cdrom,index=1")
        fi
        QEMU_ARGS+=(-boot d)
    fi

    # Monitor & serial
    QEMU_ARGS+=(
        -monitor "unix:$MONITOR_SOCK,server,nowait"
        -serial "unix:$SERIAL_SOCK,server,nowait"
    )
}

launch_vm() {
    echo "Starting Windows VM..."

    local taskset_cmd=()
    if [ -n "$CPU_PINNING" ]; then
        taskset_cmd=(taskset -c "$CPU_PINNING")
    fi

    if [ "$HEADLESS" -eq 1 ]; then
        # Foreground — let systemd manage the process directly
        "${taskset_cmd[@]}" /usr/bin/qemu-system-x86_64 \
            "${QEMU_ARGS[@]}" > "$LOG_FILE" 2>&1 &
    else
        # Background — detach from terminal
        nohup "${taskset_cmd[@]}" /usr/bin/qemu-system-x86_64 \
            "${QEMU_ARGS[@]}" > "$LOG_FILE" 2>&1 &
    fi

    # Wait for QEMU to write the PID file (systemd needs it before we exit)
    local i
    for i in $(seq 20); do
        [ -f "$PID_FILE" ] && break
        sleep 0.25
    done
    if [ ! -f "$PID_FILE" ]; then
        echo "Error: QEMU failed to start. Check $LOG_FILE" >&2
        exit 1
    fi

    QEMU_STARTED=1

    # Fix socket ownership so non-root users can connect (e.g. viewer after systemd start)
    as_root chown "$REAL_USER" "$RUN_DIR"/* 2>/dev/null || true
}

open_viewer() {
    nohup env GDK_BACKEND=x11 remote-viewer "spice+unix://$SPICE_SOCK" 2>&1 >/dev/null &
}

launch_viewer() {
    if [ "$HEADLESS" -eq 1 ]; then
        return
    fi

    local i
    for i in $(seq 10); do
        [ -S "$SPICE_SOCK" ] && break
        sleep 0.5
    done
    if [ -S "$SPICE_SOCK" ]; then
        open_viewer
    else
        echo "Warning: SPICE socket not found after 5s. Check $LOG_FILE"
    fi
}

install_desktop() {
    local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local desktop_file="$desktop_dir/windows-vm.desktop"
    mkdir -p "$desktop_dir"
    cat > "$desktop_file" <<EOF
[Desktop Entry]
Name=Windows
Comment=Windows QEMU VM
Exec=$SCRIPT_DIR/start.sh
Icon=preferences-desktop-display
Terminal=false
Type=Application
Categories=System;Emulator;
EOF
    echo "Installed $desktop_file"
}

install_systemd() {
    # Check if VM is running (any instance — manual or systemd)
    if pgrep -f 'qemu-system-x86_64.*-name windows' > /dev/null 2>&1; then
        echo "Error: VM is currently running. Shut it down first with ./stop.sh" >&2
        exit 1
    fi

    local service_file="/etc/systemd/system/windows-vm.service"
    local service_content
    service_content=$(cat <<EOF
[Unit]
Description=Windows QEMU VM
After=network.target
Wants=network.target

[Service]
Type=forking
PIDFile=$PID_FILE
RuntimeDirectory=windows-vm
Environment=HOME=$HOME
Environment=SUDO_USER=$REAL_USER
WorkingDirectory=$SCRIPT_DIR

ExecStart=$SCRIPT_DIR/start.sh --headless
ExecStop=$SCRIPT_DIR/stop.sh

# ACPI shutdown needs time for guest OS to finish
TimeoutStopSec=120
KillMode=process
KillSignal=SIGTERM

# Don't restart — stop.sh handles graceful shutdown
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    )

    # Check if already installed and identical
    if [ -f "$service_file" ] && [ "$(as_root cat "$service_file")" = "$service_content" ]; then
        echo "Systemd service already up to date."
    else
        echo "Installing systemd service at $service_file ..."
        echo "$service_content" | as_root tee "$service_file" > /dev/null
        as_root systemctl daemon-reload
    fi

    as_root systemctl enable windows-vm.service 2>/dev/null
    install_desktop
    echo "Service installed and enabled."
    echo "  Start:   sudo systemctl start windows-vm"
    echo "  Status:  sudo systemctl status windows-vm"
    echo "  Logs:    journalctl -u windows-vm"
}

cleanup() {
    if [ "$QEMU_STARTED" -eq 0 ] && [ -n "$VIRTIOFSD_PID" ]; then
        echo "QEMU failed to start. Cleaning up virtiofsd..."
        as_root kill "$VIRTIOFSD_PID" 2>/dev/null || true
        rm -f "$VIRTIOFS_SOCK"
    fi
}

main() {
    load_env
    parse_args "$@"

    # If already running, just open the viewer
    local running_pid=""
    if [ -f "$PID_FILE" ]; then
        running_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$running_pid" ] && ! kill -0 "$running_pid" 2>/dev/null; then
            echo "Found stale PID file. Removing..."
            rm -f "$PID_FILE"
            running_pid=""
        fi
    fi
    # Fallback: check by process name (covers missing/deleted PID file)
    if [ -z "$running_pid" ]; then
        running_pid=$(pgrep -f 'qemu-system-x86_64.*-name windows' 2>/dev/null | head -1 || true)
    fi
    if [ -n "$running_pid" ]; then
        if [ "$HEADLESS" -eq 0 ]; then
            open_viewer
        else
            echo "VM is already running (PID $running_pid)."
        fi
        exit 0
    fi

    detect_paths
    check_deps
    as_root mkdir -p "$RUN_DIR"
    as_root chown "$REAL_USER" "$RUN_DIR"

    # Determine mode
    FRESH_INSTALL=0
    if [ ! -f "$DISK" ]; then
        if [ -z "$ISO_PATH" ]; then
            echo "No disk image found at $DISK."
            echo "Usage: $0 <windows.iso> [virtio-win.iso]"
            echo "  First run:  $0 /path/to/windows.iso [/path/to/virtio-win.iso]"
            echo "  Later runs: $0"
            exit 1
        fi
        if [ ! -f "$ISO_PATH" ]; then
            echo "Error: ISO file not found: $ISO_PATH"
            exit 1
        fi
        FRESH_INSTALL=1
    fi

    # Fresh install: create disk
    if [ "$FRESH_INSTALL" -eq 1 ]; then
        echo "Fresh install mode — creating VM disk and booting installer..."
        mkdir -p "$VM_DIR"
        qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
    fi

    # Create writable OVMF_VARS copy if missing
    if [ ! -f "$OVMF_VARS" ]; then
        echo "Creating writable OVMF_VARS copy..."
        mkdir -p "$VM_DIR"
        cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
    fi

    # Virtio ISO validation (if specified for fresh install)
    if [ "$FRESH_INSTALL" -eq 1 ] && [ -n "$VIRTIO_ISO" ] && [ ! -f "$VIRTIO_ISO" ]; then
        echo "Error: VirtIO ISO not found: $VIRTIO_ISO"
        exit 1
    fi

    setup_hugepages

    # Set trap before starting virtiofsd
    trap cleanup EXIT SIGTERM SIGINT

    start_virtiofsd
    build_qemu_cmd
    launch_vm
    launch_viewer

    echo "VM launched in background. Logs: $LOG_FILE"
    echo "You can safely close this terminal."
}

main "$@"
