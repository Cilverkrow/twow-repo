# syntax=docker/dockerfile:1.7
#
# bot-brain: the out-of-process bot planning service (ARCH-001).
#
# Build context is services/bot-brain, NOT the repo root. This service shares no
# source with the C++ tree and must not drag it into a build context; keeping the
# context tiny is also why this image builds in seconds while Dockerfile.core
# takes minutes.
#
#   docker build -t twow/bot-brain:dev services/bot-brain
#
# The module has zero external dependencies, so there is no `go mod download`
# layer and no module proxy to reach: the build works on a disconnected machine.

ARG GO_VERSION=1.23

# ------------------------------------------------------------------- builder
FROM golang:${GO_VERSION}-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY . .

# CGO off so the result is a static binary that runs in a scratch image.
# Version metadata is passed as a build arg rather than read from git, because
# the build context deliberately does not include .git.
ARG VERSION=dev
ARG COMMIT=unknown
ENV CGO_ENABLED=0 GOOS=linux

# `go vet` only -- deliberately NOT `go test`.
#
# The build context is this directory (deploy/compose/bot-brain.yml explains
# why: a small context is what makes this build in seconds). But
# contract/golden_test.go reads ../../../contracts/bot-brain/v1/golden/, which
# is OUTSIDE that context, so `go test ./...` here failed with
#   open ../../../contracts/bot-brain/v1/golden/plan-response.json:
#   no such file or directory
# and the image could not be built at all -- `docker compose up bot-brain`
# died on the build step.
#
# The tests are not lost: ci.yml runs `go test -race -count=1 ./...` for this
# module against the full repository, where the fixtures exist. The golden
# test compares the Go types against fixtures the C++ side also reads, so it
# belongs where both trees are present. An image build is the wrong place to
# re-run a suite whose inputs it cannot see.
RUN go vet ./... && \
    go build -trimpath \
      -ldflags "-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/bot-brain ./cmd/bot-brain

# ------------------------------------------------------------------- runtime
# scratch, not alpine: this process opens a listening socket and, optionally,
# one outbound TLS connection to an inference endpoint. It needs a CA bundle and
# nothing else. A shell in this image would be attack surface with no operator
# benefit -- debugging is `docker run --entrypoint` against the builder stage.
FROM scratch AS runtime

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/bot-brain /bot-brain

# Non-root by uid, since scratch has no /etc/passwd to name a user in.
USER 65532:65532

EXPOSE 8085

ENV BOT_BRAIN_LISTEN=":8085"

# The binary is its own health probe: scratch has no curl or wget, so
# `bot-brain healthcheck` GETs the local /healthz and exits 0 or 1.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 CMD ["/bot-brain", "healthcheck"]

ENTRYPOINT ["/bot-brain"]
