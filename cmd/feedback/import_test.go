package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/foae/agent-feedback/internal/core"
	"github.com/foae/agent-feedback/internal/store"
)

// v1Records are in the shape scripts/export-v1-postgres.sh emits: family
// derived from submission_type, resolution always null, and — for rows written
// before hashing existed — payload_hash null.
var v1Records = []string{
	`{"id":1,"family":"friction","submission_type":"friction","machine_name":"workstation-a",` +
		`"coordinator_model":"claude-fable-5-1","run_id":null,` +
		`"payload":{"category":"documentation","summary":"docs drifted","context":{"cwd":"/tmp"}},` +
		`"payload_hash":null,"created_at":"2026-07-30T10:00:00.000000Z","processed_at":null,"resolution":null}`,
	`{"id":2,"family":"review","submission_type":"review-panel","machine_name":"workstation-a",` +
		`"coordinator_model":"claude-fable-5-1","run_id":"run-1",` +
		`"payload":{"prompt":"review this","reviewers":[{"slot":"a","model":"m","status":"completed"}]},` +
		`"payload_hash":"deadbeef","created_at":"2026-07-30T11:00:00.123456Z",` +
		`"processed_at":"2026-07-31T09:30:00Z","resolution":null}`,
	`{"id":7,"family":"friction","submission_type":"friction","machine_name":"workstation-b",` +
		`"coordinator_model":"claude-fable-5-1",` +
		`"payload":{"category":"tooling","summary":"tool hung"},` +
		`"created_at":"2026-08-01T12:00:00+02:00"}`,
}

func writeExportFile(t *testing.T, dir string, header string, records []string, withTerminator bool, digest string) string {
	t.Helper()

	var buf bytes.Buffer
	buf.WriteString(header + "\n")
	var body bytes.Buffer
	for _, r := range records {
		body.WriteString(r + "\n")
	}
	buf.Write(body.Bytes())
	if withTerminator {
		if digest == "" {
			sum := sha256.Sum256(body.Bytes())
			digest = hex.EncodeToString(sum[:])
		}
		fmt.Fprintf(&buf, `{"export_complete":true,"count":%d,"sha256":%q}`+"\n", len(records), digest)
	}

	path := filepath.Join(dir, "export.jsonl")
	if err := os.WriteFile(path, buf.Bytes(), 0o600); err != nil {
		t.Fatalf("write export file: %v", err)
	}

	return path
}

const v1Header = `{"export_format":1,"family":null,"since":null,"exported_at":"2026-08-02T00:00:00.000000Z","source":"agent-feedback-1.x-postgres"}`

func openDB(t *testing.T, path string) *store.DB {
	t.Helper()

	db, err := store.Open(context.Background(), path)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	return db
}

func TestImport_V1Export(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "feedback.db")
	t.Setenv("DATABASE_PATH", dbPath)

	path := writeExportFile(t, dir, v1Header, v1Records, true, "")
	if err := runImport([]string{path}); err != nil {
		t.Fatalf("import: %v", err)
	}

	ctx := context.Background()
	db := openDB(t, dbPath)
	svc := core.New(db)

	for _, want := range []struct {
		id     int64
		family string
	}{{1, "friction"}, {2, "review"}, {7, "friction"}} {
		got, err := svc.GetSubmission(ctx, want.id)
		if err != nil {
			t.Fatalf("get %d: %v", want.id, err)
		}
		if got.Family != want.family {
			t.Fatalf("submission %d: family %q, want %q", want.id, got.Family, want.family)
		}
		if got.PayloadHash == "" {
			t.Fatalf("submission %d: payload_hash must never be empty", want.id)
		}
	}

	// The row exported without a hash gets the one its family's rule produces,
	// so it still dedupes against a new submission of the same friction.
	row1, err := svc.GetSubmission(ctx, 1)
	if err != nil {
		t.Fatalf("get 1: %v", err)
	}
	wantHash, err := core.HashForFamily(store.FamilyFriction, "workstation-a", "claude-fable-5-1", row1.Payload)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if row1.PayloadHash != wantHash {
		t.Fatalf("recomputed hash %s, want %s", row1.PayloadHash, wantHash)
	}
	// The recomputed hash is the one a fresh submission of the same friction
	// produces, so the imported row still participates in duplicate detection
	// (this fixture predates the 24 h window, so the new row is a recurrence).
	resubmitted, _, err := svc.CreateFriction(ctx, core.CreateFrictionInput{
		MachineName: "workstation-a", CoordinatorModel: "claude-fable-5-1",
		Category: "documentation", Summary: "docs drifted",
		Context: map[string]string{"cwd": "/elsewhere"},
	})
	if err != nil {
		t.Fatalf("create friction: %v", err)
	}
	if resubmitted.PayloadHash != row1.PayloadHash {
		t.Fatalf("re-submitted friction hashed to %s, imported row has %s", resubmitted.PayloadHash, row1.PayloadHash)
	}

	// An explicit hash is preserved verbatim.
	row2, err := svc.GetSubmission(ctx, 2)
	if err != nil {
		t.Fatalf("get 2: %v", err)
	}
	if row2.PayloadHash != "deadbeef" {
		t.Fatalf("stored hash %q, want deadbeef", row2.PayloadHash)
	}
	if row2.ProcessedAt == nil || core.FormatMicros(*row2.ProcessedAt) != "2026-07-31T09:30:00.000000Z" {
		t.Fatalf("processed_at was not preserved: %+v", row2.ProcessedAt)
	}
	if row2.Resolution != nil {
		t.Fatalf("null resolution must stay unset, got %q", *row2.Resolution)
	}

	// A non-UTC offset is normalized.
	row7, err := svc.GetSubmission(ctx, 7)
	if err != nil {
		t.Fatalf("get 7: %v", err)
	}
	if core.FormatMicros(row7.CreatedAt) != "2026-08-01T10:00:00.000000Z" {
		t.Fatalf("created_at not normalized to UTC: %s", core.FormatMicros(row7.CreatedAt))
	}
	if row7.RunID != nil {
		t.Fatal("an absent run_id must stay unset")
	}

	// ids are never reused: the sequence continues past the highest import.
	fresh, _, err := svc.CreateFriction(ctx, core.CreateFrictionInput{
		MachineName: "workstation-a", CoordinatorModel: "m", Category: "tooling", Summary: "brand new",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if fresh.ID <= 7 {
		t.Fatalf("next id %d must be greater than the highest imported id", fresh.ID)
	}
}

func TestImport_ReservesIDsAndRefusesNonEmpty(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "feedback.db")
	t.Setenv("DATABASE_PATH", dbPath)

	path := writeExportFile(t, dir, v1Header, v1Records, true, "")
	if err := runImport([]string{"--reserve-ids-through", "500", path}); err != nil {
		t.Fatalf("import: %v", err)
	}

	svc := core.New(openDB(t, dbPath))
	fresh, _, err := svc.CreateFriction(context.Background(), core.CreateFrictionInput{
		MachineName: "m", CoordinatorModel: "c", Category: "tooling", Summary: "new",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if fresh.ID != 501 {
		t.Fatalf("reserved range ignored: next id is %d, want 501", fresh.ID)
	}

	// A second import into the now non-empty database is refused.
	err = runImport([]string{path})
	if err == nil || !strings.Contains(err.Error(), "allow-nonempty") {
		t.Fatalf("expected a refusal naming --allow-nonempty, got %v", err)
	}
}

func TestImport_RejectsBrokenStreams(t *testing.T) {
	cases := []struct {
		name       string
		header     string
		records    []string
		terminator bool
		digest     string
		wantErr    string
	}{
		{
			name: "truncated stream", header: v1Header, records: v1Records,
			terminator: false, wantErr: "truncated",
		},
		{
			name: "wrong digest", header: v1Header, records: v1Records,
			terminator: true, digest: strings.Repeat("0", 64), wantErr: "digest mismatch",
		},
		{
			name:    "unsupported format",
			header:  `{"export_format":2}`,
			records: v1Records, terminator: true, wantErr: "unsupported export_format",
		},
		{
			name:    "filtered export",
			header:  `{"export_format":1,"family":"friction","since":null,"exported_at":"2026-08-02T00:00:00.000000Z"}`,
			records: v1Records[:1], terminator: true, wantErr: "filtered export",
		},
		{
			name: "unknown family", header: v1Header,
			records: []string{`{"id":1,"family":"nope","submission_type":"x","machine_name":"m",` +
				`"coordinator_model":"c","payload":{},"created_at":"2026-08-01T12:00:00Z"}`},
			terminator: true, wantErr: "family must be",
		},
		{
			name: "payload not an object", header: v1Header,
			records: []string{`{"id":1,"family":"event","submission_type":"deploy","machine_name":"m",` +
				`"coordinator_model":"c","payload":[1],"created_at":"2026-08-01T12:00:00Z"}`},
			terminator: true, wantErr: "payload must be a JSON object",
		},
		{
			name: "missing machine_name", header: v1Header,
			records: []string{`{"id":1,"family":"event","submission_type":"deploy","machine_name":"",` +
				`"coordinator_model":"c","payload":{},"created_at":"2026-08-01T12:00:00Z"}`},
			terminator: true, wantErr: "machine_name is required",
		},
		{
			name: "bad timestamp", header: v1Header,
			records: []string{`{"id":1,"family":"event","submission_type":"deploy","machine_name":"m",` +
				`"coordinator_model":"c","payload":{},"created_at":"yesterday"}`},
			terminator: true, wantErr: "created_at",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			dbPath := filepath.Join(dir, "feedback.db")
			t.Setenv("DATABASE_PATH", dbPath)

			path := writeExportFile(t, dir, tc.header, tc.records, tc.terminator, tc.digest)
			err := runImport([]string{path})
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("expected an error containing %q, got %v", tc.wantErr, err)
			}

			// Nothing may be committed when the stream is rejected.
			if _, statErr := os.Stat(dbPath); statErr == nil {
				db := openDB(t, dbPath)
				var n int64
				if err := db.Read(context.Background(), func(q store.Querier) error {
					var err error
					n, err = store.CountAll(context.Background(), q)

					return err
				}); err != nil {
					t.Fatalf("count: %v", err)
				}
				if n != 0 {
					t.Fatalf("a rejected import must leave the database empty, found %d row(s)", n)
				}
			}
		})
	}
}

// TestImport_RoundTripFromExport is the migration path end to end: export a
// populated database, import it into an empty one, compare every record.
func TestImport_RoundTripFromExport(t *testing.T) {
	dir := t.TempDir()
	sourcePath := filepath.Join(dir, "source.db")

	ctx := context.Background()
	source := core.New(openDB(t, sourcePath))

	friction, _, err := source.CreateFriction(ctx, core.CreateFrictionInput{
		MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
		Category: "documentation", Summary: "docs drifted",
		Context: map[string]string{"cwd": "/tmp"},
	})
	if err != nil {
		t.Fatalf("create friction: %v", err)
	}
	if _, _, err := source.CreateReview(ctx, core.CreateReviewInput{
		Skill: "review-panel", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
		RunID: "run-1", Prompt: "review this",
		Reviewers: []core.ReviewerInput{{Slot: "a", Model: "m", Status: "completed"}},
	}); err != nil {
		t.Fatalf("create review: %v", err)
	}
	if _, _, err := source.CreateEvent(ctx, core.CreateEventInput{
		Kind: "deploy", Key: "k1", MachineName: "workstation-a", CoordinatorModel: "claude-fable-5",
		Payload: []byte(`{"b":2,"a":1,"n":1.50}`),
	}); err != nil {
		t.Fatalf("create event: %v", err)
	}
	if _, err := source.SetProcessed(ctx, core.SetProcessedInput{
		IDs: []int64{friction.ID}, Processed: true, Resolution: strPtr("fixed in example@1a2b3c4"),
	}); err != nil {
		t.Fatalf("mark processed: %v", err)
	}

	var exported bytes.Buffer
	if err := source.Export(ctx, core.ExportInput{}, &exported, nil); err != nil {
		t.Fatalf("export: %v", err)
	}
	exportPath := filepath.Join(dir, "export.jsonl")
	if err := os.WriteFile(exportPath, exported.Bytes(), 0o600); err != nil {
		t.Fatalf("write export: %v", err)
	}

	targetPath := filepath.Join(dir, "target.db")
	t.Setenv("DATABASE_PATH", targetPath)
	if err := runImport([]string{exportPath}); err != nil {
		t.Fatalf("import: %v", err)
	}

	target := core.New(openDB(t, targetPath))
	var reExported bytes.Buffer
	if err := target.Export(ctx, core.ExportInput{}, &reExported, nil); err != nil {
		t.Fatalf("re-export: %v", err)
	}

	wantRecords := recordLines(t, exported.String())
	gotRecords := recordLines(t, reExported.String())
	if len(wantRecords) != 3 || len(gotRecords) != len(wantRecords) {
		t.Fatalf("record counts differ: %d vs %d", len(wantRecords), len(gotRecords))
	}
	for i := range wantRecords {
		if wantRecords[i] != gotRecords[i] {
			t.Fatalf("record %d changed across the round trip:\n before: %s\n after:  %s", i, wantRecords[i], gotRecords[i])
		}
	}

	// The importer advanced the sequence, so a new row cannot collide.
	fresh, _, err := target.CreateFriction(ctx, core.CreateFrictionInput{
		MachineName: "m", CoordinatorModel: "c", Category: "tooling", Summary: "new",
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if fresh.ID != 4 {
		t.Fatalf("next id %d, want 4", fresh.ID)
	}
}

func recordLines(t *testing.T, stream string) []string {
	t.Helper()

	lines := strings.Split(strings.TrimRight(stream, "\n"), "\n")
	if len(lines) < 2 {
		t.Fatalf("stream is too short: %q", stream)
	}
	records := lines[1 : len(lines)-1]
	for _, line := range records {
		var rec core.Record
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("decode record: %v", err)
		}
	}

	return records
}

func strPtr(s string) *string { return &s }
