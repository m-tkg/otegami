# syntax=docker/dockerfile:1
# Multi-stage build for the otegami push relay server.
#
# NOTE (M0): this is a scaffold. It has not been built/run yet — building it
# is deferred until the relay has real functionality (M9). Revisit the Swift
# version pin and dependency cache layering once that lands.

FROM swift:6.0-jammy AS build
WORKDIR /build

# Resolve dependencies separately so they're cached across source changes.
COPY Package.swift Package.resolved* ./
RUN swift package resolve

COPY Sources ./Sources
RUN swift build -c release --static-swift-stdlib

FROM swift:6.0-jammy-slim AS run
WORKDIR /app
COPY --from=build /build/.build/release/OtegamiRelay ./OtegamiRelay

EXPOSE 8080
ENTRYPOINT ["./OtegamiRelay"]
