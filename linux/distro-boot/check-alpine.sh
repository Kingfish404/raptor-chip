#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
trap 'rc-status -a || true; dmesg | tail -n 30 || true; echo RAPTOR_DISTRO_CHECK_FAIL' EXIT
test "$(uname -m)" = riscv64
test "$(apk --print-arch)" = riscv64
. /etc/os-release
printf 'RAPTOR_DISTRO_ID=%s VERSION_ID=%s\n' "$ID" "$VERSION_ID"
rc-status --version
apk info -e alpine-base openrc openssh
awk 'BEGIN { if (sqrt(81) != 9 || 1.25 * 4 != 5) exit 1; print "RAPTOR_FP_PASS" }'
rc-service sshd status
printf 'raptor-distro-root-write\n' > /var/tmp/raptor-root-check
sync
test "$(cat /var/tmp/raptor-root-check)" = raptor-distro-root-write
ip address show
if grep -Eq '^isa[[:space:]]*:[[:space:]]*(rv(32|64)[a-z]*h([^a-z0-9]|$)|.*_h(_|$))' /proc/cpuinfo; then
    test -c /dev/kvm
    echo RAPTOR_KVM_DEV_PASS
fi
/usr/local/lib/raptor-smp-check "$(cat /etc/raptor-harts)"
echo RAPTOR_DISTRO_CHECK_PASS
trap - EXIT
poweroff
