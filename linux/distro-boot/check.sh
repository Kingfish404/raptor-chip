#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
trap 'systemctl --failed --no-pager; journalctl -b -p err --no-pager -n 30; echo RAPTOR_DISTRO_CHECK_FAIL' EXIT
test "$(cat /proc/1/comm)" = systemd
test "$(uname -m)" = riscv64
test "$(dpkg --print-architecture)" = riscv64
. /etc/os-release
printf 'RAPTOR_DISTRO_ID=%s VERSION_ID=%s\n' "$ID" "$VERSION_ID"
systemctl --version
getconf GNU_LIBC_VERSION
dpkg-query -W systemd libc6 apt
awk 'BEGIN { if (sqrt(81) != 9 || 1.25 * 4 != 5) exit 1; print "RAPTOR_FP_PASS" }'
systemctl is-active multi-user.target
systemctl is-active serial-getty@ttyS0.service
test -z "$(systemctl --failed --no-legend --plain)"
test "$(/bin/dash -c 'printf "%s\n" dynamic-linker | sha256sum | cut -d" " -f1')" = f315d0fd78d6f5335496116f22fbfed4c05634278a66fe805258f4b16fd66ffc
printf 'raptor-distro-root-write\n' > /var/tmp/raptor-root-check
sync
test "$(cat /var/tmp/raptor-root-check)" = raptor-distro-root-write
findmnt -n -o SOURCE,FSTYPE /
ip -brief address
/usr/local/lib/raptor-smp-check "$(cat /etc/raptor-harts)"
echo RAPTOR_DISTRO_CHECK_PASS
trap - EXIT
systemctl --no-block poweroff
