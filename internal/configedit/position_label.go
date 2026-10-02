package configedit

import (
	"bytes"
	"fmt"

	"hidhogg/internal/config"

	"github.com/pelletier/go-toml/v2/unstable/edit"
)

type PositionReference struct {
	ID       string
	Position string
}

func ListProfilePositions(source []byte, profileID string) ([]PositionReference, error) {
	decoded, err := config.Decode(source)
	if err != nil {
		return nil, fmt.Errorf("decode configuration before position listing: %w", err)
	}

	profile, ok := profileByID(decoded, profileID)
	if !ok {
		return nil, fmt.Errorf("profile ID %q does not resolve to a profile", profileID)
	}

	positions := make([]PositionReference, len(profile.Positions))
	for index, position := range profile.Positions {
		positions[index] = PositionReference{ID: position.ID, Position: position.Position}
	}
	return positions, nil
}

func GetPositionLabel(source []byte, profileID, positionID string) (string, error) {
	position, err := resolvePosition(source, profileID, positionID)
	if err != nil {
		return "", err
	}
	return position.Label, nil
}

func UpdatePositionLabel(source []byte, profileID, positionID, label string) ([]byte, error) {
	position, err := resolvePosition(source, profileID, positionID)
	if err != nil {
		return nil, err
	}
	if position.Label == label {
		return bytes.Clone(source), nil
	}

	document, err := edit.Parse(source)
	if err != nil {
		return nil, fmt.Errorf("parse configuration for position label update: %w", err)
	}
	path := []string{"profiles", profileID, "positions", position.Position, "label"}
	if err := document.Set(path, label); err != nil {
		return nil, fmt.Errorf("update position label: %w", err)
	}

	updated := document.Bytes()
	if _, err := config.Decode(updated); err != nil {
		return nil, fmt.Errorf("validate configuration after position label update: %w", err)
	}
	return updated, nil
}

func resolvePosition(source []byte, profileID, positionID string) (config.Position, error) {
	decoded, err := config.Decode(source)
	if err != nil {
		return config.Position{}, fmt.Errorf("decode configuration before position label operation: %w", err)
	}
	profile, ok := profileByID(decoded, profileID)
	if !ok {
		return config.Position{}, fmt.Errorf("profile ID %q does not resolve to a profile", profileID)
	}
	for _, position := range profile.Positions {
		if position.ID == positionID {
			return position, nil
		}
	}
	return config.Position{}, fmt.Errorf("position ID %q does not resolve within profile %q", positionID, profileID)
}
