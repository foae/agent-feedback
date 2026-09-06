package handler

import (
	"errors"
	"log/slog"
	"net/http"

	"agent-feedback/backend/services/feedback/core"
)

// HandleCreateReview handles POST /api/v1/reviews.
func (h *Handler) HandleCreateReview() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req CreateReviewRequest
		if !decodeRequestBody(w, r, &req) {
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
			errType := "create_review_failed"
			if errors.Is(err, core.ErrReplayMismatch) {
				errType = "replay_mismatch"
			}
			if status >= http.StatusInternalServerError {
				slog.ErrorContext(r.Context(), "failed to create review submission", "error", err, "skill", req.Skill, "run_id", req.RunID)
			} else {
				slog.WarnContext(r.Context(), "rejected review submission", "error", err, "skill", req.Skill, "run_id", req.RunID)
			}
			writeError(w, status, errType, errorMessage(status, err))
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
