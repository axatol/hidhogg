package config

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"

	"hidhogg/internal/profile"

	toml "github.com/pelletier/go-toml/v2"
)

//go:embed testdata/valid.toml
var validFixture []byte

//go:embed testdata/invalid/*.toml
var invalidFixtures embed.FS

func TestDecodeValidFixture(t *testing.T) {
	decoded := decodeValidFixture(t)
	if decoded.SchemaVersion != SchemaVersionV4 {
		t.Fatalf("schema version = %d, want %d", decoded.SchemaVersion, SchemaVersionV4)
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
		for positionIndex, position := range current.Positions {
			if position.LabelAlignment != DefaultLabelAlignment || position.LabelSize != DefaultLabelSize {
				t.Fatalf("profile %d position %d style = %s/%d, want %s/%d", profileIndex, positionIndex, position.LabelAlignment, position.LabelSize, DefaultLabelAlignment, DefaultLabelSize)
			}
		}
	}
	if action := decoded.Profiles[0].Positions[0].Action; action == nil || action.Type != "activate_profile" || action.Gesture != profile.ReleaseGesture || action.ProfileID != "alternate" {
		t.Fatalf("default action = %#v", action)
	}
}

func TestDecodeSparseProfilesNormalizeInDeterministicOrder(t *testing.T) {
	data := []byte(`schema_version = 4
adapter = "ulanzi.d200x"
brightness = 80
default_profile_id = "default"

[profiles."zeta"]
label = "Zeta"

[profiles."default"]
label = "Default"

[profiles."alpha"]
label = "Alpha"
`)
	decoded, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	if got := []string{decoded.Profiles[0].ID, decoded.Profiles[1].ID, decoded.Profiles[2].ID}; !reflect.DeepEqual(got, []string{"default", "alpha", "zeta"}) {
		t.Fatalf("normalized profile order = %#v", got)
	}
	for _, current := range decoded.Profiles {
		if len(current.Positions) != RequiredPositionCount {
			t.Fatalf("profile %q position count = %d", current.ID, len(current.Positions))
		}
		for index, position := range current.Positions {
			want := SupportedPositions()[index].Name
			if position.ID != want || position.Position != want || position.Label != "" || position.Background != DefaultPositionBackground || position.Action != nil || position.NotificationSources != nil || position.LabelAlignment != DefaultLabelAlignment || position.LabelSize != DefaultLabelSize {
				t.Fatalf("profile %q position %d = %#v, want blank coordinate %q", current.ID, index, position, want)
			}
		}
	}
	if _, err := decoded.ProfileCatalog(); err != nil {
		t.Fatalf("blank normalized labels rejected by catalog: %v", err)
	}
}

func TestDecodeEmptyTileDefaultsAndBlankLabelAction(t *testing.T) {
	data := []byte(`schema_version = 4
adapter = "ulanzi.d200x"
brightness = 80
default_profile_id = "default"

[profiles.default]
label = "Default"
positions = { "2_0" = {}, "0_0" = { label = "", action = { type = "execute", executable = "/bin/echo" } } }
`)
	decoded, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	blank := decoded.Profiles[0].Positions[0]
	if blank.Label != "" || blank.Background != DefaultPositionBackground || blank.Action == nil || blank.Action.Gesture != profile.ReleaseGesture || blank.Action.Arguments == nil || blank.Action.TimeoutSeconds != DefaultExecuteTimeoutSeconds {
		t.Fatalf("explicit blank action tile = %#v", blank)
	}
	empty := decoded.Profiles[0].Positions[2]
	if empty.Label != "" || empty.Background != DefaultPositionBackground || empty.Action != nil || empty.NotificationSources != nil {
		t.Fatalf("empty inline tile = %#v", empty)
	}
	if _, err := decoded.ProfileCatalog(); err != nil {
		t.Fatalf("catalog rejected configured action with blank label: %v", err)
	}
}

func TestDecodeRejectsWhitespaceOnlyTileLabelsAndExplicitInvalidDefaults(t *testing.T) {
	for _, test := range []struct {
		name        string
		needle      string
		replacement string
		want        string
	}{
		{name: "whitespace label", needle: `label = "Clock"`, replacement: `label = " \t "`, want: "label"},
		{name: "empty background", needle: `background = "#102030"`, replacement: `background = ""`, want: "background"},
		{name: "explicit empty alignment", needle: `background = "#102030"`, replacement: "label_alignment = \"\"\nbackground = \"#102030\"", want: "label_alignment"},
	} {
		t.Run(test.name, func(t *testing.T) {
			data := bytes.Replace(validFixture, []byte(test.needle), []byte(test.replacement), 1)
			_, err := Decode(data)
			if err == nil || !IsValidationError(err) || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Decode error = %v, want explicit-field validation for %q", err, test.want)
			}
		})
	}
}

func TestDecodeReportsQuotedProfileAndUnsupportedCoordinateKeys(t *testing.T) {
	data := []byte(`schema_version = 4
adapter = "ulanzi.d200x"
brightness = 80
default_profile_id = "work.day"

[profiles."work.day"]
label = "Work"

[profiles."work.day".positions."4_2"]
label = "Invalid"
`)
	_, err := Decode(data)
	if err == nil || !IsValidationError(err) || !strings.Contains(err.Error(), `profiles["work.day"].positions["4_2"]`) {
		t.Fatalf("Decode error = %v, want quoted keyed coordinate diagnostic", err)
	}
	diagnostic := newDiagnostic("config.toml", err)
	if diagnostic.Key != `profiles["work.day"].positions["4_2"]` {
		t.Fatalf("diagnostic key = %q", diagnostic.Key)
	}
}

func TestDecodeRejectsV3ArrayDocumentWithVersionGuidance(t *testing.T) {
	data := []byte(`schema_version = 3
adapter = "ulanzi.d200x"
brightness = 80
default_profile_id = "default"

[[profiles]]
id = "default"
label = "Default"
`)
	_, err := Decode(data)
	var validationError *ValidationError
	if !errors.As(err, &validationError) || len(validationError.Issues) != 1 || validationError.Issues[0].Path != "schema_version" {
		t.Fatalf("v3 array error = %v, want schema-version validation", err)
	}
	diagnostic := newDiagnostic("config.toml", err)
	if diagnostic.Category != DiagnosticSchemaVersion || diagnostic.Key != "schema_version" || diagnostic.Detail != "use schema_version = 4" {
		t.Fatalf("v3 array diagnostic = %#v", diagnostic)
	}
}

func TestDecodeReportsInvalidProfileKeyAtTablePath(t *testing.T) {
	data := []byte(`schema_version = 4
adapter = "ulanzi.d200x"
brightness = 80
default_profile_id = "default"

[profiles.default]
label = "Default"

[profiles."bad id"]
label = "Invalid"
`)
	_, err := Decode(data)
	if err == nil || !IsValidationError(err) || !strings.Contains(err.Error(), `profiles["bad id"]`) {
		t.Fatalf("invalid profile key error = %v", err)
	}
	diagnostic := newDiagnostic("config.toml", err)
	if diagnostic.Key != `profiles["bad id"]` {
		t.Fatalf("invalid profile key diagnostic = %q", diagnostic.Key)
	}
}

func TestDecodeLabelStyleDefaultsAndExplicitValues(t *testing.T) {
	data := bytes.Replace(validFixture, []byte("label = \"Clock\"\nbackground = \"#102030\""), []byte("label = \"Clock\"\nlabel_alignment = \"center\"\nlabel_size = 24\nbackground = \"#102030\""), 1)
	decoded, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	explicit := decoded.Profiles[0].Positions[0]
	if explicit.LabelAlignment != LabelAlignmentCenter || explicit.LabelSize != 24 {
		t.Fatalf("explicit label style = %s/%d, want %s/24", explicit.LabelAlignment, explicit.LabelSize, LabelAlignmentCenter)
	}
	omitted := decoded.Profiles[0].Positions[1]
	if omitted.LabelAlignment != DefaultLabelAlignment || omitted.LabelSize != DefaultLabelSize {
		t.Fatalf("omitted label style = %s/%d, want %s/%d", omitted.LabelAlignment, omitted.LabelSize, DefaultLabelAlignment, DefaultLabelSize)
	}
	catalog, err := decoded.ProfileCatalog()
	if err != nil {
		t.Fatal(err)
	}
	profile, ok := catalog.Default()
	if !ok || profile.Values[0].LabelAlignment != LabelAlignmentCenter || profile.Values[0].LabelSize != 24 || profile.Values[1].LabelAlignment != DefaultLabelAlignment || profile.Values[1].LabelSize != DefaultLabelSize {
		t.Fatalf("catalog label styles = %#v, %t", profile.Values[:2], ok)
	}
}

func TestDecodeRejectsInvalidLabelStyleFields(t *testing.T) {
	for _, test := range []struct {
		name  string
		field string
		value string
		want  string
	}{
		{name: "alignment enum", field: "label_alignment", value: `"top"`, want: "label_alignment"},
		{name: "explicit empty alignment", field: "label_alignment", value: `""`, want: "label_alignment"},
		{name: "size below minimum", field: "label_size", value: fmt.Sprintf("%d", MinimumLabelSize-1), want: "label_size"},
		{name: "size above maximum", field: "label_size", value: fmt.Sprintf("%d", MaximumLabelSize+1), want: "label_size"},
		{name: "explicit zero size", field: "label_size", value: "0", want: "label_size"},
	} {
		t.Run(test.name, func(t *testing.T) {
			needle := "background = \"#102030\""
			replacement := test.field + " = " + test.value + "\n" + needle
			data := bytes.Replace(validFixture, []byte(needle), []byte(replacement), 1)
			_, err := Decode(data)
			if err == nil || !IsValidationError(err) || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Decode error = %v, want label style validation", err)
			}
		})
	}
}

func TestDecodeAcceptsLabelStyleBoundaries(t *testing.T) {
	for _, alignment := range []string{LabelAlignmentBottom, LabelAlignmentCenter} {
		for _, size := range []int{MinimumLabelSize, DefaultLabelSize, 11, MaximumLabelSize} {
			data := bytes.Replace(validFixture, []byte("label = \"Clock\"\nbackground = \"#102030\""), []byte(fmt.Sprintf("label = \"Clock\"\nlabel_alignment = %q\nlabel_size = %d\nbackground = \"#102030\"", alignment, size)), 1)
			decoded, err := Decode(data)
			if err != nil {
				t.Fatalf("Decode style %s/%d: %v", alignment, size, err)
			}
			position := decoded.Profiles[0].Positions[0]
			if position.LabelAlignment != alignment || position.LabelSize != size {
				t.Fatalf("decoded style = %s/%d, want %s/%d", position.LabelAlignment, position.LabelSize, alignment, size)
			}
		}
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

func TestDecodeAndValidateNotificationSources(t *testing.T) {
	configuration := decodeValidFixture(t)
	if sources := configuration.Profiles[0].Positions[0].NotificationSources; sources != nil {
		t.Fatalf("omitted notification sources = %#v, want nil", sources)
	}

	formatSources := func(sources []string) string {
		encoded := make([]string, len(sources))
		for index, source := range sources {
			encoded[index] = fmt.Sprintf("%q", source)
		}
		return "[" + strings.Join(encoded, ", ") + "]"
	}
	validSources := make([]string, MaximumNotificationSourceCount)
	validSources[0] = "Source"
	validSources[1] = "source"
	validSources[2] = strings.Repeat("a", MaximumStableIDRunes)
	for index := 3; index < len(validSources); index++ {
		validSources[index] = fmt.Sprintf("source-%02d", index)
	}
	validData := bytes.Replace(validFixture, []byte("background = \"#102030\""), []byte("background = \"#102030\"\nnotification_sources = "+formatSources(validSources)), 1)
	decoded, err := Decode(validData)
	if err != nil {
		t.Fatalf("maximum and case-variant source list rejected: %v", err)
	}
	if got := decoded.Profiles[0].Positions[0].NotificationSources; !reflect.DeepEqual(got, validSources) {
		t.Fatalf("decoded notification sources = %#v, want %#v", got, validSources)
	}

	for _, test := range []struct {
		name    string
		sources string
		want    string
	}{
		{name: "empty", sources: "[]", want: "notification_sources must contain between"},
		{name: "too many", sources: formatSources(append(validSources, "source-overflow")), want: "notification_sources must contain between"},
		{name: "invalid ID", sources: `["not stable"]`, want: "notification_sources[0]"},
		{name: "oversized ID", sources: fmt.Sprintf("[%q]", strings.Repeat("a", MaximumStableIDRunes+1)), want: "notification_sources[0]"},
		{name: "non-ASCII ID", sources: `["sourcé"]`, want: "notification_sources[0]"},
		{name: "leading punctuation ID", sources: `["-source"]`, want: "notification_sources[0]"},
		{name: "duplicate", sources: `["source", "source"]`, want: "notification_sources[1]"},
	} {
		t.Run(test.name, func(t *testing.T) {
			data := bytes.Replace(validFixture, []byte("background = \"#102030\""), []byte("background = \"#102030\"\nnotification_sources = "+test.sources), 1)
			_, err := Decode(data)
			if err == nil || !IsValidationError(err) || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Decode error = %v, want validation containing %q", err, test.want)
			}
		})
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

func TestDecodeExecuteActionAppliesDefaults(t *testing.T) {
	decoded, err := Decode(executeFixture())
	if err != nil {
		t.Fatal(err)
	}
	action := decoded.Profiles[0].Positions[0].Action
	if action == nil || action.Type != ExecuteActionType || action.Gesture != profile.ReleaseGesture || action.Executable != "/bin/echo" {
		t.Fatalf("execute action = %#v", action)
	}
	if action.Arguments == nil || len(action.Arguments) != 0 {
		t.Fatalf("arguments = %#v, want non-nil empty slice", action.Arguments)
	}
	if action.TimeoutSeconds != DefaultExecuteTimeoutSeconds {
		t.Fatalf("timeout = %d, want %d", action.TimeoutSeconds, DefaultExecuteTimeoutSeconds)
	}
	catalog, err := decoded.ProfileCatalog()
	if err != nil {
		t.Fatal(err)
	}
	profile, ok := catalog.Default()
	if !ok || profile.Values[0].Action == nil || profile.Values[0].Action.TimeoutSeconds != DefaultExecuteTimeoutSeconds || profile.Values[0].Action.Arguments == nil {
		t.Fatalf("catalog execute action = %#v, %v", profile.Values[0].Action, ok)
	}
}

func TestDecodeActionGestureDefaultsToRelease(t *testing.T) {
	data := bytes.Replace(validFixture, []byte("gesture = \"release\"\n"), nil, 1)
	decoded, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	action := decoded.Profiles[0].Positions[0].Action
	if action == nil || action.Gesture != profile.ReleaseGesture {
		t.Fatalf("decoded omitted gesture = %#v, want %q", action, profile.ReleaseGesture)
	}
	catalog, err := decoded.ProfileCatalog()
	if err != nil {
		t.Fatal(err)
	}
	profileValue, ok := catalog.Default()
	if !ok || profileValue.Values[0].Action == nil || profileValue.Values[0].Action.Gesture != profile.ReleaseGesture {
		t.Fatalf("catalog omitted gesture = %#v, %t", profileValue.Values[0].Action, ok)
	}
}

func TestDecodeAcceptsPressAndReleaseActionGestures(t *testing.T) {
	for _, gesture := range []string{profile.PressGesture, profile.ReleaseGesture} {
		t.Run(gesture, func(t *testing.T) {
			data := bytes.Replace(validFixture, []byte("gesture = \"release\"\n"), []byte("gesture = \""+gesture+"\"\n"), 1)
			decoded, err := Decode(data)
			if err != nil {
				t.Fatal(err)
			}
			action := decoded.Profiles[0].Positions[0].Action
			if action == nil || action.Gesture != gesture {
				t.Fatalf("decoded gesture = %#v, want %q", action, gesture)
			}
		})
	}
}

func TestDecodeRejectsExplicitEmptyActionGesture(t *testing.T) {
	data := bytes.Replace(validFixture, []byte("gesture = \"release\"\n"), []byte("gesture = \"\"\n"), 1)
	_, err := Decode(data)
	if err == nil || !IsValidationError(err) || !strings.Contains(err.Error(), ".gesture") {
		t.Fatalf("Decode error = %v, want explicit empty gesture validation", err)
	}
}

func TestDecodeNativeActionsApplyDefaultsAndConvert(t *testing.T) {
	for _, test := range []struct {
		name      string
		data      []byte
		expected  func(*Action) bool
		catalogOK func(profile.Action) bool
	}{
		{
			name: "type text",
			data: nativeActionFixture(TypeTextActionType, `text = "hello"`),
			expected: func(action *Action) bool {
				return action.Type == TypeTextActionType && action.Gesture == profile.ReleaseGesture && action.Text == "hello" && action.Key == ""
			},
			catalogOK: func(action profile.Action) bool {
				return action.Type == profile.TypeTextActionType && action.Gesture == profile.ReleaseGesture && action.Text == "hello" && action.Key == ""
			},
		},
		{
			name: "key press",
			data: nativeActionFixture(KeyPressActionType, `key = "enter"`),
			expected: func(action *Action) bool {
				return action.Type == KeyPressActionType && action.Gesture == profile.ReleaseGesture && action.Text == "" && action.Key == "enter"
			},
			catalogOK: func(action profile.Action) bool {
				return action.Type == profile.KeyPressActionType && action.Gesture == profile.ReleaseGesture && action.Text == "" && action.Key == "enter"
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			decoded, err := Decode(test.data)
			if err != nil {
				t.Fatal(err)
			}
			action := decoded.Profiles[0].Positions[0].Action
			if action == nil || !test.expected(action) {
				t.Fatalf("decoded action = %#v", action)
			}
			catalog, err := decoded.ProfileCatalog()
			if err != nil {
				t.Fatal(err)
			}
			current, ok := catalog.Default()
			if !ok || current.Values[0].Action == nil || !test.catalogOK(*current.Values[0].Action) {
				t.Fatalf("catalog action = %#v, %t", current.Values[0].Action, ok)
			}
		})
	}
}

func TestDecodeNativeActionTextAndKeyBoundaries(t *testing.T) {
	for _, test := range []struct {
		name string
		data []byte
		want bool
	}{
		{name: "text ASCII maximum", data: nativeActionFixture(TypeTextActionType, `text = "`+strings.Repeat("a", MaximumTextUTF16Units)+`"`), want: true},
		{name: "text supplementary maximum", data: nativeActionFixture(TypeTextActionType, `text = "`+strings.Repeat("😀", MaximumTextUTF16Units/2)+`"`), want: true},
		{name: "text supplementary over maximum", data: nativeActionFixture(TypeTextActionType, `text = "`+strings.Repeat("😀", MaximumTextUTF16Units/2+1)+`"`), want: false},
		{name: "text empty", data: nativeActionFixture(TypeTextActionType, `text = ""`), want: false},
		{name: "text NUL", data: nativeActionFixture(TypeTextActionType, `text = "a\u0000b"`), want: false},
		{name: "key enter", data: nativeActionFixture(KeyPressActionType, `key = "enter"`), want: true},
		{name: "key unsupported", data: nativeActionFixture(KeyPressActionType, `key = "space"`), want: false},
		{name: "key empty", data: nativeActionFixture(KeyPressActionType, `key = ""`), want: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := Decode(test.data)
			if (err == nil) != test.want {
				t.Fatalf("Decode error = %v, want accepted = %t", err, test.want)
			}
		})
	}
}

func TestDecodeRejectsNativeActionForeignFieldsIncludingEmptyValues(t *testing.T) {
	for _, test := range []struct {
		name  string
		type_ string
		field string
	}{
		{name: "text profile ID", type_: TypeTextActionType, field: `profile_id = ""`},
		{name: "text executable", type_: TypeTextActionType, field: `executable = ""`},
		{name: "text arguments", type_: TypeTextActionType, field: `arguments = []`},
		{name: "text timeout", type_: TypeTextActionType, field: `timeout_seconds = 0`},
		{name: "text key", type_: TypeTextActionType, field: `key = ""`},
		{name: "key press profile ID", type_: KeyPressActionType, field: `profile_id = ""`},
		{name: "key press executable", type_: KeyPressActionType, field: `executable = ""`},
		{name: "key press arguments", type_: KeyPressActionType, field: `arguments = []`},
		{name: "key press timeout", type_: KeyPressActionType, field: `timeout_seconds = 0`},
		{name: "key press text", type_: KeyPressActionType, field: `text = ""`},
	} {
		t.Run(test.name, func(t *testing.T) {
			payload := `text = "ok"`
			if test.type_ == KeyPressActionType {
				payload = `key = "enter"`
			}
			data := nativeActionFixture(test.type_, payload)
			data = bytes.Replace(data, []byte(payload+"\n"), []byte(payload+"\n"+test.field+"\n"), 1)
			if _, err := Decode(data); err == nil {
				t.Fatal("Decode accepted explicitly present foreign action field")
			}
		})
	}
}

func TestValidateExecuteActionBoundsAndStrictFields(t *testing.T) {
	tests := []struct {
		name  string
		edit  func(*Action)
		valid bool
	}{
		{name: "timeout omitted", edit: func(action *Action) { action.TimeoutSeconds = 0 }, valid: true},
		{name: "timeout minimum", edit: func(action *Action) { action.TimeoutSeconds = MinimumExecuteTimeoutSeconds }, valid: true},
		{name: "timeout maximum", edit: func(action *Action) { action.TimeoutSeconds = MaximumExecuteTimeoutSeconds }, valid: true},
		{name: "timeout maximum plus one", edit: func(action *Action) { action.TimeoutSeconds = MaximumExecuteTimeoutSeconds + 1 }, valid: false},
		{name: "argument count maximum", edit: func(action *Action) { action.Arguments = make([]string, MaximumExecuteArgumentCount) }, valid: true},
		{name: "argument count maximum plus one", edit: func(action *Action) { action.Arguments = make([]string, MaximumExecuteArgumentCount+1) }, valid: false},
		{name: "argument bytes maximum", edit: func(action *Action) { action.Arguments = []string{strings.Repeat("a", MaximumExecuteArgumentBytes)} }, valid: true},
		{name: "argument bytes maximum plus one", edit: func(action *Action) { action.Arguments = []string{strings.Repeat("a", MaximumExecuteArgumentBytes+1)} }, valid: false},
		{name: "aggregate bytes maximum", edit: func(action *Action) {
			action.Arguments = executeArgumentsWithBytes(MaximumExecuteArgumentsBytes)
		}, valid: true},
		{name: "aggregate bytes maximum plus one", edit: func(action *Action) {
			action.Arguments = executeArgumentsWithBytes(MaximumExecuteArgumentsBytes + 1)
		}, valid: false},
		{name: "NUL argument", edit: func(action *Action) { action.Arguments = []string{"a\x00b"} }, valid: false},
		{name: "invalid UTF-8 argument", edit: func(action *Action) { action.Arguments = []string{string([]byte{0xff})} }, valid: false},
		{name: "relative executable", edit: func(action *Action) { action.Executable = "echo" }, valid: false},
		{name: "empty executable", edit: func(action *Action) { action.Executable = "" }, valid: false},
		{name: "NUL executable", edit: func(action *Action) { action.Executable = "/bin/e\x00cho" }, valid: false},
		{name: "wrong gesture", edit: func(action *Action) { action.Gesture = "hold" }, valid: false},
		{name: "profile ID", edit: func(action *Action) { action.ProfileID = "alternate" }, valid: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			configuration := decodeValidFixture(t)
			action := configuration.Profiles[0].Positions[0].Action
			action.Type = ExecuteActionType
			action.Gesture = profile.ReleaseGesture
			action.ProfileID = ""
			action.Executable = "/bin/echo"
			action.Arguments = nil
			action.TimeoutSeconds = 0
			test.edit(action)
			err := configuration.Validate()
			if (err == nil) != test.valid {
				t.Fatalf("Validate error = %v, valid = %v", err, test.valid)
			}
		})
	}
}

func TestDecodeRejectsExecuteVariantExclusionsAndUnknownFields(t *testing.T) {
	base := executeFixture()
	variants := []struct {
		name string
		data []byte
	}{
		{name: "timeout zero", data: bytes.Replace(base, []byte("executable = \"/bin/echo\"\n"), []byte("executable = \"/bin/echo\"\ntimeout_seconds = 0\n"), 1)},
		{name: "timeout maximum plus one", data: bytes.Replace(base, []byte("executable = \"/bin/echo\"\n"), []byte("executable = \"/bin/echo\"\ntimeout_seconds = 61\n"), 1)},
		{name: "profile ID", data: bytes.Replace(base, []byte("executable = \"/bin/echo\"\n"), []byte("executable = \"/bin/echo\"\nprofile_id = \"alternate\"\n"), 1)},
	}
	for _, field := range []string{"cwd", "environment", "shell", "unknown"} {
		variants = append(variants, struct {
			name string
			data []byte
		}{name: field, data: bytes.Replace(base, []byte("executable = \"/bin/echo\"\n"), []byte("executable = \"/bin/echo\"\n"+field+" = \"value\"\n"), 1)})
	}
	activate := validFixture
	for _, field := range []string{"executable", "arguments", "timeout_seconds"} {
		value := field + " = \"/bin/echo\"\n"
		if field == "arguments" {
			value = "arguments = []\n"
		}
		if field == "timeout_seconds" {
			value = "timeout_seconds = 0\n"
		}
		variants = append(variants, struct {
			name string
			data []byte
		}{name: "activate " + field, data: bytes.Replace(activate, []byte("profile_id = \"alternate\"\n"), []byte("profile_id = \"alternate\"\n"+value), 1)})
	}
	for _, variant := range variants {
		t.Run(variant.name, func(t *testing.T) {
			if _, err := Decode(variant.data); err == nil {
				t.Fatal("Decode accepted forbidden or unknown action field")
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
		{name: "v1", data: bytes.Replace(validFixture, []byte("schema_version = 4"), []byte("schema_version = 1"), 1), want: "schema_version"},
		{name: "v2", data: bytes.Replace(validFixture, []byte("schema_version = 4"), []byte("schema_version = 2"), 1), want: "schema_version"},
		{name: "v3", data: bytes.Replace(validFixture, []byte("schema_version = 4"), []byte("schema_version = 3"), 1), want: "schema_version"},
		{name: "missing-default", data: bytes.Replace(validFixture, []byte("default_profile_id = \"default\"\n"), nil, 1), want: "default_profile_id is required"},
		{name: "missing-profiles", data: []byte("schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = 80\ndefault_profile_id = \"default\"\n"), want: "profiles is required"},
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
		{name: "unsupported-version", edit: func(c *Config) { c.SchemaVersion = SchemaVersionV2 }, want: "schema_version"},
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
		{name: "invalid-label-alignment", edit: func(c *Config) { c.Profiles[0].Positions[0].LabelAlignment = "top" }, want: "label_alignment"},
		{name: "label-size-too-low", edit: func(c *Config) { c.Profiles[0].Positions[0].LabelSize = MinimumLabelSize - 1 }, want: "label_size"},
		{name: "label-size-too-high", edit: func(c *Config) { c.Profiles[0].Positions[0].LabelSize = MaximumLabelSize + 1 }, want: "label_size"},
		{name: "invalid-action-type", edit: func(c *Config) { c.Profiles[0].Positions[0].Action.Type = "run" }, want: "activate_profile"},
		{name: "invalid-action-gesture", edit: func(c *Config) { c.Profiles[0].Positions[0].Action.Gesture = "hold" }, want: "gesture"},
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
	profiles := projected["profiles"].(map[string]any)
	positions := profiles["default"].(map[string]any)["positions"].(map[string]any)
	if len(positions) != RequiredPositionCount {
		t.Fatalf("JSON projection position count = %d, want %d", len(positions), RequiredPositionCount)
	}
	position := positions["0_0"].(map[string]any)
	if _, ok := position["action"]; !ok {
		t.Fatal("JSON projection omitted configured action")
	}
	if _, exists := position["id"]; exists {
		t.Fatal("JSON projection retained removed position ID field")
	}
	if _, exists := position["position"]; exists {
		t.Fatal("JSON projection retained removed coordinate field")
	}
	if position["label_alignment"] != DefaultLabelAlignment || position["label_size"] != float64(DefaultLabelSize) {
		t.Fatalf("JSON projection label style = %#v/%#v, want %s/%d", position["label_alignment"], position["label_size"], DefaultLabelAlignment, DefaultLabelSize)
	}
	if _, ok := positions["1_0"].(map[string]any)["action"]; ok {
		t.Fatal("JSON projection emitted absent action")
	}

	assertMatchingTags(t, reflect.TypeOf(Config{}))
	assertMatchingTags(t, reflect.TypeOf(Profile{}))
	assertMatchingTags(t, reflect.TypeOf(Position{}))
	assertMatchingTags(t, reflect.TypeOf(Action{}))
}

func TestJSONProjectionPreservesExplicitZeroIdleTimeout(t *testing.T) {
	data := bytes.Replace(validFixture, []byte("brightness = 80\n"), []byte("brightness = 80\nidle_timeout_seconds = 0\n"), 1)
	configuration, err := Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := configuration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var projected map[string]any
	if err := json.Unmarshal(encoded, &projected); err != nil {
		t.Fatal(err)
	}
	if value, exists := projected["idle_timeout_seconds"]; !exists || value != float64(0) {
		t.Fatalf("JSON idle timeout = %#v, exists=%t; want explicit zero", value, exists)
	}
}

func TestJSONProjectionRejectsNonCanonicalNormalizedPositionIDs(t *testing.T) {
	configuration := decodeValidFixture(t)
	configuration.Profiles[0].Positions[0].ID = "other"
	if _, err := configuration.JSON(); err == nil || !strings.Contains(err.Error(), "canonical coordinate") {
		t.Fatalf("JSON accepted non-canonical normalized position ID: %v", err)
	}
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
	ordered[0].Values[0].LabelAlignment = LabelAlignmentCenter
	ordered[0].Values[0].LabelSize = 24
	ordered[0].Values[0].Action.ProfileID = "changed"
	defaultProfile, ok := catalog.Default()
	if !ok || defaultProfile.Values[0].Label != "Clock" || defaultProfile.Values[0].LabelAlignment != DefaultLabelAlignment || defaultProfile.Values[0].LabelSize != DefaultLabelSize || defaultProfile.Values[0].Action.ProfileID != "alternate" {
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

func TestProfileCatalogPropagatesNotificationSourcesDefensively(t *testing.T) {
	configuration := decodeValidFixture(t)
	configuration.Profiles[0].Positions[0].NotificationSources = []string{"Source", "source"}
	catalog, err := configuration.ProfileCatalog()
	if err != nil {
		t.Fatal(err)
	}
	configuration.Profiles[0].Positions[0].NotificationSources[0] = "changed-config"

	defaultProfile, ok := catalog.Default()
	if !ok || !reflect.DeepEqual(defaultProfile.Values[0].NotificationSources, []string{"Source", "source"}) {
		t.Fatalf("catalog sources = %#v, %t", defaultProfile.Values[0].NotificationSources, ok)
	}
	defaultProfile.Values[0].NotificationSources[0] = "changed-result"
	unchanged, ok := catalog.Default()
	if !ok || !reflect.DeepEqual(unchanged.Values[0].NotificationSources, []string{"Source", "source"}) {
		t.Fatalf("catalog sources changed through returned copy = %#v, %t", unchanged.Values[0].NotificationSources, ok)
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

func TestLoadReturnsTypedSafeDiagnostics(t *testing.T) {
	const secret = "DIAGNOSTIC_SECRET_SENTINEL"
	tests := []struct {
		name         string
		data         []byte
		category     DiagnosticCategory
		key          string
		wantLocation bool
		wantDetail   string
		wantDecode   bool
		wantValidate bool
	}{
		{
			name:         "type mismatch",
			data:         bytes.Replace(validFixture, []byte("brightness = 80"), []byte("brightness = \""+secret+"\""), 1),
			category:     DiagnosticDecode,
			key:          "brightness",
			wantLocation: true,
			wantDetail:   "TOML syntax or value type is invalid",
			wantDecode:   true,
		},
		{
			name:         "type text key mismatch",
			data:         nativeActionFixture(TypeTextActionType, "text = 123"),
			category:     DiagnosticDecode,
			key:          "profiles[\"default\"].positions[\"0_0\"].action.text",
			wantLocation: true,
			wantDetail:   "TOML syntax or value type is invalid",
			wantDecode:   true,
		},
		{
			name:         "key press key mismatch",
			data:         nativeActionFixture(KeyPressActionType, "key = 123"),
			category:     DiagnosticDecode,
			key:          "profiles[\"default\"].positions[\"0_0\"].action.key",
			wantLocation: true,
			wantDetail:   "TOML syntax or value type is invalid",
			wantDecode:   true,
		},
		{
			name:         "malformed syntax",
			data:         append(append([]byte(nil), validFixture...), []byte("\n[["+secret)...),
			category:     DiagnosticDecode,
			wantLocation: true,
			wantDetail:   "TOML syntax or value type is invalid",
			wantDecode:   true,
		},
		{
			name:         "nested unknown key",
			data:         bytes.Replace(validFixture, []byte("profile_id = \"alternate\"\n"), []byte("profile_id = \"alternate\"\nunknown = \""+secret+"\"\n"), 1),
			category:     DiagnosticUnknownKey,
			key:          "profiles[\"default\"].positions[\"0_0\"].action.unknown",
			wantLocation: true,
			wantDetail:   "key is not supported",
			wantDecode:   true,
		},
		{
			name:         "obsolete pages",
			data:         bytes.Replace(validFixture, []byte("default_profile_id = \"default\"\n"), []byte("default_profile_id = \"default\"\npages = [\""+secret+"\"]\n"), 1),
			category:     DiagnosticUnknownKey,
			key:          "pages",
			wantLocation: true,
			wantDetail:   "pages is obsolete; use profiles",
			wantDecode:   true,
		},
		{
			name:         "schema version",
			data:         bytes.Replace(validFixture, []byte("schema_version = 4"), []byte("schema_version = 2 # "+secret), 1),
			category:     DiagnosticSchemaVersion,
			key:          "schema_version",
			wantDetail:   "use schema_version = 4",
			wantValidate: true,
		},
		{
			name:         "missing required",
			data:         bytes.Replace(validFixture, []byte("default_profile_id = \"default\"\n"), []byte("# "+secret+"\n"), 1),
			category:     DiagnosticMissingKey,
			key:          "default_profile_id",
			wantDetail:   "required key is missing",
			wantValidate: true,
		},
		{
			name:         "keyed validation",
			data:         bytes.Replace(validFixture, []byte("background = \"#102030\""), []byte("background = \""+secret+"\""), 1),
			category:     DiagnosticValidation,
			key:          "profiles[\"default\"].positions[\"0_0\"].background",
			wantDetail:   "value violates configuration constraints",
			wantValidate: true,
		},
		{
			name:         "keyed missing profile label",
			data:         bytes.Replace(validFixture, []byte("label = \"Default\"\n"), []byte("# "+secret+"\n"), 1),
			category:     DiagnosticMissingKey,
			key:          "profiles[\"default\"].label",
			wantDetail:   "required key is missing",
			wantValidate: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.toml")
			if err := os.WriteFile(path, test.data, 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := Load(path)
			var diagnostic *Diagnostic
			if !errors.As(err, &diagnostic) {
				t.Fatalf("Load error = %T %v, want *Diagnostic", err, err)
			}
			if diagnostic.Path != path || diagnostic.Category != test.category || diagnostic.Key != test.key || diagnostic.Detail != test.wantDetail {
				t.Fatalf("diagnostic = %#v", diagnostic)
			}
			if test.wantLocation != (diagnostic.Line > 0 && diagnostic.Column > 0) {
				t.Fatalf("diagnostic location = %d:%d", diagnostic.Line, diagnostic.Column)
			}
			var decodeError *toml.DecodeError
			if errors.As(err, &decodeError) != test.wantDecode {
				t.Fatalf("DecodeError preservation = %t, want %t", decodeError != nil, test.wantDecode)
			}
			var validationError *ValidationError
			if errors.As(err, &validationError) != test.wantValidate {
				t.Fatalf("ValidationError preservation = %t, want %t", validationError != nil, test.wantValidate)
			}
			assertSafeDiagnosticText(t, diagnostic, secret)
		})
	}
}

func TestLoadReadDiagnosticsPreserveErrorsIs(t *testing.T) {
	missingPath := filepath.Join(t.TempDir(), "missing.toml")
	_, err := Load(missingPath)
	var diagnostic *Diagnostic
	if !errors.As(err, &diagnostic) || diagnostic.Category != DiagnosticReadNotFound || diagnostic.Path != missingPath {
		t.Fatalf("missing diagnostic = %#v, %v", diagnostic, err)
	}
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing error did not preserve fs.ErrNotExist: %v", err)
	}

	for _, test := range []struct {
		cause    error
		category DiagnosticCategory
	}{
		{cause: fmt.Errorf("wrapped: %w", fs.ErrPermission), category: DiagnosticReadDenied},
		{cause: fmt.Errorf("wrapped: %w", fs.ErrInvalid), category: DiagnosticReadInvalid},
		{cause: errors.New("opaque read failure"), category: DiagnosticRead},
	} {
		diagnostic := newDiagnostic("relative.toml", test.cause)
		if diagnostic.Category != test.category || !filepath.IsAbs(diagnostic.Path) {
			t.Fatalf("read diagnostic = %#v", diagnostic)
		}
		if !errors.Is(diagnostic, test.cause) {
			t.Fatalf("diagnostic did not preserve cause %v", test.cause)
		}
	}
}

func TestDiagnosticProjectionIsFixedBoundedAndPathFree(t *testing.T) {
	diagnostic := &Diagnostic{
		Path:     "/private/SECRET_PATH",
		Category: DiagnosticUnknownKey,
		Key:      "pages\n",
		Line:     MaximumDiagnosticLocation + 1,
		Column:   4,
		Detail:   "SECRET_DETAIL",
		cause:    errors.New("SECRET_CAUSE"),
	}
	projection := diagnostic.SafeProjection()
	if projection == nil || projection.Category != DiagnosticUnknownKey || projection.Key != "pages" || projection.Detail != "pages is obsolete; use profiles" || projection.Line != 0 || projection.Column != 0 {
		t.Fatalf("safe projection = %#v", projection)
	}
	encoded := fmt.Sprintf("%+v", projection)
	for _, secret := range []string{"SECRET_PATH", "SECRET_DETAIL", "SECRET_CAUSE"} {
		if strings.Contains(encoded, secret) {
			t.Fatalf("projection exposed %q: %s", secret, encoded)
		}
	}
	fallback := SafeDiagnosticProjection(errors.New("SECRET_OPAQUE"))
	if fallback.Category != DiagnosticDecode || fallback.Key != "" || fallback.Line != 0 || fallback.Column != 0 || fallback.Detail != "TOML syntax or value type is invalid" {
		t.Fatalf("fallback projection = %#v", fallback)
	}
}

func assertSafeDiagnosticText(t *testing.T, diagnostic *Diagnostic, secret string) {
	t.Helper()
	output := diagnostic.Error()
	if strings.Contains(output, secret) {
		t.Fatalf("diagnostic exposed configuration value: %q", output)
	}
	if !utf8.ValidString(output) || len(diagnostic.Detail) > MaximumDiagnosticDetailBytes {
		t.Fatalf("diagnostic is invalid or unbounded: %q", output)
	}
	for _, character := range diagnostic.Detail {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) {
			t.Fatalf("diagnostic detail contains control character: %q", diagnostic.Detail)
		}
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

func executeFixture() []byte {
	data := bytes.Replace(validFixture, []byte("type = \"activate_profile\"\n"), []byte("type = \"execute\"\nexecutable = \"/bin/echo\"\n"), 1)
	return bytes.Replace(data, []byte("profile_id = \"alternate\"\n"), nil, 1)
}

func nativeActionFixture(actionType, payload string) []byte {
	data := bytes.Replace(validFixture, []byte("type = \"activate_profile\"\n"), []byte("type = \""+actionType+"\"\n"), 1)
	return bytes.Replace(data, []byte("profile_id = \"alternate\"\n"), []byte(payload+"\n"), 1)
}

func executeArgumentsWithBytes(total int) []string {
	arguments := make([]string, 0, (total/MaximumExecuteArgumentBytes)+1)
	for total > 0 {
		argumentBytes := total
		if argumentBytes > MaximumExecuteArgumentBytes {
			argumentBytes = MaximumExecuteArgumentBytes
		}
		arguments = append(arguments, strings.Repeat("a", argumentBytes))
		total -= argumentBytes
	}
	return arguments
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
