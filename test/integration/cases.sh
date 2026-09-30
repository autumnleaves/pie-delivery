#!/usr/bin/env bash
# Integration cases for scripts/deploy.sh. Runs inside the "runner" container
# from compose.yml; the "pi" container is reachable as host "pi" and its
# /srv/deploy is mounted here too, so results can be checked directly.
# Hook scripts are single-quoted on purpose: they expand on the "Pi", not here.
# shellcheck disable=SC2016
set -uo pipefail

DEPLOY_SCRIPT=/repo/scripts/deploy.sh
ROOT=/srv/deploy
WORK=$(mktemp -d)
LOG="$WORK/deploy.log"
passed=0
failed=()

# --- Helpers -------------------------------------------------------------------

reset_env() {
  export DEPLOY_HOST=pi DEPLOY_USER=deploy DEPLOY_SSH_PORT=22
  DEPLOY_SSH_KEY=$(cat /etc/test/client_key)
  DEPLOY_KNOWN_HOSTS="pi $(cat /etc/ssh/ssh_host_ed25519_key.pub)"
  export DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS
  export DEPLOY_SOURCE="" DEPLOY_TARGET="" DEPLOY_DELETE=false DEPLOY_EXCLUDE=.git
  export DEPLOY_RSYNC_ARGS="" DEPLOY_PRE="" DEPLOY_POST="" DEPLOY_DRY_RUN=false
  export DEPLOY_CONNECT_ATTEMPTS=10
}

# make_source DIR FILE=CONTENT... : creates a fresh source tree.
# When redeploying a changed file, change its length too: rsync skips files
# whose size and mtime match, and a rewrite within the same second keeps
# the mtime. (Real CI checkouts always get fresh mtimes.)
make_source() {
  local dir=$1 spec
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  for spec in "$@"; do
    mkdir -p "$(dirname "$dir/${spec%%=*}")"
    printf '%s' "${spec#*=}" > "$dir/${spec%%=*}"
  done
}

deploy() { bash "$DEPLOY_SCRIPT" >> "$LOG" 2>&1; }

expect_fail() {
  if deploy; then
    echo "expected deploy to fail, but it succeeded"
    return 1
  fi
}

expect_content() {
  local actual
  actual=$(cat "$1" 2>/dev/null) || { echo "missing file: $1"; return 1; }
  [[ "$actual" == "$2" ]] || { echo "$1: expected '$2', got '$actual'"; return 1; }
}

expect_missing() {
  [[ ! -e "$1" ]] || { echo "should not exist: $1"; return 1; }
}

expect_log() {
  grep -qF -- "$1" "$LOG" || { echo "log does not contain: $1"; return 1; }
}

run_case() {
  local name=$1 rc
  : > "$LOG"
  # Subshell outside an `if` so `set -e` applies to the case body.
  (
    set -e
    reset_env
    "$name"
  ) > "$WORK/case.out" 2>&1
  rc=$?
  if ((rc == 0)); then
    echo "ok    $name"
    passed=$((passed + 1))
  else
    echo "FAIL  $name"
    sed 's/^/      /' "$WORK/case.out"
    echo "      --- deploy output ---"
    sed 's/^/      /' "$LOG"
    failed+=("$name")
  fi
}

# --- Cases -----------------------------------------------------------------------

deploys_contents_into_new_nested_target() {
  make_source "$WORK/src" a.txt=A sub/b.txt=B .git/HEAD=ref
  export DEPLOY_SOURCE="$WORK/src/" DEPLOY_TARGET="$ROOT/basic/nested/app"
  deploy
  expect_content "$ROOT/basic/nested/app/a.txt" A
  expect_content "$ROOT/basic/nested/app/sub/b.txt" B
  expect_missing "$ROOT/basic/nested/app/.git"
  expect_missing "$ROOT/basic/nested/app/src"
}

handles_spaces_in_paths() {
  make_source "$WORK/src dir" "my file.txt=spaced"
  export DEPLOY_SOURCE="$WORK/src dir" DEPLOY_TARGET="$ROOT/with space/app dir"
  deploy
  expect_content "$ROOT/with space/app dir/my file.txt" spaced
}

applies_multiple_excludes() {
  make_source "$WORK/src" keep.txt=k node_modules/x.js=x .env=secret logs/app.log=l
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/excludes"
  export DEPLOY_EXCLUDE=$'.git\n  node_modules  \n\n.env\nlogs/'
  deploy
  expect_content "$ROOT/excludes/keep.txt" k
  expect_missing "$ROOT/excludes/node_modules"
  expect_missing "$ROOT/excludes/.env"
  expect_missing "$ROOT/excludes/logs"
}

keeps_removed_files_without_delete() {
  make_source "$WORK/src" a.txt=1 old.txt=old
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/nodelete"
  deploy
  make_source "$WORK/src" a.txt=v2
  deploy
  expect_content "$ROOT/nodelete/a.txt" v2
  expect_content "$ROOT/nodelete/old.txt" old
}

delete_removes_stale_files_but_not_excluded_ones() {
  make_source "$WORK/src" a.txt=1 old.txt=old
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/delete"
  export DEPLOY_EXCLUDE=$'.git\ndata/' DEPLOY_POST="mkdir -p data && echo precious > data/db"
  deploy
  make_source "$WORK/src" a.txt=v2
  export DEPLOY_DELETE=true DEPLOY_POST=""
  deploy
  expect_content "$ROOT/delete/a.txt" v2
  expect_missing "$ROOT/delete/old.txt"
  expect_content "$ROOT/delete/data/db" precious
}

dry_run_changes_nothing_on_existing_target() {
  make_source "$WORK/src" a.txt=1 old.txt=old
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/dry"
  deploy
  make_source "$WORK/src" a.txt=v2 new.txt=new
  export DEPLOY_DRY_RUN=true DEPLOY_DELETE=true DEPLOY_PRE="touch pre-ran" DEPLOY_POST="touch post-ran"
  deploy
  expect_content "$ROOT/dry/a.txt" 1
  expect_content "$ROOT/dry/old.txt" old
  expect_missing "$ROOT/dry/new.txt"
  expect_missing "$ROOT/dry/pre-ran"
  expect_missing "$ROOT/dry/post-ran"
  expect_log "Dry run complete"
}

dry_run_does_not_create_missing_target() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/dry-new/app" DEPLOY_DRY_RUN=true
  deploy
  expect_missing "$ROOT/dry-new"
}

hooks_run_in_target_with_multiline_scripts() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/hooks dir"
  export DEPLOY_PRE='pwd > pre.txt
test ! -e a.txt && echo "before sync" > order.txt'
  export DEPLOY_POST=$'echo "it\'s \\"quoted\\" $((1 + 1))" > post.txt\nwhoami > user.txt'
  deploy
  expect_content "$ROOT/hooks dir/pre.txt" "$ROOT/hooks dir"
  expect_content "$ROOT/hooks dir/order.txt" "before sync"
  expect_content "$ROOT/hooks dir/post.txt" "it's \"quoted\" 2"
  expect_content "$ROOT/hooks dir/user.txt" deploy
}

hooks_get_empty_stdin() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/stdin"
  export DEPLOY_POST='if read -r line; then echo "got: $line" > stdin.txt; else echo empty > stdin.txt; fi'
  deploy
  expect_content "$ROOT/stdin/stdin.txt" empty
}

failing_pre_deploy_aborts_before_sync() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/prefail"
  export DEPLOY_PRE=$'false\ntouch should-not-exist'
  expect_fail
  expect_missing "$ROOT/prefail/a.txt"
  expect_missing "$ROOT/prefail/should-not-exist"
}

failing_post_deploy_fails_the_deploy() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/postfail"
  export DEPLOY_POST="exit 3"
  expect_fail
  expect_content "$ROOT/postfail/a.txt" 1
}

extra_rsync_args_are_applied() {
  make_source "$WORK/src" a.txt=1
  chmod 644 "$WORK/src/a.txt"
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/rsyncargs" DEPLOY_RSYNC_ARGS="--checksum --chmod=F600"
  deploy
  [[ $(stat -c %a "$ROOT/rsyncargs/a.txt") == 600 ]] || { echo "chmod not applied"; return 1; }
}

rejects_wrong_host_key() {
  make_source "$WORK/src" a.txt=1
  rm -f "$WORK/other_host_key"*
  ssh-keygen -q -t ed25519 -N "" -f "$WORK/other_host_key"
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/badhostkey" DEPLOY_CONNECT_ATTEMPTS=1
  DEPLOY_KNOWN_HOSTS="pi $(cat "$WORK/other_host_key.pub")"
  expect_fail
  expect_log "Could not reach deploy@pi"
  expect_missing "$ROOT/badhostkey"
}

trusts_on_first_use_without_known_hosts() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/tofu" DEPLOY_KNOWN_HOSTS=""
  deploy
  expect_content "$ROOT/tofu/a.txt" 1
  expect_log "::warning::'known-hosts' not set"
}

rejects_unauthorised_key() {
  make_source "$WORK/src" a.txt=1
  rm -f "$WORK/other_client_key"*
  ssh-keygen -q -t ed25519 -N "" -f "$WORK/other_client_key"
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/badkey" DEPLOY_CONNECT_ATTEMPTS=1
  DEPLOY_SSH_KEY=$(cat "$WORK/other_client_key")
  expect_fail
  expect_missing "$ROOT/badkey"
}

gives_up_after_connect_attempts() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/unreachable"
  export DEPLOY_HOST=no-such-host DEPLOY_CONNECT_ATTEMPTS=2
  expect_fail
  expect_log "after 2 attempts"
}

fails_on_missing_source() {
  export DEPLOY_SOURCE="$WORK/does-not-exist" DEPLOY_TARGET="$ROOT/nosource"
  expect_fail
  expect_log "does not exist"
}

fails_on_invalid_connect_attempts() {
  make_source "$WORK/src" a.txt=1
  export DEPLOY_SOURCE="$WORK/src" DEPLOY_TARGET="$ROOT/badattempts" DEPLOY_CONNECT_ATTEMPTS=abc
  expect_fail
  expect_log "positive integer"
}

# --- Run -------------------------------------------------------------------------

cases=$(declare -F | awk '{print $3}' | grep -vE '^(reset_env|make_source|deploy|expect_.*|run_case)$')
for c in $cases; do
  run_case "$c"
done

echo
echo "$passed passed, ${#failed[@]} failed"
((${#failed[@]} == 0))
