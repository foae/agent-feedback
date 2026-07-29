package postgres

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// Client wraps a pgxpool.Pool and a database/sql.DB for use with both
// pgx-native queries (sqlc) and stdlib-based libraries (golang-migrate).
type Client struct {
	pg  *pgxpool.Pool
	raw *sql.DB
}

// New creates a new Postgres client with connection pooling.
func New(pgconfigURL string, minConns int, maxConns int) (*Client, error) {
	cfg, err := pgxpool.ParseConfig(pgconfigURL)
	if err != nil {
		return nil, fmt.Errorf("failed to parse postgres config: %w", err)
	}

	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	cfg.MaxConns = int32(maxConns)
	cfg.MinConns = int32(minConns)
	cfg.MaxConnLifetime = time.Minute * 60
	cfg.MaxConnIdleTime = time.Minute * 5
	cfg.MaxConnLifetimeJitter = time.Millisecond * 450

	pg, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to postgres: %w", err)
	}

	if strings.Contains(pgconfigURL, "?") {
		pgconfigURL += "&default_query_exec_mode=exec"
	} else {
		pgconfigURL += "?default_query_exec_mode=exec"
	}

	rawConn, err := sql.Open("pgx", pgconfigURL)
	if err != nil {
		return nil, fmt.Errorf("failed to open raw connection to postgres: %w", err)
	}

	return &Client{
		pg:  pg,
		raw: rawConn,
	}, nil
}

func (c *Client) Close() {
	c.pg.Close()
}

func (c *Client) Pool() *pgxpool.Pool {
	return c.pg
}

func (c *Client) RawConn() *sql.DB {
	return c.raw
}
