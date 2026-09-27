#!/usr/bin/env bash
#
# homelab-persist-prepare — make one Azure data disk safe to mount (#99)
#
# Runs as homelab-persist-prepare@<LUN>.service on EVERY boot, ahead of that
# disk's .mount unit. It is the only code in this lab that can destroy data
# (risk R4), so it refuses rather than guesses:
#
#   partition 1 holds ext4    -> e2fsck -p, never format        (every normal boot)
#   no signature anywhere     -> GPT + one partition + ext4     (a brand-new disk, once)
#   anything else             -> FATAL, touch nothing           (a human decides)
#
# "Anything else" includes a partition table with no filesystem on partition 1
# (what an interrupted first format leaves), a filesystem other than ext4, and a
# filesystem written straight onto the whole device. None of those is ever
# formatted over; docs/runbooks/data_guard.md covers clearing one deliberately.
#
# A fresh format leaves /run/homelab-persist/lun<N>.formatted holding the new
# filesystem's UUID. That file is the only thing that lets homelab-data-guard
# bless a disk automatically (write-persist-marker.sh --created-by cloud-init),
# and /run is tmpfs, so the permission cannot outlive the boot that formatted it.
#
# The disk is addressed only as /dev/disk/azure/scsi1/lun<N> — the udev link
# WALinuxAgent creates for data disks — never as /dev/sdX, whose letters are not
# stable across boots and can name the OS or resource disk.
#
# Usage (normally via systemd):  homelab-persist-prepare <LUN>

set -euo pipefail

TAG="homelab-persist-prepare"
LUN="${1:-}"

say() { printf '%s: %s\n' "$TAG" "$*"; }
fatal() {
  printf '%s: FATAL LUN %s: %s\n' "$TAG" "${LUN:-?}" "$*"
  exit 1
}

[[ "$LUN" =~ ^[0-9]+$ ]] || fatal "usage: ${TAG} <LUN> (a number, got '${LUN}')."
[[ "$(id -u)" -eq 0 ]] || fatal "must run as root."

# Why a 300s wait and not a short device timeout: compute/vm attaches the disk
# with a separate azurerm_virtual_machine_data_disk_attachment, which can only be
# created once the VM exists. On the first boot of every recreated VM — every
# resume — the disk therefore arrives seconds to minutes after boot began. The
# wait only runs to its end when the disk is genuinely not coming.
WAIT_SECONDS="${HOMELAB_PERSIST_WAIT_SECONDS:-300}"

DISK_LINK="/dev/disk/azure/scsi1/lun${LUN}"
PART_LINK="${DISK_LINK}-part1"
RUN_DIR="/run/homelab-persist"
FLAG="${RUN_DIR}/lun${LUN}.formatted"

# The .mount unit's What= is this link, never ${PART_LINK}. A What= under /dev
# makes systemd queue its own job waiting for that device, with a 90s timeout of
# its own that runs alongside the wait below: a disk attached after 90s failed
# the mount and Docker, and nothing retried once prepare found it. A What=
# outside /dev gets no device job, and this link exists only once this run has
# vetted partition 1, so the mount waits on prepare and on nothing else.
VETTED="${RUN_DIR}/lun${LUN}-part1"
vet() {
  install -d -m 0700 "$RUN_DIR"
  ln -sfn "$1" "$VETTED"
}
# A link from an earlier run this boot must not outlive a refusal on this one.
rm -f "$VETTED"

wait_for() { # <path> <seconds>
  local i
  for ((i = 0; i < $2; i++)); do
    [[ -e "$1" ]] && return 0
    sleep 1
  done
  [[ -e "$1" ]]
}

# --- 1. The disk ---------------------------------------------------------------
if [[ ! -e "$DISK_LINK" ]]; then
  say "waiting up to ${WAIT_SECONDS}s for ${DISK_LINK} (the attachment can land after boot)"
  wait_for "$DISK_LINK" "$WAIT_SECONDS" ||
    fatal "no data disk at ${DISK_LINK} after ${WAIT_SECONDS}s. It stays unmounted and Docker stays stopped — see docs/runbooks/data_guard.md."
fi
udevadm settle --timeout=30 || true

DISK="$(readlink -f "$DISK_LINK")"
[[ -b "$DISK" ]] || fatal "${DISK_LINK} resolves to ${DISK}, which is not a block device."

# --- 2. An existing layout: check it, never format it --------------------------
if [[ -e "$PART_LINK" ]]; then
  PART="$(readlink -f "$PART_LINK")"

  if findmnt -rn --source "$PART" >/dev/null; then
    vet "$PART"
    say "LUN ${LUN}: ${PART} is already mounted; nothing to prepare"
    exit 0
  fi

  FSTYPE="$(blkid -p -s TYPE -o value "$PART" 2>/dev/null || true)"
  [[ "$FSTYPE" == "ext4" ]] ||
    fatal "partition 1 (${PART}) holds '${FSTYPE:-no filesystem}', not ext4. Refusing to touch it — an interrupted first format looks exactly like this (docs/runbooks/data_guard.md)."

  # Seam for #207 (online growth): growpart + resize2fs belong here, where the
  # partition is known to be ours and the filesystem is about to be checked.

  # e2fsck's exit status is a bitmask: 1 = errors corrected, 2 = reboot advised
  # (meaningful only for a mounted root filesystem), 4 and up = errors left
  # uncorrected or an operational failure. Only that last class blocks the mount.
  rc=0
  e2fsck -p "$PART" || rc=$?
  ((rc < 4)) ||
    fatal "e2fsck -p ${PART} exited ${rc}: the filesystem needs a manual fsck before it is mounted (docs/runbooks/data_guard.md)."

  vet "$PART"
  say "LUN ${LUN}: existing ext4 on ${PART} (UUID $(blkid -p -s UUID -o value "$PART"), e2fsck status ${rc}) — not formatting"
  exit 0
fi

# --- 3. No partition 1: format only a disk that carries nothing at all ---------
if findmnt -rn --source "$DISK" >/dev/null; then
  fatal "${DISK} is mounted as a whole device. Refusing to touch it."
fi

KERNEL_PARTS="$(lsblk -nro NAME "$DISK" | tail -n +2)"
[[ -z "$KERNEL_PARTS" ]] ||
  fatal "the kernel sees partitions on ${DISK} (${KERNEL_PARTS//$'\n'/ }) but ${PART_LINK} does not exist. Refusing to touch it."

SIGNATURES="$(wipefs --no-act --noheadings --output TYPE,OFFSET "$DISK" 2>/dev/null || true)"
if [[ -n "$SIGNATURES" ]] || blkid -p "$DISK" >/dev/null 2>&1; then
  fatal "${DISK} has no partition 1 but carries existing signatures (${SIGNATURES//$'\n'/; }). Refusing to format over them (docs/runbooks/data_guard.md)."
fi

say "LUN ${LUN}: ${DISK} carries no signature — first use of this disk: GPT, one partition, ext4"
parted --script "$DISK" mklabel gpt mkpart primary ext4 0% 100%
partprobe "$DISK" || true
udevadm settle --timeout=30 || true
wait_for "$PART_LINK" 30 || fatal "partitioned ${DISK}, but ${PART_LINK} never appeared."

PART="$(readlink -f "$PART_LINK")"
mkfs.ext4 -q "$PART"
UUID="$(blkid -p -s UUID -o value "$PART")"
[[ -n "$UUID" ]] || fatal "mkfs.ext4 ${PART} left no filesystem UUID."

install -d -m 0700 "$RUN_DIR"
printf '%s\n' "$UUID" >"$FLAG"
vet "$PART"
say "LUN ${LUN}: formatted ${PART} as ext4 (UUID ${UUID}); homelab-data-guard will bless it this boot"
