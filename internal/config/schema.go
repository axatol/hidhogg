package config

import (
	"encoding/json"

	"github.com/google/jsonschema-go/jsonschema"
)

const jsonSchemaDraft4 = "http://json-schema.org/draft-04/schema#"

//go:generate go run ./generate-schema -output ../../schema/hidhogg-d200x-v1.json

// JSONSchema reflects the canonical Config DTO and adds constraints that are
// stable for this milestone. Reflection supplies property names and types;
// semantic validation remains authoritative for cross-item invariants.
func JSONSchema() (*jsonschema.Schema, error) {
	document, err := jsonschema.For[Config](nil)
	if err != nil {
		return nil, err
	}
	document.Schema = jsonSchemaDraft4
	document.Title = "Hidhogg Ulanzi D200X configuration v1"
	document.Description = "Milestone-private single-file configuration for one Ulanzi D200X page."

	configureConfigSchema(document)
	return document, nil
}

// SchemaJSON returns the deterministic, checked-in artifact representation.
func SchemaJSON() ([]byte, error) {
	document, err := JSONSchema()
	if err != nil {
		return nil, err
	}
	encoded, err := json.MarshalIndent(document, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(encoded, '\n'), nil
}

// GenerateSchema is retained as a descriptive alias for schema-generation
// callers. It always reflects the same DTO as JSONSchema.
func GenerateSchema() ([]byte, error) {
	return SchemaJSON()
}

func configureConfigSchema(document *jsonschema.Schema) {
	if document == nil || document.Properties == nil {
		return
	}
	if field := document.Properties["schema_version"]; field != nil {
		field.Enum = []any{SchemaVersionV1}
	}
	if field := document.Properties["adapter"]; field != nil {
		field.Enum = []any{AdapterUlanziD200X}
	}
	if field := document.Properties["brightness"]; field != nil {
		field.Minimum = schemaNumber(float64(MinimumBrightness))
		field.Maximum = schemaNumber(float64(MaximumBrightness))
	}
	if field := document.Properties["pages"]; field != nil {
		field.Type = "array"
		field.Types = nil
		field.MinItems = schemaInt(RequiredPageCount)
		field.MaxItems = schemaInt(RequiredPageCount)
		if field.Items != nil {
			configurePageSchema(field.Items)
		}
	}
}

func configurePageSchema(page *jsonschema.Schema) {
	if page == nil || page.Properties == nil {
		return
	}
	positions := page.Properties["positions"]
	if positions == nil {
		return
	}
	positions.Type = "array"
	positions.Types = nil
	positions.MinItems = schemaInt(RequiredPositionCount)
	positions.MaxItems = schemaInt(RequiredPositionCount)
	positions.UniqueItems = true
	if positions.Items != nil {
		configurePositionSchema(positions.Items)
	}

}

func configurePositionSchema(position *jsonschema.Schema) {
	if position == nil || position.Properties == nil {
		return
	}
	if field := position.Properties["id"]; field != nil {
		field.Pattern = stableIDPattern.String()
		field.MinLength = schemaInt(1)
		field.MaxLength = schemaInt(MaximumStableIDRunes)
	}
	if field := position.Properties["position"]; field != nil {
		field.Enum = make([]any, 0, len(supportedPositionSpecs))
		for _, spec := range supportedPositionSpecs {
			field.Enum = append(field.Enum, spec.Name)
		}
	}
	if field := position.Properties["label"]; field != nil {
		field.MinLength = schemaInt(1)
		field.MaxLength = schemaInt(MaximumLabelRunes)
	}
	if field := position.Properties["background"]; field != nil {
		field.Pattern = backgroundPattern.String()
	}
}

func schemaInt(value int) *int {
	return &value
}

func schemaNumber(value float64) *float64 {
	return &value
}
