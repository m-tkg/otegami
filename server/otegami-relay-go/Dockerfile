# syntax=docker/dockerfile:1
# Multi-stage build for the otegami push relay server (Go port, Task #180).
#
# The entire point of this port is that the arm64 (Raspberry Pi) image can
# be built on an x86_64 runner WITHOUT QEMU: the build stage always runs
# natively on the build host (--platform=$BUILDPLATFORM) and Go
# cross-compiles to $TARGETARCH with CGO_ENABLED=0 (the SQLite driver is
# pure-Go modernc.org/sqlite, so no C cross-toolchain is needed either).
#
#   docker buildx build --platform linux/arm64 \
#     -f server/otegami-relay-go/Dockerfile -t otegami-relay-go \
#     server/otegami-relay-go
#
# Unlike the Swift relay's Dockerfile, the build context is THIS directory
# (the Go module is self-contained — no ../../packages dependency).
FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download

COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/otegami-relay ./cmd/otegami-relay

# Runtime: debian slim with CA certificates (needed for TLS to APNs, the
# OAuth token endpoints, and IMAPS hosts) and a non-root user, mirroring
# the Swift image's runtime layout (/app, /app/data volume, port 8080).
FROM debian:bookworm-slim AS run
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /app --shell /usr/sbin/nologin otegami \
    && mkdir -p /app/data && chown -R otegami:otegami /app
WORKDIR /app
COPY --from=build /out/otegami-relay ./otegami-relay
USER otegami

# RELAY_DATABASE_PATH (see docker-compose.yml) points inside this volume
# mount so the SQLite file survives container recreation.
VOLUME ["/app/data"]
EXPOSE 8080
ENTRYPOINT ["./otegami-relay"]
