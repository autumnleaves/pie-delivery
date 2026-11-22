#!/usr/bin/env bash
# Prepares a host for pie-delivery's Compose deploys (compose/action.yml). Run once per host, as
# root, from a checkout of this repo, and again to update pie-deploy after a new release:
#
#   sudo bash host/install.sh                      # CI connects with Tailscale SSH
#   sudo bash host/install.sh --ssh-key key.pub    # or with an SSH key, from Tailscale addresses
#
# It sets up:
#   - rsync, sudo and jq
#   - user `deploy`: CI's login. It owns /var/lib/pie/incoming, where bundles arrive, and may
#     run /usr/local/sbin/pie-deploy as root, and nothing else.
#   - /usr/local/sbin/pie-deploy (from host/pie-deploy) and /opt/apps, where apps live
#
# After that, any repo can deploy a Compose app here with no per-app setup on the host.
# Docker with the Compose plugin must already be installed.
set -euo pipefail

USER_NAME=deploy
KEY=""
while [ $# -gt 0 ]; do
    case $1 in
        --ssh-key) KEY=${2:?--ssh-key needs a public key file}; shift 2 ;;
        --user) USER_NAME=${2:?--user needs a name}; shift 2 ;;
        *) echo "usage: sudo bash $0 [--ssh-key <public key file>] [--user <name>]" >&2; exit 2 ;;
    esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
step() { echo "== $*"; }

step "Packages"
docker compose version >/dev/null 2>&1 || { echo "Docker with the Compose plugin isn't installed" >&2; exit 1; }
missing=()
for p in rsync sudo jq util-linux; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ ${#missing[@]} -gt 0 ]; then
    apt-get update -q && apt-get install -yq "${missing[@]}"
fi

step "pie-deploy"
install -m 755 -o root -g root "$HERE/pie-deploy" /usr/local/sbin/pie-deploy
/usr/local/sbin/pie-deploy --version

step "User $USER_NAME"
id "$USER_NAME" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$USER_NAME"
home=$(getent passwd "$USER_NAME" | cut -d: -f6)
if [ -n "$KEY" ]; then
    [ -s "$KEY" ] || { echo "no public key in $KEY" >&2; exit 1; }
    install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$home/.ssh"
    # Only from Tailscale addresses, with no tty or forwarding.
    printf 'restrict,from="100.64.0.0/10,fd7a:115c:a1e0::/48" %s\n' "$(head -n1 "$KEY" | tr -d '\r')" \
        >"$home/.ssh/authorized_keys"
    chown "$USER_NAME:$USER_NAME" "$home/.ssh/authorized_keys"
    chmod 600 "$home/.ssh/authorized_keys"
fi

step "Sudo: pie-deploy only"
tmp=$(mktemp)
echo "$USER_NAME ALL=(root) NOPASSWD: /usr/local/sbin/pie-deploy" >"$tmp"
visudo -cqf "$tmp"
install -m 440 "$tmp" /etc/sudoers.d/pie-deploy
rm -f "$tmp"

step "Folders"
install -d -m 755 /opt/apps /var/lib/pie
install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" /var/lib/pie/incoming

echo
if [ -z "$KEY" ]; then
    if command -v tailscale >/dev/null && tailscale debug prefs 2>/dev/null | jq -e '.RunSSH == true' >/dev/null; then
        echo "Tailscale SSH is on. The tailnet policy needs an ssh rule letting CI in as $USER_NAME, e.g."
    else
        echo "Tailscale SSH is off. Turn it on with 'sudo tailscale set --ssh', then add an ssh rule"
        echo "letting CI in as $USER_NAME. Careful: once it's on, ssh to this host's Tailscale"
        echo "address goes through Tailscale's policy too, so add a rule for your own login first."
    fi
    echo
    echo "  {\"action\": \"accept\", \"src\": [\"tag:ci\"], \"dst\": [\"tag:server\"], \"users\": [\"$USER_NAME\"]}"
    echo
fi
echo "Done. Apps deploy with compose/action.yml; see the README."
