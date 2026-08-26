package config

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

//go:embed testdata/valid.toml
var validFixture []byte

//go:embed testdata/invalid/*.toml
var invalidFixtures embed.FS

func TestDecodeValidFixture(t *testing.T) {
	decoded, err := Decode(validFixture)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.SchemaVersion != SchemaVersionV1 {
		t.Fatalf("schema version = %d, want %d", decoded.SchemaVersion, SchemaVersionV1)
	}
	if decoded.Adapter != AdapterUlanziD200X {
		t.Fatalf("adapter = %q, want %q", decoded.Adapter, AdapterUlanziD200X)
	}
	if decoded.Brightness != 80 {
		t.Fatalf("brightness = %d, want 80", decoded.Brightness)
	}
	if len(decoded.Pages) != RequiredPageCount {
		t.Fatalf("page count = %d, want %d", len(decoded.Pages), RequiredPageCount)
	}
	if len(decoded.Pages[0].Positions) != RequiredPositionCount {
		t.Fatalf("position count = %d, want %d", len(decoded.Pages[0].Positions), RequiredPositionCount)
	}

	seen := make(map[string]string, RequiredPositionCount)
	for _, position := range decoded.Pages[0].Positions {
		seen[position.Position] = position.ID
	}
	for _, spec := range SupportedPositions() {
		if seen[spec.Name] == "" {
			t.Fatalf("fixture omitted supported position %q", spec.Name)
		}
	}
}

func TestDecodeRejectsParserFailures(t *testing.T) {
	for _, name := range []string{"duplicate-key.toml", "malformed.toml", "unknown-field.toml", "unknown-nested-field.toml", "wrong-type.toml"} {
		t.Run(name, func(t *testing.T) {
			data, err := invalidFixtures.ReadFile("testdata/invalid/" + name)
			if err != nil {
				t.Fatal(err)
			}
			_, err = Decode(data)
			if err == nil {
				t.Fatal("Decode accepted invalid fixture")
			}
			var validationError *ValidationError
			if errors.As(err, &validationError) {
				t.Fatalf("parser failure surfaced as semantic validation: %v", err)
			}
		})
	}
}

func TestDecodeRejectsMissingRequiredBrightness(t *testing.T) {
	data := bytes.Replace(validFixture, []byte("brightness = 80\n"), nil, 1)
	_, err := Decode(data)
	if err == nil {
		t.Fatal("Decode accepted a document without brightness")
	}
	var validationError *ValidationError
	if !errors.As(err, &validationError) {
		t.Fatalf("error = %T, want *ValidationError", err)
	}
	if !strings.Contains(err.Error(), "brightness is required") {
		t.Fatalf("error = %v, want required brightness issue", err)
	}
}

func TestValidateSemanticCases(t *testing.T) {
	tests := []struct {
		name string
		edit func(*Config)
		want string
	}{
		{name: "unsupported-version", edit: func(c *Config) { c.SchemaVersion = 2 }, want: "schema_version"},
		{name: "unsupported-adapter", edit: func(c *Config) { c.Adapter = "other" }, want: "adapter"},
		{name: "brightness-too-low", edit: func(c *Config) { c.Brightness = -1 }, want: "brightness"},
		{name: "brightness-too-high", edit: func(c *Config) { c.Brightness = 101 }, want: "brightness"},
		{name: "zero-pages", edit: func(c *Config) { c.Pages = nil }, want: "pages must contain exactly 1 page"},
		{name: "two-pages", edit: func(c *Config) { c.Pages = append(c.Pages, c.Pages[0]) }, want: "pages must contain exactly 1 page"},
		{name: "short-page", edit: func(c *Config) { c.Pages[0].Positions = c.Pages[0].Positions[:13] }, want: "must contain exactly 14 positions"},
		{name: "duplicate-id", edit: func(c *Config) { c.Pages[0].Positions[1].ID = c.Pages[0].Positions[0].ID }, want: "duplicates"},
		{name: "duplicate-position", edit: func(c *Config) { c.Pages[0].Positions[1].Position = c.Pages[0].Positions[0].Position }, want: "duplicates"},
		{name: "unsupported-position", edit: func(c *Config) { c.Pages[0].Positions[0].Position = "4_2" }, want: "not a supported"},
		{name: "invalid-id", edit: func(c *Config) { c.Pages[0].Positions[0].ID = "not stable" }, want: "must start"},
		{name: "invalid-label", edit: func(c *Config) { c.Pages[0].Positions[0].Label = "\n" }, want: "visible text"},
		{name: "invalid-background", edit: func(c *Config) { c.Pages[0].Positions[0].Background = "red" }, want: "hexadecimal colour"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			decoded := decodeValidFixture(t)
			test.edit(&decoded)
			err := decoded.Validate()
			if err == nil {
				t.Fatal("Validate accepted invalid configuration")
			}
			if !IsValidationError(err) {
				t.Fatalf("error = %T, want *ValidationError", err)
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
			if err.Error() != decoded.validationErrorString() {
				t.Fatal("validation error string changed across repeated validation")
			}
		})
	}
}

func TestValidateAcceptsOpaqueAndAlphaHexColours(t *testing.T) {
	configuration := decodeValidFixture(t)
	configuration.Pages[0].Positions[0].Background = "#102030ff"
	if err := configuration.Validate(); err != nil {
		t.Fatalf("alpha colour rejected: %v", err)
	}
}

func TestValidateIsIndependentOfTOMLReflection(t *testing.T) {
	configuration := Config{
		SchemaVersion: SchemaVersionV1,
		Adapter:       AdapterUlanziD200X,
		Brightness:    50,
		Pages: []Page{{Positions: []Position{{
			ID:         "only",
			Position:   "0_0",
			Label:      "One",
			Background: "#102030",
		}}}},
	}
	err := configuration.Validate()
	if err == nil || !IsValidationError(err) {
		t.Fatalf("Validate error = %v, want semantic error", err)
	}
}

func TestLoadFile(t *testing.T) {
	path := t.TempDir() + "/config.toml"
	if err := os.WriteFile(path, validFixture, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadFile(path); err != nil {
		t.Fatal(err)
	}
}

func TestJSONProjectionUsesCanonicalNames(t *testing.T) {
	decoded := decodeValidFixture(t)
	encoded, err := decoded.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var projected map[string]any
	if err := json.Unmarshal(encoded, &projected); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"schema_version", "adapter", "brightness", "pages"} {
		if _, ok := projected[name]; !ok {
			t.Fatalf("JSON projection omitted %q", name)
		}
	}

	assertMatchingTags(t, reflect.TypeOf(Config{}))
	assertMatchingTags(t, reflect.TypeOf(Page{}))
	assertMatchingTags(t, reflect.TypeOf(Position{}))
}

func TestSupportedPositionDomain(t *testing.T) {
	positions := SupportedPositions()
	if len(positions) != RequiredPositionCount {
		t.Fatalf("supported position count = %d, want %d", len(positions), RequiredPositionCount)
	}
	for index, want := range positions {
		if want.WireIndex != byte(index) {
			t.Fatalf("position %q has wire index %d, want %d", want.Name, want.WireIndex, index)
		}
		got, ok := LookupPosition(want.Name)
		if !ok || got != want {
			t.Fatalf("LookupPosition(%q) = %#v, %v, want %#v, true", want.Name, got, ok, want)
		}
		got, ok = PositionForWireIndex(want.WireIndex)
		if !ok || got != want {
			t.Fatalf("PositionForWireIndex(%d) = %#v, %v, want %#v, true", want.WireIndex, got, ok, want)
		}
	}
	if _, ok := LookupPosition("4_2"); ok {
		t.Fatal("unsupported coordinate 4_2 was accepted")
	}
	if _, ok := PositionForWireIndex(byte(RequiredPositionCount)); ok {
		t.Fatal("wire index 14 was accepted")
	}

	positions[0].Name = "changed"
	if SupportedPositions()[0].Name != "0_0" {
		t.Fatal("SupportedPositions returned mutable package state")
	}
}

func decodeValidFixture(t *testing.T) Config {
	t.Helper()
	decoded, err := Decode(validFixture)
	if err != nil {
		t.Fatal(err)
	}
	return decoded
}

func (c Config) validationErrorString() string {
	err := c.Validate()
	if err == nil {
		return ""
	}
	return err.Error()
}

func assertMatchingTags(t *testing.T, typ reflect.Type) {
	t.Helper()
	for index := 0; index < typ.NumField(); index++ {
		field := typ.Field(index)
		if field.Tag.Get("toml") != field.Tag.Get("json") {
			t.Fatalf("%s.%s TOML tag %q differs from JSON tag %q", typ.Name(), field.Name, field.Tag.Get("toml"), field.Tag.Get("json"))
		}
		if strings.Contains(field.Tag.Get("toml"), ",") || strings.Contains(field.Tag.Get("json"), ",") {
			t.Fatalf("%s.%s tags unexpectedly carry options", typ.Name(), field.Name)
		}
	}
}

func ExampleDecode() {
	configuration, err := Decode(validFixture)
	if err != nil {
		panic(err)
	}
	fmt.Println(configuration.Adapter, configuration.Brightness, len(configuration.Pages[0].Positions))
	// Output: ulanzi.d200x 80 14
}
