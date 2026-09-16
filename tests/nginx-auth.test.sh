#!/usr/bin/env bash
# Integration test for the nginx API-key gate. Requires Docker; pulls nginx and a stub upstream.
set -euo pipefail

NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.30-alpine}"
STUB_IMAGE="${STUB_IMAGE:-hashicorp/http-echo:1.0.0}"
API_KEY="test-key-123"
STUB_BODY='{"ok":true}'
DOCS_BODY='{"docs":true}'

# Docker Desktop on Windows needs a native path for bind mounts and no MSYS path mangling.
# The MSYS override is scoped to docker only: globally it would break curl's "-o /dev/null".
repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "${dir}"
  else
    printf '%s' "${dir}"
  fi
}
dkr() { MSYS_NO_PATHCONV=1 docker "$@"; }

REPO_ROOT="$(repo_root)"
TEMPLATES_DIR="${REPO_ROOT}/nginx/templates"
SUFFIX="$$-${RANDOM}"
NETWORK="valhalla-auth-test-${SUFFIX}"
STUB="valhalla-stub-${SUFFIX}"
DOCS_STUB="swagger-stub-${SUFFIX}"
NGINX_A="nginx-auth-test-${SUFFIX}"
NGINX_B="nginx-auth-test-emptykey-${SUFFIX}"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"; failures=$((failures + 1)); }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then pass "${name}"; else fail "${name}" "${expected}" "${actual}"; fi
}

cleanup() {
  docker rm -f "${NGINX_A}" "${NGINX_B}" "${STUB}" "${DOCS_STUB}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_nginx() {
  local name="$1" key="$2"
  dkr run -d --name "${name}" --network "${NETWORK}" \
    -p 127.0.0.1::80 \
    -v "${TEMPLATES_DIR}:/etc/nginx/templates:ro" \
    -e "VALHALLA_API_KEY=${key}" \
    -e "NGINX_ENVSUBST_FILTER=^VALHALLA_" \
    "${NGINX_IMAGE}" >/dev/null
  local port
  port="$(docker port "${name}" 80/tcp 2>/dev/null | head -n1 | awk -F: '{print $NF}')"
  if [[ -z "${port}" ]]; then
    return 1
  fi
  printf '%s' "${port}"
}

is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

wait_for_http() {
  local url="$1" _attempt
  for _attempt in $(seq 1 30); do
    if curl -s -o /dev/null "${url}"; then return 0; fi
    sleep 0.5
  done
  return 1
}

status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
location_of() { curl -s -o /dev/null -D - "$@" | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}'; }

if [[ ! -d "${TEMPLATES_DIR}" ]]; then
  printf 'FAIL  templates directory missing: %s\n' "${TEMPLATES_DIR}"
  exit 1
fi

docker network create "${NETWORK}" >/dev/null
# The alias is what nginx resolves, so the config under test runs unchanged against the stub.
dkr run -d --name "${STUB}" --network "${NETWORK}" --network-alias valhalla "${STUB_IMAGE}" \
  -listen=:8002 -text="${STUB_BODY}" >/dev/null
dkr run -d --name "${DOCS_STUB}" --network "${NETWORK}" --network-alias swagger-ui "${STUB_IMAGE}" \
  -listen=:8080 -text="${DOCS_BODY}" >/dev/null

if ! PORT="$(start_nginx "${NGINX_A}" "${API_KEY}")"; then
  printf 'FAIL  nginx did not start with a configured key\n'
  docker logs "${NGINX_A}" 2>&1 | tail -n 20
  exit 1
fi
BASE="http://127.0.0.1:${PORT}"

if ! wait_for_http "${BASE}/status"; then
  printf 'FAIL  nginx never answered on %s\n' "${BASE}"
  docker logs "${NGINX_A}" 2>&1 | tail -n 20
  exit 1
fi

assert_eq "no header -> 401" "401" "$(status_of "${BASE}/status")"
assert_eq "no header -> JSON error body" '{"error":"unauthorized"}' "$(curl -s "${BASE}/status")"
assert_eq "wrong key -> 401" "401" "$(status_of -H 'X-API-Key: wrong-key' "${BASE}/status")"
assert_eq "correct key POST /route -> 200" "200" \
  "$(status_of -X POST -H "X-API-Key: ${API_KEY}" -H 'Content-Type: application/json' \
     -d '{"locations":[{"lat":14.0723,"lon":-87.1921},{"lat":15.5042,"lon":-88.0250}],"costing":"motorcycle"}' \
     "${BASE}/route")"
assert_eq "correct key POST /route -> body proxied from stub" "${STUB_BODY}" \
  "$(curl -s -X POST -H "X-API-Key: ${API_KEY}" -H 'Content-Type: application/json' -d '{}' "${BASE}/route" | tr -d '\n')"
assert_eq "correct key GET /status -> 200" "200" "$(status_of -H "X-API-Key: ${API_KEY}" "${BASE}/status")"

# Swagger UI is public; the docs location must not leak the key exemption to the API.
assert_eq "no header GET /docs/ -> 200" "200" "$(status_of "${BASE}/docs/")"
assert_eq "no header GET /docs/ -> body proxied from docs stub" "${DOCS_BODY}" \
  "$(curl -s "${BASE}/docs/" | tr -d '\n')"
assert_eq "no header GET /docs -> 301" "301" "$(status_of "${BASE}/docs")"
assert_eq "no header GET /docs -> relative Location /docs/" "/docs/" "$(location_of "${BASE}/docs")"
assert_eq "no header GET /route -> 401" "401" "$(status_of "${BASE}/route")"
assert_eq "no header GET /docsx -> 401" "401" "$(status_of "${BASE}/docsx")"

# An empty configured key must fail closed: nginx either refuses to start or answers 401.
PORT_B="$(start_nginx "${NGINX_B}" "" || true)"
sleep 2
if is_running "${NGINX_B}" && [[ -n "${PORT_B}" ]]; then
  BASE_B="http://127.0.0.1:${PORT_B}"
  wait_for_http "${BASE_B}/status" || true
  assert_eq "empty configured key, no header -> 401" "401" "$(status_of "${BASE_B}/status")"
  assert_eq "empty configured key, empty header -> 401" "401" "$(status_of -H 'X-API-Key;' "${BASE_B}/status")"
else
  pass "empty configured key -> nginx refuses to start"
fi

if [[ "${failures}" -ne 0 ]]; then
  printf '\n%d assertion(s) failed\n' "${failures}"
  exit 1
fi
printf '\nall assertions passed\n'
