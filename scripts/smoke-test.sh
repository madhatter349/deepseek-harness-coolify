#!/usr/bin/env bash
# Smoke-test a running DeepSeek Harness deployment.
#
#   BASE_URL=http://127.0.0.1:13080 ./scripts/smoke-test.sh
#
# With a first-visit token recovered from the logs, also exercise the login
# exchange and the authenticated API:
#
#   BASE_URL=... TOKEN=<token> ./scripts/smoke-test.sh
set -u

base="${BASE_URL:-http://127.0.0.1:13080}"
base="${base%/}"
fail=0

expect() { # name expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %-38s %s\n' "$1" "$3"
  else
    printf 'FAIL %-38s got %s, expected %s\n' "$1" "$3" "$2"
    fail=1
  fi
}

code="$(curl -s -o /dev/null -w '%{http_code}' "$base/")"
if [ "$code" = "401" ] || [ "$code" = "200" ]; then
  printf 'ok   %-38s %s\n' "root reachable" "$code"
else
  printf 'FAIL %-38s got %s\n' "root reachable" "${code:-no-response}"
  fail=1
fi

api_code="$(curl -s -o /dev/null -w '%{http_code}' "$base/api/does-not-exist")"
case "$api_code" in
  401|403|404) printf 'ok   %-38s %s\n' "/api gated" "$api_code" ;;
  *) printf 'FAIL %-38s got %s\n' "/api gated" "${api_code:-no-response}"; fail=1 ;;
esac

if [ -n "${TOKEN:-}" ]; then
  jar="$(mktemp)"
  trap 'rm -f "$jar"' EXIT
  redirect="$(curl -s -o /dev/null -w '%{http_code}' -c "$jar" "$base/?token=$TOKEN")"
  expect "token exchange redirects" "303" "$redirect"
  index_code="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" "$base/")"
  expect "cookie serves index" "200" "$index_code"
fi

if [ "$fail" -eq 0 ]; then
  echo "smoke test passed"
else
  echo "smoke test failed"
  exit 1
fi
