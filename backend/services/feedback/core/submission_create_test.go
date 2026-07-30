package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

func intPtr(v int) *int { return &v }

func TestCreateReview_Validation(t *testing.T) {
	t.Parallel()

	validReviewer := ReviewerInput{Slot: "gpt56", Model: "openai-codex/gpt-5.6-sol", Status: "completed"}

	tests := []struct {
		name string
		in   CreateReviewInput
	}{
		{
			name: "missing skill",
			in: CreateReviewInput{
				MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{validReviewer},
			},
		},
		{
			name: "reserved skill friction",
			in: CreateReviewInput{
				Skill: "friction", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{validReviewer},
			},
		},
		{
			name: "missing machine_name",
			in: CreateReviewInput{
				Skill: "multi-llm-review", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{validReviewer},
			},
		},
		{
			name: "missing coordinator_model",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", RunID: "run-1",
				Reviewers: []ReviewerInput{validReviewer},
			},
		},
		{
			name: "missing run_id",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				Reviewers: []ReviewerInput{validReviewer},
			},
		},
		{
			name: "empty reviewers",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: nil,
			},
		},
		{
			name: "reviewer missing slot",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Model: "m", Status: "completed"}},
			},
		},
		{
			name: "reviewer missing model",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Status: "completed"}},
			},
		},
		{
			name: "reviewer missing status",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m"}},
			},
		},
		{
			name: "reviewer negative duration",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m", Status: "completed", DurationS: intPtr(-1)}},
			},
		},
		{
			name: "reviewer score too low",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m", Status: "completed", Score: intPtr(0)}},
			},
		},
		{
			name: "reviewer score too high",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m", Status: "completed", Score: intPtr(6)}},
			},
		},
		{
			name: "reviewer negative bytes",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m", Status: "completed", Bytes: intPtr(-1)}},
			},
		},
		{
			name: "reviewer negative valid",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m", Status: "completed", Valid: intPtr(-1)}},
			},
		},
		{
			name: "reviewer negative invalid",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m", Status: "completed", Invalid: intPtr(-1)}},
			},
		},
		{
			name: "machine_name too long",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: strings.Repeat("a", maxIdentifierLen+1),
				CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{validReviewer},
			},
		},
		{
			name: "run_id too long",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				RunID:     strings.Repeat("r", maxIdentifierLen+1),
				Reviewers: []ReviewerInput{validReviewer},
			},
		},
		{
			name: "reviewer note too long",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: []ReviewerInput{{Slot: "s", Model: "m", Status: "completed", Note: strings.Repeat("n", maxNoteLen+1)}},
			},
		},
		{
			name: "too many reviewers",
			in: CreateReviewInput{
				Skill: "multi-llm-review", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", RunID: "run-1",
				Reviewers: func() []ReviewerInput {
					rs := make([]ReviewerInput, maxReviewers+1)
					for i := range rs {
						rs[i] = validReviewer
					}
					return rs
				}(),
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			s := &Service{}
			_, _, err := s.CreateReview(context.Background(), tc.in)
			if !errors.Is(err, ErrInvalidInput) {
				t.Fatalf("expected ErrInvalidInput, got %v", err)
			}
		})
	}
}

func TestCreateFriction_Validation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		in   CreateFrictionInput
	}{
		{
			name: "missing machine_name",
			in:   CreateFrictionInput{CoordinatorModel: "claude-fable-5", Category: "documentation", Summary: "s"},
		},
		{
			name: "missing coordinator_model",
			in:   CreateFrictionInput{MachineName: "workstation-a", Category: "documentation", Summary: "s"},
		},
		{
			name: "missing category",
			in:   CreateFrictionInput{MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", Summary: "s"},
		},
		{
			name: "missing summary",
			in:   CreateFrictionInput{MachineName: "workstation-a", CoordinatorModel: "claude-fable-5", Category: "documentation"},
		},
		{
			name: "category too long",
			in: CreateFrictionInput{
				MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				Category: strings.Repeat("c", maxIdentifierLen+1), Summary: "s",
			},
		},
		{
			name: "summary too long",
			in: CreateFrictionInput{
				MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				Category: "documentation", Summary: strings.Repeat("s", maxSummaryLen+1),
			},
		},
		{
			name: "context too many entries",
			in: CreateFrictionInput{
				MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				Category: "tooling", Summary: "s",
				Context: func() map[string]string {
					m := make(map[string]string, maxContextEntries+1)
					for i := 0; i <= maxContextEntries; i++ {
						m[fmt.Sprintf("k%d", i)] = "v"
					}
					return m
				}(),
			},
		},
		{
			name: "context key too long",
			in: CreateFrictionInput{
				MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				Category: "tooling", Summary: "s",
				Context: map[string]string{strings.Repeat("k", maxContextKeyLen+1): "v"},
			},
		},
		{
			name: "context value too long",
			in: CreateFrictionInput{
				MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				Category: "tooling", Summary: "s",
				Context: map[string]string{"cwd": strings.Repeat("v", maxContextValueLen+1)},
			},
		},
		{
			name: "context empty key",
			in: CreateFrictionInput{
				MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
				Category: "tooling", Summary: "s",
				Context: map[string]string{"": "v"},
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			s := &Service{}
			_, _, err := s.CreateFriction(context.Background(), tc.in)
			if !errors.Is(err, ErrInvalidInput) {
				t.Fatalf("expected ErrInvalidInput, got %v", err)
			}
		})
	}
}

func TestSetProcessed_Validation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		in   SetProcessedInput
	}{
		{name: "empty ids", in: SetProcessedInput{IDs: nil, Processed: true}},
		{name: "zero id", in: SetProcessedInput{IDs: []int64{0}, Processed: true}},
		{name: "negative id", in: SetProcessedInput{IDs: []int64{-4}, Processed: false}},
		{
			name: "too many ids",
			in: SetProcessedInput{IDs: func() []int64 {
				ids := make([]int64, maxProcessedIDs+1)
				for i := range ids {
					ids[i] = int64(i + 1)
				}
				return ids
			}(), Processed: true},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			s := &Service{}
			_, err := s.SetProcessed(context.Background(), tc.in)
			if !errors.Is(err, ErrInvalidInput) {
				t.Fatalf("expected ErrInvalidInput, got %v", err)
			}
		})
	}
}

func TestCanonicalHash_Deterministic(t *testing.T) {
	t.Parallel()

	a := frictionCanonical{
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		Payload:          frictionPayload{Category: "tooling", Summary: "s", Details: "d"},
	}
	h1, err := canonicalHash(a)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	h2, err := canonicalHash(a)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if h1 != h2 || len(h1) != 64 {
		t.Fatalf("expected stable 64-char sha256 hex, got %q / %q", h1, h2)
	}

	b := a
	b.Payload.Summary = "different"
	h3, err := canonicalHash(b)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if h3 == h1 {
		t.Fatalf("different content must produce a different hash")
	}
}
