# Build stage — full Go toolchain, discarded from the final image.
FROM golang:1.26-bookworm AS build

ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY ./ ./

RUN go build -trimpath -ldflags="-s -w" -o /opt/feedback ./services/feedback/cmd/feedback

# Runtime stage — static binary only, plus ca-certs/tzdata and a nonroot user
# from distroless. Keeps the deployable image ~20 MB instead of ~500 MB.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /opt/feedback /opt/feedback

USER nonroot
EXPOSE 8080
ENTRYPOINT ["/opt/feedback"]
