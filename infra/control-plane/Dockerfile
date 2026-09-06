FROM python:3.12-slim-bookworm
ARG TARGETARCH
ARG GH_VERSION=2.100.0
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && case "$TARGETARCH" in \
       amd64) gh_sha=e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be ;; \
       arm64) gh_sha=ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961 ;; \
       *) exit 1 ;; esac \
    && curl --fail --location --retry 3 -o /tmp/gh.tar.gz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz" \
    && echo "$gh_sha  /tmp/gh.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && install "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh \
    && rm -rf /tmp/gh* \
    && useradd --uid 10001 --create-home crew
WORKDIR /app
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY crew_control ./crew_control
RUN mkdir /data && chown crew:crew /data
USER crew
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 CREW_DATA_DIR=/data GH_CONFIG_DIR=/tmp/gh XDG_CACHE_HOME=/tmp/cache
EXPOSE 4100
CMD ["python", "-m", "crew_control.cli", "serve", "--host", "127.0.0.1", "--port", "4100"]
