package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Client wraps a pgxpool.Pool for pgx-native queries.
type Client struct {
	pg *pgxpool.Pool
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

	return &Client{
		pg: pg,
	}, nil
}

func (c *Client) Close() {
	c.pg.Close()
}

func (c *Client) Pool() *pgxpool.Pool {
	return c.pg
}

