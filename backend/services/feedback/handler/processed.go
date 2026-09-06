package handler

import (
	"log/slog"
	"net/http"

	"agent-feedback/backend/services/feedback/core"
)

// HandleSetProcessed handles POST /api/v1/submissions/processed — batch
// mark/unmark of the processed_at flag by the async feedback processor.
func (h *Handler) HandleSetProcessed() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req SetProcessedRequest
		if !decodeRequestBody(w, r, &req) {
			return
		}

		processed := true
		if req.Processed != nil {
			processed = *req.Processed
		}

		res, err := h.svc.SetProcessed(r.Context(), core.SetProcessedInput{
			IDs:       req.IDs,
			Processed: processed,
		})
		if err != nil {
			status := mapSubmissionError(err)
			if status >= http.StatusInternalServerError {
				slog.ErrorContext(r.Context(), "failed to set processed state", "error", err)
			} else {
				slog.WarnContext(r.Context(), "rejected processed state request", "error", err)
			}
			writeError(w, status, "set_processed_failed", errorMessage(status, err))
			return
		}

		writeJSON(w, http.StatusOK, SetProcessedResponse{
			Processed: processed,
			Updated:   res.Updated,
			Unchanged: res.Unchanged,
			NotFound:  res.NotFound,
		})
	}
}
