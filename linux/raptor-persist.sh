#!/bin/sh
# Optional shared ext4 data partition. Never partition, format or repair a disk.
# Mount before starting services or login shells. /run and /dev must exist.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
state=/run/raptor-persist
mkdir -p "$state"
log() { echo "raptor-persist: $*"; }
mounted() { grep -q " $1 " /proc/mounts; }
unavailable() {
    printf '%s\n' "$*" > "$state/status"
    mkdir -p /data
    if ! mounted /data; then
        mount -t tmpfs -o ro,nosuid,nodev,noexec,size=4k,mode=0555 raptor-no-data /data || log 'WARNING: cannot protect /data'
    fi
    log "$*; home/root remain in RAM"
    exit 0
}
if [ -f "$state/ready" ]; then log "already mounted: $(cat "$state/ready")"; exit 0; fi
mkdir "$state/lock" 2>/dev/null || { log 'another mount operation is active'; exit 1; }
trap 'rmdir "$state/lock"' EXIT
selector=LABEL=RAPTOR_DATA
logs=0
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        raptor.data=*) selector=${arg#raptor.data=} ;;
        raptor.persist=off) unavailable disabled ;;
        raptor.persist_logs=1) logs=1 ;;
    esac
done
case "$selector" in
    LABEL=*) field=LABEL; value=${selector#LABEL=} ;;
    UUID=*) field=UUID; value=${selector#UUID=} ;;
    *) unavailable 'invalid selector (use LABEL= or UUID=)' ;;
esac
case "$value" in ''|*[!a-zA-Z0-9_-]*) unavailable 'invalid selector characters' ;; esac
# blkid's default output is supported by both BusyBox and util-linux.
# Wait briefly for asynchronous MMC enumeration, not indefinitely on no-card.
attempt=0
while :; do
    blkid > "$state/blkid" 2>/dev/null || true
    matches=$(grep " $field=\"$value\"" "$state/blkid" || true)
    [ -n "$matches" ] && break
    attempt=$((attempt + 1))
    [ "$attempt" -ge 3 ] && unavailable 'data partition not found'
    sleep 1
done
count=$(printf '%s\n' "$matches" | wc -l)
[ "$count" -eq 1 ] || unavailable 'ambiguous data partition selector'
# Older Buildroot BusyBox omits TYPE in blkid output. The explicit ext4
# mount below still validates the filesystem before accepting it.
case "$matches" in
    *' TYPE="ext4"'*) ;;
    *' TYPE="'*) unavailable 'data partition is not ext4' ;;
esac
device=${matches%%:*}
case "$device" in /dev/*) ;; *) unavailable 'invalid block device path' ;; esac
[ -b "$device" ] || unavailable 'selected device is not a block device'
# Never bind an already-mounted root filesystem back onto itself.
if grep -q "^$device " /proc/mounts; then unavailable 'selected device already mounted'; fi
ID=unknown
VERSION_ID=unknown
[ ! -r /etc/os-release ] || . /etc/os-release
machine=$(uname -m)
case "$machine" in riscv32|riscv64) ;; *) unavailable 'unsupported machine' ;; esac
system="$machine-$ID-$VERSION_ID"
case "$system" in *[!a-zA-Z0-9_.-]*) unavailable 'invalid system identity' ;; esac
[ ! -L /data ] || unavailable 'refusing symlink /data'
mkdir -p /data
if mounted /data; then
    grep -q '^raptor-no-data /data tmpfs ' /proc/mounts || unavailable '/data already mounted'
    umount /data
fi
mount -t ext4 -o rw,noatime,nosuid,nodev,errors=remount-ro "$device" /data || unavailable 'ext4 mount failed'
base=/data/systems/$system
for directory in /data/shared /data/systems "$base"; do
    [ ! -L "$directory" ] || { log "refusing symlink $directory"; exit 1; }
    mkdir -p "$directory"
done
chmod 700 "$base"
targets='home root'
[ "$logs" -eq 0 ] || targets="$targets var/log"
# Seed each directory atomically only once. Never overwrite saved content.
for target in $targets; do
    case "$target" in var/log) name=log ;; *) name=$target ;; esac
    saved=$base/$name
    [ ! -L "$saved" ] && [ ! -L "/$target" ] || { log "refusing symlink $target"; exit 1; }
    mkdir -p "/$target"
    if [ ! -e "$saved" ]; then
        seed=$base/.seed-$name-$$
        mkdir -m 700 "$seed"
        cp -a "/$target/." "$seed/"
        mv "$seed" "$saved"
    fi
    [ -d "$saved" ] || { log "$saved is not a directory"; exit 1; }
done
bound=''
for target in $targets; do
    case "$target" in var/log) name=log ;; *) name=$target ;; esac
    if mounted "/$target" || ! mount --bind "$base/$name" "/$target"; then
        for old in $bound; do umount "/$old" || true; done
        log "bind mount failed: $target; persistence setup incomplete"
        exit 1
    fi
    bound="$target $bound"
done
printf '%s\n' "$device $system" > "$state/ready"
printf '%s\n' mounted > "$state/status"
log "mounted $device at /data; system=$system; bound=$targets"
