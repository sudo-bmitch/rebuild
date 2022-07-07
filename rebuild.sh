#!/bin/sh

set -e
base_name="alpine:latest"
tag_prefix="alpine"
git_short="$(git rev-parse --short HEAD)"
# use SOURCE_DATE_EPOCH if defined, otherwise use git commit date
# SOURCE_DATE_EPOCH is in sec, unix epoc style, e.g. 1577854800 for 2020-01-01
date_git="$(date -d "@$(git log -1 --format=%at)" +%Y-%m-%dT%H:%M:%SZ --utc)"
date_cur="$(date -u +%Y%m%d-%H%M%S)"

# - modes:
#   - build
#   - reproduce
#   - httplock refresh and compare

# TODO: add unique id for labels and container names (include git short hash and random)

# - setup private (no gw) and public networks
docker network create --internal --label rebuild.test rebuild-build
docker network create --label rebuild.test rebuild-gw
docker volume create --label rebuild.test httplock-data

  
# - setup http lock in both networks and publish random port, extract CA
# TODO: remove published port, run commands in containers if needed
docker run -d --name httplock-proxy \
  --label rebuild.test \
  --network rebuild-gw \
  -v "httplock-data:/var/lib/httplock/data" \
  -v "$(pwd)/.rebuilder/config.json:/config.json" \
  -p "127.0.0.1:8080:8080" -p "127.0.0.1:8081:8081" \
  httplock/httplock server -c /config.json
docker network connect --alias proxy rebuild-build httplock-proxy
proxy_ip="$(docker container inspect httplock-proxy --format '{{ (index .NetworkSettings.Networks "rebuild-build").IPAddress }}')"
curl -s http://127.0.0.1:8081/ca >.rebuilder/ca.pem
# for build get a uuid
if [ -n "$hash" ]; then
  uuid=$(curl -sX POST -d "hash=$hash" http://127.0.0.1:8081/token | jq -r .uuid)
else
  uuid=$(curl -sX POST http://127.0.0.1:8081/token | jq -r .uuid)
fi
echo "${uuid}"
# uuid="uuid:389f2026-fe77-4ad7-973d-ba47cb509ffe"

regctl() {
  docker container run -i --rm --net rebuild-build \
    --label rebuild.test \
    -u "$(id -u):$(id -g)" -w "$(pwd)" -v "$(pwd):$(pwd)" \
    -e http_proxy=http://token:${uuid}@proxy:8080 \
    -e https_proxy=http://token:${uuid}@proxy:8080 \
    -v "$(pwd)/.rebuilder/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro" \
    regclient/regctl "$@"
}

# TODO: for rebuild, define the login/root hash

# TODO: get timestamp from source, fixed, from base, 1970-01-01

# - pull digest for base image, use regctl on private network with http lock
base_digest=""
if [ -n "$base_name" ]; then
  base_digest=$(regctl image digest "$base_name")
fi

# - setup build environment in private net with proxy vars
# - run build, include args for source, CA, build conf
# - output to oci tar
docker run \
  --rm \
  --label rebuild.test \
  --net rebuild-build \
  --privileged \
  -e http_proxy=http://token:${uuid}@proxy:8080 \
  -e https_proxy=http://token:${uuid}@proxy:8080 \
  -v "$(pwd)/.rebuilder/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro" \
  -v "$(pwd):/tmp/work:ro" \
  -v "$(pwd)/out:/tmp/out" \
  --entrypoint buildctl-daemonless.sh \
  moby/buildkit:master \
    build \
    --frontend dockerfile.v0 \
    --local context=/tmp/work/example/alpine \
    --local dockerfile=/tmp/work/example/alpine \
    --local rebuild=/tmp/work/.rebuilder \
    --opt context:rebuild=local:rebuild \
    --opt platform=linux/amd64,linux/arm64 \
    --opt build-arg:http_proxy=http://token:${uuid}@${proxy_ip}:8080 \
    --opt build-arg:https_proxy=http://token:${uuid}@${proxy_ip}:8080 \
    --opt "build-arg:REBUILD_CA=$(cat .rebuilder/ca.pem)" \
    --opt filename=./Dockerfile \
    --opt source=docker/dockerfile:1 \
    --output type=oci,dest=/tmp/out/output.tar \
    --metadata-file /tmp/out/metadata.json

# # rootless, untested
# docker run \
#     --rm \
#     --label rebuild.test \
#     --net rebuild-build \
#     --security-opt seccomp=unconfined \
#     --security-opt apparmor=unconfined \
#     --device /dev/fuse \
#     -e "BUILDKITD_FLAGS=--oci-worker-no-process-sandbox" \
#     -e http_proxy=http://token:${uuid}@proxy:8080 \
#     -e https_proxy=http://token:${uuid}@proxy:8080 \
#     -v "$(pwd)/.rebuilder/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro" \
#     -v "$(pwd):/tmp/work:ro" \
#     -v "$(pwd)/out:/tmp/out" \
#     --entrypoint buildctl-daemonless.sh \
#     moby/buildkit:master \
#         build \
#         --frontend dockerfile.v0 \
#         --local context=/tmp/work \
#         --local dockerfile=/tmp/work/example/alpine \
#         --opt platform=linux/amd64,linux/arm64 \
#         --opt build-arg:http_proxy=http://token:${uuid}@proxy:8080 \
#         --opt build-arg:https_proxy=http://token:${uuid}@proxy:8080 \
#         --opt "build-arg:REBUILD_CA=$(cat .rebuilder/ca.pem)" \
#         --opt filename=./Dockerfile \
#         --opt source=docker/dockerfile:1 \
#         --output type=oci,dest=/tmp/out/output.tar \
#         --metadata-file /tmp/out/metadata.json

# - extract tar to ocidir
# mkdir -p out/outoci
# tar -xf out/output.tar -C out/outoci/
# date_cur=20220420-005725
# date_cur=20220530-000500
tag_cur="${tag_prefix}-${git_short}-${date_cur}"
regctl image import "ocidir://.rebuilder/repo:${tag_cur}-orig" out/output.tar

# - generate http lock digest if new image
hash=$(curl -sX POST "http://127.0.0.1:8081/token/${uuid}/save" | jq -r .hash)
echo "${hash}"
# hash="sha256:40a7c8acd175e56510f02da70f352ac41b02c513828efee3135f4d8a730e52d4"
# hash="sha256:4b1a2953a8dfe57504efa62f7a8e3bc2254dff84d8108986c11c2c9da8ef1630"

# - apply mods (strip files), strip CA layer, reset timestamps
#  --layer-strip-file /lib/apk/db/scripts.tar \
#  --buildarg-rm "REBUILD_CA=$(cat .rebuilder/ca.pem)" \
regctl image mod "ocidir://.rebuilder/repo:${tag_cur}-orig" --create "${tag_cur}-v2" \
  --layer-rm-created-by '.*\/etc\/ssl\/certs\/ca-certificates\.crt.*' \
  --file-tar-time-max "/lib/apk/db/scripts.tar,${date_git}" \
  --time-max "${date_git}" \
  --buildarg-rm-regex "REBUILD_CA=-----BEGIN CERTIFICATE.*END CERTIFICATE-----" \
  --annotation "reproducible.httplock.hash=${hash}" \
  --annotation "org.opencontainers.image.created=${date_git}" \
  --annotation "org.opencontainers.image.base.name=${base_name}" \
  --annotation "org.opencontainers.image.base.digest=${base_digest}"

# - add annotations for base, httplock, build conf
# - if reproducing, compare resulting image
#   - if digest mismatch, perform a deep compare of layers and json
#   - import json to objects and compare
#   - if json whitespace diff, push updated config/manifest to ocidir
#   - if mismatch, log diff of failure, abend
# - run post build actions (sbom, sign)
# - push image and any associated artifacts
# - run post push actions

# cleanup
docker container stop $(docker container ls --filter label=rebuild.test -q)
docker container prune -f --filter label=rebuild.test
docker network   prune -f --filter label=rebuild.test
docker volume    prune -f --filter label=rebuild.test
# TODO: prune `out` dir
