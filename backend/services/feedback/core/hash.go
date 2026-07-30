package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
)

// reviewCanonical / frictionCanonical are the exact shapes hashed into
// submissions.payload_hash. Struct field order fixes the JSON encoding, so
// identical content always produces the same digest. created_at is deliberately
// excluded — the hash identifies content, not the moment of receipt.
type reviewCanonical struct {
	MachineName      string        `json:"machine_name"`
	CoordinatorModel string        `json:"coordinator_model"`
	Payload          reviewPayload `json:"payload"`
}

type frictionCanonical struct {
	MachineName      string          `json:"machine_name"`
	CoordinatorModel string          `json:"coordinator_model"`
	Payload          frictionPayload `json:"payload"`
}

// canonicalHash returns the sha256 hex digest of v's JSON encoding.
func canonicalHash(v any) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}
