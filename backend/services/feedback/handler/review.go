package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"agent-feedback/backend/services/feedback/core"
)

// HandleCreateReview handles POST /api/v1/reviews.
func (h *Handler) HandleCreateReview() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)

		var req CreateReviewRequest
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

		reviewers := make([]core.ReviewerInput, len(req.Reviewers))
		for i, rv := range req.Reviewers {
			reviewers[i] = core.ReviewerInput{
				Slot:      rv.Slot,
				Model:     rv.Model,
				Status:    rv.Status,
				DurationS: rv.DurationS,
				Bytes:     rv.Bytes,
				Output:    rv.Output,
				Score:     rv.Score,
				Valid:     rv.Valid,
				Invalid:   rv.Invalid,
				Note:      rv.Note,
			}
		}

		sub, replayed, err := h.svc.CreateReview(r.Context(), core.CreateReviewInput{
			Skill:            req.Skill,
			MachineName:      req.MachineName,
			CoordinatorModel: req.CoordinatorModel,
			RunID:            req.RunID,
			Prompt:           req.Prompt,
			Reviewers:        reviewers,
		})
		if err != nil {
			status := mapSubmissionError(err)
			slog.Error("failed to create review submission", "error", err, "skill", req.Skill, "run_id", req.RunID)
			writeError(w, status, "create_review_failed", errorMessage(status, err))
			return
		}

		resp, err := submissionToResponse(sub)
		if err != nil {
			slog.Error("failed to decode submission payload", "error", err, "submission_id", sub.ID)
			writeError(w, http.StatusInternalServerError, "create_review_failed", "failed to encode response")
			return
		}

		status := http.StatusCreated
		if replayed {
			status = http.StatusOK
		}
		writeJSON(w, status, resp)
	}
}
