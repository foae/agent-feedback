// Package canonjson produces a canonical JSON encoding: object keys sorted by
// byte order, numbers kept in their exact textual form (1 and 1.0 stay
// different), strings escaped the way encoding/json escapes them, and no
// insignificant whitespace. Event content hashes are computed over this
// encoding, so the same content always yields the same digest regardless of
// how the producer ordered or spaced it.
package canonjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
)

// ErrDuplicateKey is returned when an object contains the same key twice.
// Silently keeping the last one would make the hash depend on a decoder
// detail, so the document is rejected instead.
var ErrDuplicateKey = errors.New("duplicate object key")

// Marshal re-encodes raw (any valid JSON document) canonically.
func Marshal(raw []byte) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()

	v, err := parse(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("canonjson: expected exactly one JSON value")
	}

	var buf bytes.Buffer
	if err := write(&buf, v); err != nil {
		return nil, err
	}

	return buf.Bytes(), nil
}

// object keeps its members in sorted order; parsing rejects duplicates.
type object struct {
	keys   []string
	values map[string]any
}

func parse(dec *json.Decoder) (any, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("canonjson: decode: %w", err)
	}

	return parseValue(dec, tok)
}

func parseValue(dec *json.Decoder, tok json.Token) (any, error) {
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			return parseObject(dec)
		case '[':
			return parseArray(dec)
		default:
			return nil, fmt.Errorf("canonjson: unexpected %q", t)
		}
	default:
		return tok, nil
	}
}

func parseObject(dec *json.Decoder) (any, error) {
	obj := object{values: map[string]any{}}
	for {
		tok, err := dec.Token()
		if err != nil {
			return nil, fmt.Errorf("canonjson: decode object: %w", err)
		}
		if d, ok := tok.(json.Delim); ok && d == '}' {
			sort.Strings(obj.keys)

			return obj, nil
		}
		key, ok := tok.(string)
		if !ok {
			return nil, fmt.Errorf("canonjson: object key must be a string")
		}
		if _, dup := obj.values[key]; dup {
			return nil, fmt.Errorf("%w: %q", ErrDuplicateKey, key)
		}
		val, err := parse(dec)
		if err != nil {
			return nil, err
		}
		obj.keys = append(obj.keys, key)
		obj.values[key] = val
	}
}

func parseArray(dec *json.Decoder) (any, error) {
	items := []any{}
	for {
		tok, err := dec.Token()
		if err != nil {
			return nil, fmt.Errorf("canonjson: decode array: %w", err)
		}
		if d, ok := tok.(json.Delim); ok && d == ']' {
			return items, nil
		}
		val, err := parseValue(dec, tok)
		if err != nil {
			return nil, err
		}
		items = append(items, val)
	}
}

func write(buf *bytes.Buffer, v any) error {
	switch t := v.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		if t {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case json.Number:
		// Verbatim: 1.0 and 1 are different texts and stay different.
		buf.WriteString(t.String())
	case string:
		enc, err := json.Marshal(t)
		if err != nil {
			return fmt.Errorf("canonjson: encode string: %w", err)
		}
		buf.Write(enc)
	case []any:
		buf.WriteByte('[')
		for i, item := range t {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := write(buf, item); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
	case object:
		buf.WriteByte('{')
		for i, k := range t.keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			enc, err := json.Marshal(k)
			if err != nil {
				return fmt.Errorf("canonjson: encode key: %w", err)
			}
			buf.Write(enc)
			buf.WriteByte(':')
			if err := write(buf, t.values[k]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
	default:
		return fmt.Errorf("canonjson: unsupported value %T", v)
	}

	return nil
}
