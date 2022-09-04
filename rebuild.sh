#!/bin/sh

set -e

# - modes:
#   - build
#   - reproduce
#   - TODO: httplock refresh and compare

# parse input
opt_b=""
opt_c="."
opt_f="Dockerfile"
opt_l="ocidir://repo"
opt_L="rebuild"
opt_n=0
opt_t="ocidir://repo:unknown"

while getopts 'b:c:ef:hl:L:nt:' option; do
  case $option in
    b) opt_b="$OPTARG";;
    c) opt_c="$OPTARG";;
    e) opt_e=1;;
    f) opt_f="$OPTARG";;
    h) opt_h=1;;
    l) opt_l="$OPTARG";;
    L) opt_L="$OPTARG";;
    n) opt_n=1;;
    t) opt_t="$OPTARG";;
  esac
done
set +e
shift $(expr $OPTIND - 1)

if [ $# -gt 0 -o "$opt_h" = "1" ]; then
  echo "Usage: $0 [opts] file"
  echo " -b ref: base image"
  echo " -c dir: context"
  echo " -e: allow external network, do not reproduce hermetically"
  echo " -f file: Dockerfile name"
  echo " -h: this help message"
  echo " -n: build a new image instead of reproducing an existing one"
  echo " -l ref: local repo for rebuilding"
  echo " -L prefix: prefix for tags in local repo"
  echo " -t ref: image to create/verify"
  exit 1
fi

# specify target image
tag_prefix="alpine"
date_cur="$(date -u +%Y%m%d-%H%M%S)"
# use SOURCE_DATE_EPOCH if defined, otherwise use git commit date
if [ -n "${SOURCE_DATE_EPOCH}" ]; then
  epoc="${SOURCE_DATE_EPOC}"
else
  epoc="$(git log -1 --format=%at)"
fi
date_max="$(date -d "@${epoc}" +%Y-%m-%dT%H:%M:%SZ --utc)"
git_short="$(git rev-parse --short HEAD)"
rnd="$(base32 </dev/random | head -c10)"
label="rebuild-${git_short}-${rnd}"
label_global="rebuild"

if [ ! -d .rebuild ]; then
  mkdir -p .rebuild
fi

# setup private (no gw) and public networks
if [ "$opt_e" = "1" ] || [ "$opt_n" = "1" ]; then
  docker network create --label "${label}" --label "${label_global}" "rebuild-gw-${git_short}-${rnd}"
fi
docker network create --internal --label "${label}" --label "${label_global}" "rebuild-build-${git_short}-${rnd}"
docker volume create --label "${label}" --label "${label_global}" "httplock-data-${git_short}-${rnd}"
docker volume inspect "httplock-data" >/dev/null 2>&1 || docker volume create --label "${label_global}-save" "httplock-data"

regctl_proxy() {
  docker container run -i --rm --net "rebuild-build-${git_short}-${rnd}" \
    --label "${label}" --label "${label_global}" \
    -u "$(id -u):$(id -g)" -w "$(pwd)" -v "$(pwd):$(pwd)" \
    -e http_proxy=http://token:${token}@proxy:8080 \
    -e https_proxy=http://token:${token}@proxy:8080 \
    -v "$(pwd)/.rebuild/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro" \
    regclient/regctl --user-agent regclient/regclient "$@"
}
regctl_public() {
  docker container run -i --rm \
    --label "${label}" --label "${label_global}" \
    -u "$(id -u):$(id -g)" -w "$(pwd)" -v "$(pwd):$(pwd)" \
    regclient/regctl "$@"
}
curl_proxy() {
  docker container run -i --rm --net "rebuild-build-${git_short}-${rnd}" \
    -u "$(id -u):$(id -g)" -w "$(pwd)" -v "$(pwd):$(pwd)" \
    --label "${label}" --label "${label_global}" \
    curlimages/curl "$@"
}

# setup http lock
docker run -d --name "httplock-proxy-${git_short}-${rnd}" \
  --label "${label}" --label "${label_global}" \
  --network "rebuild-build-${git_short}-${rnd}" --network-alias proxy \
  -v "httplock-data-${git_short}-${rnd}:/var/lib/httplock/data" \
  -v "$(pwd)/httplock/config.json:/config.json:ro" \
  httplock/httplock server -c /config.json
# attach to external network only if permitted
if [ "$opt_e" = "1" ] || [ "$opt_n" = "1" ]; then
  docker network connect "rebuild-gw-${git_short}-${rnd}" "httplock-proxy-${git_short}-${rnd}"
fi
# track proxy ip and extract CA
proxy_ip="$(docker container inspect "httplock-proxy-${git_short}-${rnd}" --format "{{ (index .NetworkSettings.Networks \"rebuild-build-${git_short}-${rnd}\").IPAddress }}")"
if [ -z "$proxy_ip" ]; then
  echo "Failed to lookup proxy ip"
  exit 1
fi
curl_proxy -s http://proxy:8081/api/ca >.rebuild/ca.pem

# for build get a uuid, use hash from existing image when rebuilding
hash=""
if [ "$opt_n" = "0" ]; then
  hash=$(regctl_proxy manifest get "${opt_t}" --format '{{ index .Annotations "reproducible.httplock.hash" }}')
  token="${hash}"
fi

# load previous data from hash into proxy
if [ "$opt_n" = "0" ]; then
  hash_digest="$(regctl_public artifact list "${opt_t}" \
    --filter-artifact-type application/vnd.httplock.export \
    --filter-annotation "reproducible.httplock.hash=${hash}" \
    --format '{{ (index .Descriptors 0).Digest }}')"
  # hash_digest=$(regctl_public artifact list "${opt_t}" \
  #   --format '{{range .Descriptors}}{{ if eq ( index .Annotations "reproducible.httplock.hash" ) "'${hash}'" }}{{println .Digest}}{{end}}{{end}}' | head -1)
  regctl_public artifact get -m application/vnd.httplock.export.tar.gzip "${opt_t}@${hash_digest}" >out/httplock.tgz
  curl_proxy -T out/httplock.tgz "http://proxy:8081/api/root/${hash}/import"
fi

# generate a uuid if needed
if [ "$opt_n" = "0" ]; then
  if [ "$opt_e" = "1" ]; then
    token=$(curl_proxy -sX POST -d "hash=$hash" http://proxy:8081/api/token | jq -r .uuid)
  fi
else
  token=$(curl_proxy -sX POST http://proxy:8081/api/token | jq -r .uuid)
fi
echo "token = ${token}"

# get base image/digest
base_digest=""
if [ "${opt_n}" = "0" ] && [ -z "${opt_b}" ]; then
  opt_b="$(regctl_proxy manifest get "${opt_t}" --format '{{ index .Annotations "org.opencontainers.image.base.name" }}')"
  base_digest="$(regctl_proxy manifest get "${opt_t}" --format '{{ index .Annotations "org.opencontainers.image.base.digest" }}')"
fi
# use digest from existing image when rebuilding
if [ -n "${opt_b}" ] && [ -z "${base_digest}" ]; then
  base_digest="$(regctl_proxy image digest "${opt_b}")"
fi

# setup build environment in private net with proxy vars
# run build, include args for source, CA, build conf
# output to oci tar
  # --opt "build-arg:REBUILD_CA=$(cat .rebuild/ca.pem)" \
if [ -t 0 ]; then
  arg_in="-it"
else
  arg_in="-i"
fi
docker run \
  --rm "$arg_in" \
  --label "${label}" --label "${label_global}" \
  --net "rebuild-build-${git_short}-${rnd}" \
  --privileged \
  -e http_proxy=http://token:${token}@proxy:8080 \
  -e https_proxy=http://token:${token}@proxy:8080 \
  -e BUILDCTL_CONNECT_RETRIES_MAX=100 \
  -v "$(pwd)/.rebuild/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro" \
  -v "$(pwd):/tmp/work:ro" \
  -v "$(pwd)/out:/tmp/out" \
  -w "/tmp/work" \
  --entrypoint buildctl-daemonless.sh \
  moby/buildkit:master \
    build \
    --frontend dockerfile.v0 \
    --local context=${opt_c} \
    --local dockerfile=${opt_c} \
    --local rebuilder=/tmp/work/.rebuild \
    --opt context:rebuilder/rebuilder=local:rebuilder \
    --opt "build-arg:http_proxy=http://token:${token}@${proxy_ip}:8080" \
    --opt "build-arg:https_proxy=http://token:${token}@${proxy_ip}:8080" \
    --opt "build-arg:SOURCE_DATE_EPOC=${epoc}" \
    --opt platform=linux/amd64,linux/arm64 \
    --opt "filename=${opt_f}" \
    --opt source=docker/dockerfile:1 \
    --output type=oci,dest=/tmp/out/output.tar \
    --metadata-file /tmp/out/metadata.json

# # rootless, untested
# docker run \
#     --rm \
#     --label "${label}" --label "${label_global}" \
#     --net "rebuild-build-${git_short}-${rnd}" \
#     --security-opt seccomp=unconfined \
#     --security-opt apparmor=unconfined \
#     --device /dev/fuse \
#     -e "BUILDKITD_FLAGS=--oci-worker-no-process-sandbox" \
#     -e http_proxy=http://token:${token}@proxy:8080 \
#     -e https_proxy=http://token:${token}@proxy:8080 \
#     -v "$(pwd)/.rebuild/ca.pem:/etc/ssl/certs/ca-certificates.crt:ro" \
#     -v "$(pwd):/tmp/work:ro" \
#     -v "$(pwd)/out:/tmp/out" \
#     --entrypoint buildctl-daemonless.sh \
#     moby/buildkit:master \
#         build \
#         --frontend dockerfile.v0 \
#         --local context=/tmp/work \
#         --local dockerfile=/tmp/work/example/alpine \
#         --opt platform=linux/amd64,linux/arm64 \
#         --opt build-arg:http_proxy=http://token:${token}@proxy:8080 \
#         --opt build-arg:https_proxy=http://token:${token}@proxy:8080 \
#         --opt "build-arg:REBUILD_CA=$(cat .rebuild/ca.pem)" \
#         --opt filename=./Dockerfile \
#         --opt source=docker/dockerfile:1 \
#         --output type=oci,dest=/tmp/out/output.tar \
#         --metadata-file /tmp/out/metadata.json

# extract tar to ocidir
tag_cur="${opt_L}-${git_short}-${date_cur}"
regctl_public image import "${opt_l}:${tag_cur}-orig" out/output.tar

# generate http lock digest if new image
if [ "$opt_n" = "1" ] || [ "$opt_e" = "1" ]; then
  hash=$(curl_proxy -sX POST "http://proxy:8081/api/token/${token}/save" | jq -r .hash)
  echo "${hash}"
fi

# apply mods (strip files), strip CA layer, reset timestamps, add annotations
#  --layer-strip-file /lib/apk/db/scripts.tar \
#  --buildarg-rm "REBUILD_CA=$(cat .rebuild/ca.pem)" \
#  --buildarg-rm-regex "REBUILD_CA=-----BEGIN CERTIFICATE.*END CERTIFICATE-----" \
#  --layer-rm-created-by '.*\/etc\/ssl\/certs\/ca-certificates\.crt.*' \
# TODO: add more user provided options, or load from a config file
regctl_public image mod "${opt_l}:${tag_cur}-orig" --create "${tag_cur}" \
  --layer-rm-created-by 'COPY ./ca.pem /etc/ssl/certs/ca-certificates.crt' \
  --buildarg-rm "SOURCE_DATE_EPOC=${epoc}" \
  --file-tar-time-max "/lib/apk/db/scripts.tar,${date_max}" \
  --time-max "${date_max}" \
  --annotation "reproducible.httplock.hash=${hash}" \
  --annotation "org.opencontainers.image.created=${date_max}" \
  --annotation "org.opencontainers.image.base.name=${opt_b}" \
  --annotation "org.opencontainers.image.base.digest=${base_digest}"

# export and push httplock data
if [ "$opt_n" = "1" ] || [ "$opt_e" = "1" ]; then
  curl_proxy "http://proxy:8081/api/root/${hash}/export" >out/httplock.tgz
  regctl_public artifact put \
    --artifact-type application/vnd.httplock.export \
    -m application/vnd.httplock.export.tar.gzip \
    -f out/httplock.tgz \
    --annotation "reproducible.httplock.hash=${hash}" \
    --refers "${opt_l}:${tag_cur}"
fi

# if reproducing, compare resulting image
#  if digest mismatch, report
#  if mismatch, log diff of failure, abend
if [ "$opt_n" = "0" ]; then
  orig_dig="$(regctl_proxy image digest "${opt_t}")"
  new_dig="$(regctl_proxy image digest "${opt_l}:${tag_cur}")"
  if [ "$orig_dig" != "$new_dig" ]; then
    echo "DIGEST MISMATCH"
    echo "Original: $orig_dig"
    echo "New: $new_dig"
    docker logs "httplock-proxy-${git_short}-${rnd}" 2>&1 | grep "Cache miss"
    # TODO: show diff
    exit 1
  else
    echo "Success: digests match: ${orig_dig}"
  fi
fi

# if new image, push image and any associated artifacts
if [ "$opt_n" = "1" ]; then
  regctl_public image copy --digest-tags --referrers "${opt_l}:${tag_cur}" "${opt_t}"
fi

# - run post build actions (sbom, sign)
# - run post push actions

# cleanup
docker container stop $(docker container ls --filter label="${label}" -q)
docker container prune -f --filter label="${label}"
docker network   prune -f --filter label="${label}"
docker volume    prune -f --filter label="${label}"

# TODO: purge out directory
