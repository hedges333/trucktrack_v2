#!/bin/sh

if ! docker image ls -a | grep trucktrack_v3; then
    docker build -t trucktrack_v3 .
fi
docker run -it -v $(pwd):/opt/trucktrack trucktrack_v3
