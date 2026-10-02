package configedit

import (
	"bytes"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"hidhogg/internal/config"
)

func TestCloneProfileAppendsCanonicalSemanticClone(t *testing.T) {
	for _, test := range []struct {
		name       string
		lineEnding []byte
		eofComment bool
	}{
		{name: "LF", lineEnding: []byte("\n")},
		{name: "LF with EOF comment", lineEnding: []byte("\n"), eofComment: true},
		{name: "CRLF", lineEnding: []byte("\r\n")},
		{name: "CRLF with EOF comment", lineEnding: []byte("\r\n"), eofComment: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			source := lifecycleSource(t)
			source = bytes.ReplaceAll(source, []byte("\n"), test.lineEnding)
			if test.eofComment {
				source = append(source, []byte("# EOF_SOURCE_COMMENT")...)
			}
			original := bytes.Clone(source)
			before, err := config.Decode(source)
			if err != nil {
				t.Fatal(err)
			}
			wantProfile, ok := profileByID(before, "room.alternate")
			if !ok {
				t.Fatal("source profile is missing")
			}
			wantProfile = cloneProfileValue(wantProfile)
			wantProfile.ID = "copy.with.dots"
			wantProfile.Label = "Copied Alternate"

			got, err := CloneProfile(source, "room.alternate", wantProfile.ID, wantProfile.Label)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(source, original) {
				t.Fatal("clone mutated its source bytes")
			}
			if !bytes.HasPrefix(got, source) {
				t.Fatal("clone changed bytes before the appended profile")
			}

			separator := expectedProfileSeparator(source, test.lineEnding)
			appended := got[len(source):]
			if !bytes.HasPrefix(appended, separator) {
				t.Fatal("clone did not add the expected profile separator")
			}
			block := appended[len(separator):]
			if !bytes.Contains(block, []byte("[profiles.'copy.with.dots']")) {
				t.Fatalf("appended profile table is missing: %q", block)
			}
			positionTableCount := 0
			for _, coordinate := range []string{"0_0", "1_0", "2_0", "3_2"} {
				positionTableCount += bytes.Count(block, []byte("[profiles.'copy.with.dots'.positions."+coordinate+"]"))
			}
			if positionTableCount != 4 {
				t.Fatalf("appended position table count = %d, want only 4 configured positions", positionTableCount)
			}
			for _, sourceComment := range []string{
				"Profile keys are immutable IDs, not display labels.",
				"Keep this trailing comment and spacing.",
				"EOF_SOURCE_COMMENT",
			} {
				if bytes.Contains(block, []byte(sourceComment)) {
					t.Fatalf("source comment %q was copied into the clone", sourceComment)
				}
			}
			if !bytes.Contains(block, []byte("notification_sources = ['system.weather', 'system.calendar']")) ||
				!bytes.Contains(block, []byte("label_alignment = 'center'")) ||
				!bytes.Contains(block, []byte("label_size = 18")) ||
				!bytes.Contains(block, []byte("type = 'activate_profile'")) ||
				!bytes.Contains(block, []byte("profile_id = 'primary'")) {
				t.Fatalf("canonical clone omitted optional profile values or action data: %q", block)
			}
			if !bytes.HasSuffix(block, test.lineEnding) {
				t.Fatal("canonical clone is missing its final line ending")
			}
			if bytes.Equal(test.lineEnding, []byte("\r\n")) {
				if bytes.Contains(bytes.ReplaceAll(block, []byte("\r\n"), nil), []byte("\n")) {
					t.Fatal("CRLF clone block contains an LF-only line ending")
				}
			} else if bytes.Contains(block, []byte("\r\n")) {
				t.Fatal("LF clone block contains a CRLF line ending")
			}

			after, err := config.Decode(got)
			if err != nil {
				t.Fatalf("cloned configuration does not decode: %v", err)
			}
			if len(after.Profiles) != len(before.Profiles)+1 {
				t.Fatalf("profile count = %d, want %d", len(after.Profiles), len(before.Profiles)+1)
			}
			gotProfile, ok := profileByID(after, "copy.with.dots")
			if !ok || !reflect.DeepEqual(gotProfile, wantProfile) {
				t.Fatal("clone differs from its source profile beyond ID and label")
			}
		})
	}
}

func TestCloneProfileRejectsInvalidSourceAndRequestedValues(t *testing.T) {
	duplicateSourceID := bytes.Replace(
		lifecycleSource(t),
		[]byte("[profiles.\"room.alternate\"]"),
		[]byte("[profiles.primary]"),
		1,
	)
	for _, test := range []struct {
		name     string
		source   []byte
		sourceID string
		newID    string
		newLabel string
	}{
		{name: "malformed source profile IDs", source: duplicateSourceID, sourceID: "room.alternate", newID: "copy", newLabel: "Copy"},
		{name: "missing source ID", source: lifecycleSource(t), sourceID: "missing", newID: "copy", newLabel: "Copy"},
		{name: "empty source ID", source: lifecycleSource(t), sourceID: "", newID: "copy", newLabel: "Copy"},
		{name: "invalid new ID", source: lifecycleSource(t), sourceID: "primary", newID: "bad id", newLabel: "Copy"},
		{name: "duplicate new ID", source: lifecycleSource(t), sourceID: "primary", newID: "primary", newLabel: "Copy"},
		{name: "empty new ID", source: lifecycleSource(t), sourceID: "primary", newID: "", newLabel: "Copy"},
		{name: "empty label", source: lifecycleSource(t), sourceID: "primary", newID: "copy", newLabel: ""},
		{name: "control character in label", source: lifecycleSource(t), sourceID: "primary", newID: "copy", newLabel: "Bad\nLabel"},
		{name: "overlong label", source: lifecycleSource(t), sourceID: "primary", newID: "copy", newLabel: strings.Repeat("a", config.MaximumLabelRunes+1)},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := CloneProfile(test.source, test.sourceID, test.newID, test.newLabel); err == nil {
				t.Fatal("CloneProfile unexpectedly accepted invalid input")
			}
		})
	}
}

func TestCloneProfilePreservesAllActionVariants(t *testing.T) {
	for _, test := range []struct {
		name        string
		replacement string
	}{
		{name: "activate_profile"},
		{
			name:        "execute",
			replacement: "type = \"execute\", gesture = \"press\", executable = \"/usr/bin/printf\", arguments = [\"copied\"], timeout_seconds = 7",
		},
		{
			name:        "type_text",
			replacement: "type = \"type_text\", gesture = \"press\", text = \"copied text\"",
		},
		{
			name:        "key_press",
			replacement: "type = \"key_press\", gesture = \"release\", key = \"enter\"",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			source := lifecycleSource(t)
			if test.replacement != "" {
				updated := bytes.Replace(
					source,
					[]byte("type = \"activate_profile\", gesture = \"release\", profile_id = \"primary\""),
					[]byte(test.replacement),
					1,
				)
				if bytes.Equal(source, updated) {
					t.Fatal("action variant replacement did not match the fixture")
				}
				source = updated
			}
			before, err := config.Decode(source)
			if err != nil {
				t.Fatalf("action fixture does not decode: %v", err)
			}
			if before.Profiles[1].Positions[0].Action == nil || before.Profiles[1].Positions[0].Action.Type != test.name {
				t.Fatalf("variant fixture action = %#v, want %s", before.Profiles[1].Positions[0].Action, test.name)
			}

			got, err := CloneProfile(source, "room.alternate", "copy", "Copy")
			if err != nil {
				t.Fatal(err)
			}
			after, err := config.Decode(got)
			if err != nil {
				t.Fatalf("clone with %s action does not decode: %v", test.name, err)
			}
			want, ok := profileByID(before, "room.alternate")
			if !ok {
				t.Fatal("source profile is missing")
			}
			want = cloneProfileValue(want)
			want.ID = "copy"
			want.Label = "Copy"
			gotProfile, ok := profileByID(after, "copy")
			if !ok || !reflect.DeepEqual(gotProfile, want) {
				t.Fatalf("clone did not preserve the %s action exactly", test.name)
			}
		})
	}
}

func TestCloneProfileEnforcesMaximumProfileCount(t *testing.T) {
	source := lifecycleSource(t)
	for index := 0; index < config.MaximumProfileCount-2; index++ {
		var err error
		source, err = CloneProfile(
			source,
			"primary",
			fmt.Sprintf("copy-%02d", index),
			fmt.Sprintf("Copy %02d", index),
		)
		if err != nil {
			t.Fatalf("clone %d failed before the profile limit: %v", index, err)
		}
	}
	decoded, err := config.Decode(source)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Profiles) != config.MaximumProfileCount {
		t.Fatalf("profile count = %d, want %d", len(decoded.Profiles), config.MaximumProfileCount)
	}
	if _, err := CloneProfile(source, "primary", "over-limit", "Over Limit"); err == nil {
		t.Fatal("CloneProfile accepted a 32nd profile")
	}
}

func TestCloneProfileAllowsDuplicateLabels(t *testing.T) {
	got, err := CloneProfile(lifecycleSource(t), "primary", "copy", "Alternate")
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := config.Decode(got)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Profiles[1].Label != decoded.Profiles[2].Label {
		t.Fatal("clone did not preserve the caller's valid duplicate label")
	}
}

func TestCloneProfileSupportsInlineProfilesAndOmitsBlankPositions(t *testing.T) {
	source := []byte("schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = 80\ndefault_profile_id = \"primary\"\nprofiles = { primary = { label = \"Primary\" } } # Keep inline profile comment.\n")
	if _, err := config.Decode(source); err != nil {
		t.Fatalf("inline profile fixture is invalid: %v", err)
	}
	profileEntry := []byte("primary = { label = \"Primary\" }")
	entryStart := bytes.Index(source, profileEntry)
	if entryStart < 0 {
		t.Fatal("inline profile fixture does not contain the expected profile entry")
	}
	prefix := bytes.Clone(source[:entryStart])
	suffix := bytes.Clone(source[entryStart+len(profileEntry):])

	updated, err := CloneProfile(source, "primary", "room.copy", "Copy")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(updated, prefix) || !bytes.Contains(updated, profileEntry) || !bytes.HasSuffix(updated, suffix) {
		t.Fatal("inline clone changed bytes outside the inserted profile entry")
	}
	if bytes.Contains(updated, []byte("positions")) {
		t.Fatal("clone emitted a positions table containing only normalized defaults")
	}
	after, err := config.Decode(updated)
	if err != nil {
		t.Fatalf("inline clone does not decode: %v", err)
	}
	want, ok := profileByID(after, "room.copy")
	if !ok || want.Label != "Copy" || len(want.Positions) != config.RequiredPositionCount {
		t.Fatalf("inline clone was not normalized as a full profile: %+v", want)
	}
}

func TestDeleteProfilePreservesUnrelatedBytesAndRemovesAttachedComments(t *testing.T) {
	for _, lineEnding := range [][]byte{[]byte("\n"), []byte("\r\n")} {
		name := "LF"
		if bytes.Equal(lineEnding, []byte("\r\n")) {
			name = "CRLF"
		}
		t.Run(name, func(t *testing.T) {
			source := deleteLifecycleSource(t, lineEnding)
			original := bytes.Clone(source)
			if _, err := config.Decode(source); err != nil {
				t.Fatalf("delete fixture does not decode: %v", err)
			}

			targetComment := bytes.Index(source, []byte("# TARGET_ONLY_COMMENT"))
			if targetComment < 0 {
				t.Fatal("target comment missing from fixture")
			}
			nextProfileHeader := bytes.Index(source, []byte("[profiles.clone-two]"+string(lineEnding)))
			if nextProfileHeader < 0 {
				t.Fatal("following profile missing from fixture")
			}
			prefix := bytes.Clone(source[:targetComment])
			suffix := bytes.Clone(source[nextProfileHeader:])

			got, err := DeleteProfile(source, "clone", "primary")
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(source, original) {
				t.Fatal("deletion mutated its source bytes")
			}
			if !bytes.HasPrefix(got, prefix) {
				t.Fatal("deletion changed unrelated bytes before the target profile")
			}
			if !bytes.Contains(got, suffix) {
				t.Fatal("deletion changed bytes after the target profile")
			}
			if bytes.Contains(got, []byte("TARGET_ONLY_COMMENT")) {
				t.Fatal("deletion retained a comment attached to the target profile")
			}
			for _, unrelatedComment := range []string{
				"Profile keys are immutable IDs, not display labels.",
				"Keep this trailing comment and spacing.",
				"UNRELATED_EOF_COMMENT",
			} {
				if !bytes.Contains(got, []byte(unrelatedComment)) {
					t.Fatalf("deletion removed unrelated comment %q", unrelatedComment)
				}
			}
			if bytes.Equal(lineEnding, []byte("\r\n")) {
				if bytes.Contains(bytes.ReplaceAll(got, []byte("\r\n"), nil), []byte("\n")) {
					t.Fatal("CRLF deletion output contains an LF-only line ending")
				}
			}

			decoded, err := config.Decode(got)
			if err != nil {
				t.Fatalf("deleted configuration does not decode: %v", err)
			}
			_, cloneExists := profileByID(decoded, "clone")
			_, secondCloneExists := profileByID(decoded, "clone-two")
			if len(decoded.Profiles) != 3 || cloneExists || !secondCloneExists {
				t.Fatalf("unexpected remaining profiles after deletion: %d", len(decoded.Profiles))
			}
		})
	}
}

func TestDeleteProfileRemovesKeyFromInlineProfilesAndPreservesRemainingSource(t *testing.T) {
	source := []byte("schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = 80\ndefault_profile_id = \"primary\"\nprofiles = { primary = { label = \"Primary\" }, \"room.to-delete\" = { label = \"Remove\" } } # Keep inline profiles comment.\n")
	if _, err := config.Decode(source); err != nil {
		t.Fatalf("inline delete fixture is invalid: %v", err)
	}

	updated, err := DeleteProfile(source, "room.to-delete", "primary")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(updated, []byte("primary = { label = \"Primary\" }")) || !bytes.Contains(updated, []byte("# Keep inline profiles comment.")) {
		t.Fatal("inline deletion changed the retained profile or surrounding comment")
	}
	if bytes.Contains(updated, []byte("room.to-delete")) {
		t.Fatal("inline deletion retained the target profile key")
	}
	decoded, err := config.Decode(updated)
	if err != nil {
		t.Fatalf("deleted inline profiles do not decode: %v", err)
	}
	if len(decoded.Profiles) != 1 || decoded.Profiles[0].ID != "primary" {
		t.Fatalf("remaining inline profiles = %+v", decoded.Profiles)
	}
}

func TestDeleteProfileRefusesUnsafeTargets(t *testing.T) {
	malformedSource := append(bytes.Clone(lifecycleSource(t)), []byte("\nunclosed = [")...)
	duplicateSourceIDs := bytes.Replace(
		lifecycleSource(t),
		[]byte("[profiles.\"room.alternate\"]"),
		[]byte("[profiles.primary]"),
		1,
	)
	for _, test := range []struct {
		name     string
		source   []byte
		targetID string
		current  string
	}{
		{name: "malformed source", source: malformedSource, targetID: "room.alternate", current: "primary"},
		{name: "duplicate source profile IDs", source: duplicateSourceIDs, targetID: "room.alternate", current: "primary"},
		{name: "default profile", source: lifecycleSource(t), targetID: "primary", current: "room.alternate"},
		{name: "current profile", source: lifecycleSource(t), targetID: "room.alternate", current: "room.alternate"},
		{name: "activate profile reference", source: lifecycleSource(t), targetID: "room.alternate", current: "primary"},
		{name: "missing target ID", source: lifecycleSource(t), targetID: "missing", current: "primary"},
		{name: "invalid target ID", source: lifecycleSource(t), targetID: "bad id", current: "primary"},
		{name: "unknown current ID", source: lifecycleSource(t), targetID: "room.alternate", current: "missing"},
		{name: "empty current ID", source: lifecycleSource(t), targetID: "room.alternate", current: ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DeleteProfile(test.source, test.targetID, test.current); err == nil {
				t.Fatal("DeleteProfile unexpectedly accepted unsafe input")
			}
		})
	}
}

func TestDeleteProfileRefusesLastProfile(t *testing.T) {
	source := []byte("schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = 80\ndefault_profile_id = \"primary\"\n[profiles.primary]\nlabel = \"Primary\"\n")
	if _, err := DeleteProfile(source, "primary", "primary"); err == nil || !strings.Contains(err.Error(), "last profile") {
		t.Fatalf("DeleteProfile error = %v, want last-profile refusal", err)
	}
}

func lifecycleSource(t *testing.T) []byte {
	t.Helper()
	source := bytes.Replace(
		profileLabelFixture,
		[]byte("background = \"#4e481d\"\n"),
		[]byte("background = \"#4e481d\"\nnotification_sources = [\"system.weather\", \"system.calendar\"]\nlabel_alignment = \"center\"\nlabel_size = 18\n"),
		1,
	)
	if bytes.Equal(source, profileLabelFixture) {
		t.Fatal("optional style and source fields were not added to the lifecycle fixture")
	}
	return bytes.Clone(source)
}

func deleteLifecycleSource(t *testing.T, lineEnding []byte) []byte {
	t.Helper()
	source := bytes.ReplaceAll(lifecycleSource(t), []byte("\n"), lineEnding)
	firstClone, err := CloneProfile(source, "primary", "clone", "Clone")
	if err != nil {
		t.Fatal(err)
	}
	cloneHeader := []byte("[profiles.clone]" + string(lineEnding))
	cloneHeaderWithComment := []byte("# TARGET_ONLY_COMMENT" + string(lineEnding) + string(cloneHeader))
	withTargetComment := bytes.Replace(firstClone, cloneHeader, cloneHeaderWithComment, 1)
	if bytes.Equal(withTargetComment, firstClone) {
		t.Fatalf("target profile header %q not found in appended block %q", cloneHeader, firstClone[len(source):])
	}
	secondClone, err := CloneProfile(withTargetComment, "primary", "clone-two", "Clone Two")
	if err != nil {
		t.Fatal(err)
	}
	return append(secondClone, []byte("# UNRELATED_EOF_COMMENT")...)
}

func expectedProfileSeparator(source, lineEnding []byte) []byte {
	if bytes.HasSuffix(source, []byte("\n\n")) || bytes.HasSuffix(source, []byte("\r\n\r\n")) {
		return nil
	}
	if bytes.HasSuffix(source, []byte("\n")) {
		return lineEnding
	}
	separator := append([]byte(nil), lineEnding...)
	return append(separator, lineEnding...)
}
