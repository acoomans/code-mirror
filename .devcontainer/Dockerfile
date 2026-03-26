FROM mcr.microsoft.com/devcontainers/base:trixie

RUN apt-get update \
	&& apt-get install -y --no-install-recommends shellcheck git-lfs \
	&& rm -rf /var/lib/apt/lists/*
