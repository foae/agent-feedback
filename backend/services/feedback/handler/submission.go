package handler

import (
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"

	"agent-feedback/backend/services/feedback/core"
)

// HandleListSubmissions handles GET /api/v1/submissions.
func (h *Handler) HandleListSubmissions() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()

		in := core.ListSubmissionsInput{
			Type:    q.Get("type"),
			Machine: q.Get("machine"),
			Model:   q.Get("model"),
		}

		if v := q.Get("since"); v != "" {
			t, err := time.Parse(time.RFC3339, v)
			if err != nil {
				writeError(w, http.StatusBadRequest, "bad_request", "since must be RFC 3339")
				return
			}
			in.Since = &t
		}

		if v := q.Get("until"); v != "" {
			t, err := time.Parse(time.RFC3339, v)
			if err != nil {
				writeError(w, http.StatusBadRequest, "bad_request", "until must be RFC 3339")
				return
			}
			in.Until = &t
		}

		if v := q.Get("limit"); v != "" {
			limit, err := strconv.Atoi(v)
			if err != nil {
				writeError(w, http.StatusBadRequest, "bad_request", "limit must be an integer")
				return
			}
			in.Limit = limit
		}

		if v := q.Get("offset"); v != "" {
			offset, err := strconv.Atoi(v)
			if err != nil {
				writeError(w, http.StatusBadRequest, "bad_request", "offset must be an integer")
				return
			}
			in.Offset = offset
		}

		rows, err := h.svc.ListSubmissions(r.Context(), in)
		if err != nil {
			slog.Error("failed to list submissions", "error", err)
			writeError(w, http.StatusInternalServerError, "list_submissions_failed", errorMessage(http.StatusInternalServerError, err))
			return
		}

		limit, offset := core.NormalizeListWindow(in.Limit, in.Offset)

		resp := ListSubmissionsResponse{
			Submissions: make([]SubmissionSummaryResponse, len(rows)),
			Limit:       limit,
			Offset:      offset,
		}
		for i, row := range rows {
			resp.Submissions[i] = submissionToSummary(row)
		}

		writeJSON(w, http.StatusOK, resp)
	}
}

// HandleGetSubmission handles GET /api/v1/submissions/{id}.
func (h *Handler) HandleGetSubmission() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "id must be a numeric submission ID")
			return
		}

		sub, err := h.svc.GetSubmission(r.Context(), id)
		if err != nil {
			status := mapSubmissionError(err)
			if status >= http.StatusInternalServerError {
				slog.Error("failed to get submission", "error", err, "submission_id", id)
			}
			writeError(w, status, "get_submission_failed", errorMessage(status, err))
			return
		}

		resp, err := submissionToResponse(sub)
		if err != nil {
			slog.Error("failed to decode submission payload", "error", err, "submission_id", sub.ID)
			writeError(w, http.StatusInternalServerError, "get_submission_failed", "failed to encode response")
			return
		}

		writeJSON(w, http.StatusOK, resp)
	}
}
