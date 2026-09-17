#!/usr/bin/env bash
# Integration test for the nginx front end. Requires Docker; pulls nginx and a stub upstream.
# TEMPORAL: la puerta de API key esta deshabilitada, asi que este test verifica el routing
# (/health, /swagger/, proxy a Valhalla) pero ya no la autenticacion. Ver la nota en
# nginx/templates/default.conf.template para restaurarla.
set -euo pipefail

NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.30-alpine}"
STUB_IMAGE="${STUB_IMAGE:-hashicorp/http-echo:1.0.0}"
# 48 hex chars, the length openssl rand -hex 24 produces; short keys hide nginx map hash sizing errors.
API_KEY="0123456789abcdef0123456789abcdef0123456789abcdef"
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
    -e "VALHALLA_TRUSTED_PROXY_CIDR=127.0.0.1" \
    -e "VALHALLA_RESOLVER=127.0.0.11" \
    -e "VALHALLA_UPSTREAM=http://valhalla:8002" \
    -e "VALHALLA_DOCS_UPSTREAM=http://swagger-ui:8080" \
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

# --- TEMPORAL: la puerta de API key esta deshabilitada en el template ------------------------
# Mientras el equipo de dev no provea la key, todo pasa sin autenticacion. Los asserts de 401
# de abajo estan invertidos a proposito para reflejar ese estado; al restaurar la puerta hay
# que revertir este bloque junto con el map y el `if` de nginx/templates/default.conf.template.
assert_eq "sin header -> 200 (gate deshabilitada)" "200" "$(status_of "${BASE}/status")"
assert_eq "sin header -> body proxied from stub" "${STUB_BODY}" "$(curl -s "${BASE}/status" | tr -d '\n')"
assert_eq "key incorrecta -> 200 (el header se ignora)" "200" \
  "$(status_of -H 'X-API-Key: wrong-key' "${BASE}/status")"
assert_eq "POST /route sin header -> 200" "200" \
  "$(status_of -X POST -H 'Content-Type: application/json' \
     -d '{"locations":[{"lat":14.0723,"lon":-87.1921},{"lat":15.5042,"lon":-88.0250}],"costing":"motorcycle"}' \
     "${BASE}/route")"
assert_eq "POST /route sin header -> body proxied from stub" "${STUB_BODY}" \
  "$(curl -s -X POST -H 'Content-Type: application/json' -d '{}' "${BASE}/route" | tr -d '\n')"
assert_eq "key correcta sigue funcionando -> 200" "200" "$(status_of -H "X-API-Key: ${API_KEY}" "${BASE}/status")"
# ---------------------------------------------------------------------------------------------

# The ALB health check cannot send X-API-Key, so /health must answer without one and must
# still reach the upstream: a 200 generated by nginx itself would report a dead Valhalla healthy.
assert_eq "no header -> /health 200" "200" "$(status_of "${BASE}/health")"
assert_eq "/health body comes from upstream" "${STUB_BODY}" "$(curl -s "${BASE}/health" | tr -d '\n')"

# Swagger UI is public; the docs location must keep routing to the docs stub, not to Valhalla.
assert_eq "no header GET /swagger/ -> 200" "200" "$(status_of "${BASE}/swagger/")"
assert_eq "no header GET /swagger/ -> body proxied from docs stub" "${DOCS_BODY}" \
  "$(curl -s "${BASE}/swagger/" | tr -d '\n')"
assert_eq "no header GET /swagger -> 301" "301" "$(status_of "${BASE}/swagger")"
assert_eq "no header GET /swagger -> relative Location /swagger/" "/swagger/" "$(location_of "${BASE}/swagger")"
# /swaggerx no cae en el location de docs: tiene que ir a Valhalla, no a Swagger UI.
assert_eq "no header GET /swaggerx -> body proxied from valhalla stub" "${STUB_BODY}" \
  "$(curl -s "${BASE}/swaggerx" | tr -d '\n')"

# TEMPORAL: sin key configurada nginx debe arrancar igual, porque el map ya no la consume.
PORT_B="$(start_nginx "${NGINX_B}" "" || true)"
sleep 2
if is_running "${NGINX_B}" && [[ -n "${PORT_B}" ]]; then
  BASE_B="http://127.0.0.1:${PORT_B}"
  wait_for_http "${BASE_B}/status" || true
  assert_eq "sin key configurada -> nginx arranca y proxea" "200" "$(status_of "${BASE_B}/status")"
else
  fail "sin key configurada -> nginx deberia arrancar" "running" "not running"
  docker logs "${NGINX_B}" 2>&1 | tail -n 20
fi

if [[ "${failures}" -ne 0 ]]; then
  printf '\n%d assertion(s) failed\n' "${failures}"
  exit 1
fi
printf '\nall assertions passed\n'
