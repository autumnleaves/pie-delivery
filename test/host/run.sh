#!/usr/bin/env bash
# Tests host/pie-deploy against the local Docker daemon: real Compose projects, image loading,
# health checks, rollback and pruning. Run as root (CI uses sudo):
#
#   sudo bash test/host/run.sh
#
# Needs docker with the Compose plugin, jq and go. Nothing is pulled from a registry: the app
# and the health probe are one small Go binary in a scratch image (test/host/app).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PIE=$REPO/host/pie-deploy
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0" >&2; exit 1; }

WORK=$(mktemp -d)
export PIE_INCOMING_ROOT=$WORK/incoming
export PIE_APPS_ROOT=$WORK/apps
export PIE_PROBE_IMAGE=pietest-probe:latest
APP=pietest
PASS=0
FAIL=0

cleanup() {
    docker compose -p pietest down -v --remove-orphans >/dev/null 2>&1 || true
    docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^pietest-' | xargs -r docker image rm -f >/dev/null 2>&1 || true
    rm -rf -- "$WORK"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); echo "  ok: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

echo "== Building the test images"
(cd "$HERE/app" && CGO_ENABLED=0 go build -o "$WORK/build/app" .)
printf 'FROM scratch\nCOPY app /app\nENTRYPOINT ["/app", "probe"]\n' >"$WORK/build/Dockerfile"
docker build -q -t "$PIE_PROBE_IMAGE" "$WORK/build" >/dev/null
printf 'FROM scratch\nCOPY app /app\nENTRYPOINT ["/app"]\n' >"$WORK/build/Dockerfile"

# Makes a bundle in incoming/ for release $1. $2: "ok" or "fail" (the app's health).
# Extra pie.json fields come from $3 (a jq object, merged in).
bundle() {
    local rel=$1 health=${2:-ok} extra=${3:-'{}'}
    local b=$PIE_INCOMING_ROOT/$APP/$rel
    mkdir -p "$b/stack" "$b/images"
    docker build -q -t "pietest-app:$rel" "$WORK/build" >/dev/null
    docker save "pietest-app:$rel" | gzip >"$b/images/app.tar.gz"
    docker image rm "pietest-app:$rel" >/dev/null # pie-deploy must load it from the bundle
    cat >"$b/stack/compose.yaml" <<EOF
name: pietest
services:
  web:
    image: pietest-app:\${RELEASE}
    environment:
      HEALTH: \${HEALTH_MODE}
      RELEASE: \${RELEASE}
    volumes:
      - \${APP_ROOT}/data:/data
EOF
    printf 'HEALTH_MODE=%s\nGREETING=from-example\n' "$health" >"$b/stack/.env.example"
    jq -n --argjson extra "$extra" '{
        projects: ["stack"],
        health: [{network: "pietest_default", url: "http://web:8080/health"}],
        dirs: [{path: "data", owner: "1000:1000", mode: "750"}],
        keep: 2,
        timeout: 20
    } + $extra' >"$b/pie.json"
}

deploy() { "$PIE" deploy "$APP" "$@"; }
live() { basename "$(readlink -f "$PIE_APPS_ROOT/$APP/current")"; }
answers() { docker run --rm --network pietest_default "$PIE_PROBE_IMAGE" "http://web:8080/health" >/dev/null 2>&1; }
running_release() { docker inspect pietest-web-1 --format '{{.Config.Image}}' 2>/dev/null; }

echo "== First deploy, with secrets"
bundle r1
# shellcheck disable=SC2016 # a literal $ in the value, on purpose
printf 'GREETING=from-secret\nAPI_TOKEN=s3cr$t value\n' | deploy r1 >"$WORK/out" 2>&1 || { cat "$WORK/out"; bad "first deploy"; }
check "r1 is live" test "$(live)" = r1
check "the app answers" answers
check "the bundle's image was loaded and runs" test "$(running_release)" = "pietest-app:r1"
env=$PIE_APPS_ROOT/$APP/releases/r1/stack/.env
check ".env is root-only" test "$(stat -c %a "$env")" = 600
check ".env has APP_ROOT and RELEASE" grep -qxF "RELEASE='r1'" "$env"
check "a secret overrides .env.example" grep -qxF "GREETING='from-secret'" "$env"
check "only once" test "$(grep -c '^GREETING=' "$env")" = 1
check "secret values are quoted literally" grep -qxF "API_TOKEN='s3cr\$t value'" "$env"
check "data folder made with its owner" test "$(stat -c '%u:%g %a' "$PIE_APPS_ROOT/$APP/data")" = "1000:1000 750"
check "the incoming bundle is removed" test ! -e "$PIE_INCOMING_ROOT/$APP/r1"

echo "== A release that fails its health check is rolled back"
bundle r2 fail
if deploy r2 </dev/null >"$WORK/out" 2>&1; then bad "r2 should fail"; else ok "r2 fails"; fi
check "it says why" grep -q "not healthy" "$WORK/out"
check "r1 is still live" test "$(live)" = r1
check "r1 runs again" test "$(running_release)" = "pietest-app:r1"
check "and answers" answers

echo "== Pruning keeps the newest releases and the live one"
for r in r3 r4 r5; do
    bundle "$r"
    deploy "$r" </dev/null >"$WORK/out" 2>&1 || { cat "$WORK/out"; bad "deploy $r"; }
    sleep 1 # distinct mtimes
done
check "r5 is live" test "$(live)" = r5
check "two releases kept" test "$(find "$PIE_APPS_ROOT/$APP/releases" -mindepth 1 -maxdepth 1 | wc -l)" = 2
check "old images removed" test -z "$(docker image ls -q pietest-app:r1)"
check "kept images stay" test -n "$(docker image ls -q pietest-app:r4)"

echo "== Rollback by hand"
"$PIE" rollback "$APP" >"$WORK/out" 2>&1 || { cat "$WORK/out"; bad "rollback"; }
check "r4 is live" test "$(live)" = r4
check "r4 runs" test "$(running_release)" = "pietest-app:r4"
"$PIE" status "$APP" >"$WORK/out"
check "status marks the live release" grep -qE '^\s+\* r4$' "$WORK/out"

echo "== Bad bundles change nothing"
refused() {
    local what=$1 rel=$2
    if deploy "$rel" </dev/null >"$WORK/out" 2>&1; then bad "$what: accepted"; return; fi
    if test "$(live)" = r4 && test ! -e "$PIE_APPS_ROOT/$APP/releases/$rel"; then ok "$what: refused, nothing changed"; else bad "$what: left changes"; fi
}
bundle b1; sed -i '/^name:/d' "$PIE_INCOMING_ROOT/$APP/b1/stack/compose.yaml"
refused "no Compose project name" b1
bundle b2 ok '{"projects": ["../escape"]}'
refused "a project outside the bundle" b2
bundle b3 ok '{"dirs": [{"path": "../../etc"}]}'
refused "a data folder outside the app" b3
bundle b4 ok '{"mounts": ["/nonexistent-pietest"]}'
refused "a missing mount" b4
bundle b5
if printf 'not a secret line\n' | deploy b5 >"$WORK/out" 2>&1; then bad "bad secrets accepted"; else ok "bad secret lines are refused"; fi
check "app names are checked" bash -c "! '$PIE' deploy 'Bad_App' r1 </dev/null >/dev/null 2>&1"
check "missing bundles are reported" bash -c "'$PIE' deploy '$APP' nope </dev/null 2>&1 | grep -q 'no bundle'"
check "--version" test "$("$PIE" --version)" = "pie-deploy 2"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
