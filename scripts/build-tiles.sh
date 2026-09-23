#!/usr/bin/env bash
# Build the Honduras tile set from a fresh PBF and publish it to S3.
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_cmd docker

mkdir -p "${CUSTOM_FILES}"
# Stale PBFs would be reused instead of downloading the current extract.
rm -f "${CUSTOM_FILES}"/*.pbf

echo "INFO: building tiles into ${CUSTOM_FILES}"
docker compose --project-directory "${REPO_ROOT}" --profile build up \
  --abort-on-container-exit --exit-code-from valhalla-build valhalla-build
docker compose --project-directory "${REPO_ROOT}" --profile build down --remove-orphans

for artifact in "${TILE_ARTIFACTS[@]}"; do
  if [[ ! -f "${CUSTOM_FILES}/${artifact}" ]]; then
    echo "ERROR: expected build artifact missing: ${CUSTOM_FILES}/${artifact}" >&2
    exit 1
  fi
done

"${REPO_ROOT}/scripts/push-tiles.sh"
