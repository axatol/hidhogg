package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
)

func TestCheckedInSchemaIsCurrentAndDeterministic(t *testing.T) {
	generated, err := SchemaJSON()
	if err != nil {
		t.Fatal(err)
	}
	regenerated, err := SchemaJSON()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(generated, regenerated) {
		t.Fatal("schema generation is not deterministic")
	}

	artifactPath := filepath.Join("..", "..", "schema", "hidhogg-d200x-v4.json")
	artifact, err := os.ReadFile(artifactPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(generated, artifact) {
		t.Fatalf("checked-in schema %q is stale; run go generate ./internal/config", artifactPath)
	}
	var artifactObject map[string]any
	if err := json.Unmarshal(artifact, &artifactObject); err != nil {
		t.Fatalf("checked-in schema is not JSON: %v", err)
	}
	if artifactObject["$schema"] != jsonSchemaDraft4 {
		t.Fatalf("schema dialect = %v, want %s", artifactObject["$schema"], jsonSchemaDraft4)
	}
	if artifactObject["title"] != "Hidhogg Ulanzi D200X configuration v4" {
		t.Fatalf("schema title = %v", artifactObject["title"])
	}
	if _, exists := artifactObject["properties"].(map[string]any)["pages"]; exists {
		t.Fatal("v3 schema retained obsolete pages property")
	}
}

func TestSchemaValidatesJSONProjection(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	// google/jsonschema-go validates Draft 2020-12; the generated artifact is
	// deliberately restricted to the Draft 4 vocabulary consumed by Taplo.
	document.Schema = "https://json-schema.org/draft/2020-12/schema"
	resolved, err := document.Resolve(nil)
	if err != nil {
		t.Fatal(err)
	}

	configuration := decodeValidFixture(t)
	encoded, err := configuration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var validInstance any
	if err := json.Unmarshal(encoded, &validInstance); err != nil {
		t.Fatal(err)
	}
	if err := resolved.Validate(validInstance); err != nil {
		t.Fatalf("valid JSON projection rejected: %v", err)
	}
	delete(validInstance.(map[string]any), "idle_timeout_seconds")
	if err := resolved.Validate(validInstance); err != nil {
		t.Fatalf("schema rejected omitted optional idle timeout: %v", err)
	}

	var invalidInstance map[string]any
	if err := json.Unmarshal(encoded, &invalidInstance); err != nil {
		t.Fatal(err)
	}
	invalidInstance["schema_version"] = 1
	if err := resolved.Validate(invalidInstance); err == nil {
		t.Fatal("schema accepted schema version 1")
	}
	invalidInstance["schema_version"] = SchemaVersionV2
	invalidInstance["brightness"] = 101
	if err := resolved.Validate(invalidInstance); err == nil {
		t.Fatal("schema accepted brightness outside 0..100")
	}
	invalidInstance["brightness"] = 80
	invalidInstance["idle_timeout_seconds"] = MaximumIdleTimeoutSeconds + 1
	if err := resolved.Validate(invalidInstance); err == nil {
		t.Fatal("schema accepted idle timeout outside 0..86400")
	}
	invalidInstance["idle_timeout_seconds"] = DefaultIdleTimeoutSeconds
	invalidInstance["profiles"] = nil
	if err := resolved.Validate(invalidInstance); err == nil {
		t.Fatal("schema accepted null profiles")
	}
}

func TestSchemaReflectsLabelStyleContract(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	positionSchema := sourcePositionSchema(document)
	alignmentSchema := positionSchema.Properties["label_alignment"]
	if alignmentSchema == nil || alignmentSchema.Type != "string" || len(alignmentSchema.Enum) != 2 || alignmentSchema.Enum[0] != LabelAlignmentBottom || alignmentSchema.Enum[1] != LabelAlignmentCenter || string(alignmentSchema.Default) != `"bottom"` {
		t.Fatalf("label_alignment schema = %#v", alignmentSchema)
	}
	sizeSchema := positionSchema.Properties["label_size"]
	if sizeSchema == nil || sizeSchema.Type != "integer" || sizeSchema.Minimum == nil || *sizeSchema.Minimum != MinimumLabelSize || sizeSchema.Maximum == nil || *sizeSchema.Maximum != MaximumLabelSize || string(sizeSchema.Default) != "10" {
		t.Fatalf("label_size schema = %#v", sizeSchema)
	}

	document.Schema = "https://json-schema.org/draft/2020-12/schema"
	resolved, err := document.Resolve(nil)
	if err != nil {
		t.Fatal(err)
	}
	configuration := decodeValidFixture(t)
	encoded, err := configuration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var valid map[string]any
	if err := json.Unmarshal(encoded, &valid); err != nil {
		t.Fatal(err)
	}
	position := projectedPosition(t, valid, "default", "0_0")
	delete(position, "label_alignment")
	delete(position, "label_size")
	if err := resolved.Validate(valid); err != nil {
		t.Fatalf("schema rejected omitted label style: %v", err)
	}
	for _, test := range []struct {
		name string
		edit func(map[string]any)
	}{
		{name: "invalid alignment", edit: func(value map[string]any) { value["label_alignment"] = "top" }},
		{name: "size below minimum", edit: func(value map[string]any) { value["label_size"] = MinimumLabelSize - 1 }},
		{name: "size above maximum", edit: func(value map[string]any) { value["label_size"] = MaximumLabelSize + 1 }},
	} {
		t.Run(test.name, func(t *testing.T) {
			candidateBytes, err := json.Marshal(valid)
			if err != nil {
				t.Fatal(err)
			}
			var candidate map[string]any
			if err := json.Unmarshal(candidateBytes, &candidate); err != nil {
				t.Fatal(err)
			}
			candidatePosition := projectedPosition(t, candidate, "default", "0_0")
			test.edit(candidatePosition)
			if err := resolved.Validate(candidate); err == nil {
				t.Fatal("schema accepted invalid label style")
			}
		})
	}
}

func TestSchemaReflectsNotificationSourceContract(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	positionSchema := sourcePositionSchema(document)
	sourcesSchema := positionSchema.Properties["notification_sources"]
	if sourcesSchema == nil || sourcesSchema.Type != "array" || sourcesSchema.Types != nil || sourcesSchema.MinItems == nil || *sourcesSchema.MinItems != 1 || sourcesSchema.MaxItems == nil || *sourcesSchema.MaxItems != MaximumNotificationSourceCount || !sourcesSchema.UniqueItems {
		t.Fatalf("notification_sources schema = %#v", sourcesSchema)
	}
	itemSchema := sourcesSchema.Items
	if itemSchema == nil || itemSchema.Type != "string" || itemSchema.MinLength == nil || *itemSchema.MinLength != 1 || itemSchema.MaxLength == nil || *itemSchema.MaxLength != MaximumStableIDRunes || itemSchema.Pattern != stableIDPattern.String() {
		t.Fatalf("notification source item schema = %#v", itemSchema)
	}

	document.Schema = "https://json-schema.org/draft/2020-12/schema"
	resolved, err := document.Resolve(nil)
	if err != nil {
		t.Fatal(err)
	}
	configuration := decodeValidFixture(t)
	encoded, err := configuration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var valid map[string]any
	if err := json.Unmarshal(encoded, &valid); err != nil {
		t.Fatal(err)
	}
	position := projectedPosition(t, valid, "default", "0_0")
	validSources := make([]any, MaximumNotificationSourceCount)
	validSources[0] = "Source"
	validSources[1] = "source"
	validSources[2] = strings.Repeat("a", MaximumStableIDRunes)
	for index := 3; index < len(validSources); index++ {
		validSources[index] = fmt.Sprintf("source-%02d", index)
	}
	position["notification_sources"] = validSources
	if err := resolved.Validate(valid); err != nil {
		t.Fatalf("schema rejected maximum case-variant sources: %v", err)
	}

	for _, test := range []struct {
		name string
		edit func(map[string]any)
	}{
		{name: "null", edit: func(value map[string]any) { value["notification_sources"] = nil }},
		{name: "empty", edit: func(value map[string]any) { value["notification_sources"] = []any{} }},
		{name: "too many", edit: func(value map[string]any) { value["notification_sources"] = append(validSources, "source-overflow") }},
		{name: "invalid item", edit: func(value map[string]any) { value["notification_sources"] = []any{"not stable"} }},
		{name: "oversized item", edit: func(value map[string]any) {
			value["notification_sources"] = []any{strings.Repeat("a", MaximumStableIDRunes+1)}
		}},
		{name: "non-ASCII item", edit: func(value map[string]any) { value["notification_sources"] = []any{"sourcé"} }},
		{name: "leading punctuation item", edit: func(value map[string]any) { value["notification_sources"] = []any{"-source"} }},
		{name: "duplicate item", edit: func(value map[string]any) { value["notification_sources"] = []any{"source", "source"} }},
	} {
		t.Run(test.name, func(t *testing.T) {
			candidateBytes, err := json.Marshal(valid)
			if err != nil {
				t.Fatal(err)
			}
			var candidate map[string]any
			if err := json.Unmarshal(candidateBytes, &candidate); err != nil {
				t.Fatal(err)
			}
			candidatePosition := projectedPosition(t, candidate, "default", "0_0")
			test.edit(candidatePosition)
			if err := resolved.Validate(candidate); err == nil {
				t.Fatal("schema accepted invalid notification sources")
			}
		})
	}
}

func TestSchemaReflectsProfileAndActionBounds(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	document.Schema = "https://json-schema.org/draft/2020-12/schema"
	resolved, err := document.Resolve(nil)
	if err != nil {
		t.Fatal(err)
	}
	configuration := decodeValidFixture(t)
	encoded, err := configuration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var instance map[string]any
	if err := json.Unmarshal(encoded, &instance); err != nil {
		t.Fatal(err)
	}
	profiles := instance["profiles"].(map[string]any)
	defaultProfile := profiles["default"].(map[string]any)
	delete(profiles, "default")
	oversizedProfileID := stringsRepeat("a", MaximumStableIDRunes+1)
	profiles[oversizedProfileID] = defaultProfile
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an oversized profile ID")
	}
	delete(profiles, oversizedProfileID)
	profiles["default"] = defaultProfile
	action := projectedPosition(t, instance, "default", "0_0")["action"].(map[string]any)
	action["type"] = "run"
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an unsupported action type")
	}
	action["type"] = "activate_profile"
	delete(action, "gesture")
	if err := resolved.Validate(instance); err != nil {
		t.Fatalf("schema rejected optional action gesture: %v", err)
	}
}

func TestSchemaReflectsExecuteActionUnionAndBounds(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	positionSchema := sourcePositionSchema(document)
	actionSchema := positionSchema.Properties["action"]
	if len(actionSchema.OneOf) != 5 || actionSchema.OneOf[0].Type != "null" {
		t.Fatalf("action oneOf = %#v", actionSchema.OneOf)
	}
	activateSchema := actionSchema.OneOf[1]
	executeSchema := actionSchema.OneOf[2]
	typeTextSchema := actionSchema.OneOf[3]
	keyPressSchema := actionSchema.OneOf[4]
	for _, variant := range []*jsonschema.Schema{activateSchema, executeSchema, typeTextSchema, keyPressSchema} {
		gesture := variant.Properties["gesture"]
		if gesture == nil || gesture.Type != "string" || len(gesture.Enum) != 2 || gesture.Enum[0] != "press" || gesture.Enum[1] != "release" || string(gesture.Default) != `"release"` {
			t.Fatalf("gesture schema = %#v", gesture)
		}
		for _, required := range variant.Required {
			if required == "gesture" {
				t.Fatalf("gesture is still required in action schema: %#v", variant.Required)
			}
		}
	}
	if _, exists := activateSchema.Properties["executable"]; exists {
		t.Fatal("activate_profile schema exposes executable")
	}
	if _, exists := executeSchema.Properties["profile_id"]; exists {
		t.Fatal("execute schema exposes profile_id")
	}
	if _, exists := activateSchema.Properties["text"]; exists {
		t.Fatal("activate_profile schema exposes text")
	}
	if _, exists := activateSchema.Properties["key"]; exists {
		t.Fatal("activate_profile schema exposes key")
	}
	if _, exists := executeSchema.Properties["text"]; exists {
		t.Fatal("execute schema exposes text")
	}
	if _, exists := executeSchema.Properties["key"]; exists {
		t.Fatal("execute schema exposes key")
	}
	if _, exists := typeTextSchema.Properties["profile_id"]; exists {
		t.Fatal("type_text schema exposes profile_id")
	}
	if _, exists := typeTextSchema.Properties["executable"]; exists {
		t.Fatal("type_text schema exposes executable")
	}
	if _, exists := typeTextSchema.Properties["arguments"]; exists {
		t.Fatal("type_text schema exposes arguments")
	}
	if _, exists := typeTextSchema.Properties["timeout_seconds"]; exists {
		t.Fatal("type_text schema exposes timeout_seconds")
	}
	if _, exists := typeTextSchema.Properties["key"]; exists {
		t.Fatal("type_text schema exposes key")
	}
	if _, exists := keyPressSchema.Properties["profile_id"]; exists {
		t.Fatal("key_press schema exposes profile_id")
	}
	if _, exists := keyPressSchema.Properties["executable"]; exists {
		t.Fatal("key_press schema exposes executable")
	}
	if _, exists := keyPressSchema.Properties["arguments"]; exists {
		t.Fatal("key_press schema exposes arguments")
	}
	if _, exists := keyPressSchema.Properties["timeout_seconds"]; exists {
		t.Fatal("key_press schema exposes timeout_seconds")
	}
	if _, exists := keyPressSchema.Properties["text"]; exists {
		t.Fatal("key_press schema exposes text")
	}
	textSchema := typeTextSchema.Properties["text"]
	if textSchema == nil || textSchema.Type != "string" || *textSchema.MinLength != 1 || *textSchema.MaxLength != MaximumTextUTF16Units || textSchema.Pattern != `^[^\x00]*$` {
		t.Fatalf("text schema = %#v", textSchema)
	}
	if keySchema := keyPressSchema.Properties["key"]; keySchema == nil || keySchema.Type != "string" || len(keySchema.Enum) != 1 || keySchema.Enum[0] != "enter" {
		t.Fatalf("key schema = %#v", keySchema)
	}
	if got := string(executeSchema.Properties["arguments"].Default); got != "[]" {
		t.Fatalf("arguments default = %s, want []", got)
	}
	if got := string(executeSchema.Properties["timeout_seconds"].Default); got != "10" {
		t.Fatalf("timeout default = %s, want 10", got)
	}
	if !strings.Contains(executeSchema.Properties["arguments"].Description, "Go semantic validation authoritatively enforces UTF-8 byte and aggregate argument bounds") || !strings.Contains(executeSchema.Properties["arguments"].Description, "JSON Schema maxLength is character-based") {
		t.Fatalf("arguments description does not document semantic byte limits: %q", executeSchema.Properties["arguments"].Description)
	}
	if *executeSchema.Properties["arguments"].MaxItems != MaximumExecuteArgumentCount || *executeSchema.Properties["arguments"].Items.MaxLength != MaximumExecuteArgumentBytes {
		t.Fatalf("argument schema bounds = %#v", executeSchema.Properties["arguments"])
	}
	if *executeSchema.Properties["timeout_seconds"].Minimum != MinimumExecuteTimeoutSeconds || *executeSchema.Properties["timeout_seconds"].Maximum != MaximumExecuteTimeoutSeconds {
		t.Fatalf("timeout schema bounds = %#v", executeSchema.Properties["timeout_seconds"])
	}

	document.Schema = "https://json-schema.org/draft/2020-12/schema"
	resolved, err := document.Resolve(nil)
	if err != nil {
		t.Fatal(err)
	}
	configuration, err := Decode(executeFixture())
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := configuration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var validInstance map[string]any
	if err := json.Unmarshal(encoded, &validInstance); err != nil {
		t.Fatal(err)
	}
	if err := resolved.Validate(validInstance); err != nil {
		t.Fatalf("valid execute projection rejected: %v", err)
	}
	for _, test := range []struct {
		name string
		edit func(map[string]any)
	}{
		{name: "relative executable", edit: func(value map[string]any) { value["executable"] = "echo" }},
		{name: "NUL executable", edit: func(value map[string]any) { value["executable"] = "/bin/e\x00cho" }},
		{name: "profile ID", edit: func(value map[string]any) { value["profile_id"] = "default" }},
		{name: "missing executable", edit: func(value map[string]any) { delete(value, "executable") }},
		{name: "invalid gesture", edit: func(value map[string]any) { value["gesture"] = "hold" }},
		{name: "empty gesture", edit: func(value map[string]any) { value["gesture"] = "" }},
		{name: "too many arguments", edit: func(value map[string]any) { value["arguments"] = make([]any, MaximumExecuteArgumentCount+1) }},
		{name: "argument too long", edit: func(value map[string]any) {
			value["arguments"] = []any{strings.Repeat("a", MaximumExecuteArgumentBytes+1)}
		}},
		{name: "timeout below minimum", edit: func(value map[string]any) { value["timeout_seconds"] = MinimumExecuteTimeoutSeconds - 1 }},
		{name: "timeout above maximum", edit: func(value map[string]any) { value["timeout_seconds"] = MaximumExecuteTimeoutSeconds + 1 }},
		{name: "unknown shell", edit: func(value map[string]any) { value["shell"] = "/bin/sh" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			candidateBytes, err := json.Marshal(validInstance)
			if err != nil {
				t.Fatal(err)
			}
			var candidate map[string]any
			if err := json.Unmarshal(candidateBytes, &candidate); err != nil {
				t.Fatal(err)
			}
			candidateAction := projectedPosition(t, candidate, "default", "0_0")["action"].(map[string]any)
			test.edit(candidateAction)
			if err := resolved.Validate(candidate); err == nil {
				t.Fatal("schema accepted invalid execute action")
			}
		})
	}

	activateConfiguration := decodeValidFixture(t)
	activateEncoded, err := activateConfiguration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var activateInstance map[string]any
	if err := json.Unmarshal(activateEncoded, &activateInstance); err != nil {
		t.Fatal(err)
	}
	activateAction := projectedPosition(t, activateInstance, "default", "0_0")["action"].(map[string]any)
	activateAction["executable"] = "/bin/echo"
	if err := resolved.Validate(activateInstance); err == nil {
		t.Fatal("schema accepted execute field on activate_profile action")
	}

	for _, test := range []struct {
		name    string
		type_   string
		payload string
		invalid func(map[string]any)
	}{
		{
			name:    "type_text",
			type_:   TypeTextActionType,
			payload: `text = "hello"`,
			invalid: func(action map[string]any) { action["text"] = "" },
		},
		{
			name:    "key_press",
			type_:   KeyPressActionType,
			payload: `key = "enter"`,
			invalid: func(action map[string]any) { action["key"] = "space" },
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			configuration, err := Decode(nativeActionFixture(test.type_, test.payload))
			if err != nil {
				t.Fatal(err)
			}
			encoded, err := configuration.JSON()
			if err != nil {
				t.Fatal(err)
			}
			var instance map[string]any
			if err := json.Unmarshal(encoded, &instance); err != nil {
				t.Fatal(err)
			}
			if err := resolved.Validate(instance); err != nil {
				t.Fatalf("valid native action rejected: %v", err)
			}
			action := projectedPosition(t, instance, "default", "0_0")["action"].(map[string]any)
			test.invalid(action)
			if err := resolved.Validate(instance); err == nil {
				t.Fatal("schema accepted invalid native action")
			}
		})
	}
}

func TestSchemaRejectsIncompletePositionDomain(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	document.Schema = "https://json-schema.org/draft/2020-12/schema"
	resolved, err := document.Resolve(nil)
	if err != nil {
		t.Fatal(err)
	}

	configuration := decodeValidFixture(t)
	encoded, err := configuration.JSON()
	if err != nil {
		t.Fatal(err)
	}
	var instance map[string]any
	if err := json.Unmarshal(encoded, &instance); err != nil {
		t.Fatal(err)
	}
	profiles := instance["profiles"].(map[string]any)
	profile := profiles["default"].(map[string]any)
	positions := profile["positions"].(map[string]any)
	positions["4_2"] = map[string]any{}
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an unsupported coordinate")
	}
	delete(positions, "4_2")
	delete(profile, "positions")
	if err := resolved.Validate(instance); err != nil {
		t.Fatalf("schema rejected omitted positions: %v", err)
	}
	profile["positions"] = nil
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted null positions")
	}
}

func TestSchemaUsesClosedKeyedProfileAndPositionMaps(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	profilesSchema := document.Properties["profiles"]
	if profilesSchema == nil || profilesSchema.Type != "object" || profilesSchema.AdditionalProperties == nil {
		t.Fatalf("profiles schema does not describe stable-ID keyed objects: %#v", profilesSchema)
	}
	profileSchema := profilesSchema.PatternProperties[stableIDPattern.String()]
	if profileSchema == nil {
		t.Fatalf("profiles schema omitted stable-ID pattern %q", stableIDPattern.String())
	}
	positionsSchema := profileSchema.Properties["positions"]
	if positionsSchema == nil || positionsSchema.Type != "object" || len(positionsSchema.Properties) != RequiredPositionCount || positionsSchema.AdditionalProperties == nil {
		t.Fatalf("positions schema does not describe a closed coordinate map: %#v", positionsSchema)
	}
	for _, spec := range supportedPositionSpecs {
		if positionsSchema.Properties[spec.Name] == nil {
			t.Fatalf("positions schema omitted coordinate %q", spec.Name)
		}
	}
	tileSchema := positionsSchema.Properties["3_2"]
	if tileSchema == nil || tileSchema.Properties["id"] != nil || tileSchema.Properties["position"] != nil || tileSchema.AdditionalProperties == nil {
		t.Fatalf("tile schema retained removed identity fields or allows unknown fields: %#v", tileSchema)
	}
	if tileSchema.Properties["label"] == nil || tileSchema.Properties["background"] == nil {
		t.Fatalf("tile schema omitted defaulted fields: %#v", tileSchema.Properties)
	}
	if got := string(tileSchema.Properties["label"].Default); got != `""` {
		t.Fatalf("tile label default = %s, want empty string", got)
	}
	if got := string(tileSchema.Properties["background"].Default); got != `"#000000"` {
		t.Fatalf("tile background default = %s, want black", got)
	}
}

func sourcePositionSchema(document *jsonschema.Schema) *jsonschema.Schema {
	profile := document.Properties["profiles"].PatternProperties[stableIDPattern.String()]
	positions := profile.Properties["positions"]
	return positions.Properties["0_0"]
}

func projectedPosition(t *testing.T, instance map[string]any, profileID, coordinate string) map[string]any {
	t.Helper()
	profiles, ok := instance["profiles"].(map[string]any)
	if !ok {
		t.Fatalf("profiles projection = %T, want object", instance["profiles"])
	}
	profile, ok := profiles[profileID].(map[string]any)
	if !ok {
		t.Fatalf("profile %q projection = %T, want object", profileID, profiles[profileID])
	}
	positions, ok := profile["positions"].(map[string]any)
	if !ok {
		t.Fatalf("positions projection = %T, want object", profile["positions"])
	}
	position, ok := positions[coordinate].(map[string]any)
	if !ok {
		t.Fatalf("position %q projection = %T, want object", coordinate, positions[coordinate])
	}
	return position
}

func stringsRepeat(value string, count int) string {
	result := ""
	for index := 0; index < count; index++ {
		result += value
	}
	return result
}
