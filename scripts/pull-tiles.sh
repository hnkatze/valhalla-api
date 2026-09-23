#!/usr/bin/env bash
# Download the published tile set from ${TILES_S3_URI}/ into ./custom_files.
# Afterwards start the API with: docker compose --profile runtime up -d
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd aws

mkdir -p "${CUSTOM_FILES}"

echo "INFO: pulling tile set from ${TILES_S3_URI}/"
aws s3 cp "${TILES_S3_URI}/${MARKER_FILE}" "${CUSTOM_FILES}/${MARKER_FILE}"
for artifact in "${TILE_ARTIFACTS[@]}"; do
  aws s3 cp "${TILES_S3_URI}/${artifact}" "${CUSTOM_FILES}/${artifact}"
done

expected="$(awk '/^valhalla_tiles.tar sha256=/{sub(/.*sha256=/, ""); print}' "${CUSTOM_FILES}/${MARKER_FILE}")"
actual="$(sha256sum "${CUSTOM_FILES}/valhalla_tiles.tar" | cut -d' ' -f1)"
if [[ -n "${expected}" && "${expected}" != "${actual}" ]]; then
  echo "ERROR: valhalla_tiles.tar checksum mismatch (expected ${expected}, got ${actual})." >&2
  exit 1
fi

echo "INFO: tile set ready in ${CUSTOM_FILES}"
awk '/^built_at=/' "${CUSTOM_FILES}/${MARKER_FILE}"
