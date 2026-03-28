#!/bin/bash

# ── Configuration (adjust per machine) ──────────────────────────────
SMP="cores=4,threads=1,sockets=1"
MEM="8G"
HUGEPAGES_COUNT=4096          # MEM in 2MB pages (8G = 4096)
CPU_PINNING="0-3"             # P-cores; empty string to disable pinning
SMB_PATH="$HOME/projects"    # shared via QEMU SMB
HOST_FORWARDS="hostfwd=tcp::22220-:22,hostfwd=tcp::5000-:5000,hostfwd=tcp::5001-:5001"
DISK_SIZE="100G"
# ────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$SCRIPT_DIR/windows"
PID_FILE="$VM_DIR/windows.pid"
LOG_FILE="$VM_DIR/vm.log"
SPICE_SOCK="$VM_DIR/spice.sock"
OVMF_VARS="$VM_DIR/OVMF_VARS.4m.fd"
DISK="$VM_DIR/disk.qcow2"

ISO_PATH="${1:-}"
VIRTIO_ISO="${2:-}"

# ── Install .desktop file ───────────────────────────────────────────
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_DIR/windows-vm.desktop"
if [ ! -f "$DESKTOP_FILE" ] || ! grep -qF "$SCRIPT_DIR/start.sh" "$DESKTOP_FILE" 2>/dev/null; then
    mkdir -p "$DESKTOP_DIR"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Windows
Comment=Windows 10 QEMU VM
Exec=$SCRIPT_DIR/start.sh
Icon=preferences-desktop-display
Terminal=false
Type=Application
Categories=System;Emulator;
EOF
fi

# ── Determine mode ──────────────────────────────────────────────────
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

# ── If already running, just open the viewer ────────────────────────
if [ -f "$PID_FILE" ]; then
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        nohup env QT_SCALE_FACTOR=1 remote-viewer --auto-resize=never "spice+unix://$SPICE_SOCK" 2>&1 &
        exit 0
    else
        echo "Found stale PID file. Removing..."
        rm "$PID_FILE"
    fi
fi

# ── Fresh install: create disk ──────────────────────────────────────
if [ "$FRESH_INSTALL" -eq 1 ]; then
    echo "Fresh install mode — creating VM disk and booting installer..."
    mkdir -p "$VM_DIR"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
fi

# ── Create writable OVMF_VARS copy if missing ──────────────────────
if [ ! -f "$OVMF_VARS" ]; then
    echo "Creating writable OVMF_VARS copy..."
    cp /usr/share/OVMF/x64/OVMF_VARS.4m.fd "$OVMF_VARS"
fi

# ── Allocate hugepages ──────────────────────────────────────────────
CURRENT_HUGEPAGES=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
if [ "$CURRENT_HUGEPAGES" -lt "$HUGEPAGES_COUNT" ]; then
    echo "Allocating $HUGEPAGES_COUNT hugepages..."
    echo "$HUGEPAGES_COUNT" | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages > /dev/null
    ACTUAL=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages)
    if [ "$ACTUAL" -lt "$HUGEPAGES_COUNT" ]; then
        echo "Warning: Only got $ACTUAL/$HUGEPAGES_COUNT hugepages. Continuing without hugepages."
        USE_HUGEPAGES=0
    else
        USE_HUGEPAGES=1
    fi
else
    USE_HUGEPAGES=1
fi

# ── Build memory args ──────────────────────────────────────────────
MEM_ARGS="-m $MEM"
if [ "$USE_HUGEPAGES" -eq 1 ]; then
    MEM_ARGS="-m $MEM -mem-prealloc -mem-path /dev/hugepages"
fi

# ── Build CD-ROM args for fresh install ─────────────────────────────
CDROM_ARGS=""
BOOT_ARGS=""
if [ "$FRESH_INSTALL" -eq 1 ]; then
    CDROM_ARGS="-cdrom $ISO_PATH"
    if [ -n "$VIRTIO_ISO" ]; then
        if [ ! -f "$VIRTIO_ISO" ]; then
            echo "Error: VirtIO ISO not found: $VIRTIO_ISO"
            exit 1
        fi
        CDROM_ARGS="$CDROM_ARGS -drive file=$VIRTIO_ISO,media=cdrom,index=1"
    fi
    BOOT_ARGS="-boot d"
fi

# ── Build taskset prefix ───────────────────────────────────────────
TASKSET=""
if [ -n "$CPU_PINNING" ]; then
    TASKSET="taskset -c $CPU_PINNING"
fi

echo "Starting Windows 10 VM..."

# ── The QEMU Command ───────────────────────────────────────────────
nohup $TASKSET /usr/bin/qemu-system-x86_64 \
    -name windows,process=windows \
    -machine q35,hpet=off,smm=off,vmport=off,accel=kvm \
    -global kvm-pit.lost_tick_policy=discard \
    -global ICH9-LPC.disable_s3=1 \
    -cpu host,+hypervisor,+invtsc,l3-cache=on,migratable=no,hv_passthrough \
    -smp "$SMP" \
    $MEM_ARGS \
    -pidfile "$PID_FILE" \
    -rtc base=localtime,clock=host,driftfix=slew \
    -object iothread,id=iothread0 \
    -device qxl-vga,ram_size_mb=64,vgamem_mb=32,vram_size_mb=64 \
    -spice unix=on,addr="$SPICE_SOCK",disable-ticketing=on \
    -display none \
    -device virtio-serial-pci \
    -chardev socket,id=agent0,path="$VM_DIR/windows-agent.sock",server=on,wait=off \
    -device virtserialport,chardev=agent0,name=org.qemu.guest_agent.0 \
    -chardev spicevmc,id=vdagent0,name=vdagent \
    -device virtserialport,chardev=vdagent0,name=com.redhat.spice.0 \
    -chardev spiceport,id=webdav0,name=org.spice-space.webdav.0 \
    -device virtserialport,chardev=webdav0,name=org.spice-space.webdav.0 \
    -device virtio-rng-pci,rng=rng0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device qemu-xhci,id=spicepass \
    -chardev spicevmc,id=usbredirchardev1,name=usbredir \
    -device usb-redir,chardev=usbredirchardev1,id=usbredirdev1 \
    -chardev spicevmc,id=usbredirchardev2,name=usbredir \
    -device usb-redir,chardev=usbredirchardev2,id=usbredirdev2 \
    -chardev spicevmc,id=usbredirchardev3,name=usbredir \
    -device usb-redir,chardev=usbredirchardev3,id=usbredirdev3 \
    -device pci-ohci,id=smartpass \
    -device usb-ccid \
    -chardev spicevmc,id=ccid,name=smartcard \
    -device ccid-card-passthru,chardev=ccid \
    -device usb-ehci,id=input \
    -device usb-kbd,bus=input.0 \
    -k en-us \
    -device usb-tablet,bus=input.0 \
    -audiodev spice,id=audio0 \
    -device intel-hda \
    -device hda-micro,audiodev=audio0 \
    -device virtio-net,netdev=nic \
    -netdev user,hostname=windows,${HOST_FORWARDS},smb="$SMB_PATH",id=nic \
    -drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/x64/OVMF_CODE.4m.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$OVMF_VARS" \
    -device virtio-blk-pci,drive=SystemDisk,iothread=iothread0 \
    -drive id=SystemDisk,if=none,format=qcow2,file="$DISK",cache=writeback,aio=io_uring,discard=unmap,detect-zeroes=unmap \
    $CDROM_ARGS \
    $BOOT_ARGS \
    -monitor unix:"$VM_DIR/windows-monitor.socket",server,nowait \
    -serial unix:"$VM_DIR/windows-serial.socket",server,nowait > "$LOG_FILE" 2>&1 &

# ── Launch SPICE viewer ─────────────────────────────────────────────
for i in $(seq 10); do
    [ -S "$SPICE_SOCK" ] && break
    sleep 0.5
done
if [ -S "$SPICE_SOCK" ]; then
    nohup env QT_SCALE_FACTOR=1 remote-viewer --auto-resize=never "spice+unix://$SPICE_SOCK" 2>&1 &
else
    echo "Warning: SPICE socket not found after 5s. Check $LOG_FILE"
fi

echo "VM launched in background. Logs: $LOG_FILE"
echo "You can safely close this terminal."
