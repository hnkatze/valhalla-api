#!/usr/bin/env bash
# Arranque de la imagen unica que corre la tarea de ECS: Valhalla y nginx en el mismo
# contenedor, porque el template de deploy en ECS admite un solo contenedor por tarea.
#
# Bajo compose estos son tres servicios y Docker supervisa cada uno. Aqui esa supervision
# la hace este script: si cualquiera de los dos procesos muere, el contenedor entero termina
# con codigo distinto de cero para que ECS lo reemplace. Un contenedor que sigue vivo con
# Valhalla caido es peor que uno que se cae, porque el target group lo reporta sano.
set -euo pipefail

VALHALLA_CONFIG="${VALHALLA_CONFIG:-/custom_files/valhalla.json}"
VALHALLA_THREADS="${VALHALLA_THREADS:-$(nproc)}"
STARTUP_TIMEOUT="${VALHALLA_STARTUP_TIMEOUT:-180}"

log() { printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# --- 1. Renderizar los templates de nginx -----------------------------------------------------
# Replica lo que hace el entrypoint de la imagen oficial de nginx, que aqui no tenemos porque
# la base es la de Valhalla. Sin el filtro, envsubst tambien reemplazaria las variables propias
# de nginx ($host, $remote_addr, $binary_remote_addr) y la config quedaria rota.
render_templates() {
  local tpl out name defined_envs=""
  while IFS= read -r name; do
    defined_envs+="\${${name}} "
  done < <(printenv | cut -d= -f1 | grep -E "${NGINX_ENVSUBST_FILTER:-^VALHALLA_}")
  shopt -s nullglob
  for tpl in /etc/nginx/templates/*.template; do
    out="/etc/nginx/conf.d/$(basename "${tpl}" .template)"
    log "renderizando ${tpl} -> ${out}"
    envsubst "${defined_envs}" < "${tpl}" > "${out}"
  done
  shopt -u nullglob
}

render_templates
nginx -t

# --- 2. Arrancar Valhalla ---------------------------------------------------------------------
log "arrancando valhalla_service (${VALHALLA_THREADS} hilos) con ${VALHALLA_CONFIG}"
valhalla_service "${VALHALLA_CONFIG}" "${VALHALLA_THREADS}" &
VALHALLA_PID=$!

# Cargar los tiles lleva tiempo. nginx no debe aceptar trafico antes, porque el health check
# del target group tomaria los 502 iniciales como un backend muerto y ECS mataria la tarea.
log "esperando a que valhalla responda en 127.0.0.1:8002 (timeout ${STARTUP_TIMEOUT}s)"
for _ in $(seq 1 "${STARTUP_TIMEOUT}"); do
  if curl -fsS -o /dev/null http://127.0.0.1:8002/status 2>/dev/null; then
    log "valhalla listo"
    break
  fi
  if ! kill -0 "${VALHALLA_PID}" 2>/dev/null; then
    log "ERROR: valhalla murio durante el arranque"
    wait "${VALHALLA_PID}" || true
    exit 1
  fi
  sleep 1
done

if ! curl -fsS -o /dev/null http://127.0.0.1:8002/status 2>/dev/null; then
  log "ERROR: valhalla no respondio en ${STARTUP_TIMEOUT}s"
  kill "${VALHALLA_PID}" 2>/dev/null || true
  exit 1
fi

# --- 3. Arrancar nginx ------------------------------------------------------------------------
log "arrancando nginx en :80"
nginx -g 'daemon off;' &
NGINX_PID=$!

shutdown() {
  log "senal recibida, terminando"
  kill -TERM "${NGINX_PID}" "${VALHALLA_PID}" 2>/dev/null || true
  wait "${NGINX_PID}" "${VALHALLA_PID}" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

# El primero que termine baja al otro: no queremos medio servicio en pie.
# El `|| EXIT_CODE=$?` no es cosmetico: con `set -e`, un wait que devuelve distinto de cero
# aborta el script aqui mismo y los mensajes de abajo nunca llegan a los logs, que es
# precisamente lo unico que explica por que murio la tarea.
EXIT_CODE=0
wait -n "${VALHALLA_PID}" "${NGINX_PID}" || EXIT_CODE=$?

if kill -0 "${VALHALLA_PID}" 2>/dev/null; then
  log "ERROR: nginx termino (codigo ${EXIT_CODE}), bajando valhalla"
else
  log "ERROR: valhalla termino (codigo ${EXIT_CODE}), bajando nginx"
fi

kill -TERM "${NGINX_PID}" "${VALHALLA_PID}" 2>/dev/null || true
wait 2>/dev/null || true
exit "${EXIT_CODE:-1}"
