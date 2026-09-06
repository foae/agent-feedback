package core

import (
	"context"
	"encoding/json"
	"errors"
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

	sub, duplicate, err := svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		Category:         "documentation",
		Summary:          "docs were stale " + uniqueRunID(t),
	})
	if err != nil {
		t.Fatalf("create friction: %v", err)
	}
	if duplicate {
		t.Fatalf("expected first friction to not be a duplicate")
	}
	if sub.SubmissionType != "friction" {
		t.Fatalf("expected submission_type friction, got %s", sub.SubmissionType)
	}
	if sub.RunID.Valid {
		t.Fatalf("expected friction run_id to be NULL")
	}
}

func TestIntegration_CreateFriction_DuplicateAbsorption(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()

	in := CreateFrictionInput{
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		Category:         "tooling",
		Summary:          "identical friction " + uniqueRunID(t),
		Details:          "same details",
	}

	first, duplicate, err := svc.CreateFriction(ctx, in)
	if err != nil {
		t.Fatalf("first create: %v", err)
	}
	if duplicate {
		t.Fatalf("expected first create to not be a duplicate")
	}

	// Identical content inside the window is absorbed: same row, no insert.
	second, duplicate, err := svc.CreateFriction(ctx, in)
	if err != nil {
		t.Fatalf("second create: %v", err)
	}
	if !duplicate {
		t.Fatalf("expected identical friction to be absorbed as a duplicate")
	}
	if second.ID != first.ID {
		t.Fatalf("expected duplicate to return the existing row, got %d != %d", second.ID, first.ID)
	}

	// Different content is a new row.
	in2 := in
	in2.Summary = "different friction " + uniqueRunID(t)
	third, duplicate, err := svc.CreateFriction(ctx, in2)
	if err != nil {
		t.Fatalf("third create: %v", err)
	}
	if duplicate {
		t.Fatalf("expected different content to create a new row")
	}
	if third.ID == first.ID {
		t.Fatalf("expected a new row for different content")
	}

	// Context is enrichment, not identity: the same friction re-submitted with
	// different auto-collected context (new timestamp, new commit) must still
	// be absorbed — and the original row's context stays untouched.
	inCtx := in
	inCtx.Context = map[string]string{"occurred_at": "2026-07-30T12:00:00Z", "git_commit": "deadbee"}
	fifth, duplicate, err := svc.CreateFriction(ctx, inCtx)
	if err != nil {
		t.Fatalf("context-variant create: %v", err)
	}
	if !duplicate || fifth.ID != first.ID {
		t.Fatalf("expected context differences to be ignored by dedupe, got duplicate=%v id=%d (want %d)", duplicate, fifth.ID, first.ID)
	}

	// A fresh friction stores its context verbatim in the payload.
	inNew := in
	inNew.Summary = "context-carrying friction " + uniqueRunID(t)
	inNew.Context = map[string]string{"cwd": "/tmp/somewhere", "git_branch": "main"}
	created, _, err := svc.CreateFriction(ctx, inNew)
	if err != nil {
		t.Fatalf("create with context: %v", err)
	}
	var stored struct {
		Context map[string]string `json:"context"`
	}
	if err := json.Unmarshal(created.Payload, &stored); err != nil {
		t.Fatalf("decode stored payload: %v", err)
	}
	if stored.Context["cwd"] != "/tmp/somewhere" || stored.Context["git_branch"] != "main" {
		t.Fatalf("expected context stored in payload, got %+v", stored.Context)
	}

	// Outside the window the same content lands again (recurrence stays visible).
	saved := frictionDedupeWindow
	frictionDedupeWindow = 0
	defer func() { frictionDedupeWindow = saved }()

	fourth, duplicate, err := svc.CreateFriction(ctx, in)
	if err != nil {
		t.Fatalf("fourth create: %v", err)
	}
	if duplicate {
		t.Fatalf("expected expired window to produce a new row, not a duplicate")
	}
	if fourth.ID == first.ID {
		t.Fatalf("expected a new row after the window expired")
	}
}

func TestIntegration_CreateFriction_ConcurrentDuplicateAbsorption(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()
	in := CreateFrictionInput{
		MachineName:      uniqueRunID(t),
		CoordinatorModel: "claude-fable-5",
		Category:         "tooling",
		Summary:          "concurrent duplicate",
	}

	type result struct {
		id        int64
		duplicate bool
		err       error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for range 2 {
		go func() {
			<-start
			sub, duplicate, err := svc.CreateFriction(ctx, in)
			results <- result{id: sub.ID, duplicate: duplicate, err: err}
		}()
	}
	close(start)

	ids := make(map[int64]struct{}, 2)
	created := 0
	duplicates := 0
	for range 2 {
		res := <-results
		if res.err != nil {
			t.Fatalf("concurrent create: %v", res.err)
		}
		ids[res.id] = struct{}{}
		if res.duplicate {
			duplicates++
		} else {
			created++
		}
	}
	if created != 1 || duplicates != 1 {
		t.Fatalf("expected one creation and one duplicate, got created=%d duplicates=%d", created, duplicates)
	}
	if len(ids) != 1 {
		t.Fatalf("expected both results to identify one row, got ids=%v", ids)
	}

	rows, err := svc.ListSubmissions(ctx, ListSubmissionsInput{Type: "friction", Machine: in.MachineName})
	if err != nil {
		t.Fatalf("list concurrent frictions: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected exactly one stored friction, got %d", len(rows))
	}
}

func TestIntegration_CreateReview_ReplayMismatch(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()

	in := CreateReviewInput{
		Skill:            "multi-llm-review",
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		RunID:            uniqueRunID(t),
		Prompt:           "review this",
		Reviewers: []ReviewerInput{
			{Slot: "gpt56", Model: "openai-codex/gpt-5.6-sol", Status: "completed", Score: intPtr(4)},
		},
	}

	first, _, err := svc.CreateReview(ctx, in)
	if err != nil {
		t.Fatalf("first create: %v", err)
	}

	// Same run_id, different content → mismatch, stored row untouched.
	changed := in
	changed.Reviewers = []ReviewerInput{
		{Slot: "gpt56", Model: "openai-codex/gpt-5.6-sol", Status: "completed", Score: intPtr(5)},
	}
	_, _, err = svc.CreateReview(ctx, changed)
	if !errors.Is(err, ErrReplayMismatch) {
		t.Fatalf("expected ErrReplayMismatch, got %v", err)
	}

	stored, err := svc.GetSubmission(ctx, first.ID)
	if err != nil {
		t.Fatalf("get stored: %v", err)
	}
	if string(stored.Payload) != string(first.Payload) {
		t.Fatalf("stored payload must be untouched by a mismatching replay")
	}
}

func TestIntegration_GetSubmission(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()

	created, _, err := svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      "workstation-a",
		CoordinatorModel: "claude-fable-5",
		Category:         "tooling",
		Summary:          "tool broke " + uniqueRunID(t),
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

	_, _, err = svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      machine,
		CoordinatorModel: "claude-fable-5",
		Category:         "documentation",
		Summary:          "s",
		Project:          "agent-feedback",
		Harness:          "claude-code",
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
	// Friction payload fields are surfaced on list rows.
	if rows[0].FrictionCategory != "documentation" || rows[0].FrictionSummary != "s" ||
		rows[0].FrictionProject != "agent-feedback" || rows[0].FrictionHarness != "claude-code" {
		t.Fatalf("expected friction fields on the list row, got %+v", rows[0])
	}

	rows, err = svc.ListSubmissions(ctx, ListSubmissionsInput{Machine: machine})
	if err != nil {
		t.Fatalf("list submissions (no type filter): %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows for machine %s, got %d", machine, len(rows))
	}
	// Review rows carry empty friction fields.
	for _, row := range rows {
		if row.SubmissionType != "friction" && row.FrictionCategory != "" {
			t.Fatalf("expected empty friction fields on review rows, got %+v", row)
		}
	}
}

func TestIntegration_SetProcessed(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()

	machine := uniqueRunID(t)
	friction, _, err := svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      machine,
		CoordinatorModel: "claude-fable-5",
		Category:         "tooling",
		Summary:          "to be processed",
	})
	if err != nil {
		t.Fatalf("create friction: %v", err)
	}
	review, _, err := svc.CreateReview(ctx, CreateReviewInput{
		Skill:            "multi-llm-review",
		MachineName:      machine,
		CoordinatorModel: "claude-fable-5",
		RunID:            uniqueRunID(t),
		Reviewers:        []ReviewerInput{{Slot: "gpt56", Model: "m", Status: "completed"}},
	})
	if err != nil {
		t.Fatalf("create review: %v", err)
	}

	const bogusID = int64(1<<62 - 1)

	// Mark both plus a bogus id.
	res, err := svc.SetProcessed(ctx, SetProcessedInput{
		IDs: []int64{friction.ID, review.ID, bogusID}, Processed: true,
	})
	if err != nil {
		t.Fatalf("set processed: %v", err)
	}
	if len(res.Updated) != 2 || len(res.Unchanged) != 0 || len(res.NotFound) != 1 {
		t.Fatalf("expected 2 updated / 0 unchanged / 1 not_found, got %+v", res)
	}

	// Marking again is idempotent: everything existing is unchanged.
	res, err = svc.SetProcessed(ctx, SetProcessedInput{
		IDs: []int64{friction.ID, review.ID}, Processed: true,
	})
	if err != nil {
		t.Fatalf("set processed again: %v", err)
	}
	if len(res.Updated) != 0 || len(res.Unchanged) != 2 {
		t.Fatalf("expected idempotent re-mark, got %+v", res)
	}

	// processed=false filter excludes marked rows; processed=true finds them.
	f := false
	rows, err := svc.ListSubmissions(ctx, ListSubmissionsInput{Machine: machine, Processed: &f})
	if err != nil {
		t.Fatalf("list unprocessed: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected no unprocessed rows for %s, got %d", machine, len(rows))
	}
	tr := true
	rows, err = svc.ListSubmissions(ctx, ListSubmissionsInput{Machine: machine, Processed: &tr})
	if err != nil {
		t.Fatalf("list processed: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 processed rows for %s, got %d", machine, len(rows))
	}
	for _, row := range rows {
		if !row.ProcessedAt.Valid {
			t.Fatalf("expected processed_at set on processed rows")
		}
	}

	// Unmark one and confirm it is unprocessed again.
	res, err = svc.SetProcessed(ctx, SetProcessedInput{IDs: []int64{friction.ID}, Processed: false})
	if err != nil {
		t.Fatalf("unmark: %v", err)
	}
	if len(res.Updated) != 1 {
		t.Fatalf("expected 1 updated on unmark, got %+v", res)
	}
	rows, err = svc.ListSubmissions(ctx, ListSubmissionsInput{Machine: machine, Processed: &f})
	if err != nil {
		t.Fatalf("list unprocessed after unmark: %v", err)
	}
	if len(rows) != 1 || rows[0].ID != friction.ID {
		t.Fatalf("expected exactly the unmarked friction to be unprocessed, got %+v", rows)
	}
}

func TestIntegration_SetProcessed_ConcurrentClassification(t *testing.T) {
	svc := newTestService(t)
	ctx := context.Background()
	machine := uniqueRunID(t)

	first, _, err := svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      machine,
		CoordinatorModel: "claude-fable-5",
		Category:         "tooling",
		Summary:          "first concurrent processing row",
	})
	if err != nil {
		t.Fatalf("create first friction: %v", err)
	}
	second, _, err := svc.CreateFriction(ctx, CreateFrictionInput{
		MachineName:      machine,
		CoordinatorModel: "claude-fable-5",
		Category:         "tooling",
		Summary:          "second concurrent processing row",
	})
	if err != nil {
		t.Fatalf("create second friction: %v", err)
	}

	type result struct {
		value SetProcessedResult
		err   error
	}
	start := make(chan struct{})
	results := make(chan result, 2)
	for _, ids := range [][]int64{{first.ID, second.ID}, {second.ID, first.ID}} {
		ids := ids
		go func() {
			<-start
			value, err := svc.SetProcessed(ctx, SetProcessedInput{IDs: ids, Processed: true})
			results <- result{value: value, err: err}
		}()
	}
	close(start)

	updatedBatches := 0
	unchangedBatches := 0
	for range 2 {
		res := <-results
		if res.err != nil {
			t.Fatalf("concurrent set processed: %v", res.err)
		}
		switch {
		case len(res.value.Updated) == 2 && len(res.value.Unchanged) == 0 && len(res.value.NotFound) == 0:
			updatedBatches++
		case len(res.value.Updated) == 0 && len(res.value.Unchanged) == 2 && len(res.value.NotFound) == 0:
			unchangedBatches++
		default:
			t.Fatalf("expected one atomic classification per batch, got %+v", res.value)
		}
	}
	if updatedBatches != 1 || unchangedBatches != 1 {
		t.Fatalf("expected one updated batch and one unchanged batch, got updated=%d unchanged=%d", updatedBatches, unchangedBatches)
	}

	processed := true
	rows, err := svc.ListSubmissions(ctx, ListSubmissionsInput{Machine: machine, Processed: &processed})
	if err != nil {
		t.Fatalf("list processed rows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected both rows to remain processed, got %d", len(rows))
	}
}

func uniqueRunID(t *testing.T) string {
	t.Helper()
	return t.Name() + "-" + time.Now().Format("20060102-150405.000000000")
}
