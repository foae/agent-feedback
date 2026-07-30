package handler

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"agent-feedback/backend/services/feedback/core"
)

// HandleSetProcessed handles POST /api/v1/submissions/processed — batch
// mark/unmark of the processed_at flag by the async feedback processor.
func (h *Handler) HandleSetProcessed() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)

		var req SetProcessedRequest
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
				slog.Error("failed to set processed state", "error", err)
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
