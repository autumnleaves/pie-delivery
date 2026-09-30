#!/usr/bin/env bash
# Runs the deploy integration tests against a throwaway sshd container.
# Usage: test/integration/run.sh   (requires Docker with the compose plugin)
set -euo pipefail
cd "$(dirname "$0")"

compose=(docker compose --project-name pie-delivery-test --file compose.yml)
cleanup() { "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

cleanup
"${compose[@]}" build
"${compose[@]}" run --rm runner
