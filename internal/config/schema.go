package config

import (
	"encoding/json"

	"hidhogg/internal/profile"

	"github.com/google/jsonschema-go/jsonschema"
)

const jsonSchemaDraft4 = "http://json-schema.org/draft-04/schema#"

//go:generate go run ./generate-schema -output ../../schema/hidhogg-d200x-v3.json

// JSONSchema reflects the canonical Config DTO and adds constraints that are
// stable for this milestone. Reflection supplies property names and types;
// semantic validation remains authoritative for cross-item invariants.
func JSONSchema() (*jsonschema.Schema, error) {
	document, err := jsonschema.For[Config](nil)
	if err != nil {
		return nil, err
	}
	document.Schema = jsonSchemaDraft4
	document.Title = "Hidhogg Ulanzi D200X configuration v3"
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
		field.Enum = []any{SchemaVersionV3}
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
	if field := position.Properties["label_alignment"]; field != nil {
		field.Enum = []any{LabelAlignmentBottom, LabelAlignmentCenter}
		field.Default = json.RawMessage(`"bottom"`)
	}
	if field := position.Properties["label_size"]; field != nil {
		field.Minimum = schemaNumber(float64(MinimumLabelSize))
		field.Maximum = schemaNumber(float64(MaximumLabelSize))
		field.Default = json.RawMessage("10")
	}
	if field := position.Properties["background"]; field != nil {
		field.Pattern = backgroundPattern.String()
	}
	if field := position.Properties["action"]; field != nil {
		configureActionSchema(field)
	}
}

func configureActionSchema(action *jsonschema.Schema) {
	if action == nil {
		return
	}
	// Reflection sees one Go struct containing all variant fields. Replace that
	// projection with a strict nullable oneOf so each TOML action shape has its
	// own required and forbidden property set.
	action.Type = ""
	action.Types = nil
	action.Properties = nil
	action.Required = nil
	action.AdditionalProperties = nil
	action.PropertyOrder = nil
	action.OneOf = []*jsonschema.Schema{
		{Type: "null"},
		activateProfileActionSchema(),
		executeActionSchema(),
		typeTextActionSchema(),
		keyPressActionSchema(),
	}
}

func activateProfileActionSchema() *jsonschema.Schema {
	return actionObjectSchema(
		map[string]*jsonschema.Schema{
			"type":       actionStringSchema("action type", []any{profileActionType}),
			"gesture":    actionGestureSchema(),
			"profile_id": stableIDActionSchema("case-sensitive target profile identifier"),
		},
		[]string{"type", "profile_id"},
		[]string{"type", "gesture", "profile_id"},
	)
}

func executeActionSchema() *jsonschema.Schema {
	arguments := &jsonschema.Schema{
		Type:        "array",
		Description: "executable arguments; Go semantic validation authoritatively enforces UTF-8 byte and aggregate argument bounds because JSON Schema maxLength is character-based and cannot express aggregate encoded bytes",
		Items: &jsonschema.Schema{
			Type:      "string",
			MaxLength: schemaInt(MaximumExecuteArgumentBytes),
			Pattern:   `^[^\x00]*$`,
		},
		MaxItems: schemaInt(MaximumExecuteArgumentCount),
		Default:  json.RawMessage("[]"),
	}
	timeout := &jsonschema.Schema{
		Type:        "integer",
		Description: "maximum synchronous execution time in seconds",
		Default:     json.RawMessage("10"),
		Minimum:     schemaNumber(MinimumExecuteTimeoutSeconds),
		Maximum:     schemaNumber(MaximumExecuteTimeoutSeconds),
	}
	return actionObjectSchema(
		map[string]*jsonschema.Schema{
			"type":            actionStringSchema("action type", []any{ExecuteActionType}),
			"gesture":         actionGestureSchema(),
			"executable":      {Type: "string", Description: "absolute executable path without NUL", MinLength: schemaInt(1), Pattern: `^/[^\x00]*$`},
			"arguments":       arguments,
			"timeout_seconds": timeout,
		},
		[]string{"type", "executable"},
		[]string{"type", "gesture", "executable", "arguments", "timeout_seconds"},
	)
}

func typeTextActionSchema() *jsonschema.Schema {
	return actionObjectSchema(
		map[string]*jsonschema.Schema{
			"type":    actionStringSchema("action type", []any{TypeTextActionType}),
			"gesture": actionGestureSchema(),
			"text": {
				Type:        "string",
				Description: "non-empty UTF-8 text without NUL; Go semantic validation authoritatively enforces the maximum of 64 UTF-16 code units",
				MinLength:   schemaInt(1),
				MaxLength:   schemaInt(MaximumTextUTF16Units),
				Pattern:     `^[^\x00]*$`,
			},
		},
		[]string{"type", "text"},
		[]string{"type", "gesture", "text"},
	)
}

func keyPressActionSchema() *jsonschema.Schema {
	return actionObjectSchema(
		map[string]*jsonschema.Schema{
			"type":    actionStringSchema("action type", []any{KeyPressActionType}),
			"gesture": actionGestureSchema(),
			"key": {
				Type:        "string",
				Description: "physical key; only enter is supported",
				Enum:        []any{"enter"},
			},
		},
		[]string{"type", "key"},
		[]string{"type", "gesture", "key"},
	)
}

func actionObjectSchema(properties map[string]*jsonschema.Schema, required, order []string) *jsonschema.Schema {
	return &jsonschema.Schema{
		Type:                 "object",
		Properties:           properties,
		Required:             required,
		AdditionalProperties: &jsonschema.Schema{Not: &jsonschema.Schema{}},
		PropertyOrder:        order,
	}
}

func actionStringSchema(description string, enum []any) *jsonschema.Schema {
	return &jsonschema.Schema{Type: "string", Description: description, Enum: enum}
}

func actionGestureSchema() *jsonschema.Schema {
	return &jsonschema.Schema{
		Type:        "string",
		Description: "input gesture; defaults to release when omitted",
		Enum:        []any{profile.PressGesture, profile.ReleaseGesture},
		Default:     json.RawMessage(`"release"`),
	}
}

func stableIDActionSchema(description string) *jsonschema.Schema {
	field := &jsonschema.Schema{Type: "string", Description: description}
	configureStableIDSchema(field)
	return field
}

const (
	profileActionType = "activate_profile"
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
