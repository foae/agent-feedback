package canonjson

import "testing"

func TestMarshalSortsKeysAndKeepsNumbers(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		in   string
		want string
	}{
		{"sorts object keys", `{"b":1,"a":2}`, `{"a":2,"b":1}`},
		{"sorts nested keys", `{"a":{"z":1,"y":[{"d":1,"c":2}]}}`, `{"a":{"y":[{"c":2,"d":1}],"z":1}}`},
		{"numbers verbatim", `{"a":1.0,"b":1,"c":1e3,"d":0.30000000000000004}`, `{"a":1.0,"b":1,"c":1e3,"d":0.30000000000000004}`},
		{"strips whitespace", "{\n  \"a\" : 1\n}", `{"a":1}`},
		{"scalars and nulls", `[null,true,false,"x"]`, `[null,true,false,"x"]`},
		{"escapes strings like encoding/json", `{"a":"<&>\"x\\y"}`, `{"a":"\u003c\u0026\u003e\"x\\y"}`},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got, err := Marshal([]byte(tc.in))
			if err != nil {
				t.Fatalf("Marshal: %v", err)
			}
			if string(got) != tc.want {
				t.Fatalf("want %s, got %s", tc.want, got)
			}
		})
	}
}

func TestMarshalRejectsInvalidJSON(t *testing.T) {
	t.Parallel()

	if _, err := Marshal([]byte(`{`)); err == nil {
		t.Fatal("expected an error for malformed JSON")
	}
}

func TestMarshalRejectsDuplicateKeys(t *testing.T) {
	t.Parallel()

	if _, err := Marshal([]byte(`{"a":1,"a":2}`)); err == nil {
		t.Fatal("expected duplicate keys to be rejected")
	}
	if _, err := Marshal([]byte(`{"a":{"b":1,"b":2}}`)); err == nil {
		t.Fatal("expected nested duplicate keys to be rejected")
	}
}

func TestMarshalRejectsTrailingValues(t *testing.T) {
	t.Parallel()

	if _, err := Marshal([]byte(`{"a":1} {}`)); err == nil {
		t.Fatal("expected a trailing JSON value to be rejected")
	}
}
