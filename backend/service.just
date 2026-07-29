# Shared recipes for all services.
# Import from each service's justfile after setting SERVICE_NAME.
#
# Example (backend/services/myservice/justfile):
#   SERVICE_NAME := "myservice"
#   import '../../service.just'
#
# Override any recipe by redefining it after the import.

_module_root := source_directory()
_cmd_path := "./services/" + SERVICE_NAME + "/cmd/" + SERVICE_NAME
_svc_path := "./services/" + SERVICE_NAME + "/..."
_bin := _module_root / "bin" / SERVICE_NAME
_svc_dir := _module_root / "services" / SERVICE_NAME
_sqlc_yaml := _svc_dir / "storage" / "postgres" / "sqlc.yaml"

# Build the service binary to backend/bin/<service>.
build:
    cd {{_module_root}} && go build -o bin/{{SERVICE_NAME}} {{_cmd_path}}

# Build and run locally from the service directory (godotenv finds .env there).
run-local: build
    cd {{_svc_dir}} && {{_bin}}

# Run tests with race detection.
test:
    cd {{_module_root}} && go test -race -v {{_svc_path}}

# Run go vet.
vet:
    cd {{_module_root}} && go vet {{_svc_path}}

# Run go fmt.
fmt:
    cd {{_module_root}} && go fmt {{_svc_path}}

# Run go mod tidy.
tidy:
    cd {{_module_root}} && go mod tidy

# Run go generate.
generate:
    cd {{_module_root}} && go generate {{_svc_path}}

# Lint SQL queries (sqlc vet + compile). Fails fast before code generation.
sqlc-vet:
    sqlc vet -f {{_sqlc_yaml}} && sqlc compile -f {{_sqlc_yaml}}

# Generate type-safe Go code from SQL queries (vet + compile + generate).
sqlc-generate: sqlc-vet
    sqlc generate -f {{_sqlc_yaml}}

# Run all checks: fmt, vet, sqlc lint, tidy, build. Use as a pre-commit gate.
check: fmt vet sqlc-vet tidy build

# Build Docker image tagged as <service-name>.
docker-build:
    cd {{_module_root}} && docker build -t {{SERVICE_NAME}} -f services/{{SERVICE_NAME}}/Dockerfile .

# Run Docker container with port 8080 exposed. Override env file: just docker-run .env
docker-run env_file=".env.example": docker-build
    docker run --rm -p 8080:8080 --env-file {{env_file}} {{SERVICE_NAME}}

# Remove the built binary.
clean:
    rm -f {{_bin}}
