#!/usr/bin/env bash
# Syncs DEPLOY_SOURCE to DEPLOY_TARGET on DEPLOY_HOST over SSH.
# Invoked by action.yml; all configuration arrives via DEPLOY_* env vars.
set -euo pipefail

fail() { echo "::error::$*"; exit 1; }
is_true() { [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]; }

[[ -n "$DEPLOY_HOST" ]] || fail "'host' input is required."
[[ -n "$DEPLOY_TARGET" ]] || fail "'target' input is required."
[[ -d "$DEPLOY_SOURCE" ]] || fail "Source directory '$DEPLOY_SOURCE' does not exist (did you run actions/checkout?)."
[[ "$DEPLOY_CONNECT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || fail "'connect-attempts' must be a positive integer."
command -v rsync >/dev/null || fail "rsync is not installed on the runner."

remote="$DEPLOY_USER@$DEPLOY_HOST"
target_q=$(printf '%q' "$DEPLOY_TARGET")

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
  echo "::warning::'known-hosts' not set; trusting the Pi's host key on first use."
  ssh_opts+=(-o StrictHostKeyChecking=accept-new)
fi

rsh() { ssh "${ssh_opts[@]}" "$remote" "$@"; }

# Runs a script on the Pi inside the target directory. The script travels
# base64-encoded so multi-line hooks need no quoting, and stdin is /dev/null
# so commands in the hook can't hang waiting for input.
run_hook() {
  local name=$1 script=$2
  [[ -z "$script" ]] && return 0
  if is_true "$DEPLOY_DRY_RUN"; then
    echo "Dry run: skipping $name hook."
    return 0
  fi
  echo "::group::$name"
  local payload
  payload=$(printf 'set -euo pipefail\ncd %s\n%s\n' "$target_q" "$script" | base64 -w0)
  rsh "bash -c \"\$(echo $payload | base64 -d)\" </dev/null"
  echo "::endgroup::"
}

# --- Wait for the Pi -----------------------------------------------------------
echo "::group::Connecting to $remote"
for ((i = 1; ; i++)); do
  if rsh true; then
    break
  fi
  if ((i >= DEPLOY_CONNECT_ATTEMPTS)); then
    echo "::endgroup::"
    fail "Could not reach $remote over SSH after $i attempts. Check the host name, tailnet ACLs and SSH credentials."
  fi
  echo "Attempt $i failed; retrying in 3s..."
  sleep 3
done
rsh 'command -v rsync >/dev/null' || fail "rsync is not installed on the Pi. Run: sudo apt install rsync"
echo "::endgroup::"

if ! is_true "$DEPLOY_DRY_RUN"; then
  rsh "mkdir -p -- $target_q"
fi

run_hook "pre-deploy" "$DEPLOY_PRE"

# --- Sync ------------------------------------------------------------------------
rsync_opts=(
  --archive --compress --no-owner --no-group
  --human-readable --itemize-changes --stats
)
if is_true "$DEPLOY_DELETE"; then rsync_opts+=(--delete); fi
if is_true "$DEPLOY_DRY_RUN"; then rsync_opts+=(--dry-run); fi

while IFS= read -r pattern; do
  pattern="${pattern#"${pattern%%[![:space:]]*}"}"
  pattern="${pattern%"${pattern##*[![:space:]]}"}"
  [[ -n "$pattern" ]] && rsync_opts+=("--exclude=$pattern")
done <<< "$DEPLOY_EXCLUDE"

if [[ -n "$DEPLOY_RSYNC_ARGS" ]]; then
  read -ra extra <<< "$DEPLOY_RSYNC_ARGS"
  rsync_opts+=("${extra[@]}")
fi

# rsync splits -e on spaces itself (no backslash escapes); none of these contain spaces.
rsync_rsh="ssh ${ssh_opts[*]}"

echo "::group::rsync ${DEPLOY_SOURCE%/}/ -> $remote:$DEPLOY_TARGET"
# Trailing slash on the source copies its contents rather than the directory itself.
# The remote path is passed unescaped: rsync >= 3.2.4 protects it from the remote shell.
rsync "${rsync_opts[@]}" -e "$rsync_rsh" -- "${DEPLOY_SOURCE%/}/" "$remote:${DEPLOY_TARGET%/}/"
echo "::endgroup::"

run_hook "post-deploy" "$DEPLOY_POST"

if is_true "$DEPLOY_DRY_RUN"; then
  echo "Dry run complete; nothing was changed on $remote."
else
  echo "Deployed ${DEPLOY_SOURCE} to $remote:$DEPLOY_TARGET"
fi
{
  echo "### Raspberry Pi deploy"
  echo "- **Host:** \`$remote\`"
  echo "- **Source:** \`$DEPLOY_SOURCE\`"
  echo "- **Target:** \`$DEPLOY_TARGET\`"
  if is_true "$DEPLOY_DRY_RUN"; then echo "- **Dry run** (no changes made)"; fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
