package configedit

import (
	"bytes"
	"strings"
	"testing"

	"hidhogg/internal/config"
)

func TestListProfilePositionsReturnsCoordinateIdentityInWireOrder(t *testing.T) {
	positions, err := ListProfilePositions(profileLabelFixture, "room.alternate")
	if err != nil {
		t.Fatal(err)
	}
	if len(positions) != config.RequiredPositionCount {
		t.Fatalf("position count = %d, want %d", len(positions), config.RequiredPositionCount)
	}
	if positions[0] != (PositionReference{ID: "0_0", Position: "0_0"}) || positions[1] != (PositionReference{ID: "1_0", Position: "1_0"}) {
		t.Fatalf("first position references = %+v", positions[:2])
	}
	if positions[len(positions)-1] != (PositionReference{ID: "3_2", Position: "3_2"}) {
		t.Fatalf("last position reference = %+v", positions[len(positions)-1])
	}
	for _, position := range positions {
		if position.ID == "" || position.ID != position.Position {
			t.Fatalf("coordinate identity differs in %+v", position)
		}
	}
}

func TestPositionLabelsResolveAndUpdateByKeyWithoutChangingUnrelatedSource(t *testing.T) {
	primary, err := GetPositionLabel(profileLabelFixture, "primary", "0_0")
	if err != nil {
		t.Fatal(err)
	}
	alternate, err := GetPositionLabel(profileLabelFixture, "room.alternate", "0_0")
	if err != nil {
		t.Fatal(err)
	}
	if primary != "Clock" || alternate != "Alt Clock" {
		t.Fatalf("labels for profile-local 0_0 coordinates = %q, %q", primary, alternate)
	}

	for _, lineEnding := range []struct {
		name string
		from []byte
		to   []byte
	}{
		{name: "LF", from: []byte("\n"), to: []byte("\n")},
		{name: "CRLF", from: []byte("\n"), to: []byte("\r\n")},
	} {
		t.Run(lineEnding.name, func(t *testing.T) {
			source := bytes.ReplaceAll(profileLabelFixture, lineEnding.from, lineEnding.to)
			want := bytes.Replace(source, []byte("label = \"Alt Clock\""), []byte("label = 'Control Clock'"), 1)

			updated, err := UpdatePositionLabel(source, "room.alternate", "0_0", "Control Clock")
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(updated, want) {
				t.Fatal("position label update changed bytes outside the selected value")
			}
			label, err := GetPositionLabel(updated, "room.alternate", "0_0")
			if err != nil || label != "Control Clock" {
				t.Fatalf("updated position label = %q, err = %v", label, err)
			}
			unchanged, err := GetPositionLabel(updated, "primary", "0_0")
			if err != nil || unchanged != "Clock" {
				t.Fatalf("other profile position label = %q, err = %v", unchanged, err)
			}
		})
	}

	want := bytes.Replace(profileLabelFixture, []byte("label = \"Clock\""), []byte("label = 'Inline Clock'"), 1)
	updated, err := UpdatePositionLabel(profileLabelFixture, "primary", "0_0", "Inline Clock")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(updated, want) {
		t.Fatal("inline tile label update changed bytes outside the selected value")
	}
}

func TestUpdatePositionLabelNoOpPreservesBytesAndOwnership(t *testing.T) {
	source := bytes.Clone(profileLabelFixture)
	updated, err := UpdatePositionLabel(source, "room.alternate", "0_0", "Alt Clock")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(updated, source) {
		t.Fatal("no-op changed source bytes")
	}
	if len(updated) == 0 || &updated[0] == &source[0] {
		t.Fatal("no-op result aliases source bytes")
	}
	updated[0] = ' '
	if source[0] != '#' {
		t.Fatal("mutating no-op result changed source bytes")
	}
}

func TestUpdatePositionLabelUsesCoordinateAfterSourceReordering(t *testing.T) {
	clockHeader := []byte("[profiles.\"room.alternate\".positions.\"0_0\"]")
	calendarHeader := []byte("[profiles.\"room.alternate\".positions.\"1_0\"]")
	timerHeader := []byte("[profiles.\"room.alternate\".positions.\"2_0\"]")
	clockStart := bytes.Index(profileLabelFixture, clockHeader)
	calendarStart := bytes.Index(profileLabelFixture, calendarHeader)
	timerStart := bytes.Index(profileLabelFixture, timerHeader)
	if clockStart < 0 || calendarStart < 0 || timerStart < 0 || !(clockStart < calendarStart && calendarStart < timerStart) {
		t.Fatal("fixture position tables are not in expected source order")
	}

	reordered := make([]byte, 0, len(profileLabelFixture))
	reordered = append(reordered, profileLabelFixture[:clockStart]...)
	reordered = append(reordered, profileLabelFixture[calendarStart:timerStart]...)
	reordered = append(reordered, profileLabelFixture[clockStart:calendarStart]...)
	reordered = append(reordered, profileLabelFixture[timerStart:]...)
	configuration, err := config.Decode(reordered)
	if err != nil {
		t.Fatalf("reordered fixture is invalid: %v", err)
	}
	if configuration.Profiles[1].Positions[0].ID != "0_0" || configuration.Profiles[1].Positions[1].ID != "1_0" {
		t.Fatalf("normalized coordinate order = %q, %q", configuration.Profiles[1].Positions[0].ID, configuration.Profiles[1].Positions[1].ID)
	}

	want := bytes.Replace(reordered, []byte("label = \"Alt Clock\""), []byte("label = 'Stable coordinate edit'"), 1)
	updated, err := UpdatePositionLabel(reordered, "room.alternate", "0_0", "Stable coordinate edit")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(updated, want) {
		t.Fatal("position update did not change only the value for the selected coordinate")
	}
}

func TestUpdatePositionLabelPreservesInlineComment(t *testing.T) {
	source := bytes.Replace(profileLabelFixture, []byte("label = \"Alt Clock\""), []byte("label = \"Alt Clock\" # Keep the position note."), 1)
	want := bytes.Replace(source, []byte("label = \"Alt Clock\" # Keep the position note."), []byte("label = 'Renamed Clock' # Keep the position note."), 1)
	updated, err := UpdatePositionLabel(source, "room.alternate", "0_0", "Renamed Clock")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(updated, want) {
		t.Fatal("position label update did not preserve its inline comment and surrounding source")
	}
}

func TestUpdatePositionLabelInsertsOmittedLabelAndAllowsExplicitBlank(t *testing.T) {
	source := bytes.Replace(profileLabelFixture, []byte("label = \"Alt Clock\"\n"), nil, 1)
	if _, err := config.Decode(source); err != nil {
		t.Fatalf("omitted-label fixture is invalid: %v", err)
	}
	unchanged, err := UpdatePositionLabel(source, "room.alternate", "0_0", "")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(unchanged, source) {
		t.Fatal("blank semantic no-op inserted an omitted label")
	}

	updated, err := UpdatePositionLabel(source, "room.alternate", "0_0", "Restored Clock")
	if err != nil {
		t.Fatal(err)
	}
	label, err := GetPositionLabel(updated, "room.alternate", "0_0")
	if err != nil || label != "Restored Clock" {
		t.Fatalf("inserted position label = %q, err = %v", label, err)
	}
	for _, preserved := range [][]byte{
		[]byte("label  =  \"Alternate\"  # Keep this trailing comment and spacing."),
		[]byte("[profiles.\"room.alternate\".positions.\"1_0\"]"),
		[]byte("background = \"#4e481d\""),
	} {
		if !bytes.Contains(updated, preserved) {
			t.Fatalf("inserting a label changed unrelated source bytes %q", preserved)
		}
	}

	blank, err := UpdatePositionLabel(updated, "room.alternate", "0_0", "")
	if err != nil {
		t.Fatalf("explicit blank label was rejected: %v", err)
	}
	label, err = GetPositionLabel(blank, "room.alternate", "0_0")
	if err != nil || label != "" {
		t.Fatalf("explicit blank position label = %q, err = %v", label, err)
	}
	if !bytes.Contains(blank, []byte("label = \"\"")) && !bytes.Contains(blank, []byte("label = ''")) {
		t.Fatal("blank-label update did not insert an explicit empty label")
	}
}

func TestUpdatePositionLabelInsertsOmittedTileAndPositionsTable(t *testing.T) {
	source := []byte("schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = 80\ndefault_profile_id = \"primary\"\nprofiles = { primary = { label = \"Primary\" } } # Keep inline profile comment.\n")
	if _, err := config.Decode(source); err != nil {
		t.Fatalf("sparse fixture is invalid: %v", err)
	}

	updated, err := UpdatePositionLabel(source, "primary", "3_2", "Wide Status")
	if err != nil {
		t.Fatal(err)
	}
	label, err := GetPositionLabel(updated, "primary", "3_2")
	if err != nil || label != "Wide Status" {
		t.Fatalf("inserted sparse position label = %q, err = %v", label, err)
	}
	if !bytes.Contains(updated, []byte("# Keep inline profile comment.")) {
		t.Fatal("sparse edit removed the unrelated inline-profile comment")
	}
	if !bytes.Contains(updated, []byte("positions")) || !bytes.Contains(updated, []byte("3_2")) {
		t.Fatalf("sparse edit did not insert the positions table and coordinate: %s", updated)
	}
}

func TestUpdatePositionLabelInsertsIntoEmptyAndMissingInlineTiles(t *testing.T) {
	source := []byte("schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = 80\ndefault_profile_id = \"primary\"\nprofiles = { primary = { label = \"Primary\", positions = { \"0_0\" = {}, \"1_0\" = { label = \"Calendar\" } } } } # Keep inline profile comment.\n")
	if _, err := config.Decode(source); err != nil {
		t.Fatalf("inline sparse fixture is invalid: %v", err)
	}

	updated, err := UpdatePositionLabel(source, "primary", "0_0", "Empty Tile")
	if err != nil {
		t.Fatal(err)
	}
	updated, err = UpdatePositionLabel(updated, "primary", "3_2", "Missing Tile")
	if err != nil {
		t.Fatal(err)
	}
	for _, coordinate := range []string{"0_0", "3_2"} {
		label, err := GetPositionLabel(updated, "primary", coordinate)
		if err != nil || label == "" {
			t.Fatalf("inserted label at %s = %q, err = %v", coordinate, label, err)
		}
	}
	if !bytes.Contains(updated, []byte("\"1_0\" = { label = \"Calendar\" }")) || !bytes.Contains(updated, []byte("# Keep inline profile comment.")) {
		t.Fatal("inline sparse edit changed an unrelated tile or profile comment")
	}
}

func TestPositionLabelOperationsRejectInvalidSourceAndArguments(t *testing.T) {
	malformed := append(bytes.Clone(profileLabelFixture), []byte("\nunclosed = [")...)
	invalid := bytes.Replace(profileLabelFixture, []byte("label = \"Alt Clock\""), []byte("label = \"\\n\""), 1)
	for _, test := range []struct {
		name       string
		source     []byte
		profileID  string
		positionID string
		label      string
	}{
		{name: "malformed source", source: malformed, profileID: "room.alternate", positionID: "0_0", label: "Updated"},
		{name: "invalid source position label", source: invalid, profileID: "room.alternate", positionID: "0_0", label: "Updated"},
		{name: "unknown profile", source: profileLabelFixture, profileID: "missing", positionID: "0_0", label: "Updated"},
		{name: "unknown coordinate", source: profileLabelFixture, profileID: "room.alternate", positionID: "missing", label: "Updated"},
		{name: "control character in label", source: profileLabelFixture, profileID: "room.alternate", positionID: "0_0", label: "bad\nlabel"},
		{name: "overlong label", source: profileLabelFixture, profileID: "room.alternate", positionID: "0_0", label: strings.Repeat("a", config.MaximumLabelRunes+1)},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := UpdatePositionLabel(test.source, test.profileID, test.positionID, test.label); err == nil {
				t.Fatal("UpdatePositionLabel accepted invalid source or arguments")
			}
		})
	}

	if _, err := ListProfilePositions(profileLabelFixture, "missing"); err == nil {
		t.Fatal("ListProfilePositions accepted an unknown profile ID")
	}
	if _, err := GetPositionLabel(profileLabelFixture, "room.alternate", "missing"); err == nil {
		t.Fatal("GetPositionLabel accepted an unknown coordinate")
	}
}
