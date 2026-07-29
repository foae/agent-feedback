package handler

import (
	"errors"
	"fmt"
	"net/http"
	"testing"

	"agent-feedback/backend/services/feedback/core"
)

func TestMapSubmissionError(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want int
	}{
		{
			name: "not found",
			err:  core.ErrSubmissionNotFound,
			want: http.StatusNotFound,
		},
		{
			name: "invalid input",
			err:  core.ErrInvalidInput,
			want: http.StatusBadRequest,
		},
		{
			name: "wrapped invalid input",
			err:  fmt.Errorf("create review submission: %w", core.ErrInvalidInput),
			want: http.StatusBadRequest,
		},
		{
			name: "unknown error",
			err:  errors.New("boom"),
			want: http.StatusInternalServerError,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			if got := mapSubmissionError(tc.err); got != tc.want {
				t.Fatalf("expected %d, got %d", tc.want, got)
			}
		})
	}
}
