package configedit

import (
	"bytes"
	"fmt"

	"hidhogg/internal/config"
	neutralprofile "hidhogg/internal/profile"

	toml "github.com/pelletier/go-toml/v2"
	"github.com/pelletier/go-toml/v2/unstable/edit"
)

const defaultBackground = "#000000"

type appendedProfileDocument struct {
	Profiles map[string]profileDocument `toml:"profiles"`
}

type profileDocument struct {
	Label     string                      `toml:"label"`
	Positions map[string]positionDocument `toml:"positions,omitempty"`
}

type positionDocument struct {
	Label               string          `toml:"label,omitempty"`
	Background          string          `toml:"background,omitempty"`
	NotificationSources []string        `toml:"notification_sources,omitempty"`
	LabelAlignment      string          `toml:"label_alignment,omitempty"`
	LabelSize           int             `toml:"label_size,omitempty"`
	Action              *actionDocument `toml:"action,omitempty"`
}

type actionDocument struct {
	Type           string   `toml:"type"`
	Gesture        string   `toml:"gesture,omitempty"`
	ProfileID      string   `toml:"profile_id,omitempty"`
	Executable     string   `toml:"executable,omitempty"`
	Arguments      []string `toml:"arguments,omitempty"`
	TimeoutSeconds int      `toml:"timeout_seconds,omitempty"`
	Text           string   `toml:"text,omitempty"`
	Key            string   `toml:"key,omitempty"`
}

// CloneProfile appends a canonical semantic clone of an existing profile.
func CloneProfile(source []byte, sourceID, newID, newLabel string) ([]byte, error) {
	decoded, err := config.Decode(source)
	if err != nil {
		return nil, fmt.Errorf("decode configuration before profile clone: %w", err)
	}
	if len(decoded.Profiles) >= config.MaximumProfileCount {
		return nil, fmt.Errorf("cannot clone profile: configuration already has %d profiles", config.MaximumProfileCount)
	}

	sourceProfile, exists := profileByID(decoded, sourceID)
	if !exists {
		return nil, fmt.Errorf("source profile ID %q does not resolve to a profile", sourceID)
	}
	if _, exists := profileByID(decoded, newID); exists {
		return nil, fmt.Errorf("new profile ID %q already resolves to a profile", newID)
	}

	clone := cloneProfileValue(sourceProfile)
	clone.ID = newID
	clone.Label = newLabel

	block, err := toml.Marshal(appendedProfileDocument{
		Profiles: map[string]profileDocument{newID: profileDocumentForClone(clone)},
	})
	if err != nil {
		return nil, fmt.Errorf("marshal cloned profile: %w", err)
	}
	profileRoot := []byte("[profiles]\n")
	if !bytes.HasPrefix(block, profileRoot) {
		return nil, fmt.Errorf("marshal cloned profile: generated source has no profiles root table")
	}
	block = block[len(profileRoot):]
	lineEnding := sourceLineEnding(source)
	block = convertLineEndings(block, lineEnding)
	updated := make([]byte, 0, len(source)+len(block)+2*len(lineEnding))
	updated = append(updated, source...)
	updated = append(updated, profileSeparator(source, lineEnding)...)
	updated = append(updated, block...)
	if !bytes.HasSuffix(updated, lineEnding) {
		updated = append(updated, lineEnding...)
	}
	if _, err := config.Decode(updated); err == nil {
		return updated, nil
	}

	// An inline root profiles value cannot be extended with a [profiles.*] header.
	document, err := edit.Parse(source)
	if err != nil {
		return nil, fmt.Errorf("parse configuration for profile clone: %w", err)
	}
	if err := document.Set([]string{"profiles", newID}, profileDocumentForClone(clone)); err != nil {
		return nil, fmt.Errorf("append cloned profile: %w", err)
	}
	updated = document.Bytes()
	if _, err := config.Decode(updated); err != nil {
		return nil, fmt.Errorf("validate configuration after profile clone: %w", err)
	}
	return updated, nil
}

func profileDocumentForClone(source config.Profile) profileDocument {
	result := profileDocument{Label: source.Label}
	positions := make(map[string]positionDocument, len(source.Positions))
	for _, position := range source.Positions {
		positionDocument, include := positionDocumentForClone(position)
		if include {
			positions[position.Position] = positionDocument
		}
	}
	if len(positions) > 0 {
		result.Positions = positions
	}
	return result
}

func positionDocumentForClone(position config.Position) (positionDocument, bool) {
	result := positionDocument{}
	if position.Label != "" {
		result.Label = position.Label
	}
	if position.Background != defaultBackground {
		result.Background = position.Background
	}
	if len(position.NotificationSources) > 0 {
		result.NotificationSources = append([]string(nil), position.NotificationSources...)
	}
	if position.LabelAlignment != config.DefaultLabelAlignment {
		result.LabelAlignment = position.LabelAlignment
	}
	if position.LabelSize != config.DefaultLabelSize {
		result.LabelSize = position.LabelSize
	}
	if position.Action != nil {
		action := position.Action
		result.Action = &actionDocument{
			Type:       action.Type,
			Gesture:    action.Gesture,
			ProfileID:  action.ProfileID,
			Executable: action.Executable,
			Arguments:  append([]string(nil), action.Arguments...),
			Text:       action.Text,
			Key:        action.Key,
		}
		if action.Gesture == neutralprofile.DefaultGesture {
			result.Action.Gesture = ""
		}
		if action.TimeoutSeconds != config.DefaultExecuteTimeoutSeconds {
			result.Action.TimeoutSeconds = action.TimeoutSeconds
		}
	}

	return result, result.Label != "" || result.Background != "" || len(result.NotificationSources) > 0 || result.LabelAlignment != "" || result.LabelSize != 0 || result.Action != nil
}

// DeleteProfile removes a profile only when it is neither default nor current
// and no activate_profile action refers to it.
func DeleteProfile(source []byte, targetID, currentID string) ([]byte, error) {
	decoded, err := config.Decode(source)
	if err != nil {
		return nil, fmt.Errorf("decode configuration before profile deletion: %w", err)
	}

	if _, exists := profileByID(decoded, targetID); !exists {
		return nil, fmt.Errorf("target profile ID %q does not resolve to a profile", targetID)
	}
	if _, exists := profileByID(decoded, currentID); !exists {
		return nil, fmt.Errorf("current profile ID %q does not resolve to a profile", currentID)
	}
	if len(decoded.Profiles) <= 1 {
		return nil, fmt.Errorf("cannot delete the last profile")
	}
	if targetID == decoded.DefaultProfileID {
		return nil, fmt.Errorf("cannot delete default profile %q", targetID)
	}
	if targetID == currentID {
		return nil, fmt.Errorf("cannot delete current profile %q", targetID)
	}
	if profileIsReferenced(decoded, targetID) {
		return nil, fmt.Errorf("cannot delete profile %q because an activate_profile action refers to it", targetID)
	}

	document, err := edit.Parse(source)
	if err != nil {
		return nil, fmt.Errorf("parse configuration for profile deletion: %w", err)
	}
	if !document.Delete([]string{"profiles", targetID}) {
		return nil, fmt.Errorf("profile %q was not deleted", targetID)
	}

	updated := document.Bytes()
	if _, err := config.Decode(updated); err != nil {
		return nil, fmt.Errorf("validate configuration after profile deletion: %w", err)
	}
	return updated, nil
}

func profileByID(decoded config.Config, profileID string) (config.Profile, bool) {
	for _, profile := range decoded.Profiles {
		if profile.ID == profileID {
			return profile, true
		}
	}
	return config.Profile{}, false
}

func cloneProfileValue(source config.Profile) config.Profile {
	clone := source
	clone.Positions = append([]config.Position(nil), source.Positions...)
	for index := range clone.Positions {
		position := &clone.Positions[index]
		position.NotificationSources = append([]string(nil), position.NotificationSources...)
		if position.Action == nil {
			continue
		}
		action := *position.Action
		action.Arguments = append([]string(nil), action.Arguments...)
		position.Action = &action
	}
	return clone
}

func profileIsReferenced(decoded config.Config, profileID string) bool {
	for _, profile := range decoded.Profiles {
		for _, position := range profile.Positions {
			if position.Action != nil && position.Action.Type == "activate_profile" && position.Action.ProfileID == profileID {
				return true
			}
		}
	}
	return false
}

func sourceLineEnding(source []byte) []byte {
	index := bytes.IndexByte(source, '\n')
	if index > 0 && source[index-1] == '\r' {
		return []byte("\r\n")
	}
	return []byte("\n")
}

func profileSeparator(source, lineEnding []byte) []byte {
	if bytes.HasSuffix(source, []byte("\n\n")) || bytes.HasSuffix(source, []byte("\r\n\r\n")) {
		return nil
	}
	if bytes.HasSuffix(source, []byte("\n")) {
		return lineEnding
	}
	separator := make([]byte, 0, 2*len(lineEnding))
	separator = append(separator, lineEnding...)
	return append(separator, lineEnding...)
}

func convertLineEndings(source, lineEnding []byte) []byte {
	lf := bytes.ReplaceAll(source, []byte("\r\n"), []byte("\n"))
	return bytes.ReplaceAll(lf, []byte("\n"), lineEnding)
}
