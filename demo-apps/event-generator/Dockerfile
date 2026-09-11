# demo-apps/event-generator/Dockerfile
#
# Multi-stage build: the "build" stage has the full Go toolchain (hundreds
# of MB) but nothing from it ends up in the final image except the compiled
# binary, copied across via `COPY --from=build`. This keeps the shipped
# image small and free of build tooling/source code that has no business
# being in a running container.

FROM golang:1.26 AS build
WORKDIR /src

# Copying go.mod/go.sum and running `go mod download` before copying the
# rest of the source lets Docker cache this (usually slow) layer — it only
# re-runs when dependencies change, not on every source-code edit, thanks
# to Docker's layer caching working off each COPY's content hash.
COPY go.mod go.sum ./
RUN go mod download
COPY . .

# CGO_ENABLED=0 produces a statically-linked binary with no dependency on
# the host's C library (glibc/musl) — required here because the final stage
# below is `distroless/static`, an image so minimal it has no C library at
# all. GOOS=linux is explicit in case this is ever built on a non-Linux
# machine (e.g. this repo's Docker Desktop/OrbStack setup on macOS) — the
# image that runs inside the kind cluster must always be a Linux binary
# regardless of what built it.
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/event-generator .

# distroless images (https://github.com/GoogleContainerTools/distroless)
# contain just the app and its runtime dependencies — no shell, no package
# manager, no coreutils. That shrinks both the image size and the attack
# surface (there's no `/bin/sh` for an attacker who gets code execution to
# pivot into), at the cost of `kubectl exec ... sh` not working against
# this container — a deliberate, common production trade-off.
FROM gcr.io/distroless/static-debian12
COPY --from=build /out/event-generator /event-generator

# EXPOSE is documentation, not enforcement — it doesn't actually open the
# port. The real exposure happens via the Kubernetes Service (Task 7's
# service.yaml) targeting this same containerPort: 8080.
EXPOSE 8080
ENTRYPOINT ["/event-generator"]
