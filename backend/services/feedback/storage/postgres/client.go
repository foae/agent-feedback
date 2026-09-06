package postgres

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"log/slog"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5"
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

func runMigrations(cfgURL string) (retErr error) {
	d, err := iofs.New(migrationFiles, "migrations")
	if err != nil {
		return fmt.Errorf("pg: unable to create migration driver: %w", err)
	}

	m, err := migrate.NewWithSourceInstance("iofs", d, cfgURL)
	if err != nil {
		migrationErr := fmt.Errorf("pg: unable to create migration instance: %w", err)
		if closeErr := d.Close(); closeErr != nil {
			return errors.Join(migrationErr, fmt.Errorf("pg: unable to close migration source: %w", closeErr))
		}
		return migrationErr
	}
	defer func() {
		sourceErr, databaseErr := m.Close()
		if closeErr := errors.Join(sourceErr, databaseErr); closeErr != nil {
			closeErr = fmt.Errorf("pg: unable to close migration drivers: %w", closeErr)
			if retErr == nil {
				retErr = closeErr
			} else {
				retErr = errors.Join(retErr, closeErr)
			}
		}
	}()

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
		p.Close()
		return nil, fmt.Errorf("pg: unable to ping postgres: %w", err)
	}

	if shouldRunMigrations {
		slog.Info("pg: running database migrations")
		if err := runMigrations(cfgURL); err != nil {
			p.Close()
			return nil, fmt.Errorf("pg: migration failed: %w", err)
		}
		slog.Info("pg: migrations completed successfully")
	}

	pool := p.Pool()
	return &Client{
		cl:  p,
		sql: sqlc.New(pool),
		pgx: pool,
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
