# valhalla-api

Self-hosted [Valhalla](https://valhalla.github.io/valhalla/) routing API for Honduras.

- Coverage: Honduras only (Geofabrik `central-america/honduras-latest.osm.pbf`).
- Costing used by clients: `motorcycle`.
- No traffic (live or historical), no elevation (`/height` is out of scope).
- Auth: an `X-API-Key` header validated by nginx in front of Valhalla.

## Architecture

```
client --X-API-Key--> nginx:80 --> valhalla:8002 (not published)
                                      |
                                      +-- /custom_files  <-- pull-tiles.sh <-- S3 (tile set)
                                                              ^
                                    build-tiles.sh (one-off job) --> push-tiles.sh
```

One `t4g.medium` (ARM64 Graviton) EC2 instance runs the `runtime` compose profile. Tiles are
built as a one-off job with the `build` profile on any machine with AWS credentials, then
published to S3 and pulled by the runtime host.

## Why these choices

- **Upstream `ghcr.io/valhalla/valhalla-scripted`**: the `gis-ops/docker-valhalla` and
  `nilsnolde/docker-valhalla` images are archived; the scripts now live in
  [`valhalla/valhalla/docker`](https://github.com/valhalla/valhalla/tree/master/docker). The
  image is multi-arch, so the same tag runs on the amd64 build box and the arm64 host.
- **ARM64**: `t4g.medium` is the cheapest 4 GB instance that serves a country-size graph
  comfortably. Tiles are architecture independent; `docker compose` picks the host platform.
- **nginx API-key gate**: Valhalla has no built-in auth. Port 8002 is never published; only
  nginx is reachable, and it also applies a per-IP rate limit and a 1 MB body cap.
- **Tiles in S3, not built on the host**: the build needs more RAM and CPU time than serving.
  The runtime host only downloads a finished tar, so a replacement instance is ready in minutes.

## Local quickstart

Requirements: Docker Desktop (or Docker Engine) with the compose plugin, `aws` CLI for S3.

```bash
cp .env.example .env            # set VALHALLA_API_KEY and TILES_S3_URI

# Build the tile set once (downloads the PBF, builds admins + timezones, tars the tiles,
# then uploads to S3). Takes a few minutes for Honduras.
scripts/build-tiles.sh

# On any host that only serves: pull the published tile set and start the API.
scripts/pull-tiles.sh
docker compose --profile runtime up -d

# Tegucigalpa -> San Pedro Sula by motorcycle
set -a; . ./.env; set +a
curl -s http://localhost/route \
  -H "X-API-Key: ${VALHALLA_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"locations":[{"lat":14.0723,"lon":-87.1921},{"lat":15.5042,"lon":-88.0250}],
       "costing":"motorcycle","units":"kilometers"}'
```

To build locally without uploading, run `docker compose --profile build up` directly; the
container exits when the build is done and the artifacts are in `./custom_files`.

## Endpoints

All Valhalla endpoints are proxied under `/`. Every request needs `X-API-Key`. See the
[API reference](https://valhalla.github.io/valhalla/api/) for payloads.

| Endpoint            | Purpose                                   |
|---------------------|-------------------------------------------|
| `POST /route`       | Turn-by-turn route between locations      |
| `POST /isochrone`   | Reachability polygons                     |
| `POST /sources_to_targets` | Time/distance matrix               |
| `POST /locate`      | Snap coordinates to the graph             |
| `POST /trace_route` | Map-match a GPS trace to a route          |
| `POST /trace_attributes` | Map-match and return edge attributes |
| `POST /optimized_route` | Traveling-salesman ordering           |
| `GET /status`       | Service health (used by the healthcheck)  |

`/height` is disabled: elevation tiles are not built (`build_elevation=False`).

Responses from nginx itself are JSON: `401 {"error":"unauthorized"}` and
`429 {"error":"rate_limited"}` (20 req/s per IP, burst 40).

## Tile lifecycle

1. **Build** (`scripts/build-tiles.sh`): removes stale PBFs, runs the `build` profile
   (`tile_urls` set to the Honduras extract, `serve_tiles=False` so the container exits),
   then calls `push-tiles.sh`.
2. **Push** (`scripts/push-tiles.sh`): uploads `valhalla_tiles.tar`, `valhalla.json`,
   `admins.sqlite`, `timezones.sqlite`, `default_speeds.json` and `file_hashes.txt` from
   `./custom_files` to `${TILES_S3_URI}/`, plus `latest.txt` with the build time and checksums.
3. **Pull** (`scripts/pull-tiles.sh`): downloads the same files into `./custom_files` and
   verifies the tar checksum against `latest.txt`.

The runtime profile starts Valhalla with `use_tiles_ignore_pbf=True` and `force_rebuild=False`,
so it serves the tar as-is and never rebuilds on the host.

To refresh the data: run `scripts/build-tiles.sh` again, then on the runtime host
`docker compose --profile runtime down && scripts/pull-tiles.sh && docker compose --profile runtime up -d`.
The build runs on any amd64 or arm64 machine with AWS credentials; a spot instance for it is
not managed by Terraform yet.

## AWS deploy (Terraform)

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # set allowed_cidrs and repo_url
export TF_VAR_valhalla_api_key="$(openssl rand -hex 32)"
terraform init && terraform apply
```

This creates the tiles bucket (versioned, SSE-S3, public access blocked), an IAM role with
`AmazonSSMManagedInstanceCore` plus read access to the bucket, a security group (80/443 from
`allowed_cidrs`, no SSH), and the `t4g.medium` instance. Cloud-init installs Docker and the
compose plugin, clones `repo_url` at `git_ref` into `/opt/valhalla-api`, writes `.env`,
pulls the tiles and starts the runtime profile.

Publish the tile set before or right after `apply` using the `tiles_s3_uri` output as
`TILES_S3_URI`; cloud-init fails if the bucket is still empty (rerun it with
`terraform apply -replace=aws_instance.runtime` after publishing).

Connect without SSH:

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)"
sudo tail -f /var/log/valhalla-user-data.log
```

Put TLS in front (CloudFront, Caddy, or an nginx `listen 443 ssl` block) before exposing the
API beyond a trusted network; the API key travels in a header.

## Tests

```bash
bash tests/nginx-auth.test.sh      # nginx gate against a stub upstream, needs Docker
cp .env.example .env && docker compose --profile runtime config -q && docker compose --profile build config -q
terraform -chdir=infra/terraform init -backend=false && terraform -chdir=infra/terraform validate
shellcheck scripts/*.sh tests/*.sh
```

CI (`.github/workflows/ci.yml`) runs the same four checks on every push and pull request.

## Upgrading Valhalla

Bump the tag in the `x-valhalla-image` anchor at the top of `docker-compose.yml` (the only
place it appears), then rebuild and republish the tiles with `scripts/build-tiles.sh`: the tile
format can change between Valhalla versions, and a mismatched tar fails at startup.
