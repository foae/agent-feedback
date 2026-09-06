package handler

import (
	"agent-feedback/backend/services/feedback/core"
)

// Handler is the HTTP transport layer. It extracts request parameters,
// calls core methods, and writes HTTP responses.
type Handler struct {
	svc *core.Service
}

// New creates a new Handler.
func New(svc *core.Service) *Handler {
	return &Handler{svc: svc}
}
