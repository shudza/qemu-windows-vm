# Windows QEMU VM

Effortless Windows VM on Linux. Two scripts, one `.env` file, no XML — just `./start.sh` and you're running a fully accelerated KVM guest with UEFI, VirtioFS, SPICE, and hugepages out of the box.

## Supported Guests

- **Windows 10** — tested and working
- **Windows 11** — should work but untested (may need TPM passthrough)

## Features

- **UEFI boot** via OVMF with Q35 chipset
- **SPICE display** with clipboard sharing, USB redirection, and smartcard passthrough
- **VirtioFS** shared folder between host and guest
- **Hugepages** for memory performance
- **CPU pinning** to dedicated cores
- **Distro-agnostic** — auto-detects OVMF and virtiofsd paths across Arch, Fedora, Ubuntu, etc.
- **Systemd service** — optional, for headless/autostart setups
- **Desktop entry** — launch from your app menu

## Requirements

- QEMU >= 10 with KVM support
- OVMF (UEFI firmware)
- virtiofsd
- socat
- remote-viewer (virt-viewer) — not needed for headless mode

### Install (Arch/CachyOS)

```sh
sudo pacman -S qemu-full edk2-ovmf virtiofsd socat virt-viewer
```

### Install (Fedora)

```sh
sudo dnf install qemu-kvm edk2-ovmf virtiofsd socat virt-viewer
```

### Install (Ubuntu/Debian)

```sh
sudo apt install qemu-system-x86 ovmf virtiofsd socat virt-viewer
```

## Quick Start

### First run (install Windows)

Download a [Windows 10 ISO](https://www.microsoft.com/software-download/windows10ISO) and optionally the [VirtIO drivers ISO](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso).

```sh
./start.sh /path/to/windows.iso /path/to/virtio-win.iso
```

This creates a 100G qcow2 disk, boots the installer, and opens a SPICE viewer.

### Subsequent runs

```sh
./start.sh
```

If the VM is already running, this opens a new viewer window.

### Shutdown

From within Windows (Start > Shut down), or from the host:

```sh
./stop.sh
```

`stop.sh` sends an ACPI shutdown via the QEMU monitor, waits for graceful poweroff, and cleans up virtiofsd.

## Configuration

Copy `.env.example` to `.env` and uncomment the values you want to change:

```sh
cp .env.example .env
```

| Variable | Default | Description |
|-|-|-|
| `SMP` | `cores=4,threads=1,sockets=1` | CPU topology |
| `MEM` | `8G` | RAM allocation |
| `HUGEPAGES_COUNT` | `4096` | 2MB hugepages (must match MEM) |
| `CPU_PINNING` | `0-3` | CPU cores to pin to (empty to disable) |
| `DISK_SIZE` | `100G` | Disk size (only used on first run) |
| `SMB_PATH` | *(empty)* | Directory to share via QEMU SMB |
| `HOST_FORWARDS` | *(empty)* | Port forwards (e.g. `hostfwd=tcp::2222-:22`) |
| `VIRTIOFS_SHARED` | `./shared` | Directory to share via VirtioFS |
| `OVMF_CODE` | *(auto-detected)* | Path to OVMF_CODE firmware |
| `OVMF_VARS_TEMPLATE` | *(auto-detected)* | Path to OVMF_VARS template |
| `VIRTIOFSD_BIN` | *(auto-detected)* | Path to virtiofsd binary |

## Systemd Service

Install and enable a systemd service for headless/autostart operation:

```sh
./start.sh --systemd
```

This installs a system service, enables it, and creates a desktop entry. Manage with:

```sh
sudo systemctl start windows-vm
sudo systemctl stop windows-vm
sudo systemctl status windows-vm
journalctl -u windows-vm
```

The VM starts headless. Use `./start.sh` to open a viewer window while the service is running.

## CLI Reference

```
./start.sh [OPTIONS] [windows.iso] [virtio-win.iso]

Options:
  --headless          Launch VM without SPICE viewer
  --install-desktop   Install .desktop file and exit
  --systemd           Install systemd service and exit
  --help, -h          Show this help
```

## File Layout

```
.
├── start.sh            # Main launch script
├── stop.sh             # Graceful shutdown script
├── .env.example        # Configuration template
├── .env                # Your configuration (gitignored)
├── shared/             # VirtioFS shared directory (gitignored)
└── windows/            # VM state (gitignored)
    ├── disk.qcow2      # Virtual disk
    └── OVMF_VARS.4m.fd # UEFI variables (per-VM copy)
```

Runtime files (sockets, PID, logs) are stored in `/run/windows-vm/`.

## Guest Setup

### VirtioFS shared folder

In Windows, install [WinFsp](https://winfsp.dev/) then start the VirtioFS service:

```
sc start VirtioFsSvc
```

The shared folder appears as a network drive.

### SPICE guest tools

Install [SPICE guest tools](https://www.spice-space.org/download.html) for clipboard sharing, dynamic resolution, and USB redirection.
