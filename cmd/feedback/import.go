package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/foae/agent-feedback/internal/core"
	"github.com/foae/agent-feedback/internal/store"
)

// importRecord is one line of an export stream. Every nullable field is a
// pointer so "absent" and "null" both read as unset.
type importRecord struct {
	ID               int64           `json:"id"`
	Family           string          `json:"family"`
	SubmissionType   string          `json:"submission_type"`
	MachineName      string          `json:"machine_name"`
	CoordinatorModel string          `json:"coordinator_model"`
	RunID            *string         `json:"run_id"`
	Payload          json.RawMessage `json:"payload"`
	PayloadHash      *string         `json:"payload_hash"`
	CreatedAt        string          `json:"created_at"`
	ProcessedAt      *string         `json:"processed_at"`
	Resolution       *string         `json:"resolution"`
}

// importHeader is the first line. Unknown keys (a producer's "source", for
// example) are ignored on purpose: the format is allowed to grow.
type importHeader struct {
	ExportFormat int     `json:"export_format"`
	Family       *string `json:"family"`
	Since        *string `json:"since"`
}

type importTerminator struct {
	ExportComplete bool   `json:"export_complete"`
	Count          int64  `json:"count"`
	SHA256         string `json:"sha256"`
}

// runImport restores an export stream into the database. Everything happens in
// one transaction: a stream that fails validation anywhere leaves the database
// untouched.
func runImport(args []string) error {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	allowNonEmpty := fs.Bool("allow-nonempty", false, "import into a database that already holds rows")
	allowPartial := fs.Bool("allow-partial", false, "import a filtered (partial) export")
	reserveThrough := fs.Int64("reserve-ids-through", 0, "advance the id sequence at least this far after importing")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: feedback import [--allow-nonempty] [--allow-partial] [--reserve-ids-through N] <file.jsonl>")
	}
	path := fs.Arg(0)

	cfg, err := loadConfig(false)
	if err != nil {
		return err
	}
	setupLogger(cfg.LogLevel)

	records, err := readExportFile(path, *allowPartial)
	if err != nil {
		return err
	}

	ctx := context.Background()
	db, err := store.Open(ctx, cfg.DatabasePath)
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()

	var (
		maxID     int64
		byFamily  = map[string]int64{}
		imported  int64
		sequence  = *reserveThrough
		importErr = db.Write(ctx, func(q store.Querier) error {
			existing, err := store.CountAll(ctx, q)
			if err != nil {
				return err
			}
			if existing > 0 && !*allowNonEmpty {
				return fmt.Errorf("database %s already holds %d row(s); pass --allow-nonempty to import anyway",
					cfg.DatabasePath, existing)
			}

			for _, rec := range records {
				if err := store.InsertSubmissionWithID(ctx, q, rec); err != nil {
					return err
				}
				imported++
				byFamily[rec.Family]++
				if rec.ID > maxID {
					maxID = rec.ID
				}
			}
			if maxID > sequence {
				sequence = maxID
			}
			if sequence > 0 {
				// ids are never reused: push the AUTOINCREMENT counter past
				// everything imported (and past any archived range the
				// operator reserved).
				return store.SetSequence(ctx, q, sequence)
			}

			return nil
		})
	)
	if importErr != nil {
		return importErr
	}

	families := make([]string, 0, len(byFamily))
	for f := range byFamily {
		families = append(families, f)
	}
	sort.Strings(families)
	parts := make([]string, 0, len(families))
	for _, f := range families {
		parts = append(parts, fmt.Sprintf("%q:%d", f, byFamily[f]))
	}

	fmt.Printf("{\"imported\":%d,\"max_id\":%d,\"by_family\":{%s}}\n", imported, sequence, strings.Join(parts, ","))

	return nil
}

// readExportFile parses and validates the whole stream before anything touches
// the database: header, records, terminator, count and digest.
func readExportFile(path string, allowPartial bool) ([]store.Submission, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 64<<20)

	var (
		header     importHeader
		haveHeader bool
		terminator importTerminator
		haveTerm   bool
		digest     = sha256.New()
		out        []store.Submission
		lineNo     int
	)

	for sc.Scan() {
		lineNo++
		line := sc.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		if haveTerm {
			return nil, fmt.Errorf("line %d: content after the export terminator", lineNo)
		}

		if !haveHeader {
			if err := json.Unmarshal(line, &header); err != nil {
				return nil, fmt.Errorf("line %d: header is not valid JSON: %w", lineNo, err)
			}
			if header.ExportFormat != 1 {
				return nil, fmt.Errorf("line %d: unsupported export_format %d, expected 1", lineNo, header.ExportFormat)
			}
			if !allowPartial && (header.Family != nil || header.Since != nil) {
				return nil, errors.New("refusing a filtered export: it restores a subset of the data; pass --allow-partial to import it anyway")
			}
			haveHeader = true

			continue
		}

		if bytes.Contains(line, []byte(`"export_complete"`)) {
			if err := json.Unmarshal(line, &terminator); err != nil {
				return nil, fmt.Errorf("line %d: terminator is not valid JSON: %w", lineNo, err)
			}
			haveTerm = true

			continue
		}

		rec, err := parseImportRecord(line, lineNo)
		if err != nil {
			return nil, err
		}
		out = append(out, rec)
		digest.Write(append(append([]byte{}, line...), '\n'))
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}

	if !haveHeader {
		return nil, errors.New("missing export header line (export_format 1)")
	}
	if !haveTerm || !terminator.ExportComplete {
		return nil, errors.New("missing export terminator: the stream is truncated and must not be imported")
	}
	if terminator.Count != int64(len(out)) {
		return nil, fmt.Errorf("export declares %d record(s) but the stream holds %d", terminator.Count, len(out))
	}
	if got := hex.EncodeToString(digest.Sum(nil)); terminator.SHA256 != "" && got != terminator.SHA256 {
		return nil, fmt.Errorf("export digest mismatch: declared %s, computed %s", terminator.SHA256, got)
	}

	return out, nil
}

func parseImportRecord(line []byte, lineNo int) (store.Submission, error) {
	var rec importRecord
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.UseNumber()
	if err := dec.Decode(&rec); err != nil {
		return store.Submission{}, fmt.Errorf("line %d: not valid JSON: %w", lineNo, err)
	}

	if rec.ID <= 0 {
		return store.Submission{}, fmt.Errorf("line %d: id must be a positive integer", lineNo)
	}
	switch rec.Family {
	case store.FamilyFriction, store.FamilyReview, store.FamilyEvent:
	default:
		return store.Submission{}, fmt.Errorf("line %d: family must be friction, review or event, got %q", lineNo, rec.Family)
	}
	for field, v := range map[string]string{
		"submission_type":   rec.SubmissionType,
		"machine_name":      rec.MachineName,
		"coordinator_model": rec.CoordinatorModel,
		"created_at":        rec.CreatedAt,
	} {
		if strings.TrimSpace(v) == "" {
			return store.Submission{}, fmt.Errorf("line %d: %s is required", lineNo, field)
		}
	}
	if len(bytes.TrimSpace(rec.Payload)) == 0 || bytes.TrimSpace(rec.Payload)[0] != '{' {
		return store.Submission{}, fmt.Errorf("line %d: payload must be a JSON object", lineNo)
	}

	var payload bytes.Buffer
	if err := json.Compact(&payload, rec.Payload); err != nil {
		return store.Submission{}, fmt.Errorf("line %d: payload is not valid JSON: %w", lineNo, err)
	}

	createdAt, err := core.ParseMicros(rec.CreatedAt)
	if err != nil {
		return store.Submission{}, fmt.Errorf("line %d: created_at: %w", lineNo, err)
	}

	sub := store.Submission{
		ID:               rec.ID,
		Family:           rec.Family,
		SubmissionType:   rec.SubmissionType,
		MachineName:      rec.MachineName,
		CoordinatorModel: rec.CoordinatorModel,
		Payload:          payload.Bytes(),
		CreatedAt:        createdAt,
		Resolution:       trimmedPtr(rec.Resolution),
	}
	if rec.RunID != nil && *rec.RunID != "" {
		v := *rec.RunID
		sub.RunID = &v
	}
	if rec.ProcessedAt != nil && *rec.ProcessedAt != "" {
		us, err := core.ParseMicros(*rec.ProcessedAt)
		if err != nil {
			return store.Submission{}, fmt.Errorf("line %d: processed_at: %w", lineNo, err)
		}
		sub.ProcessedAt = &us
	}

	if rec.PayloadHash != nil && strings.TrimSpace(*rec.PayloadHash) != "" {
		sub.PayloadHash = strings.TrimSpace(*rec.PayloadHash)
	} else {
		// Rows exported before hashing existed get the hash their family's
		// rule produces, so they dedupe against new submissions.
		hash, err := core.HashForFamily(rec.Family, rec.MachineName, rec.CoordinatorModel, payload.Bytes())
		if err != nil {
			return store.Submission{}, fmt.Errorf("line %d: recompute payload_hash: %w", lineNo, err)
		}
		sub.PayloadHash = hash
	}

	return sub, nil
}

func trimmedPtr(s *string) *string {
	if s == nil {
		return nil
	}
	v := strings.TrimSpace(*s)
	if v == "" {
		return nil
	}

	return &v
}
