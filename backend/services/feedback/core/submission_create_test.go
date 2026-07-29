package core

import (
	"context"
	"errors"
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
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			s := &Service{}
			_, err := s.CreateFriction(context.Background(), tc.in)
			if !errors.Is(err, ErrInvalidInput) {
				t.Fatalf("expected ErrInvalidInput, got %v", err)
			}
		})
	}
}
