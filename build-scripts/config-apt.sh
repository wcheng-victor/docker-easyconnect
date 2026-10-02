#!/bin/sh
. /etc/os-release &&
if [ -n "${ANDROID_PATCH}" ]; then
	groupadd -g 3003 inet && usermod -a -G inet root && usermod -g inet -ou 0 daemon && usermod -g inet -ou 0 _apt
fi &&
# use qemu-user >= 8.0.0 which fixes https://gitlab.com/qemu-project/qemu/-/issues/866
echo "\
Package: *
Pin: release n=trixie
Pin-Priority: 1

Package: qemu-user
Pin: release n=trixie
Pin-Priority: 990" > /etc/apt/preferences.d/qemu &&
# bullseye (source of aTrust's libssl1.1/libldap-2.4-2) is EOL since 2026-08-31:
# deb.debian.org dropped the bullseye-security files but its stale index still lists
# libssl1.1 1.1.1w-0+deb11u8, which apt prefers over bullseye main and then 404s
# (Debian bug #1147093). Use the complete bullseye archive instead (libssl1.1 there
# is the release version 1.1.1w-0+deb11u1); add bullseye-security from
# archive.debian.org again once it appears there.
echo "deb $MIRROR_URL trixie main
deb $MIRROR_URL $VERSION_CODENAME main
deb http://deb.debian.org/debian-security $VERSION_CODENAME-security main
deb [check-valid-until=no] http://archive.debian.org/debian bullseye main
" > /etc/apt/sources.list &&
rm -rf /etc/apt/sources.list.d
