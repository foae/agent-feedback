package handler

import (
	"log/slog"
	"net/http"

	"agent-feedback/backend/services/feedback/core"
)

// HandleCreateFriction handles POST /api/v1/frictions.
func (h *Handler) HandleCreateFriction() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req CreateFrictionRequest
		if !decodeRequestBody(w, r, &req) {
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
			if status >= http.StatusInternalServerError {
				slog.ErrorContext(r.Context(), "failed to create friction submission", "error", err, "category", req.Category)
			} else {
				slog.WarnContext(r.Context(), "rejected friction submission", "error", err, "category", req.Category)
			}
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
