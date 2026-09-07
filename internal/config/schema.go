package config

import (
	"encoding/json"

	"github.com/google/jsonschema-go/jsonschema"
)

const jsonSchemaDraft4 = "http://json-schema.org/draft-04/schema#"

//go:generate go run ./generate-schema -output ../../schema/hidhogg-d200x-v2.json

// JSONSchema reflects the canonical Config DTO and adds constraints that are
// stable for this milestone. Reflection supplies property names and types;
// semantic validation remains authoritative for cross-item invariants.
func JSONSchema() (*jsonschema.Schema, error) {
	document, err := jsonschema.For[Config](nil)
	if err != nil {
		return nil, err
	}
	document.Schema = jsonSchemaDraft4
	document.Title = "Hidhogg Ulanzi D200X configuration v2"
	document.Description = "Strict named-profile configuration for one Ulanzi D200X adapter."

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
		field.Enum = []any{SchemaVersionV2}
	}
	if field := document.Properties["adapter"]; field != nil {
		field.Enum = []any{AdapterUlanziD200X}
	}
	if field := document.Properties["brightness"]; field != nil {
		field.Minimum = schemaNumber(float64(MinimumBrightness))
		field.Maximum = schemaNumber(float64(MaximumBrightness))
	}
	if field := document.Properties["idle_timeout_seconds"]; field != nil {
		field.Minimum = schemaNumber(0)
		field.Maximum = schemaNumber(float64(MaximumIdleTimeoutSeconds))
		field.Default = json.RawMessage("300")
	}
	if field := document.Properties["default_profile_id"]; field != nil {
		configureStableIDSchema(field)
	}
	if field := document.Properties["profiles"]; field != nil {
		field.Type = "array"
		field.Types = nil
		field.MinItems = schemaInt(1)
		field.MaxItems = schemaInt(MaximumProfileCount)
		field.UniqueItems = true
		if field.Items != nil {
			configureProfileSchema(field.Items)
		}
	}
	// The decoder applies the default when this optional field is omitted.
	document.Required = withoutRequired(document.Required, "idle_timeout_seconds")
}

func withoutRequired(required []string, omitted string) []string {
	filtered := make([]string, 0, len(required))
	for _, property := range required {
		if property != omitted {
			filtered = append(filtered, property)
		}
	}
	return filtered
}

func configureProfileSchema(profileSchema *jsonschema.Schema) {
	if profileSchema == nil || profileSchema.Properties == nil {
		return
	}
	if field := profileSchema.Properties["id"]; field != nil {
		configureStableIDSchema(field)
	}
	if field := profileSchema.Properties["label"]; field != nil {
		field.MinLength = schemaInt(1)
		field.MaxLength = schemaInt(MaximumLabelRunes)
	}
	if field := profileSchema.Properties["positions"]; field != nil {
		field.Type = "array"
		field.Types = nil
		field.MinItems = schemaInt(RequiredPositionCount)
		field.MaxItems = schemaInt(RequiredPositionCount)
		field.UniqueItems = true
		if field.Items != nil {
			configurePositionSchema(field.Items)
		}
	}
}

func configurePositionSchema(position *jsonschema.Schema) {
	if position == nil || position.Properties == nil {
		return
	}
	if field := position.Properties["id"]; field != nil {
		configureStableIDSchema(field)
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
	if field := position.Properties["action"]; field != nil {
		configureActionSchema(field)
	}
}

func configureActionSchema(action *jsonschema.Schema) {
	if action == nil || action.Properties == nil {
		return
	}
	if field := action.Properties["type"]; field != nil {
		field.Enum = []any{profileActionType}
	}
	if field := action.Properties["gesture"]; field != nil {
		field.Enum = []any{profileActionGesture}
	}
	if field := action.Properties["profile_id"]; field != nil {
		configureStableIDSchema(field)
	}
}

const (
	profileActionType    = "activate_profile"
	profileActionGesture = "press"
)

func configureStableIDSchema(field *jsonschema.Schema) {
	field.Pattern = stableIDPattern.String()
	field.MinLength = schemaInt(1)
	field.MaxLength = schemaInt(MaximumStableIDRunes)
}

func schemaInt(value int) *int {
	return &value
}

func schemaNumber(value float64) *float64 {
	return &value
}
