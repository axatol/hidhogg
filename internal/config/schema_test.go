package config

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
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

	artifactPath := filepath.Join("..", "..", "schema", "hidhogg-d200x-v2.json")
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
	if artifactObject["title"] != "Hidhogg Ulanzi D200X configuration v2" {
		t.Fatalf("schema title = %v", artifactObject["title"])
	}
	if _, exists := artifactObject["properties"].(map[string]any)["pages"]; exists {
		t.Fatal("v2 schema retained obsolete pages property")
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
	profiles := instance["profiles"].([]any)
	profiles[0].(map[string]any)["id"] = stringsRepeat("a", MaximumStableIDRunes+1)
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an oversized profile ID")
	}
	profiles[0].(map[string]any)["id"] = "default"
	profiles[0].(map[string]any)["positions"].([]any)[0].(map[string]any)["action"].(map[string]any)["type"] = "run"
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an unsupported action type")
	}
	profiles[0].(map[string]any)["positions"].([]any)[0].(map[string]any)["action"].(map[string]any)["type"] = "activate_profile"
	delete(profiles[0].(map[string]any)["positions"].([]any)[0].(map[string]any)["action"].(map[string]any), "gesture")
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an incomplete action")
	}
}

func TestSchemaReflectsExecuteActionUnionAndBounds(t *testing.T) {
	document, err := JSONSchema()
	if err != nil {
		t.Fatal(err)
	}
	positionSchema := document.Properties["profiles"].Items.Properties["positions"].Items
	actionSchema := positionSchema.Properties["action"]
	if len(actionSchema.OneOf) != 3 || actionSchema.OneOf[0].Type != "null" {
		t.Fatalf("action oneOf = %#v", actionSchema.OneOf)
	}
	activateSchema := actionSchema.OneOf[1]
	executeSchema := actionSchema.OneOf[2]
	if _, exists := activateSchema.Properties["executable"]; exists {
		t.Fatal("activate_profile schema exposes executable")
	}
	if _, exists := executeSchema.Properties["profile_id"]; exists {
		t.Fatal("execute schema exposes profile_id")
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
			candidateAction := candidate["profiles"].([]any)[0].(map[string]any)["positions"].([]any)[0].(map[string]any)["action"].(map[string]any)
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
	activateAction := activateInstance["profiles"].([]any)[0].(map[string]any)["positions"].([]any)[0].(map[string]any)["action"].(map[string]any)
	activateAction["executable"] = "/bin/echo"
	if err := resolved.Validate(activateInstance); err == nil {
		t.Fatal("schema accepted execute field on activate_profile action")
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
	profiles := instance["profiles"].([]any)
	profile := profiles[0].(map[string]any)
	positions := profile["positions"].([]any)
	position := positions[0].(map[string]any)
	position["position"] = "4_2"
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an unsupported coordinate")
	}
	position["position"] = "0_0"
	profile["positions"] = nil
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted null positions")
	}
}

func stringsRepeat(value string, count int) string {
	result := ""
	for index := 0; index < count; index++ {
		result += value
	}
	return result
}
