#!/usr/bin/env bash
# Upload the built tile set from ./custom_files to ${TILES_S3_URI}/ and write a latest.txt marker.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd aws

for artifact in "${TILE_ARTIFACTS[@]}"; do
  src="${CUSTOM_FILES}/${artifact}"
  if [[ ! -f "${src}" ]]; then
    echo "ERROR: missing ${src}; run scripts/build-tiles.sh first." >&2
    exit 1
  fi
done

built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pbf_hashes=""
for pbf in "${CUSTOM_FILES}"/*.pbf; do
  [[ -f "${pbf}" ]] || continue
  pbf_hashes="${pbf_hashes}$(basename "${pbf}") sha256=$(sha256sum "${pbf}" | cut -d' ' -f1)\n"
done
tiles_sha256="$(sha256sum "${CUSTOM_FILES}/valhalla_tiles.tar" | cut -d' ' -f1)"

for artifact in "${TILE_ARTIFACTS[@]}"; do
  echo "INFO: uploading ${artifact}"
  aws s3 cp "${CUSTOM_FILES}/${artifact}" "${TILES_S3_URI}/${artifact}"
done

printf 'built_at=%s\nvalhalla_tiles.tar sha256=%s\n%b' "${built_at}" "${tiles_sha256}" "${pbf_hashes}" \
  | aws s3 cp - "${TILES_S3_URI}/${MARKER_FILE}"

echo "INFO: published tile set to ${TILES_S3_URI}/ (built_at=${built_at})"
