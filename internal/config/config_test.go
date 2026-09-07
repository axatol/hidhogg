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
	decoded := decodeValidFixture(t)
	if decoded.SchemaVersion != SchemaVersionV2 {
		t.Fatalf("schema version = %d, want %d", decoded.SchemaVersion, SchemaVersionV2)
	}
	if decoded.Adapter != AdapterUlanziD200X {
		t.Fatalf("adapter = %q, want %q", decoded.Adapter, AdapterUlanziD200X)
	}
	if decoded.Brightness != 80 {
		t.Fatalf("brightness = %d, want 80", decoded.Brightness)
	}
	if decoded.IdleTimeoutSeconds != DefaultIdleTimeoutSeconds {
		t.Fatalf("idle timeout = %d, want default %d", decoded.IdleTimeoutSeconds, DefaultIdleTimeoutSeconds)
	}
	if decoded.DefaultProfileID != "default" {
		t.Fatalf("default profile = %q, want default", decoded.DefaultProfileID)
	}
	if len(decoded.Profiles) != 2 {
		t.Fatalf("profile count = %d, want 2", len(decoded.Profiles))
	}
	if decoded.Profiles[0].ID != "default" || decoded.Profiles[1].ID != "alternate" {
		t.Fatalf("profile order = %q, %q", decoded.Profiles[0].ID, decoded.Profiles[1].ID)
	}
	for profileIndex, current := range decoded.Profiles {
		if len(current.Positions) != RequiredPositionCount {
			t.Fatalf("profile %d position count = %d, want %d", profileIndex, len(current.Positions), RequiredPositionCount)
		}
		seen := make(map[string]struct{}, RequiredPositionCount)
		for _, position := range current.Positions {
			seen[position.Position] = struct{}{}
		}
		for _, spec := range SupportedPositions() {
			if _, ok := seen[spec.Name]; !ok {
				t.Fatalf("profile %d omitted supported position %q", profileIndex, spec.Name)
			}
		}
	}
	if action := decoded.Profiles[0].Positions[0].Action; action == nil || action.Type != "activate_profile" || action.Gesture != "press" || action.ProfileID != "alternate" {
		t.Fatalf("default action = %#v", action)
	}
}

func TestDecodeIdleTimeoutAcceptsZeroAndMaximum(t *testing.T) {
	for _, value := range []int{0, MaximumIdleTimeoutSeconds} {
		data := bytes.Replace(validFixture, []byte("brightness = 80\n"), []byte(fmt.Sprintf("brightness = 80\nidle_timeout_seconds = %d\n", value)), 1)
		decoded, err := Decode(data)
		if err != nil {
			t.Fatalf("Decode timeout %d: %v", value, err)
		}
		if decoded.IdleTimeoutSeconds != value {
			t.Fatalf("idle timeout = %d, want %d", decoded.IdleTimeoutSeconds, value)
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

func TestDecodeRejectsUnknownOrDuplicateActionFields(t *testing.T) {
	for _, test := range []struct {
		name string
		data []byte
	}{
		{
			name: "unknown action field",
			data: bytes.Replace(validFixture, []byte("profile_id = \"alternate\"\n"), []byte("profile_id = \"alternate\"\nunknown = true\n"), 1),
		},
		{
			name: "duplicate action field",
			data: bytes.Replace(validFixture, []byte("profile_id = \"alternate\"\n"), []byte("profile_id = \"alternate\"\nprofile_id = \"alternate\"\n"), 1),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := Decode(test.data)
			if err == nil {
				t.Fatal("Decode accepted malformed action")
			}
			var validationError *ValidationError
			if errors.As(err, &validationError) {
				t.Fatalf("parser failure surfaced as semantic validation: %v", err)
			}
		})
	}
}

func TestDecodeRejectsObsoletePagesField(t *testing.T) {
	data := bytes.Replace(validFixture, []byte("default_profile_id = \"default\"\n"), []byte("default_profile_id = \"default\"\npages = []\n"), 1)
	_, err := Decode(data)
	if err == nil {
		t.Fatal("Decode accepted obsolete pages field")
	}
	var validationError *ValidationError
	if errors.As(err, &validationError) {
		t.Fatalf("obsolete pages parser failure surfaced as semantic validation: %v", err)
	}
}

func TestDecodeRejectsV1AndMissingRequiredFields(t *testing.T) {
	tests := []struct {
		name string
		data []byte
		want string
	}{
		{name: "v1", data: bytes.Replace(validFixture, []byte("schema_version = 2"), []byte("schema_version = 1"), 1), want: "schema_version"},
		{name: "missing-default", data: bytes.Replace(validFixture, []byte("default_profile_id = \"default\"\n"), nil, 1), want: "default_profile_id is required"},
		{name: "missing-profiles", data: []byte("schema_version = 2\nadapter = \"ulanzi.d200x\"\nbrightness = 80\ndefault_profile_id = \"default\"\n"), want: "profiles is required"},
		{name: "missing-brightness", data: bytes.Replace(validFixture, []byte("brightness = 80\n"), nil, 1), want: "brightness is required"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := Decode(test.data)
			if err == nil || !IsValidationError(err) {
				t.Fatalf("Decode error = %v, want semantic validation", err)
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Decode error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestValidateSemanticCases(t *testing.T) {
	tests := []struct {
		name string
		edit func(*Config)
		want string
	}{
		{name: "unsupported-version", edit: func(c *Config) { c.SchemaVersion = SchemaVersionV1 }, want: "schema_version"},
		{name: "unsupported-adapter", edit: func(c *Config) { c.Adapter = "other" }, want: "adapter"},
		{name: "brightness-too-low", edit: func(c *Config) { c.Brightness = -1 }, want: "brightness"},
		{name: "brightness-too-high", edit: func(c *Config) { c.Brightness = 101 }, want: "brightness"},
		{name: "idle-timeout-too-low", edit: func(c *Config) { c.IdleTimeoutSeconds = -1 }, want: "idle_timeout_seconds"},
		{name: "idle-timeout-too-high", edit: func(c *Config) { c.IdleTimeoutSeconds = MaximumIdleTimeoutSeconds + 1 }, want: "idle_timeout_seconds"},
		{name: "zero-profiles", edit: func(c *Config) { c.Profiles = nil }, want: "profiles must contain between"},
		{name: "too-many-profiles", edit: func(c *Config) { c.Profiles = appendProfiles(c.Profiles, MaximumProfileCount+1) }, want: "profiles must contain between"},
		{name: "short-profile", edit: func(c *Config) { c.Profiles[0].Positions = c.Profiles[0].Positions[:13] }, want: "must contain exactly 14 positions"},
		{name: "duplicate-profile-id", edit: func(c *Config) { c.Profiles[1].ID = c.Profiles[0].ID }, want: "duplicates"},
		{name: "unknown-default", edit: func(c *Config) { c.DefaultProfileID = "missing" }, want: "resolve to exactly one"},
		{name: "case-sensitive-profile-id", edit: func(c *Config) { c.Profiles[1].ID = "DEFAULT" }, want: "resolve to exactly one"},
		{name: "duplicate-position-id", edit: func(c *Config) { c.Profiles[0].Positions[1].ID = c.Profiles[0].Positions[0].ID }, want: "duplicates"},
		{name: "duplicate-position", edit: func(c *Config) { c.Profiles[0].Positions[1].Position = c.Profiles[0].Positions[0].Position }, want: "duplicates"},
		{name: "unsupported-position", edit: func(c *Config) { c.Profiles[0].Positions[0].Position = "4_2" }, want: "not a supported"},
		{name: "invalid-profile-id", edit: func(c *Config) { c.Profiles[0].ID = "not stable" }, want: "must start"},
		{name: "invalid-position-id", edit: func(c *Config) { c.Profiles[0].Positions[0].ID = "not stable" }, want: "must start"},
		{name: "invalid-profile-label", edit: func(c *Config) { c.Profiles[0].Label = "\n" }, want: "visible text"},
		{name: "invalid-position-label", edit: func(c *Config) { c.Profiles[0].Positions[0].Label = "\n" }, want: "visible text"},
		{name: "invalid-background", edit: func(c *Config) { c.Profiles[0].Positions[0].Background = "red" }, want: "hexadecimal colour"},
		{name: "invalid-action-type", edit: func(c *Config) { c.Profiles[0].Positions[0].Action.Type = "run" }, want: "activate_profile"},
		{name: "invalid-action-gesture", edit: func(c *Config) { c.Profiles[0].Positions[0].Action.Gesture = "release" }, want: "press"},
		{name: "unknown-action-target", edit: func(c *Config) { c.Profiles[0].Positions[0].Action.ProfileID = "missing" }, want: "resolve to exactly one"},
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
	configuration.Profiles[0].Positions[0].Background = "#102030ff"
	if err := configuration.Validate(); err != nil {
		t.Fatalf("alpha colour rejected: %v", err)
	}
}

func TestValidateTreatsProfileIDsAsCaseSensitive(t *testing.T) {
	configuration := decodeValidFixture(t)
	configuration.Profiles[1].ID = "DEFAULT"
	configuration.Profiles[0].Positions[0].Action.ProfileID = "DEFAULT"
	if err := configuration.Validate(); err != nil {
		t.Fatalf("case-variant profile ID rejected: %v", err)
	}
}

func TestValidateAcceptsMaximumProfileAndLabelBoundaries(t *testing.T) {
	configuration := decodeValidFixture(t)
	configuration.Profiles = appendProfiles(configuration.Profiles, MaximumProfileCount)
	for profileIndex := range configuration.Profiles {
		for positionIndex := range configuration.Profiles[profileIndex].Positions {
			configuration.Profiles[profileIndex].Positions[positionIndex].Action = nil
		}
	}
	maximumID := strings.Repeat("a", MaximumStableIDRunes)
	maximumLabel := strings.Repeat("😀", MaximumLabelRunes)
	configuration.DefaultProfileID = maximumID
	configuration.Profiles[0].ID = maximumID
	configuration.Profiles[0].Label = maximumLabel
	configuration.Profiles[0].Positions[0].ID = maximumID
	configuration.Profiles[0].Positions[0].Label = maximumLabel
	if err := configuration.Validate(); err != nil {
		t.Fatalf("maximum profile/label boundaries rejected: %v", err)
	}
}

func TestValidateRejectsProfileAndLabelOverflow(t *testing.T) {
	configuration := decodeValidFixture(t)
	configuration.Profiles = appendProfiles(configuration.Profiles, MaximumProfileCount+1)
	if err := configuration.Validate(); err == nil {
		t.Fatal("more than maximum profile count accepted")
	}

	configuration = decodeValidFixture(t)
	tooLong := strings.Repeat("a", MaximumStableIDRunes+1)
	configuration.Profiles[0].ID = tooLong
	if err := configuration.Validate(); err == nil {
		t.Fatal("oversized profile ID accepted")
	}
	configuration = decodeValidFixture(t)
	configuration.Profiles[0].Label = tooLong
	if err := configuration.Validate(); err == nil {
		t.Fatal("oversized profile label accepted")
	}
	configuration = decodeValidFixture(t)
	configuration.Profiles[0].Positions[0].Label = tooLong
	if err := configuration.Validate(); err == nil {
		t.Fatal("oversized position label accepted")
	}
	configuration = decodeValidFixture(t)
	configuration.Profiles[0].Positions[0].Action.ProfileID = tooLong
	if err := configuration.Validate(); err == nil {
		t.Fatal("oversized action target ID accepted")
	}
}

func TestValidateRejectsInvisibleControlAndFormatLabels(t *testing.T) {
	for _, label := range []string{"\u0000", "\u200b", "\u202e", "\u0301", " \t ", " \u0301 "} {
		configuration := decodeValidFixture(t)
		configuration.Profiles[0].Label = label
		if err := configuration.Validate(); err == nil {
			t.Fatalf("profile label %q accepted", label)
		}

		configuration = decodeValidFixture(t)
		configuration.Profiles[0].Positions[0].Label = label
		if err := configuration.Validate(); err == nil {
			t.Fatalf("position label %q accepted", label)
		}
	}
	configuration := decodeValidFixture(t)
	configuration.Profiles[0].Label = "Cafe\u0301"
	if err := configuration.Validate(); err != nil {
		t.Fatalf("visible combining label rejected: %v", err)
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
	for _, name := range []string{"schema_version", "adapter", "brightness", "idle_timeout_seconds", "default_profile_id", "profiles"} {
		if _, ok := projected[name]; !ok {
			t.Fatalf("JSON projection omitted %q", name)
		}
	}
	profiles := projected["profiles"].([]any)
	positions := profiles[0].(map[string]any)["positions"].([]any)
	if _, ok := positions[0].(map[string]any)["action"]; !ok {
		t.Fatal("JSON projection omitted configured action")
	}
	if _, ok := positions[1].(map[string]any)["action"]; ok {
		t.Fatal("JSON projection emitted absent action")
	}

	assertMatchingTags(t, reflect.TypeOf(Config{}))
	assertMatchingTags(t, reflect.TypeOf(Profile{}))
	assertMatchingTags(t, reflect.TypeOf(Position{}))
	assertMatchingTags(t, reflect.TypeOf(Action{}))
}

func TestProfileCatalogProvidesOrderedImmutableLookup(t *testing.T) {
	configuration := decodeValidFixture(t)
	catalog, err := configuration.ProfileCatalog()
	if err != nil {
		t.Fatal(err)
	}
	if catalog.DefaultProfileID() != "default" {
		t.Fatalf("default ID = %q", catalog.DefaultProfileID())
	}
	ordered := catalog.Profiles()
	if len(ordered) != 2 || ordered[0].ID != "default" || ordered[1].ID != "alternate" {
		t.Fatalf("ordered profiles = %#v", ordered)
	}
	ordered[0].Values[0].Label = "changed"
	ordered[0].Values[0].Action.ProfileID = "changed"
	defaultProfile, ok := catalog.Default()
	if !ok || defaultProfile.Values[0].Label != "Clock" || defaultProfile.Values[0].Action.ProfileID != "alternate" {
		t.Fatalf("catalog state changed through returned copy: %#v", defaultProfile)
	}
	target, ok := catalog.ResolveTarget("alternate")
	if !ok || target.ID != "alternate" {
		t.Fatalf("target lookup = %#v, %v", target, ok)
	}
	if _, ok := catalog.ResolveTarget("ALTERNATE"); ok {
		t.Fatal("profile lookup was not case-sensitive")
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

func appendProfiles(source []Profile, count int) []Profile {
	profiles := append([]Profile(nil), source...)
	for len(profiles) < count {
		copyOfLast := profiles[len(profiles)-1]
		copyOfLast.ID = fmt.Sprintf("profile-%02d", len(profiles))
		profiles = append(profiles, copyOfLast)
	}
	return profiles
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
		tomlName := strings.Split(field.Tag.Get("toml"), ",")[0]
		jsonName := strings.Split(field.Tag.Get("json"), ",")[0]
		if tomlName != jsonName {
			t.Fatalf("%s.%s TOML tag %q differs from JSON tag %q", typ.Name(), field.Name, field.Tag.Get("toml"), field.Tag.Get("json"))
		}
	}
}

func ExampleDecode() {
	configuration, err := Decode(validFixture)
	if err != nil {
		panic(err)
	}
	fmt.Println(configuration.Adapter, configuration.Brightness, len(configuration.Profiles))
	// Output: ulanzi.d200x 80 2
}
