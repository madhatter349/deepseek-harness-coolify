#!/bin/sh
# Container healthcheck: any valid HTTP response from the Harness root proves
# the server is listening. The root is 401 before the browser-session cookie
# and 200 after it, so both codes are healthy.
set -u

port="${PORT:-3080}"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" || true)"

if [ "$code" = "200" ] || [ "$code" = "401" ]; then
  exit 0
fi

echo "unhealthy: GET / returned HTTP '${code:-no-response}'" >&2
exit 1
