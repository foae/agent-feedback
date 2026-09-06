# syntax=docker/dockerfile:1
# Build on the BuildKit builder platform and cross-compile the static binary for
# the target image platform.
FROM --platform=$BUILDPLATFORM golang:1.27.1-bookworm AS build

ARG TARGETOS
ARG TARGETARCH

ENV CGO_ENABLED=0

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY ./ ./

RUN GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -trimpath -ldflags="-s -w" -o /opt/feedback ./services/feedback/cmd/feedback

# Alpine supplies the runtime curl used by the Compose readiness healthcheck,
# CA roots, timezone data, and a non-root service account.
FROM alpine:3.24.1

RUN apk add --no-cache ca-certificates curl tzdata \
    && addgroup -S feedback \
    && adduser -S -G feedback feedback

COPY --from=build /opt/feedback /opt/feedback

USER feedback
EXPOSE 8080
ENTRYPOINT ["/opt/feedback"]
