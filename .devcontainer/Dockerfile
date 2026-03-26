FROM mcr.microsoft.com/devcontainers/base:trixie

RUN apt-get update \
	&& apt-get install -y --no-install-recommends shellcheck \
	&& rm -rf /var/lib/apt/lists/*
