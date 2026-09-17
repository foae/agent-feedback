# Build the service binary to bin/feedback.
build:
    go build -o bin/feedback ./cmd/feedback

# Run all checks: fmt, vet, tidy, build. The pre-commit gate.
check: fmt vet tidy build

# Format every package.
fmt:
    go fmt ./...

# Run go vet.
vet:
    go vet ./...

# Run go mod tidy.
tidy:
    go mod tidy

# Run the tests with race detection. No Docker, no database required.
test:
    go test -race -count=1 ./...

# Run locally against a database in ./local (created on demand).
run-local: build
    mkdir -p local
    DATABASE_PATH=${DATABASE_PATH:-local/feedback.db} \
    HTTP_LISTEN_ADDR=${HTTP_LISTEN_ADDR:-127.0.0.1:8090} \
    API_KEY=${API_KEY:-local-dev-key} \
    ./bin/feedback

# Build the Docker image tagged agent-feedback.
docker-build:
    docker build -t agent-feedback .

# Remove build artifacts.
clean:
    rm -rf bin/
