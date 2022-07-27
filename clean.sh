#!/bin/sh

label=rebuild

docker container stop $(docker container ls --filter label="${label}" -q)
docker container prune -f --filter label="${label}"
docker network   prune -f --filter label="${label}"
docker volume    prune -f --filter label="${label}"
