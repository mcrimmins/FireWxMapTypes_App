#!/usr/bin/env bash
# build/setup_server.sh
# -----------------------------------------------------------------------------
# One-time preparation of the Ubuntu Server build box (ThinkCentre M710q).
# Run as your normal user; it uses sudo where it needs to.
#
#   bash build/setup_server.sh
#
# Idempotent — safe to re-run. It installs system libraries and R, and then
# checks the things that quietly ruin a 21-hour unattended run: disk space that
# is smaller than df suggests, automatic reboots, and suspend-on-idle.
# -----------------------------------------------------------------------------
set -euo pipefail

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }

say "1. System packages"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential gfortran pkg-config \
    libcurl4-openssl-dev libssl-dev libxml2-dev \
    libnetcdf-dev netcdf-bin \
    libgdal-dev libgeos-dev libproj-dev libudunits2-dev \
    libsodium-dev libsecret-1-dev \
    curl git rsync tmux jq

# libnetcdf-dev  -> ncdf4
# libgdal/geos/proj/udunits2 -> terra (phase 4). Heavy, but installing it now
#   means phase 2 and 4 do not need a second maintenance window.
# libsecret-1-dev -> keyring builds; the "env" backend is what actually gets
#   used headless (see setup_cds in util/era5_common.R) but the package still
#   compiles against libsecret.

say "2. R"
if ! command -v R >/dev/null 2>&1; then
    # CRAN's Ubuntu repository — the distro's own r-base is usually years old,
    # and renv.lock pins R 4.5.2.
    sudo apt-get install -y --no-install-recommends software-properties-common dirmngr
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
        | sudo tee /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc >/dev/null
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    sudo add-apt-repository -y \
        "deb https://cloud.r-project.org/bin/linux/ubuntu ${CODENAME}-cran40/"
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends r-base-core r-base-dev
fi
R --version | head -1

say "3. Disk space"
# THE ONE THAT BITES: the Ubuntu Server installer's default LVM layout leaves
# roughly half the disk unallocated — ubuntu-lv is commonly created at ~100 GB
# on a 250 GB SSD and the rest sits idle in the volume group. Phase 1 needs
# ~9 GB at peak and phase 2 needs headroom on top, so this is usually fine, but
# find out now rather than at hour 14.
df -h /
if command -v vgs >/dev/null 2>&1; then
    vgs || true
    FREE=$(sudo vgs --noheadings -o vg_free --units g 2>/dev/null | tr -d ' g' | head -1 || echo 0)
    if [ "${FREE%%.*}" -gt 5 ] 2>/dev/null; then
        warn "${FREE}G is unallocated in the volume group. To claim it:"
        echo "     sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv"
        echo "     sudo resize2fs /dev/ubuntu-vg/ubuntu-lv"
    fi
fi

say "4. Memory"
free -h
# Aggregation holds every year of a variable's daily matrices in memory before
# writing: 3,321 cells x 12,054 days x 8 bytes is ~320 MB per statistic, and
# gust carries two. Peak is roughly 1.5-2 GB. 8 GB is comfortable; 4 GB is not,
# and the OOM killer will take the R process without ceremony.
TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_MB" -lt 7000 ]; then
    warn "Only ${TOTAL_MB} MB RAM. Add swap before running the full record:"
    echo "     sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile"
    echo "     sudo mkswap /swapfile && sudo swapon /swapfile"
    echo "     echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"
fi

say "5. Stop the box interrupting itself"
# Unattended-upgrades can reboot mid-run if Automatic-Reboot is on. Suspend on a
# headless machine is worse: it comes back with a dead TCP connection to the CDS
# and the run wedged rather than failed.
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
if grep -rqs '^Unattended-Upgrade::Automatic-Reboot *"true"' /etc/apt/apt.conf.d/; then
    warn "unattended-upgrades is set to reboot automatically. Turn it off for the run:"
    echo "     sudo sed -i 's/^Unattended-Upgrade::Automatic-Reboot .*/Unattended-Upgrade::Automatic-Reboot \"false\";/' /etc/apt/apt.conf.d/50unattended-upgrades"
fi
# Also worth checking in BIOS: "After Power Loss -> Power On", so an outage
# brings the box back and systemd resumes the run on its own.

say "6. Let user services run without a login session"
# Without lingering, systemd --user units are killed when your SSH session ends
# — which is precisely the thing we are trying to survive.
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger

say "7. Timezone"
timedatectl | sed -n '1,4p'
# The build applies the MST offset explicitly (BCFG$tz_shift_h = -7) and every
# POSIXct it constructs carries tzone="UTC", so as.Date() cannot pick up the
# server's local zone. Setting TZ=UTC in the service unit anyway costs nothing
# and makes the log timestamps unambiguous.

say "8. Install the systemd units"
mkdir -p "$HOME/.config/systemd/user"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed "s|@REPO@|$REPO|g" "$REPO/build/firewx-build.service" \
    > "$HOME/.config/systemd/user/firewx-build.service"
cp "$REPO/build/firewx-notify-fail.service" "$HOME/.config/systemd/user/"
sed -i "s|@REPO@|$REPO|g" "$HOME/.config/systemd/user/firewx-notify-fail.service"
systemctl --user daemon-reload
echo "installed: firewx-build.service, firewx-notify-fail.service"

say "Next steps"
cat <<EOF
  1. Put your secrets in ${REPO}/.Renviron  (gitignored — never commit it):
         CDS_KEY=<your CDS personal access token>
         NTFY_TOPIC=firewx-build-<long-random-string>
         RENV_PROFILE=build
  2. Install the R packages:
         cd ${REPO} && RENV_PROFILE=build Rscript build/bootstrap.R
  3. Smoke test one year in the foreground:
         cd ${REPO} && Rscript build/run_phase1.R 2020
  4. Start the real run:
         systemctl --user start firewx-build
         journalctl --user -u firewx-build -f
EOF
