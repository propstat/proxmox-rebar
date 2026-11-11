# pve-arc-rebar

Full Resizable BAR for Intel Arc GPUs on Proxmox VE 9, also on boards
whose firmware has no Resizable BAR option.

Without firmware support an Arc GPU is stuck with a 256 MiB BAR2, so the
CPU, or the VM the card is passed through to, can only see a small part
of the VRAM at once. Intel Arc relies on Resizable BAR for performance.
This repository builds a Proxmox kernel that can enlarge the BAR itself,
and adds a few tools for passthrough setups.

> **Status: experimental.** The patches apply to proxmox-kernel 7.0.14-29
> and the changed files compile, but they have not been tested on real
> hardware yet. Test reports are welcome; see [Reporting](#reporting).

## How it works

An Arc card contains its own PCIe switch. Firmware gives that switch an
8 MiB BAR0 and places it in the same root port window as the GPU's
BAR2. When the kernel tries to enlarge BAR2, that BAR0 keeps the window
pinned and the resize fails. The kernel built here carries three patches:

| Patch | Origin | What it does |
|---|---|---|
| `9180` | Liz Fong-Jones, mainline 7.3 | Fixes BAR resize for devices directly on a root bus |
| `9181` | Ilpo Järvinen (Intel), posted upstream, not merged | Releases BAR0 of the Arc switch (IDs `4fa0`, `4fa1`, `e2ff`) |
| `9182` | this repository | Makes `9181` opt-in via the boot parameter `pci_arc_release_bar0` |

Without the parameter, the kernel behaves like the stock Proxmox kernel
and only logs a hint per Arc switch. The opt-in exists because one review
question upstream is still open: whether the switch keeps responding at
the address of the released BAR0.

With the parameter set, the xe and i915 drivers enlarge BAR2 themselves
when they load. Cards passed through to VMs are resized by
`arc-vfio-resize` before the VMs start.

## Requirements

- Proxmox VE 9 (Debian 13 trixie), amd64
- **Above 4G decoding** (64-bit MMIO) enabled in the BIOS. A Resizable
  BAR option is not needed.
- A 64-bit PCI window large enough for all enlarged BARs, e.g. about
  64 GiB per Arc Pro B60 Dual. `rebar-window-check` tells you.
- Each GPU on its own root port: separate slots, or a bifurcated slot
  such as x8/x8 for the B60 Dual. GPUs behind a shared PCIe switch need
  `pci-rebar-group` instead (see [Tools](#tools)).
- Secure Boot off: the self-built kernel is not signed.
- To build: about 60 GB of free disk, 8+ GB RAM, and a few hours.

## Installation

The script builds the kernel from Proxmox's own sources plus the patches
in this repository, then installs it **next to** the stock kernel. The
stock kernel stays the default; nothing reboots on its own.

### On the Proxmox host

```sh
git clone https://github.com/propstat/proxmox-rebar.git
cd proxmox-rebar
./install.sh --test-boot
reboot
```

Or without cloning:

```sh
curl -fsSL https://raw.githubusercontent.com/propstat/proxmox-rebar/main/install.sh | bash -s -- --test-boot
```

`--test-boot` boots the new kernel for one boot only. A reset brings the
host back to the stock kernel.

### Building on a separate machine

The build installs a lot of packages. To keep them off the hypervisor,
build in a Debian 13 VM or container and install only the result:

```sh
# on the build machine
./install.sh --build-only
# result: /var/tmp/pve-arc-rebar/out/proxmox-kernel-7.0.14-29-arc1-pve_7.0.14-29_amd64.deb

# on the Proxmox host
./install.sh --install-deb proxmox-kernel-7.0.14-29-arc1-pve_7.0.14-29_amd64.deb --test-boot
```

### Options

| Option | Effect |
|---|---|
| `--build-only` | Build the packages, don't install |
| `--install-deb FILE` | Install a package built earlier, skip the build |
| `--enable-param` | Add `pci_arc_release_bar0` to the kernel command line |
| `--param on\|off` | Only add or remove that parameter |
| `--test-boot` | Boot the new kernel on the next reboot only |
| `--make-default` | Pin the new kernel permanently (blocks newer Proxmox kernels until `proxmox-boot-tool kernel unpin`) |
| `--vfio-autoresize` | Enable the boot service that resizes vfio-pci GPUs |
| `--no-tools` | Don't install the helper tools |
| `--ref REF` | pve-kernel git ref to build (default: the tested commit) |
| `--suffix SUFFIX` | Kernel name suffix (default `-arc1`, giving `7.0.14-29-arc1-pve`) |
| `--workdir DIR` | Build directory (default `/var/tmp/pve-arc-rebar`) |
| `--uninstall` | Remove kernel, parameter, services and tools |
| `--force` | Continue despite failed preflight checks |
| `-y` | Don't ask for confirmation |

The command line parameter is written to `/etc/kernel/cmdline`
(systemd-boot) and `/etc/default/grub` (GRUB), whichever exist. The stock
kernel ignores it.

## Testing step by step

1. **Baseline on the stock kernel.**
   - Save the current state: `collect-arc-info baseline`
   - Check the window: `rebar-window-check` should say `fits`.
   - Check the switches: `lspci -nn | grep -iE '8086:(4fa0|4fa1|e2ff)'`
     must show one switch per GPU. If it shows another ID, the patch
     won't match your card: please open an issue.
2. **Test kernel without the parameter.**
   - Install and reboot: `./install.sh --test-boot && reboot`
   - `uname -r` shows `7.0.14-29-arc1-pve`.
   - `dmesg | grep pci_arc_release_bar0` shows one hint per Arc switch.
   - Everything else behaves as before. Save with `collect-arc-info no-param`.
3. **Test kernel with the parameter.**
   - Enable it and boot the test kernel again:
     ```sh
     ./install.sh --param on
     proxmox-boot-tool kernel pin 7.0.14-29-arc1-pve --next-boot && reboot
     ```
   - `dmesg | grep -E 'BAR 0 .*releasing'` shows one line per Arc switch.
     Save with `collect-arc-info param`.
4. **Resize.**
   - **GPUs used by the host:** xe or i915 resizes BAR2 when it loads.
     Check with `lspci -vv -s <gpu> | grep 'BAR 2'`.
   - **Passthrough GPUs:** stop the VMs, then run `arc-vfio-resize --dry-run`
     followed by `arc-vfio-resize`. Save with `collect-arc-info resized`.
5. **Inside the VM.** Check BAR2 in the guest (`lspci -vv`, or GPU-Z on
   Windows). See [Troubleshooting](#troubleshooting) if it's missing.

## Tools

Installed to `/usr/local/sbin`; the services are installed but not enabled.

| Tool | Purpose |
|---|---|
| `rebar-window-check` | Read-only. Checks per host bridge whether the 64-bit window holds all enlarged BARs with their alignment |
| `arc-vfio-resize` | Resizes BAR2 of Arc GPUs bound to vfio-pci, then rebinds them. Options: `--dry-run`, `--max-gib N`, `--with-audio` |
| `arc-vfio-resize.service` | Runs `arc-vfio-resize` at boot before the VMs start, only when the parameter is set |
| `collect-arc-info` | Read-only. Saves all diagnostics of one test phase into a tarball |
| `pci-rebar-group` | Works without the patched kernel. For GPUs behind a shared PCIe switch: sets all sizes, then re-enumerates the subtree. Riskier: it removes and re-adds devices. Dry run unless `--apply`. Don't use together with `arc-vfio-resize.service` |

## Troubleshooting

- **The resize fails with `ENOSPC`.**
  - Check `dmesg | grep -iE 'was not released|BAR 2' | tail`.
  - If the device named there is the card's audio function, run
    `arc-vfio-resize --with-audio`.
  - If the window is too small, cap the size: `arc-vfio-resize --max-gib 16`.
- **No 64-bit window at all.** Enable Above 4G decoding in the BIOS.
- **The guest shows no BAR2, or the VM won't start.** The VM's own 64-bit
  MMIO area is probably too small. Enlarge it, here to 128 GiB:
  ```sh
  qm set <vmid> --args '-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=131072'
  ```
  Use a q35 machine with `pcie=1` on the `hostpci` entry.
- **The test kernel doesn't boot.** Reset the machine; the one-time boot
  falls back to the stock kernel.
- **The build stops while applying patches.** The pve-kernel version
  changed in a way the patches no longer fit. Build the tested version
  (the default `--ref`) and open an issue.

Even when a requirement is missing, nothing breaks: the resize fails as
it does on the stock kernel, and the GPU keeps its 256 MiB BAR.

## Uninstall

Boot the stock kernel, then run:

```sh
./install.sh --uninstall
```

This removes the test kernel, the boot parameter, the services and the
tools.

## Reporting

Please open an issue with the `arc-test-*.tar.gz` files from
`collect-arc-info`, plus:

- board, BIOS version and CPU
- cards, and which slots they're in
- BAR2 size before and after
- host driver or passthrough, and the guest OS

Successful tests help get the patches into the Proxmox kernel and
upstream Linux.

## Upstream status

- **Root-bus fix (`9180`):** merged in Linux 7.3 and marked for stable.
- **Arc quirk (`9181`):** posted by Ilpo Järvinen in September 2025 but
  not merged. He calls it an interim fix until a reworked PCI resource
  allocator plans for Resizable BAR sizes from the start.
- **Proxmox:** the same patches have been prepared for submission to the
  pve-devel list. Once Proxmox or upstream ships them, this repository
  becomes obsolete.

## Credits

- The kernel patches are by their authors, as recorded in each patch:
  - Ilpo Järvinen, with Lucas De Marchi (Intel)
  - Liz Fong-Jones
- The opt-in patch, scripts and tools are by Fabian Thobe.

This project is not affiliated with Proxmox Server Solutions GmbH or Intel.