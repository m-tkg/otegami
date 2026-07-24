# syntax=docker/dockerfile:1
# Multi-stage build for the otegami push relay server.
#
# Build context must be the **repository root** (not this directory) —
# `Package.swift` depends on `../../packages/OtegamiKit` (the
# `OtegamiRelayAPI`/`OtegamiCore` shared DTOs), which needs to be inside the
# build context to be COPYed in. `docker-compose.yml` sets this
# automatically (`build.context: ../..`); if invoking `docker build`
# directly, do it from the repo root:
#
#   docker build -f server/otegami-relay/Dockerfile -t otegami-relay .
#
# (see `make relay-docker`, which does exactly this).
FROM swift:6.2-jammy AS build
WORKDIR /build

# Only OtegamiRelayAPI + its own dependency OtegamiCore are actually used
# (see Package.swift's dependency comment) — SwiftPM's target-based
# dependency pruning means the rest of OtegamiKit's manifest (MailCore2,
# GRDB, ...) is resolved (their repos are fetched, to compute the
# dependency graph) but never *built*, so this stays reasonably fast
# despite copying the whole package in.
COPY packages/OtegamiKit ./packages/OtegamiKit

COPY server/otegami-relay/Package.swift server/otegami-relay/Package.resolved* ./server/otegami-relay/
WORKDIR /build/server/otegami-relay
RUN swift package resolve

COPY server/otegami-relay/Sources ./Sources
COPY server/otegami-relay/Tests ./Tests
# `--product OtegamiRelay` skips actually *building* the test target (only
# the executable is needed at runtime), but SwiftPM still validates every
# target's declared path while loading the manifest — hence copying
# `Tests/` in too, even though nothing under it ends up in the final image.
RUN swift build -c release --product OtegamiRelay --static-swift-stdlib

FROM swift:6.2-jammy-slim AS run
WORKDIR /app
RUN useradd --system --create-home --home-dir /app --shell /usr/sbin/nologin otegami \
    && mkdir -p /app/data && chown -R otegami:otegami /app
COPY --from=build /build/server/otegami-relay/.build/release/OtegamiRelay ./OtegamiRelay
USER otegami

# `RELAY_DATABASE_PATH` (see docker-compose.yml) points inside this volume
# mount so the SQLite file survives container recreation.
VOLUME ["/app/data"]
EXPOSE 8080
ENTRYPOINT ["./OtegamiRelay"]
