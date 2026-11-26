# Autoconf 2.69 and Automake 1.15.1, the versions upstream's configure and
# Makefile.in files are made with. Ubuntu 18.04 ships exactly those.
ARG BASE=ubuntu:18.04
FROM ${BASE}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        autoconf automake pkg-config make && rm -rf /var/lib/apt/lists/*
