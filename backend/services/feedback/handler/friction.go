package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"agent-feedback/backend/services/feedback/core"
)

// HandleCreateFriction handles POST /api/v1/frictions.
func (h *Handler) HandleCreateFriction() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)

		var req CreateFrictionRequest
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil {
			var maxBytesErr *http.MaxBytesError
			if errors.As(err, &maxBytesErr) {
				writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "request body exceeds 10 MiB")
				return
			}
			writeError(w, http.StatusBadRequest, "bad_request", "invalid request body: "+err.Error())
			return
		}

		sub, duplicate, err := h.svc.CreateFriction(r.Context(), core.CreateFrictionInput{
			MachineName:      req.MachineName,
			CoordinatorModel: req.CoordinatorModel,
			Category:         req.Category,
			Summary:          req.Summary,
			Details:          req.Details,
			SuggestedFix:     req.SuggestedFix,
			Project:          req.Project,
			Harness:          req.Harness,
			Context:          req.Context,
		})
		if err != nil {
			status := mapSubmissionError(err)
			slog.Error("failed to create friction submission", "error", err, "category", req.Category)
			writeError(w, status, "create_friction_failed", errorMessage(status, err))
			return
		}

		resp, err := submissionToResponse(sub)
		if err != nil {
			slog.Error("failed to decode submission payload", "error", err, "submission_id", sub.ID)
			writeError(w, http.StatusInternalServerError, "create_friction_failed", "failed to encode response")
			return
		}

		// A duplicate absorbed inside the dedupe window returns the existing
		// row with 200 — the submitter's retry succeeded either way.
		status := http.StatusCreated
		if duplicate {
			status = http.StatusOK
		}
		writeJSON(w, status, resp)
	}
}
