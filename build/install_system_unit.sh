#!/usr/bin/env bash
# build/install_system_unit.sh
# -----------------------------------------------------------------------------
# FALLBACK: install the build as a SYSTEM service instead of a user service.
#
#   sudo bash build/install_system_unit.sh
#
# Use this only if `systemctl --user` cannot reach the per-user bus — typically
# because the shell is not a logind session (reached via `su -` from root) and
# logging in directly over SSH is not an option.
#
# A system unit needs no XDG_RUNTIME_DIR and no lingering; it starts at boot
# regardless of whether anyone has logged in. The cost is that every command
# loses the --user flag and gains a sudo:
#
#   sudo systemctl start firewx-build
#   sudo journalctl -u firewx-build -f
#
# The service still RUNS as your user, from your home directory, reading your
# .Renviron — only the manager is different.
# -----------------------------------------------------------------------------
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_AS="${SUDO_USER:-}"
[ -n "$RUN_AS" ] || { echo "Could not determine the invoking user; run via sudo, not as root directly."; exit 1; }
RUN_GRP="$(id -gn "$RUN_AS")"

echo "repo:  $REPO"
echo "user:  $RUN_AS:$RUN_GRP"

# The unit is identical apart from the manager, so generate it from the same
# source file rather than maintaining a second copy that can drift.
sed -e "s|@REPO@|$REPO|g" \
    -e "/^\[Service\]/a User=$RUN_AS\nGroup=$RUN_GRP" \
    "$REPO/build/firewx-build.service" > /etc/systemd/system/firewx-build.service

# The notifier greps `journalctl --user`; a system unit's log is not there.
sed -e "s|@REPO@|$REPO|g" \
    -e "s|journalctl --user -u|journalctl -u|" \
    -e "/^\[Service\]/a User=$RUN_AS\nGroup=$RUN_GRP" \
    "$REPO/build/firewx-notify-fail.service" > /etc/systemd/system/firewx-notify-fail.service

systemctl daemon-reload
echo "installed: /etc/systemd/system/firewx-build.service"
echo "           /etc/systemd/system/firewx-notify-fail.service"

cat <<EOF

Commands change — drop --user, add sudo:
    sudo systemctl start   firewx-build
    sudo systemctl status  firewx-build
    sudo journalctl -u     firewx-build -f
    sudo systemctl stop    firewx-build        # safe, the build is resumable

Optional, so it resumes by itself after a reboot or power cut:
    sudo systemctl enable firewx-build
EOF
