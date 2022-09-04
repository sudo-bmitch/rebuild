# Docker Image Rebuilder

This is currently a proof of concept thrown together with a shell script.
Don't rely on it for anything production related.

Example usage:

```shell
# build an alpine image
./rebuild.sh -c example/alpine/ -L alpine -t ocidir://repo:alpine -n -b alpine:latest
# rebuild
./rebuild.sh -c example/alpine/ -L alpine -t ocidir://repo:alpine

# build a docker image
./rebuild.sh -c example/debian/ -L debian -t ocidir://repo:debian -n -b debian:latest
# rebuild
./rebuild.sh -c example/debian/ -L debian -t ocidir://repo:debian
```
