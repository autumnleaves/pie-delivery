#!/usr/bin/env bash
# Ships a Compose app's bundle to a pie-delivery host and runs pie-deploy there.
# Invoked by compose/action.yml; all configuration arrives via DEPLOY_* env vars.
set -euo pipefail

fail() { echo "::error::$*"; exit 1; }
HOST_VERSION=2

[[ -n "$DEPLOY_HOST" ]] || fail "'host' input is required."
[[ "$DEPLOY_APP" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || fail "'app' must be lowercase letters, digits and dashes (got '$DEPLOY_APP')."
[[ "$DEPLOY_RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "'release' must be letters, digits, dots, dashes or underscores."
[[ -d "$DEPLOY_BUNDLE" ]] || fail "Bundle directory '$DEPLOY_BUNDLE' does not exist."
[[ -f "$DEPLOY_BUNDLE/pie.json" ]] || fail "The bundle has no pie.json (see the README's Compose apps section)."
jq -e 'type == "object" and (.projects | type == "array" and length > 0)' "$DEPLOY_BUNDLE/pie.json" >/dev/null \
  || fail "pie.json needs a non-empty \"projects\" list."
while read -r project; do
  [[ -f "$DEPLOY_BUNDLE/$project/compose.yaml" ]] || fail "pie.json lists '$project', but there's no $project/compose.yaml in the bundle."
done < <(jq -r '.projects[]' "$DEPLOY_BUNDLE/pie.json")
[[ "$DEPLOY_CONNECT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || fail "'connect-attempts' must be a positive integer."
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || fail "'secrets' must be KEY=VALUE lines (one per line)."
done <<< "$DEPLOY_SECRETS"
command -v rsync >/dev/null || fail "rsync is not installed on the runner."

remote="$DEPLOY_USER@$DEPLOY_HOST"
incoming="/var/lib/pie/incoming/$DEPLOY_APP/$DEPLOY_RELEASE"

# --- SSH setup ---------------------------------------------------------------
ssh_dir=$(mktemp -d)
trap 'rm -rf "$ssh_dir"' EXIT
ssh_opts=(
  -p "$DEPLOY_SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o UserKnownHostsFile="$ssh_dir/known_hosts"
)
if [[ -n "$DEPLOY_SSH_KEY" ]]; then
  printf '%s\n' "$DEPLOY_SSH_KEY" > "$ssh_dir/id"
  chmod 600 "$ssh_dir/id"
  ssh_opts+=(-i "$ssh_dir/id" -o IdentitiesOnly=yes)
fi
if [[ -n "$DEPLOY_KNOWN_HOSTS" ]]; then
  printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > "$ssh_dir/known_hosts"
  ssh_opts+=(-o StrictHostKeyChecking=yes)
else
  if [[ -n "$DEPLOY_SSH_KEY" ]]; then
    echo "::warning::'known-hosts' not set; trusting the host key on first use."
  fi
  # With Tailscale SSH the tailnet itself vouches for the host.
  ssh_opts+=(-o StrictHostKeyChecking=accept-new)
fi
# shellcheck disable=SC2029 # remote commands are built here on purpose, from validated values
rsh() { ssh "${ssh_opts[@]}" "$remote" "$@"; }

# --- Reach the host -----------------------------------------------------------
echo "::group::Connecting to $remote"
for ((i = 1; ; i++)); do
  if rsh true </dev/null; then break; fi
  if ((i >= DEPLOY_CONNECT_ATTEMPTS)); then
    echo "::endgroup::"
    fail "Could not reach $remote over SSH after $i attempts. Check the host name, the tailnet policy (an ssh rule for this runner's tag, or tcp:22 with ssh-key) and that host/install.sh has run."
  fi
  echo "Attempt $i failed; retrying in 3s..."
  sleep 3
done
version=$(rsh "sudo -n /usr/local/sbin/pie-deploy --version" </dev/null 2>/dev/null || true)
[[ "$version" == "pie-deploy $HOST_VERSION" ]] \
  || fail "$DEPLOY_HOST doesn't have pie-deploy $HOST_VERSION (got '${version:-nothing}'). Run 'sudo bash host/install.sh' there from a checkout of pie-delivery v2 or later."
echo "$version"
echo "::endgroup::"

# --- Ship the bundle ------------------------------------------------------------
echo "::group::rsync $DEPLOY_BUNDLE/ -> $remote:$incoming"
rsh "mkdir -p -- '$incoming'" </dev/null
rsync --archive --compress --delete --no-owner --no-group --human-readable --stats \
  -e "ssh ${ssh_opts[*]}" -- "${DEPLOY_BUNDLE%/}/" "$remote:$incoming/"
echo "::endgroup::"

# --- Deploy ----------------------------------------------------------------------
# Secrets travel on stdin, never in the bundle or on a command line.
echo "::group::pie-deploy deploy $DEPLOY_APP $DEPLOY_RELEASE"
status=0
printf '%s\n' "$DEPLOY_SECRETS" | sed '/^$/d' \
  | rsh "sudo -n /usr/local/sbin/pie-deploy deploy '$DEPLOY_APP' '$DEPLOY_RELEASE'" || status=$?
echo "::endgroup::"

{
  echo "### Deploy of $DEPLOY_APP"
  echo "- **Host:** \`$remote\`"
  echo "- **Release:** \`$DEPLOY_RELEASE\`"
  if ((status == 0)); then echo "- **Result:** live"; else echo "- **Result:** failed (the previous release, if any, was brought back)"; fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
((status == 0)) || fail "The deploy of $DEPLOY_APP $DEPLOY_RELEASE failed; the log above has the container state."
echo "Deployed $DEPLOY_APP $DEPLOY_RELEASE to $DEPLOY_HOST"
