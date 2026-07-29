package observability

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
	"google.golang.org/grpc/encoding/gzip"
)

// OTelConfig holds configuration for OpenTelemetry tracing setup.
type OTelConfig struct {
	Env            string
	ServiceName    string
	ServiceVersion string
	Endpoint       string
	Region         string
}

// SetupTracing initializes OpenTelemetry tracing with a gRPC exporter.
// If cfg.Endpoint is empty, tracing is silently skipped (no error).
// The returned shutdown function should be called on service exit.
func SetupTracing(ctx context.Context, cfg OTelConfig) (shutdown func(), err error) {
	noop := func() {}

	if cfg.Endpoint == "" {
		slog.InfoContext(ctx, "tracing: no OTEL endpoint provided, skipping setup")
		return noop, nil
	}

	slog.InfoContext(ctx, "setting up OTEL tracing", "service", cfg.ServiceName, "endpoint", cfg.Endpoint)

	exp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(cfg.Endpoint),
		otlptracegrpc.WithInsecure(),
		otlptracegrpc.WithCompressor(gzip.Name),
		otlptracegrpc.WithTimeout(time.Second*30),
		otlptracegrpc.WithReconnectionPeriod(time.Second*5),
	)
	if err != nil {
		return noop, fmt.Errorf("failed to create tracing exporter: %w", err)
	}

	bsp := sdktrace.NewBatchSpanProcessor(exp,
		sdktrace.WithMaxQueueSize(256),
		sdktrace.WithMaxExportBatchSize(128),
		sdktrace.WithExportTimeout(time.Second*30),
	)

	res := resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(cfg.ServiceName),
		semconv.ServiceVersion(cfg.ServiceVersion),
		semconv.DeploymentEnvironment(cfg.Env),
		attribute.String("service.region", cfg.Region),
	)

	provider := sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithSpanProcessor(bsp),
		sdktrace.WithSampler(sdktrace.TraceIDRatioBased(0.1)),
	)

	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return func() {
		shutdownCtx := context.Background()
		_ = exp.Shutdown(shutdownCtx)
		_ = provider.Shutdown(shutdownCtx)
		_ = bsp.Shutdown(shutdownCtx)
	}, nil
}
