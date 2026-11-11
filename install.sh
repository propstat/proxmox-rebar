#!/bin/bash
#
# install.sh: build and install a Proxmox VE 9 kernel with the Intel Arc
# Resizable BAR patches from this repository, next to the stock kernel.
#
# Usage: install.sh [options]
#
#   (no options)        build the kernel and install it
#   --build-only        only build the packages (e.g. on a Debian 13 build VM)
#   --install-deb FILE  install a kernel package built earlier, skip the build
#   --enable-param      add pci_arc_release_bar0 to the kernel command line
#   --param on|off      only add or remove that parameter, nothing else
#   --test-boot         boot the new kernel once, on the next reboot only
#   --make-default      pin the new kernel permanently as the default
#   --vfio-autoresize   enable the boot service that resizes vfio-pci GPUs
#   --no-tools          don't install the helper tools to /usr/local/sbin
#   --ref REF           pve-kernel git ref to build (default: tested commit)
#   --suffix SUFFIX     kernel name suffix (default: -arc1)
#   --workdir DIR       build directory (default: /var/tmp/pve-arc-rebar)
#   --uninstall         remove kernel, parameter, services and tools
#   --force             continue despite failed preflight checks
#   -y, --yes           don't ask for confirmation
#
# Nothing reboots on its own. The stock kernel stays the default unless
# --make-default is given.

set -euo pipefail

REPO=${PVE_ARC_REBAR_REPO:-propstat/proxmox-rebar}
REPO_REF=${PVE_ARC_REBAR_REF:-main}
PVE_KERNEL_GIT=https://git.proxmox.com/git/pve-kernel.git
# proxmox-kernel 7.0.14-29, the version the patches were checked against
PVE_KERNEL_REF=6e8323667a9635eede4b84cb71d1c9d5de04946e
SUFFIX=-arc1
WORKDIR=/var/tmp/pve-arc-rebar
PARAM=pci_arc_release_bar0
MIN_DISK_GB=60

DO_BUILD=1 DO_INSTALL=1 DEB="" PARAM_ONLY="" ENABLE_PARAM=0 TEST_BOOT=0 MAKE_DEFAULT=0
VFIO_AUTO=0 TOOLS=1 UNINSTALL=0 FORCE=0 YES=0

# ==============================================================================
# PROPSTAT COLOR PALETTE
# ==============================================================================

# CI COLORS
PS_DARK_BLUE=$(printf '\033[38;2;0;40;85m')       # #002855
PS_LIGHT_BLUE=$(printf '\033[38;2;94;147;219m')   # #5E93DB
PS_GREY=$(printf '\033[38;2;63;68;68m')           # #3F4444
PS_SKY_BLUE=$(printf '\033[38;2;221;229;237m')    # #DDE5ED

# INTERFACE COLORS
PS_RED=$(printf '\033[38;2;218;41;28m')            # #DA291C
PS_ORANGE=$(printf '\033[38;2;253;170;99m')        # #FDAA63
PS_YELLOW=$(printf '\033[38;2;250;224;83m')        # #FAE053
PS_GREEN=$(printf '\033[38;2;92;170;127m')         # #5CAA7F

# TERMINAL FORMATTING
PS_BOLD=$(printf '\033[1m')
PS_DIM=$(printf '\033[2m')
NC=$(printf '\033[0m')

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
check_fail() { if [ $FORCE -eq 1 ]; then warn "$* (continuing because of --force)"; else die "$* (override with --force)"; fi; }

confirm() {
  [ $YES -eq 1 ] && return 0
  local a
  [ -r /dev/tty ] || die "no terminal to ask; rerun with -y"
  read -r -p "$1 [y/N] " a </dev/tty
  [[ $a == [yY]* ]]
}

# ==========================================
# LOGO
# ==========================================
cat << EOF

=========================================================

            ${PS_DARK_BLUE}${PS_BOLD}ii${PS_LIGHT_BLUE}%%%%%%%             ${PS_DARK_BLUE}i${PS_LIGHT_BLUE}%%%%%%%${NC}           
           ${PS_DARK_BLUE}${PS_BOLD}iiii${PS_LIGHT_BLUE}%%%%%%%           ${PS_DARK_BLUE}iii${PS_LIGHT_BLUE}%%%%%%%${NC}          
          ${PS_DARK_BLUE}${PS_BOLD}iiiiii${PS_LIGHT_BLUE}%%%%%%%         ${PS_DARK_BLUE}iiiii${PS_LIGHT_BLUE}%%%%%%%${NC}         
         ${PS_DARK_BLUE}${PS_BOLD}iiiiiii ${PS_LIGHT_BLUE}%%%%%%%       ${PS_DARK_BLUE}iiiiii ${PS_LIGHT_BLUE}%%%%%%%${NC}        
        ${PS_DARK_BLUE}${PS_BOLD}iiiiiii   ${PS_LIGHT_BLUE}%%%%%%%    ${PS_DARK_BLUE}iiiiiii   ${PS_LIGHT_BLUE}%%%%%%%${NC}       
       ${PS_DARK_BLUE}${PS_BOLD}iiiiiii     ${PS_LIGHT_BLUE}%%%%%%%  ${PS_DARK_BLUE}iiiiiii     ${PS_LIGHT_BLUE}%%%%%%%${NC}      
      ${PS_DARK_BLUE}${PS_BOLD}iiiiiii       ${PS_LIGHT_BLUE}%%%%%%%${PS_DARK_BLUE}iiiiii        ${PS_LIGHT_BLUE}%%%%%%%${NC}     
     ${PS_DARK_BLUE}${PS_BOLD}iiiiiii         ${PS_LIGHT_BLUE}%%%%%%%${PS_DARK_BLUE}iiii          ${PS_LIGHT_BLUE}%%%%%%%${NC}    
    ${PS_DARK_BLUE}${PS_BOLD}iiiiiii           ${PS_LIGHT_BLUE}%%%%%%%${PS_DARK_BLUE}ii            ${PS_LIGHT_BLUE}%%%%%%%${NC}   
   ${PS_DARK_BLUE}${PS_BOLD}iiiiiiiiiiiiiiiiiiii${PS_LIGHT_BLUE}%%%%%%*%%%%%%%%%%%%%%%%%%%%%${NC}  
  ${PS_DARK_BLUE}${PS_BOLD}iiiiiiiiiiiiiiiiiiiiii${PS_LIGHT_BLUE}%%%%%%%%%%%%%%%%%%%%%%%%%%%%${NC}
 ${PS_DARK_BLUE}${PS_BOLD}iiiiiiiiiiiiiiiiiiiiiiii${PS_LIGHT_BLUE}%%%%%%%%%%%%%%%%%%%%%%%%%%%%${NC}
                                                   
${PS_DARK_BLUE}${PS_BOLD}iiiii  iiiiii iiiiii  iiiii  iiiiii iiiiii  iii  iiiiii${NC}
${PS_DARK_BLUE}${PS_BOLD}ii  ii ii  ii ii  ii  ii  ii  ii     ii    ii ii   ii${NC}  
${PS_DARK_BLUE}${PS_BOLD}iiiii  iiiiii ii  ii  iiiii     ii   ii   iiiiiii  ii${NC}  
${PS_DARK_BLUE}${PS_BOLD}ii     ii  ii iiiiii  ii     iiiiii  ii   ii   ii  ii${NC}  

=========================================================
${PS_GREEN}${PS_BOLD}Propstat Installation Wizard${NC}
=========================================================

Non-Commercial use is free of charge, please consult our
license for commercial use.
Please use the following link to view the license:
https://github.com/propstat/server-templates?tab=License-1-ov-file

=========================================================

${PS_RED}${PS_BOLD}YOU ARE DOWNLOADING MATERIAL COVERED BY COPYRIGHT AND${NC}
${PS_RED}${PS_BOLD}LICENSED UNDER THE PROPSTAT LICENSE. IF YOU CONTINUE${NC}
${PS_RED}${PS_BOLD}YOU AGREE TO THE LICENSE TERMS.${NC}

=========================================================

EOF

usage() { sed -n '4,27p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) DO_INSTALL=0 ;;
    --install-deb) shift; DEB=${1:?--install-deb needs a file}; DO_BUILD=0 ;;
    --enable-param) ENABLE_PARAM=1 ;;
    --param) shift; PARAM_ONLY=${1:?--param needs on or off} ;;
    --test-boot) TEST_BOOT=1 ;;
    --make-default) MAKE_DEFAULT=1 ;;
    --vfio-autoresize) VFIO_AUTO=1 ;;
    --no-tools) TOOLS=0 ;;
    --ref) shift; PVE_KERNEL_REF=${1:?--ref needs a value} ;;
    --suffix) shift; SUFFIX=${1:?--suffix needs a value} ;;
    --workdir) shift; WORKDIR=${1:?--workdir needs a value} ;;
    --uninstall) UNINSTALL=1 ;;
    --force) FORCE=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) usage 0 ;;
    *) warn "unknown option: $1"; usage 1 ;;
  esac
  shift
done

WORKDIR=$(readlink -m "$WORKDIR")
[[ $SUFFIX =~ ^-[a-z0-9]+$ ]] || die "suffix must look like -arc1 (lowercase letters and digits)"
[ $TEST_BOOT -eq 1 ] && [ $MAKE_DEFAULT -eq 1 ] && die "--test-boot and --make-default exclude each other"

# ---------------------------------------------------------------- helpers

is_pve() { command -v proxmox-boot-tool >/dev/null && [ -d /etc/pve ]; }

boot_refresh() {
  if command -v proxmox-boot-tool >/dev/null; then
    proxmox-boot-tool refresh || warn "proxmox-boot-tool refresh failed"
  fi
  if command -v update-grub >/dev/null && [ -f /boot/grub/grub.cfg ]; then
    update-grub || warn "update-grub failed"
  fi
}

param_add() {
  local changed=0
  if [ -f /etc/kernel/cmdline ] && ! grep -qw "$PARAM" /etc/kernel/cmdline; then
    sed -i -E "1s/\$/ $PARAM/; 1s/^ +//" /etc/kernel/cmdline; changed=1
    log "added $PARAM to /etc/kernel/cmdline (systemd-boot)"
  fi
  if [ -f /etc/default/grub ] && ! grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*\b$PARAM\b" /etc/default/grub; then
    sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\")(.*)\"/\1\2 $PARAM\"/; s/^(GRUB_CMDLINE_LINUX_DEFAULT=\") +/\1/" /etc/default/grub; changed=1
    log "added $PARAM to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
  fi
  [ $changed -eq 1 ] && boot_refresh
  return 0
}

param_remove() {
  local changed=0
  if [ -f /etc/kernel/cmdline ] && grep -qw "$PARAM" /etc/kernel/cmdline; then
    sed -i -E "s/ ?\b$PARAM(=[^ ]*)?\b//g; 1s/^ +//" /etc/kernel/cmdline; changed=1
  fi
  if [ -f /etc/default/grub ] && grep -q "\b$PARAM\b" /etc/default/grub; then
    sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/{s/ ?\b$PARAM(=[^ \"]*)?\b//g; s/=\" +/=\"/}" /etc/default/grub; changed=1
  fi
  [ $changed -eq 1 ] && { log "removed $PARAM from the kernel command line"; boot_refresh; }
  return 0
}

# Directory holding patches/ and tools/: next to this script, or downloaded.
SRC_DIR=""
find_sources() {
  local here=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [ -n "$here" ] && [ -d "$here/patches" ] && [ -d "$here/tools" ]; then
    SRC_DIR=$here
    return
  fi
  log "downloading $REPO ($REPO_REF)"
  command -v curl >/dev/null || { apt-get update -q && apt-get install -y -q curl ca-certificates; }
  mkdir -p "$WORKDIR/src"
  rm -rf "$WORKDIR/src/repo" && mkdir -p "$WORKDIR/src/repo"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REPO_REF" | tar xz -C "$WORKDIR/src/repo" --strip-components=1 ||
    die "download of $REPO failed"
  SRC_DIR=$WORKDIR/src/repo
}

# ---------------------------------------------------------------- --param

if [ -n "$PARAM_ONLY" ]; then
  [ "$(id -u)" -eq 0 ] || die "run as root"
  case "$PARAM_ONLY" in
    on) param_add ;;
    off) param_remove ;;
    *) die "--param takes on or off" ;;
  esac
  log "kernel command line for the next boot:"
  [ -f /etc/kernel/cmdline ] && echo "  /etc/kernel/cmdline: $(cat /etc/kernel/cmdline)"
  [ -f /etc/default/grub ] && echo "  /etc/default/grub:   $(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub)"
  exit 0
fi

# ---------------------------------------------------------------- uninstall

if [ $UNINSTALL -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "run as root"
  mapfile -t PKGS < <(dpkg-query -W -f='${Package}\n' "proxmox-kernel-*${SUFFIX}-pve" "proxmox-headers-*${SUFFIX}-pve" 2>/dev/null || true)
  if uname -r | grep -q -- "${SUFFIX}-pve\$"; then
    die "the test kernel $(uname -r) is running; boot the stock kernel first"
  fi
  confirm "Remove ${PKGS[*]:-no packages}, the $PARAM parameter, services and tools?" || exit 1
  if [ -f /etc/kernel/proxmox-boot-pin ] && grep -q -- "${SUFFIX}-pve" /etc/kernel/proxmox-boot-pin; then
    proxmox-boot-tool kernel unpin || true
  fi
  for s in arc-vfio-resize pci-rebar-group; do
    systemctl disable --now "$s.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/sbin/{arc-vfio-resize,collect-arc-info,rebar-window-check,pci-rebar-group}
  param_remove
  [ ${#PKGS[@]} -gt 0 ] && apt-get remove -y "${PKGS[@]}"
  log "done; the build directory $WORKDIR can be deleted by hand"
  exit 0
fi

# ---------------------------------------------------------------- preflight

[ "$(id -u)" -eq 0 ] || die "run as root"
[ "$(dpkg --print-architecture)" = amd64 ] || die "only amd64 is supported"
# shellcheck disable=SC1091
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || check_fail "this needs Debian 13 (trixie) / Proxmox VE 9, found ${PRETTY_NAME:-unknown}"

if [ $DO_BUILD -eq 1 ]; then
  mkdir -p "$WORKDIR"
  free_gb=$(df -BG --output=avail "$WORKDIR" | tail -1 | tr -dc 0-9)
  [ "$free_gb" -ge $MIN_DISK_GB ] || check_fail "only ${free_gb} GB free in $WORKDIR, the build needs about ${MIN_DISK_GB} GB"
  mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  [ "$mem_gb" -ge 8 ] || warn "only ${mem_gb} GB RAM; the build may be very slow or fail"
  log "build machine: $(nproc) cores, ${mem_gb} GB RAM, ${free_gb} GB free in $WORKDIR"
fi

if [ $DO_INSTALL -eq 1 ]; then
  is_pve || check_fail "this is not a Proxmox VE host; use --build-only on a build machine"
  if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
    check_fail "Secure Boot is enabled; the self-built kernel is unsigned and will not boot"
  fi
  if [ -n "$DEB" ]; then
    [ -f "$DEB" ] || die "no such file: $DEB"
    DEB=$(readlink -f "$DEB")
  fi
fi

find_sources
ls "$SRC_DIR"/patches/9*.patch >/dev/null 2>&1 || die "no patches found in $SRC_DIR/patches"

# ---------------------------------------------------------------- build

if [ $DO_BUILD -eq 1 ]; then
  confirm "Build the Proxmox kernel with the Arc patches in $WORKDIR? This takes hours." || exit 1
  exec > >(tee -a "$WORKDIR/build.log") 2>&1
  log "log file: $WORKDIR/build.log"

  log "installing build tools"
  apt-get update -q
  apt-get install -y -q --no-install-recommends git devscripts equivs patch ca-certificates curl

  K=$WORKDIR/pve-kernel
  if [ -d "$K/.git" ]; then
    log "updating $K"
    git -C "$K" fetch -q origin
    git -C "$K" reset -q --hard
    git -C "$K" clean -q -xdff
  else
    log "cloning pve-kernel"
    git clone -q "$PVE_KERNEL_GIT" "$K"
  fi
  ref=$PVE_KERNEL_REF
  git -C "$K" rev-parse -q --verify "origin/$ref" >/dev/null && ref=origin/$ref
  git -C "$K" checkout -q --detach "$ref"
  log "pve-kernel at $(git -C "$K" log -1 --format='%h %s')"
  log "fetching kernel and ZFS sources (large download)"
  git -C "$K" submodule update -q --init --recursive

  cp "$SRC_DIR"/patches/9*.patch "$K/patches/kernel/"
  sed -i "s/^KREL_EXTRA=.*/KREL_EXTRA=$SUFFIX/" "$K/Makefile"

  cd "$K"
  log "preparing the build directory and applying all patches"
  make build-dir-fresh </dev/null || die "preparing the build failed; if a 9xxx patch was rejected, it no longer fits this pve-kernel version"
  BD=$(find . -maxdepth 1 -type d -name 'proxmox-kernel-*' | head -1)
  [ -n "$BD" ] || die "build directory not found"
  grep -q "$PARAM" "$BD/ubuntu-kernel/drivers/pci/quirks.c" || die "the Arc patches are missing from the prepared source"

  log "installing build dependencies"
  mk-build-deps -ir -t "apt-get -y -q --no-install-recommends" "$BD/debian/control"

  log "building (this takes a while)"
  make deb </dev/null || warn "make deb reported an error; checking whether the packages were built anyway"
  DEB=$(find "$K" -maxdepth 1 -name "proxmox-kernel-*${SUFFIX}-pve_*_amd64.deb" | head -1)
  [ -n "$DEB" ] || die "kernel package not found, see $WORKDIR/build.log"
  mkdir -p "$WORKDIR/out"
  cp "$K"/proxmox-kernel-*"${SUFFIX}"-pve_*_amd64.deb "$K"/proxmox-headers-*"${SUFFIX}"-pve_*_amd64.deb "$WORKDIR/out/" 2>/dev/null || true
  DEB=$WORKDIR/out/$(basename "$DEB")
  log "built: $DEB"
fi

[ $DO_INSTALL -eq 1 ] || { log "done; copy $DEB to the Proxmox host and run: install.sh --install-deb <file>"; exit 0; }

# ---------------------------------------------------------------- install

KV=$(basename "$DEB"); KV=${KV#proxmox-kernel-}; KV=${KV%%_*}
[[ $KV == *-pve ]] || die "unexpected package name: $(basename "$DEB")"

confirm "Install kernel $KV next to the stock kernel?" || exit 1
apt-get install -y "$DEB"
log "installed kernel $KV"

if [ $TOOLS -eq 1 ]; then
  install -m 0755 "$SRC_DIR"/tools/{arc-vfio-resize,collect-arc-info,rebar-window-check,pci-rebar-group} /usr/local/sbin/
  install -m 0644 "$SRC_DIR"/tools/{arc-vfio-resize,pci-rebar-group}.service /etc/systemd/system/
  systemctl daemon-reload
  log "installed helper tools to /usr/local/sbin (services not enabled)"
fi

if [ $VFIO_AUTO -eq 1 ]; then
  [ -f /etc/systemd/system/arc-vfio-resize.service ] || die "--vfio-autoresize needs the tools; drop --no-tools"
  systemctl enable arc-vfio-resize.service
  log "enabled arc-vfio-resize.service (runs only with $PARAM set)"
fi

[ $ENABLE_PARAM -eq 1 ] && param_add

if [ $TEST_BOOT -eq 1 ]; then
  proxmox-boot-tool kernel pin "$KV" --next-boot
  log "the next boot uses $KV once; the boot after that uses the default again"
fi
if [ $MAKE_DEFAULT -eq 1 ]; then
  warn "pinning $KV permanently; newer Proxmox kernels will not boot by default until 'proxmox-boot-tool kernel unpin'"
  proxmox-boot-tool kernel pin "$KV"
fi

echo
log "kernels on this host:"
proxmox-boot-tool kernel list || true
echo
cat <<EOF
Next steps:
  1. Boot the test kernel once:  proxmox-boot-tool kernel pin $KV --next-boot && reboot
     (skip if you used --test-boot or --make-default)
  2. Without $PARAM the kernel behaves like the stock one and logs a hint.
     Enable it, then boot the test kernel again:  install.sh --param on
  3. Resize passthrough GPUs (VMs stopped):  arc-vfio-resize --dry-run, then arc-vfio-resize
  4. Collect results per phase:  collect-arc-info <label>
  Roll back: just reboot (one-time boot), or: install.sh --uninstall
EOF
