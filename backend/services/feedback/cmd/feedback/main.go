package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/caarlos0/env/v11"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	slogchi "github.com/samber/slog-chi"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

	"agent-feedback/backend/pkg/envutil"
	"agent-feedback/backend/pkg/httputil"
	"agent-feedback/backend/pkg/observability"
	"agent-feedback/backend/services/feedback/core"
	"agent-feedback/backend/services/feedback/handler"
	"agent-feedback/backend/services/feedback/storage/postgres"

	_ "go.uber.org/automaxprocs"
)

const (
	envDev  = "dev"
	envProd = "prod"
)

type config struct {
	ServiceName     string        `env:"SERVICE_NAME" envDefault:"agent-feedback"`
	ServiceVersion  string        `env:"SERVICE_VERSION" envDefault:"v1.0.0"`
	EnvMode         string        `env:"ENV_MODE" envDefault:"dev"`
	HTTPListenAddr  string        `env:"HTTP_LISTEN_ADDR" envDefault:"0.0.0.0:8080"`
	OtelEndpoint    string        `env:"OTEL_TRACING_ENDPOINT"`
	PostgresURL     string        `env:"POSTGRES_URL,required"`
	APIKey          string        `env:"API_KEY,required"`
	ServiceRegion   string        `env:"SERVICE_REGION" envDefault:"local"`
	ShutdownTimeout time.Duration `env:"GRACEFUL_SHUTDOWN_TIMEOUT" envDefault:"90s"`
}

// buildLoggerMiddleware creates slog-chi middleware with conditional OTel support.
func buildLoggerMiddleware(logger *slog.Logger, envMode string) func(http.Handler) http.Handler {
	filters := []slogchi.Filter{
		slogchi.IgnorePath(
			"/health",
			"/healthz",
			"/ready",
			"/metrics",
		),
	}

	cfg := slogchi.Config{
		DefaultLevel:     slog.LevelInfo,
		ClientErrorLevel: slog.LevelWarn,
		ServerErrorLevel: slog.LevelError,
		WithRequestID:    true,
		Filters:          filters,
	}
	if envMode == envProd {
		cfg.WithTraceID = true
		cfg.WithSpanID = true
	}

	return slogchi.NewWithConfig(logger, cfg)
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)

	_ = godotenv.Load()

	var cfg config
	if err := env.Parse(&cfg); err != nil {
		log.Fatalf("unable to parse config: %v", err)
	}

	cfg.PostgresURL = envutil.ReplaceHost("POSTGRES_URL", cfg.PostgresURL)

	if cfg.ShutdownTimeout <= 0 {
		slog.Warn("GRACEFUL_SHUTDOWN_TIMEOUT must be positive, using default 90s",
			"provided", cfg.ShutdownTimeout)
		cfg.ShutdownTimeout = 90 * time.Second
	}

	// Logger
	loglvl := slog.LevelInfo
	if cfg.EnvMode == envDev {
		loglvl = slog.LevelDebug
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		AddSource: false,
		Level:     loglvl,
	}))
	slog.SetDefault(logger)
	slog.Info("booting up...")

	// OpenTelemetry (skips if endpoint not configured)
	otelShutdown, err := observability.SetupTracing(context.Background(), observability.OTelConfig{
		Env:            cfg.EnvMode,
		ServiceName:    cfg.ServiceName,
		ServiceVersion: cfg.ServiceVersion,
		Endpoint:       cfg.OtelEndpoint,
		Region:         cfg.ServiceRegion,
	})
	if err != nil {
		slog.Info("failed to setup tracing, continuing without otel", "error", err)
	}
	defer otelShutdown()

	// Postgres
	pg, err := postgres.New(cfg.PostgresURL, 1, 20, true)
	if err != nil {
		log.Fatalf("unable to boot up pgsql: %v", err)
	}

	// Core service
	svc, err := core.New(pg)
	if err != nil {
		log.Fatalf("unable to boot svc: %v", err)
	}
	defer svc.Close()

	// Handler
	h := handler.New(svc)

	// Router
	r := chi.NewRouter()

	// middleware.RealIP is deliberately absent: it rewrites RemoteAddr from
	// spoofable headers (X-Forwarded-For etc.) and nothing proxies this service.
	r.Use(
		middleware.Recoverer,
		middleware.RequestID,
		buildLoggerMiddleware(logger, cfg.EnvMode),
		httputil.ReqMonitor(cfg.ServiceName),
	)

	// Health and monitoring
	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	})
	var shuttingDown atomic.Bool
	r.Get("/ready", func(w http.ResponseWriter, r *http.Request) {
		if shuttingDown.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte("SHUTTING_DOWN"))
			return
		}
		// Readiness includes the database: a wedged Postgres must fail the
		// probe (and the deploy script's post-deploy check), not report READY
		// while every write spools client-side.
		pingCtx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := pg.DB().Ping(pingCtx); err != nil {
			slog.Warn("readiness probe failed: postgres unreachable", "error", err)
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte("DB_UNAVAILABLE"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("READY"))
	})
	r.Handle("/metrics", promhttp.Handler())

	// API routes (auth-gated)
	r.Route("/api/v1", func(api chi.Router) {
		api.Use(handler.RequireAPIKey(cfg.APIKey))

		api.Post("/reviews", h.HandleCreateReview())
		api.Post("/frictions", h.HandleCreateFriction())
		api.Get("/submissions", h.HandleListSubmissions())
		api.Post("/submissions/processed", h.HandleSetProcessed())
		api.Get("/submissions/{id}", h.HandleGetSubmission())
	})

	httpSrv := http.Server{
		Addr:              cfg.HTTPListenAddr,
		Handler:           otelhttp.NewHandler(r, cfg.ServiceName),
		ReadTimeout:       time.Minute * 5,
		ReadHeaderTimeout: time.Second * 5,
		WriteTimeout:      time.Minute * 10,
		IdleTimeout:       time.Second * 60,
		MaxHeaderBytes:    1 << 20,
	}

	go func() {
		if err := httpSrv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			slog.Error("http server failed", "error", err)
			os.Exit(1)
		}
	}()

	slog.Info(fmt.Sprintf("service (%v) is up and running on (%v) at (%v)",
		cfg.ServiceName, runtime.Version(), cfg.HTTPListenAddr))

	// Graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	sig := <-stop
	slog.Info(fmt.Sprintf("service (%v) received signal (%v), beginning graceful shutdown",
		cfg.ServiceName, sig))

	// Phase 1: Mark as shutting down so /ready returns 503
	shuttingDown.Store(true)
	slog.Info("readiness probe marked as shutting down")

	// Phase 2: Drain delay for K8s endpoint de-registration propagation
	slog.Info("waiting 5s for K8s endpoint de-registration to propagate")
	time.Sleep(5 * time.Second)

	// Phase 3: Gracefully drain in-flight requests
	cctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()

	slog.Info(fmt.Sprintf("starting graceful shutdown with %v timeout", cfg.ShutdownTimeout))

	if err := httpSrv.Shutdown(cctx); err != nil {
		slog.Error("http server did not shutdown gracefully within timeout",
			"error", err, "timeout", cfg.ShutdownTimeout)
	} else {
		slog.Info("http server shut down gracefully")
	}

	slog.Info("service successfully shut down")
}
