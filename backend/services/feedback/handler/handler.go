package handler

import (
	"agent-feedback/backend/services/feedback/core"
)

// Handler is the HTTP transport layer. It extracts request parameters,
// calls core methods, and writes HTTP responses.
type Handler struct {
	svc     *core.Service
	envMode string
}

// New creates a new Handler.
func New(svc *core.Service, envMode string) *Handler {
	return &Handler{
		svc:     svc,
		envMode: envMode,
	}
}
