package postgres

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"log/slog"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	sharedpg "agent-feedback/backend/pkg/postgres"
	"agent-feedback/backend/services/feedback/storage/postgres/sqlc"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

// Client provides database access for the service.
type Client struct {
	cl  *sharedpg.Client
	sql *sqlc.Queries
	pgx *pgxpool.Pool
}

func runMigrations(cfgURL string) error {
	d, err := iofs.New(migrationFiles, "migrations")
	if err != nil {
		return fmt.Errorf("pg: unable to create migration driver: %w", err)
	}

	m, err := migrate.NewWithSourceInstance("iofs", d, cfgURL)
	if err != nil {
		return fmt.Errorf("pg: unable to create migration instance: %w", err)
	}

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return fmt.Errorf("pg: unable to run migrations: %w", err)
	}

	return nil
}

// New creates a new database client with optional migration execution.
func New(cfgURL string, minConns int, maxConns int, shouldRunMigrations bool) (*Client, error) {
	p, err := sharedpg.New(cfgURL, minConns, maxConns)
	if err != nil {
		return nil, fmt.Errorf("pg: unable to create postgres client: %w", err)
	}

	if err := p.Pool().Ping(context.Background()); err != nil {
		return nil, fmt.Errorf("pg: unable to ping postgres: %w", err)
	}

	if shouldRunMigrations {
		slog.Info("pg: running database migrations")
		if err := runMigrations(cfgURL); err != nil {
			return nil, fmt.Errorf("pg: migration failed: %w", err)
		}
		slog.Info("pg: migrations completed successfully")
	}

	scWrap := &SqlcWrapper{pgx: p.Pool()}
	sc := sqlc.New(scWrap)

	return &Client{
		cl:  p,
		sql: sc,
		pgx: scWrap.pgx,
	}, nil
}

func (c *Client) DB() *pgxpool.Pool {
	return c.pgx
}

func (c *Client) Queries() *sqlc.Queries {
	return c.sql
}

func (c *Client) WithTx(tx pgx.Tx) *Client {
	return &Client{
		cl:  c.cl,
		pgx: c.pgx,
		sql: c.sql.WithTx(tx),
	}
}

func (c *Client) Close() {
	c.cl.Close()
}

func (c *Client) RawConn() *sql.DB {
	return c.cl.RawConn()
}

// SqlcWrapper wraps pgxpool.Pool to implement sqlc's DBTX interface.
type SqlcWrapper struct {
	pgx *pgxpool.Pool
}

func (sw *SqlcWrapper) Exec(ctx context.Context, query string, args ...interface{}) (pgconn.CommandTag, error) {
	return sw.pgx.Exec(ctx, query, args...)
}

func (sw *SqlcWrapper) Query(ctx context.Context, query string, args ...interface{}) (pgx.Rows, error) {
	return sw.pgx.Query(ctx, query, args...)
}

func (sw *SqlcWrapper) QueryRow(ctx context.Context, query string, args ...interface{}) pgx.Row {
	return sw.pgx.QueryRow(ctx, query, args...)
}
