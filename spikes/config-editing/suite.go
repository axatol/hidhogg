package configediting

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"

	toml "github.com/pelletier/go-toml/v2"
	"github.com/pelletier/go-toml/v2/unstable"
	"github.com/pelletier/go-toml/v2/unstable/edit"
	"github.com/tailscale/hujson"
)

type caseExpectation uint8

const (
	expectValue caseExpectation = iota
	expectMissing
	expectParseError
)

type editCase struct {
	ID             string
	Fixture        string
	Operation      string
	Required       bool
	Expectation    caseExpectation
	Path           []string
	JSONPointer    string
	Want           any
	TOMLMutation   func(*edit.Document) error
	JSONPatch      string
	SourceOverride []byte
	JSONOverride   []byte
	Protected      []string
	ProtectedBytes []string
	OrderFirst     string
	OrderSecond    string
}

type spanResult struct {
	Name             string `json:"name"`
	Comparison       string `json:"comparison"`
	ByteIdentical    bool   `json:"byte_identical"`
	MarkerCountEqual bool   `json:"marker_count_equal,omitempty"`
	Detail           string `json:"detail,omitempty"`
	SourceByteHash   string `json:"source_byte_hash,omitempty"`
	OutputByteHash   string `json:"output_byte_hash,omitempty"`
}

type caseResult struct {
	ID                  string       `json:"id"`
	Fixture             string       `json:"fixture"`
	Format              string       `json:"format"`
	LineEnding          string       `json:"line_ending"`
	Operation           string       `json:"operation"`
	Required            bool         `json:"required"`
	Status              string       `json:"status"`
	Detail              string       `json:"detail,omitempty"`
	SemanticValid       bool         `json:"semantic_valid"`
	ExpectedPresent     *bool        `json:"expected_present,omitempty"`
	ObservedPresent     *bool        `json:"observed_present,omitempty"`
	MinimalEditVerified bool         `json:"minimal_edit_verified,omitempty"`
	UntouchedSpans      []spanResult `json:"untouched_spans,omitempty"`
	OutputHash          string       `json:"output_sha256,omitempty"`
}

type suiteResults struct {
	MeasurementNote string        `json:"measurement_note"`
	Dependencies    []dependency  `json:"dependencies"`
	TOML            []caseResult  `json:"toml"`
	JSONC           []caseResult  `json:"jsonc"`
	Transactions    []checkResult `json:"transactional_writes"`
	Deterministic   bool          `json:"deterministic_regeneration"`
	FallbackMode    string        `json:"jsonc_mode"`
	Recommendation  string        `json:"recommendation"`
}

type dependency struct {
	Module  string `json:"module"`
	Version string `json:"version"`
	License string `json:"license"`
}

type checkResult struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

func dependencyPins() []dependency {
	return []dependency{
		{
			Module:  "github.com/pelletier/go-toml/v2",
			Version: "v2.4.4-0.20260718201843-686c980c4758",
			License: "MIT",
		},
		{
			Module:  "github.com/tailscale/hujson",
			Version: "v0.0.0-20260727124030-b80ff77dac4f",
			License: "BSD-3-Clause",
		},
	}
}

func allEditCases() []editCase {
	rootProtected := []string{
		"# Root configuration: stable note.",
		"version = 1",
		"unknown_runtime = \"keep-runtime\"",
		"# vendor comment must remain byte-identical",
		"vendor_key = \"do-not-touch\"",
		"# first page comment must remain byte-identical",
	}
	deviceProtected := []string{
		"# Device fixture: representative adapter configuration.",
		"unknown_setting = \"keep-device-setting\"",
		"# device page one",
		"id = \"clock\"",
	}

	return []editCase{
		{
			ID:          "replace.scalar",
			Fixture:     "root",
			Operation:   "path-based scalar replacement",
			Required:    true,
			Path:        []string{"runtime", "log_level"},
			JSONPointer: "/runtime/log_level",
			Want:        "debug",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"runtime", "log_level"}, "debug")
			},
			JSONPatch: `[{"op":"replace","path":"/runtime/log_level","value":"debug"}]`,
			Protected: rootProtected,
		},
		{
			ID:          "insert.scalar",
			Fixture:     "root",
			Operation:   "path-based scalar insertion",
			Required:    true,
			Path:        []string{"runtime", "new_field"},
			JSONPointer: "/runtime/new_field",
			Want:        "inserted",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"runtime", "new_field"}, "inserted")
			},
			JSONPatch: `[{"op":"add","path":"/runtime/new_field","value":"inserted"}]`,
			Protected: rootProtected,
		},
		{
			ID:          "delete.scalar",
			Fixture:     "root",
			Operation:   "path-based scalar deletion",
			Required:    true,
			Expectation: expectMissing,
			Path:        []string{"legacy"},
			JSONPointer: "/legacy",
			TOMLMutation: func(d *edit.Document) error {
				if !d.Delete([]string{"legacy"}) {
					return errors.New("legacy key was not found")
				}
				return nil
			},
			JSONPatch: `[{"op":"remove","path":"/legacy"}]`,
			Protected: rootProtected,
		},
		{
			ID:           "reorder.object",
			Fixture:      "root",
			Operation:    "delete-and-reinsert a key to move it within a table",
			Required:     true,
			Path:         []string{"runtime", "timeout_ms"},
			JSONPointer:  "/runtime/timeout_ms",
			Want:         int64(1000),
			OrderFirst:   "timeout_ms",
			OrderSecond:  "unknown_runtime",
			TOMLMutation: reorderTOML,
			JSONPatch:    `[{"op":"move","from":"/runtime/timeout_ms","path":"/runtime/__reorder_tmp"},{"op":"move","from":"/runtime/__reorder_tmp","path":"/runtime/timeout_ms"}]`,
			Protected:    rootProtected,
		},
		{
			ID:          "table.insert",
			Fixture:     "root",
			Operation:   "create table through a nested path",
			Required:    true,
			Path:        []string{"runtime", "new_table", "enabled"},
			JSONPointer: "/runtime/new_table/enabled",
			Want:        true,
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"runtime", "new_table", "enabled"}, true)
			},
			JSONPatch: `[{"op":"add","path":"/runtime/new_table","value":{"enabled":true}}]`,
			Protected: rootProtected,
		},
		{
			ID:          "array-of-tables.insert",
			Fixture:     "root",
			Operation:   "append an array-of-tables element",
			Required:    true,
			Path:        []string{"pages", "2", "name"},
			JSONPointer: "/pages/2/name",
			Want:        "alerts",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"pages", "2", "name"}, "alerts")
			},
			JSONPatch: `[{"op":"add","path":"/pages/-","value":{"name":"alerts","brightness":80}}]`,
			Protected: rootProtected,
		},
		{
			ID:          "array.element.replace",
			Fixture:     "root",
			Operation:   "replace an array element by index",
			Required:    true,
			Path:        []string{"ports", "1"},
			JSONPointer: "/ports/1",
			Want:        int64(9001),
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"ports", "1"}, 9001)
			},
			JSONPatch: `[{"op":"replace","path":"/ports/1","value":9001}]`,
			Protected: rootProtected,
		},
		{
			ID:          "inline-table.replace",
			Fixture:     "root",
			Operation:   "replace a value nested inside an inline table",
			Required:    true,
			Path:        []string{"inline", "max"},
			JSONPointer: "/inline/max",
			Want:        int64(42),
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"inline", "max"}, 42)
			},
			JSONPatch: `[{"op":"replace","path":"/inline/max","value":42}]`,
			Protected: rootProtected,
		},
		{
			ID:          "dotted-key.replace",
			Fixture:     "root",
			Operation:   "replace a value addressed through a dotted key",
			Required:    true,
			Path:        []string{"dotted", "host"},
			JSONPointer: "/dotted/host",
			Want:        "127.0.0.2",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"dotted", "host"}, "127.0.0.2")
			},
			JSONPatch: `[{"op":"replace","path":"/dotted/host","value":"127.0.0.2"}]`,
			Protected: rootProtected,
		},
		{
			ID:          "multiline-string.replace",
			Fixture:     "root",
			Operation:   "replace a value with an explicit multiline string",
			Required:    true,
			Path:        []string{"multiline"},
			JSONPointer: "/multiline",
			Want:        "Updated\nline\n",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"multiline"}, unstable.RawMessage("\"\"\"\nUpdated\nline\n\"\"\""))
			},
			JSONPatch: `[{"op":"replace","path":"/multiline","value":"Updated\nline\n"}]`,
			Protected: rootProtected,
		},
		{
			ID:          "comment-preservation.replace",
			Fixture:     "root",
			Operation:   "replace while preserving full-line and trailing comments",
			Required:    true,
			Path:        []string{"runtime", "log_level"},
			JSONPointer: "/runtime/log_level",
			Want:        "warn",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"runtime", "log_level"}, "warn")
			},
			JSONPatch:      `[{"op":"replace","path":"/runtime/log_level","value":"warn"}]`,
			Protected:      append(rootProtected, "# runtime comment stays attached"),
			ProtectedBytes: []string{"# trailing runtime comment"},
		},
		{
			ID:          "unknown-field.preservation",
			Fixture:     "root",
			Operation:   "replace a known field without touching unknown fields",
			Required:    true,
			Path:        []string{"runtime", "log_level"},
			JSONPointer: "/runtime/log_level",
			Want:        "error",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"runtime", "log_level"}, "error")
			},
			JSONPatch: `[{"op":"replace","path":"/runtime/log_level","value":"error"}]`,
			Protected: append(rootProtected, "unknown_runtime = \"keep-runtime\"", "vendor_key = \"do-not-touch\""),
		},
		{
			ID:          "device.table.insert",
			Fixture:     "device",
			Operation:   "create a nested device settings table",
			Required:    true,
			Path:        []string{"settings", "notifications", "enabled"},
			JSONPointer: "/settings/notifications/enabled",
			Want:        true,
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"settings", "notifications", "enabled"}, true)
			},
			JSONPatch: `[{"op":"add","path":"/settings/notifications","value":{"enabled":true}}]`,
			Protected: deviceProtected,
		},
		{
			ID:          "device.array-of-tables.insert",
			Fixture:     "device",
			Operation:   "append a device page",
			Required:    true,
			Path:        []string{"pages", "2", "title"},
			JSONPointer: "/pages/2/title",
			Want:        "Alerts",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"pages", "2", "title"}, "Alerts")
			},
			JSONPatch: `[{"op":"add","path":"/pages/-","value":{"id":"alerts","title":"Alerts","layout":{"x":0,"y":4,"width":4,"height":2}}}]`,
			Protected: deviceProtected,
		},
		{
			ID:          "device.inline-table.replace",
			Fixture:     "device",
			Operation:   "replace a nested transport value",
			Required:    true,
			Path:        []string{"transport", "retries"},
			JSONPointer: "/transport/retries",
			Want:        int64(5),
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"transport", "retries"}, 5)
			},
			JSONPatch: `[{"op":"replace","path":"/transport/retries","value":5}]`,
			Protected: deviceProtected,
		},
		{
			ID:          "device.multiline-string.replace",
			Fixture:     "device",
			Operation:   "replace a device multiline string",
			Required:    true,
			Path:        []string{"description"},
			JSONPointer: "/description",
			Want:        "Updated device\ntext\n",
			TOMLMutation: func(d *edit.Document) error {
				return d.Set([]string{"description"}, unstable.RawMessage("\"\"\"\nUpdated device\ntext\n\"\"\""))
			},
			JSONPatch: `[{"op":"replace","path":"/description","value":"Updated device\ntext\n"}]`,
			Protected: deviceProtected,
		},
		{
			ID:             "malformed-input.reject",
			Fixture:        "root",
			Operation:      "reject malformed source before editing",
			Required:       true,
			Expectation:    expectParseError,
			SourceOverride: []byte("version = 1\n[runtime]\nlog_level =\n"),
			JSONOverride:   []byte(`{"version":1,"runtime":}`),
		},
	}
}

func reorderTOML(d *edit.Document) error {
	path := []string{"runtime", "timeout_ms"}
	value, ok := d.Get(path)
	if !ok {
		return errors.New("timeout_ms key was not found")
	}
	if !d.Delete(path) {
		return errors.New("timeout_ms key could not be deleted")
	}
	return d.Set(path, value)
}

func runTOMLCase(c editCase, lineEnding string) caseResult {
	f := fixtures[c.Fixture]
	source := sourceWithLineEnding(f.TOML, lineEnding)
	if c.SourceOverride != nil {
		source = sourceWithLineEnding(c.SourceOverride, lineEnding)
	}
	result := caseResult{
		ID:         c.ID,
		Fixture:    c.Fixture,
		Format:     "toml",
		LineEnding: lineEnding,
		Operation:  c.Operation,
		Required:   c.Required,
	}
	doc, err := edit.Parse(source)
	if c.Expectation == expectParseError {
		if err == nil {
			result.Status = "fail"
			result.Detail = "malformed source was accepted"
			result.SemanticValid = true
			return result
		}
		result.Status = "pass"
		result.Detail = "parser rejected malformed source"
		result.SemanticValid = false
		return result
	}
	if err != nil {
		result.Status = "fail"
		result.Detail = "fixture parse failed: " + err.Error()
		return result
	}
	before := doc.Bytes()
	if err := c.TOMLMutation(doc); err != nil {
		result.Status = "fail"
		result.Detail = "mutation failed: " + err.Error()
		return result
	}
	after := doc.Bytes()
	result.OutputHash = hashBytes(after)
	result.SemanticValid = validateTOML(after) == nil
	result.UntouchedSpans = append(
		[]spanResult{compareUnmodifiedLines(before, after, changedLineSpec(c, "toml"))},
		compareProtectedSpans(before, after, protectedMarkers(c, "toml"), c.ProtectedBytes)...,
	)
	if spec, ok := minimalEditFor(c, "toml"); ok {
		result.MinimalEditVerified = true
		if err := checkMinimalLineEdit(before, after, spec); err != nil {
			result.Status = "fail"
			result.Detail = err.Error()
			return result
		}
	}
	if !result.SemanticValid {
		result.Status = "fail"
		result.Detail = "mutation output is not semantically valid TOML"
		return result
	}
	if err := checkTOMLExpectation(doc, c); err != nil {
		result.Status = "fail"
		result.Detail = err.Error()
		return result
	}
	if err := checkOrdering(after, c); err != nil {
		result.Status = "fail"
		result.Detail = err.Error()
		return result
	}
	if failedSpan := firstFailedSpan(result.UntouchedSpans); failedSpan != "" {
		result.Status = "fail"
		result.Detail = "untouched span changed: " + failedSpan
		return result
	}
	result.Status = "pass"
	return result
}

func checkTOMLExpectation(doc *edit.Document, c editCase) error {
	got, present := doc.Get(c.Path)
	wantPresent := c.Expectation != expectMissing
	if present != wantPresent {
		return fmt.Errorf("expected path %q present=%t, got %t", strings.Join(c.Path, "."), wantPresent, present)
	}
	if wantPresent && !valuesEqual(got, c.Want) {
		return fmt.Errorf("path %q value mismatch: got %#v, want %#v", strings.Join(c.Path, "."), got, c.Want)
	}
	return nil
}

func validateTOML(source []byte) error {
	var value any
	return toml.Unmarshal(source, &value)
}

func runJSONCCase(c editCase, lineEnding string) caseResult {
	f := fixtures[c.Fixture]
	source := sourceWithLineEnding(f.JSONC, lineEnding)
	if c.JSONOverride != nil {
		source = sourceWithLineEnding(c.JSONOverride, lineEnding)
	}
	result := caseResult{
		ID:         c.ID,
		Fixture:    c.Fixture,
		Format:     "jsonc",
		LineEnding: lineEnding,
		Operation:  c.Operation,
		Required:   c.Required,
	}
	doc, err := hujson.Parse(source)
	if c.Expectation == expectParseError {
		if err == nil {
			result.Status = "fail"
			result.Detail = "malformed source was accepted"
			return result
		}
		result.Status = "pass"
		result.Detail = "parser rejected malformed source"
		return result
	}
	if err != nil {
		result.Status = "fail"
		result.Detail = "fixture parse failed: " + err.Error()
		return result
	}
	before := doc.Pack()
	working := doc.Clone()
	if err := working.Patch([]byte(c.JSONPatch)); err != nil {
		result.Status = "fail"
		result.Detail = "mutation failed: " + err.Error()
		return result
	}
	after := working.Pack()
	result.OutputHash = hashBytes(after)
	result.SemanticValid = validateJSONC(after) == nil
	result.UntouchedSpans = append(
		[]spanResult{compareUnmodifiedLines(before, after, changedLineSpec(c, "jsonc"))},
		compareProtectedSpans(before, after, protectedMarkers(c, "jsonc"), jsonMarkers(c.ProtectedBytes))...,
	)
	if spec, ok := minimalEditFor(c, "jsonc"); ok {
		result.MinimalEditVerified = true
		if err := checkMinimalLineEdit(before, after, spec); err != nil {
			result.Status = "fail"
			result.Detail = err.Error()
			return result
		}
	}
	if !result.SemanticValid {
		result.Status = "fail"
		result.Detail = "mutation output is not semantically valid JSONC"
		return result
	}
	if err := checkJSONCExpectation(after, c); err != nil {
		result.Status = "fail"
		result.Detail = err.Error()
		return result
	}
	if err := checkOrdering(after, c); err != nil {
		result.Status = "fail"
		result.Detail = err.Error()
		return result
	}
	if failedSpan := firstFailedSpan(result.UntouchedSpans); failedSpan != "" {
		result.Status = "fail"
		result.Detail = "untouched span changed: " + failedSpan
		return result
	}
	result.Status = "pass"
	return result
}

func checkJSONCExpectation(source []byte, c editCase) error {
	standard, err := hujson.Standardize(bytes.Clone(source))
	if err != nil {
		return err
	}
	var root any
	if err := json.Unmarshal(standard, &root); err != nil {
		return err
	}
	got, present := lookupJSONPath(root, c.Path)
	wantPresent := c.Expectation != expectMissing
	if present != wantPresent {
		return fmt.Errorf("expected path %q present=%t, got %t", strings.Join(c.Path, "."), wantPresent, present)
	}
	if wantPresent && !valuesEqual(got, c.Want) {
		return fmt.Errorf("path %q value mismatch: got %#v, want %#v", strings.Join(c.Path, "."), got, c.Want)
	}
	return nil
}

func validateJSONC(source []byte) error {
	standard, err := hujson.Standardize(bytes.Clone(source))
	if err != nil {
		return err
	}
	var value any
	return json.Unmarshal(standard, &value)
}

func lookupJSONPath(root any, path []string) (any, bool) {
	value := root
	for _, segment := range path {
		switch current := value.(type) {
		case map[string]any:
			var ok bool
			value, ok = current[segment]
			if !ok {
				return nil, false
			}
		case []any:
			var index int
			if _, err := fmt.Sscanf(segment, "%d", &index); err != nil || index < 0 || index >= len(current) {
				return nil, false
			}
			value = current[index]
		default:
			return nil, false
		}
	}
	return value, true
}

func valuesEqual(got, want any) bool {
	if reflect.DeepEqual(got, want) {
		return true
	}
	gotJSON, gotErr := json.Marshal(got)
	wantJSON, wantErr := json.Marshal(want)
	return gotErr == nil && wantErr == nil && bytes.Equal(gotJSON, wantJSON)
}

func compareProtectedSpans(before, after []byte, lineMarkers, byteMarkers []string) []spanResult {
	spans := compareLineSpans(before, after, lineMarkers)
	spans = append(spans, compareByteSpans(before, after, byteMarkers)...)
	return spans
}

type minimalEdit struct {
	LineMarker string
	OldValue   string
	NewValue   string
}

func minimalEditFor(c editCase, format string) (minimalEdit, bool) {
	lineMarker := func(tomlMarker, jsoncMarker string) string {
		if format == "jsonc" {
			return jsoncMarker
		}
		return tomlMarker
	}
	newValue := func(tomlValue, jsoncValue string) string {
		if format == "jsonc" {
			return jsoncValue
		}
		return tomlValue
	}
	switch c.ID {
	case "array.element.replace":
		return minimalEdit{LineMarker: lineMarker("ports", `"ports"`), OldValue: "8081", NewValue: "9001"}, true
	case "inline-table.replace":
		return minimalEdit{LineMarker: lineMarker("inline", `"inline"`), OldValue: "9", NewValue: "42"}, true
	case "device.inline-table.replace":
		return minimalEdit{LineMarker: lineMarker("transport", `"transport"`), OldValue: "3", NewValue: "5"}, true
	case "comment-preservation.replace":
		return minimalEdit{LineMarker: lineMarker("log_level", `"log_level"`), OldValue: `"info"`, NewValue: newValue(`'warn'`, `"warn"`)}, true
	default:
		return minimalEdit{}, false
	}
}

func checkMinimalLineEdit(before, after []byte, spec minimalEdit) error {
	beforeLine := lineSpan(before, spec.LineMarker)
	afterLine := lineSpan(after, spec.LineMarker)
	if len(beforeLine) == 0 || len(afterLine) == 0 {
		return fmt.Errorf("minimal edit line %q was not found before and after mutation", spec.LineMarker)
	}
	oldOffset := bytes.Index(beforeLine, []byte(spec.OldValue))
	if oldOffset < 0 || bytes.Index(beforeLine[oldOffset+len(spec.OldValue):], []byte(spec.OldValue)) >= 0 {
		return fmt.Errorf("minimal edit old value %q was not uniquely located on line %q", spec.OldValue, spec.LineMarker)
	}
	newOffset := bytes.Index(afterLine, []byte(spec.NewValue))
	if newOffset < 0 || bytes.Index(afterLine[newOffset+len(spec.NewValue):], []byte(spec.NewValue)) >= 0 {
		return fmt.Errorf("minimal edit new value %q was not uniquely located on line %q", spec.NewValue, spec.LineMarker)
	}
	expected := make([]byte, 0, len(beforeLine)-len(spec.OldValue)+len(spec.NewValue))
	expected = append(expected, beforeLine[:oldOffset]...)
	expected = append(expected, spec.NewValue...)
	expected = append(expected, beforeLine[oldOffset+len(spec.OldValue):]...)
	if !bytes.Equal(expected, afterLine) {
		return fmt.Errorf("minimal edit changed bytes outside %q on line %q", spec.OldValue, spec.LineMarker)
	}
	return nil
}

type preservationSpec struct {
	Markers      []string
	Anchors      []string
	BlockMarkers []string
}

func compareUnmodifiedLines(before, after []byte, spec preservationSpec) spanResult {
	beforeLines := splitLines(before)
	afterLines := splitLines(after)
	pairs, unmatchedBefore, unmatchedAfter := lineLCS(beforeLines, afterLines)
	beforeAllowed := allowedLineMask(beforeLines, spec)
	afterAllowed := allowedLineMask(afterLines, spec)
	var detail string
	for _, index := range unmatchedBefore {
		if !beforeAllowed[index] {
			detail = fmt.Sprintf("source line %d is outside the allowed edit region: %q", index+1, beforeLines[index])
			break
		}
	}
	if detail == "" {
		for _, index := range unmatchedAfter {
			if !afterAllowed[index] {
				detail = fmt.Sprintf("output line %d is outside the allowed edit region: %q", index+1, afterLines[index])
				break
			}
		}
	}
	common := make([]byte, 0)
	for _, pair := range pairs {
		common = append(common, beforeLines[pair.before]...)
	}
	return spanResult{
		Name:           "all-unmodified-lines",
		Comparison:     "lcs-unmodified-lines",
		ByteIdentical:  detail == "",
		Detail:         detail,
		SourceByteHash: hashBytes(common),
		OutputByteHash: hashBytes(common),
	}
}

type linePair struct {
	before int
	after  int
}

func splitLines(source []byte) [][]byte {
	if len(source) == 0 {
		return nil
	}
	lines := make([][]byte, 0, bytes.Count(source, []byte("\n"))+1)
	start := 0
	for start < len(source) {
		end := bytes.IndexByte(source[start:], '\n')
		if end < 0 {
			lines = append(lines, bytes.Clone(source[start:]))
			break
		}
		end += start + 1
		lines = append(lines, bytes.Clone(source[start:end]))
		start = end
	}
	return lines
}

func lineLCS(before, after [][]byte) ([]linePair, []int, []int) {
	dp := make([][]int, len(before)+1)
	for i := range dp {
		dp[i] = make([]int, len(after)+1)
	}
	for i := len(before) - 1; i >= 0; i-- {
		for j := len(after) - 1; j >= 0; j-- {
			if bytes.Equal(before[i], after[j]) {
				dp[i][j] = dp[i+1][j+1] + 1
			} else if dp[i+1][j] >= dp[i][j+1] {
				dp[i][j] = dp[i+1][j]
			} else {
				dp[i][j] = dp[i][j+1]
			}
		}
	}
	pairs := make([]linePair, 0, dp[0][0])
	unmatchedBefore := make([]int, 0)
	unmatchedAfter := make([]int, 0)
	i, j := 0, 0
	for i < len(before) && j < len(after) {
		if bytes.Equal(before[i], after[j]) {
			pairs = append(pairs, linePair{before: i, after: j})
			i++
			j++
			continue
		}
		if dp[i+1][j] >= dp[i][j+1] {
			unmatchedBefore = append(unmatchedBefore, i)
			i++
		} else {
			unmatchedAfter = append(unmatchedAfter, j)
			j++
		}
	}
	for ; i < len(before); i++ {
		unmatchedBefore = append(unmatchedBefore, i)
	}
	for ; j < len(after); j++ {
		unmatchedAfter = append(unmatchedAfter, j)
	}
	return pairs, unmatchedBefore, unmatchedAfter
}

func allowedLineMask(lines [][]byte, spec preservationSpec) []bool {
	allowed := make([]bool, len(lines))
	for i, line := range lines {
		for _, marker := range spec.Markers {
			if bytes.Contains(line, []byte(marker)) {
				allowed[i] = true
			}
		}
	}
	for _, marker := range spec.BlockMarkers {
		for i := 0; i < len(lines); i++ {
			if !bytes.Contains(lines[i], []byte(marker)) {
				continue
			}
			allowed[i] = true
			if bytes.Count(lines[i], []byte(`"""`)) >= 2 {
				continue
			}
			for j := i + 1; j < len(lines); j++ {
				allowed[j] = true
				if bytes.Contains(lines[j], []byte(`"""`)) {
					break
				}
			}
		}
	}
	for _, anchor := range spec.Anchors {
		for i, line := range lines {
			if !bytes.Contains(line, []byte(anchor)) {
				continue
			}
			for j := maxInt(0, i-1); j <= minInt(len(lines)-1, i+1); j++ {
				allowed[j] = true
			}
		}
	}
	for i, line := range lines {
		if len(bytes.TrimSpace(line)) != 0 || allowed[i] {
			continue
		}
		for j := maxInt(0, i-1); j <= minInt(len(lines)-1, i+1); j++ {
			if allowed[j] {
				allowed[i] = true
				break
			}
		}
	}
	return allowed
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func changedLineSpec(c editCase, format string) preservationSpec {
	marker := func(value string) []string { return []string{value} }
	block := func(value string) preservationSpec {
		return preservationSpec{Markers: marker(value), BlockMarkers: marker(value)}
	}
	switch c.ID {
	case "replace.scalar", "comment-preservation.replace", "unknown-field.preservation":
		return preservationSpec{Markers: marker("log_level")}
	case "insert.scalar":
		return preservationSpec{Markers: marker("new_field"), Anchors: marker("new_field")}
	case "delete.scalar":
		return preservationSpec{Markers: marker("legacy")}
	case "reorder.object":
		return preservationSpec{Markers: marker("timeout_ms")}
	case "table.insert":
		return preservationSpec{Markers: marker("new_table"), Anchors: marker("new_table")}
	case "array-of-tables.insert":
		return preservationSpec{Markers: marker("alerts"), Anchors: marker("alerts")}
	case "device.array-of-tables.insert":
		return preservationSpec{Markers: marker("Alerts"), Anchors: marker("Alerts")}
	case "array.element.replace":
		return preservationSpec{Markers: marker("ports")}
	case "inline-table.replace":
		return preservationSpec{Markers: marker("inline")}
	case "dotted-key.replace":
		return preservationSpec{Markers: marker("host")}
	case "multiline-string.replace":
		if format == "toml" {
			return block("multiline =")
		}
		return preservationSpec{Markers: marker("multiline")}
	case "device.table.insert":
		return preservationSpec{Markers: marker("notifications"), Anchors: marker("notifications")}
	case "device.inline-table.replace":
		return preservationSpec{Markers: marker("transport")}
	case "device.multiline-string.replace":
		if format == "toml" {
			return block("description =")
		}
		return preservationSpec{Markers: marker("description")}
	default:
		return preservationSpec{}
	}
}

func compareLineSpans(before, after []byte, markers []string) []spanResult {
	spans := make([]spanResult, 0, len(markers))
	for _, marker := range markers {
		beforeSpan := lineSpan(before, marker)
		afterSpan := lineSpan(after, marker)
		spans = append(spans, spanResult{
			Name:           marker,
			Comparison:     "exact-line",
			ByteIdentical:  len(beforeSpan) > 0 && bytes.Equal(beforeSpan, afterSpan),
			SourceByteHash: hashBytes(beforeSpan),
			OutputByteHash: hashBytes(afterSpan),
		})
	}
	return spans
}

func compareByteSpans(before, after []byte, markers []string) []spanResult {
	spans := make([]spanResult, 0, len(markers))
	for _, marker := range markers {
		markerBytes := []byte(marker)
		beforeSpan, afterSpan := markerBytes, markerBytes
		if !bytes.Contains(before, markerBytes) {
			beforeSpan = nil
		}
		if !bytes.Contains(after, markerBytes) {
			afterSpan = nil
		}
		spans = append(spans, spanResult{
			Name:             marker,
			Comparison:       "marker-count",
			MarkerCountEqual: len(beforeSpan) > 0 && len(afterSpan) > 0 && bytes.Count(before, markerBytes) == bytes.Count(after, markerBytes),
			SourceByteHash:   hashBytes(beforeSpan),
			OutputByteHash:   hashBytes(afterSpan),
		})
	}
	return spans
}

func protectedMarkers(c editCase, format string) []string {
	if format == "toml" {
		return c.Protected
	}
	return jsonMarkers(c.Protected)
}

func jsonMarkers(markers []string) []string {
	converted := make([]string, 0, len(markers))
	for _, marker := range markers {
		converted = append(converted, jsonMarker(marker))
	}
	return converted
}

func jsonMarker(marker string) string {
	if strings.HasPrefix(marker, "# ") {
		return "//" + marker[1:]
	}
	if strings.HasPrefix(marker, "version = 1") {
		return `"version": 1`
	}
	if strings.HasPrefix(marker, "unknown_runtime = ") {
		return `"unknown_runtime": "keep-runtime"`
	}
	if strings.HasPrefix(marker, "vendor_key = ") {
		return `"vendor_key": "do-not-touch"`
	}
	if strings.HasPrefix(marker, "unknown_setting = ") {
		return `"unknown_setting": "keep-device-setting"`
	}
	if strings.HasPrefix(marker, "id = ") {
		return `"id": "clock"`
	}
	return marker
}

func firstFailedSpan(spans []spanResult) string {
	for _, span := range spans {
		if !spanPassed(span) {
			return span.Name
		}
	}
	return ""
}

func spanPassed(span spanResult) bool {
	if span.Comparison == "marker-count" {
		return span.MarkerCountEqual
	}
	return span.ByteIdentical
}

func checkOrdering(source []byte, c editCase) error {
	if c.OrderFirst == "" {
		return nil
	}
	first := bytes.Index(source, []byte(c.OrderFirst))
	second := bytes.Index(source, []byte(c.OrderSecond))
	if first < 0 || second < 0 || first <= second {
		return fmt.Errorf("expected %q to follow %q", c.OrderSecond, c.OrderFirst)
	}
	return nil
}

func hashBytes(source []byte) string {
	digest := sha256.Sum256(source)
	return hex.EncodeToString(digest[:])
}

func runSuite() suiteResults {
	results := suiteResults{
		MeasurementNote: "Ephemeral feasibility output; fields and meanings are not a public schema. Untouched lines use an LCS comparison outside operation-specific allowed edit regions.",
		Dependencies:    dependencyPins(),
		Transactions:    runTransactionalChecks(),
	}
	var requiredTOMLFailure bool
	for _, c := range allEditCases() {
		for _, lineEnding := range []string{"LF", "CRLF"} {
			tomlResult := runTOMLCase(c, lineEnding)
			results.TOML = append(results.TOML, tomlResult)
			if c.Required && tomlResult.Status != "pass" {
				requiredTOMLFailure = true
			}
			results.JSONC = append(results.JSONC, runJSONCCase(c, lineEnding))
		}
	}
	if requiredTOMLFailure {
		results.FallbackMode = "fallback-required"
		results.Recommendation = "TOML does not meet every required measured case; inspect JSONC results before choosing a format."
	} else {
		results.FallbackMode = "comparison-only"
		results.Recommendation = "Every required TOML case passed in this fixture suite; TOML remains provisional pending review of the measured artifact."
	}
	return results
}
