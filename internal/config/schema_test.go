package config

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
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

	artifactPath := filepath.Join("..", "..", "schema", "hidhogg-d200x-v1.json")
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

	var invalidInstance map[string]any
	if err := json.Unmarshal(encoded, &invalidInstance); err != nil {
		t.Fatal(err)
	}
	invalidInstance["brightness"] = 101
	if err := resolved.Validate(invalidInstance); err == nil {
		t.Fatal("schema accepted brightness outside 0..100")
	}
	invalidInstance["brightness"] = 80
	invalidInstance["pages"] = nil
	if err := resolved.Validate(invalidInstance); err == nil {
		t.Fatal("schema accepted null pages")
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
	pages := instance["pages"].([]any)
	page := pages[0].(map[string]any)
	positions := page["positions"].([]any)
	position := positions[0].(map[string]any)
	position["position"] = "4_2"
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted an unsupported coordinate")
	}
	page["positions"] = nil
	if err := resolved.Validate(instance); err == nil {
		t.Fatal("schema accepted null positions")
	}
}
