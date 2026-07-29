package core

import (
	"context"
	"os"
	"testing"
	"time"

	"agent-feedback/backend/services/feedback/storage/postgres"
)

// newTestService connects to TEST_POSTGRES_URL (running migrations) and returns a
// Service backed by a real database. Callers must call t.Skip if the env var is
// unset before calling this.
func newTestService(t *testing.T) *Service {
	t.Helper()

	url := os.Getenv("TEST_POSTGRES_URL")
	if url == "" {
		t.Skip("TEST_POSTGRES_URL not set, skipping integration test")
	}

	db, err := postgres.New(url, 1, 5, true)
	if err != nil {
		t.Fatalf("connect to test postgres: %v", err)
	}
	t.Cleanup(db.Close)

	svc, err := New(db)
	if err != nil {
		t.Fatalf("construct service: %v", err)
	}

	return svc
}

func TestIntegration_CreateReview_ReplayIdempotency(t *testing.T) {
	url := os.Getenv("TEST_POSTGRES_URL")
	if url == "" {
		t.Skip("TEST_POSTGRES_URL not set, skipping integration test")
	}

	svc := newTestService(t)
	ctx := context.Background()

	in := CreateReviewInput{
		Skill:            "multi-llm-review",
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		RunID:            uniqueRunID(t),
		Prompt:           "review this",
		Reviewers: []ReviewerInput{
			{Slot: "gpt56", Model: "openai-codex/gpt-5.6-sol", Status: "completed", Score: intPtr(5)},
		},
	}

	first, replayed, err := svc.CreateReview(ctx, in)
	if err != nil {
		t.Fatalf("first create: %v", err)
	}
	if replayed {
		t.Fatalf("expected first create to not be a replay")
	}

	second, replayed, err := svc.CreateReview(ctx, in)
	if err != nil {
		t.Fatalf("second create (replay): %v", err)
	}
	if !replayed {
		t.Fatalf("expected second create to be a replay")
	}
	if second.ID != first.ID {
		t.Fatalf("expected replay to return the same submission id, got %d != %d", second.ID, first.ID)
	}
}

func TestIntegration_CreateFriction(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()

	sub, err := svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		Category:         "documentation",
		Summary:          "docs were stale",
	})
	if err != nil {
		t.Fatalf("create friction: %v", err)
	}
	if sub.SubmissionType != "friction" {
		t.Fatalf("expected submission_type friction, got %s", sub.SubmissionType)
	}
	if sub.RunID.Valid {
		t.Fatalf("expected friction run_id to be NULL")
	}
}

func TestIntegration_GetSubmission(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()

	created, err := svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		Category:         "tooling",
		Summary:          "tool broke",
	})
	if err != nil {
		t.Fatalf("create friction: %v", err)
	}

	got, err := svc.GetSubmission(ctx, created.ID)
	if err != nil {
		t.Fatalf("get submission: %v", err)
	}
	if got.ID != created.ID {
		t.Fatalf("expected id %d, got %d", created.ID, got.ID)
	}

	if _, err := svc.GetSubmission(ctx, -1); err == nil {
		t.Fatalf("expected error for nonexistent submission")
	}
}

func TestIntegration_ListSubmissions_Filters(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()

	machine := uniqueRunID(t) // reuse as a unique machine name to isolate this test's rows
	runID := uniqueRunID(t)

	_, _, err := svc.CreateReview(ctx, CreateReviewInput{
		Skill:            "multi-llm-review",
		MachineName:      machine,
		CoordinatorModel: "claude-fable-5",
		RunID:            runID,
		Reviewers:        []ReviewerInput{{Slot: "gpt56", Model: "m", Status: "completed"}},
	})
	if err != nil {
		t.Fatalf("create review: %v", err)
	}

	_, err = svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      machine,
		CoordinatorModel: "claude-fable-5",
		Category:         "documentation",
		Summary:          "s",
	})
	if err != nil {
		t.Fatalf("create friction: %v", err)
	}

	rows, err := svc.ListSubmissions(ctx, ListSubmissionsInput{Machine: machine, Type: "friction"})
	if err != nil {
		t.Fatalf("list submissions: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 friction row for machine %s, got %d", machine, len(rows))
	}
	if rows[0].SubmissionType != "friction" {
		t.Fatalf("expected submission_type friction, got %s", rows[0].SubmissionType)
	}

	rows, err = svc.ListSubmissions(ctx, ListSubmissionsInput{Machine: machine})
	if err != nil {
		t.Fatalf("list submissions (no type filter): %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows for machine %s, got %d", machine, len(rows))
	}
}

func uniqueRunID(t *testing.T) string {
	t.Helper()
	return t.Name() + "-" + time.Now().Format("20060102-150405.000000000")
}
