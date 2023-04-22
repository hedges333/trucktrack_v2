FROM debian:bullseye-slim
WORKDIR /tmp
COPY apt-reqs .
RUN apt-get update && \
    apt-get dist-upgrade -y && \
    apt install -y `cat apt-reqs`

RUN mkdir -p /opt/trucktrack
WORKDIR /opt/trucktrack

ENTRYPOINT ["perl", "trucktrack_v3.pl"]

