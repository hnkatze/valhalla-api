#!/usr/bin/env bash
# Shared helpers for the tile lifecycle scripts. Sourced, not executed.
# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUSTOM_FILES="${REPO_ROOT}/custom_files"

# Names are fixed by the upstream image (docker/scripts/helpers.sh in valhalla/valhalla).
TILE_ARTIFACTS=(
  valhalla_tiles.tar
  valhalla.json
  admins.sqlite
  timezones.sqlite
  default_speeds.json
  file_hashes.txt
)
MARKER_FILE="latest.txt"

load_env() {
  local env_file="${REPO_ROOT}/.env"
  if [[ ! -f "${env_file}" ]]; then
    echo "ERROR: ${env_file} not found. Copy .env.example to .env first." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a
  if [[ -z "${TILES_S3_URI:-}" ]]; then
    echo "ERROR: TILES_S3_URI is not set in .env (expected s3://bucket/prefix)." >&2
    exit 1
  fi
  TILES_S3_URI="${TILES_S3_URI%/}"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}
