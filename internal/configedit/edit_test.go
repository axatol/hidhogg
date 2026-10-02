package configedit

import (
	"bytes"
	_ "embed"
	"strings"
	"testing"

	"hidhogg/internal/config"
)

//go:embed testdata/profile-label.toml
var profileLabelFixture []byte

func TestUpdateProfileLabelPreservesUnrelatedSource(t *testing.T) {
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
			want := bytes.Replace(source, []byte("label  =  \"Alternate\""), []byte("label  =  'Control Room'"), 1)

			got, err := UpdateProfileLabel(source, "room.alternate", "Control Room")
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, want) {
				t.Fatal("updated source differs from the single expected value-token change")
			}

			decoded, err := config.Decode(got)
			if err != nil {
				t.Fatalf("updated source does not decode: %v", err)
			}
			if decoded.Profiles[0].Label != "Primary" || decoded.Profiles[1].Label != "Control Room" {
				t.Fatalf("profile labels = %q, %q", decoded.Profiles[0].Label, decoded.Profiles[1].Label)
			}
		})
	}
}

func TestUpdateProfileLabelEditsOneLineInlineProfileByKey(t *testing.T) {
	source := bytes.Clone(profileLabelFixture)
	want := bytes.Replace(source, []byte("label = \"Primary\""), []byte("label = 'Control Room'"), 1)
	updated, err := UpdateProfileLabel(source, "primary", "Control Room")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(updated, want) {
		t.Fatal("inline profile label update changed bytes outside the selected value")
	}
	decoded, err := config.Decode(updated)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Profiles[0].Label != "Control Room" || decoded.Profiles[1].Label != "Alternate" {
		t.Fatalf("profile labels = %q, %q", decoded.Profiles[0].Label, decoded.Profiles[1].Label)
	}
}

func TestUpdateProfileLabelRejectsInvalidSourceAndArguments(t *testing.T) {
	duplicateID := bytes.Replace(profileLabelFixture, []byte("[profiles.\"room.alternate\"]"), []byte("[profiles.primary]"), 1)
	invalidSourceID := bytes.Replace(profileLabelFixture, []byte("[profiles.\"room.alternate\"]"), []byte("[profiles.\"bad id\"]"), 1)
	invalidSourceLabel := bytes.Replace(profileLabelFixture, []byte("label  =  \"Alternate\""), []byte("label  =  \"\""), 1)

	for _, test := range []struct {
		name      string
		source    []byte
		profileID string
		label     string
	}{
		{name: "duplicate source profile ID", source: duplicateID, profileID: "room.alternate", label: "Updated"},
		{name: "invalid source profile ID", source: invalidSourceID, profileID: "room.alternate", label: "Updated"},
		{name: "invalid source profile label", source: invalidSourceLabel, profileID: "room.alternate", label: "Updated"},
		{name: "invalid requested profile ID", source: profileLabelFixture, profileID: "bad id", label: "Updated"},
		{name: "unknown requested profile ID", source: profileLabelFixture, profileID: "missing", label: "Updated"},
		{name: "empty requested profile ID", source: profileLabelFixture, profileID: "", label: "Updated"},
		{name: "empty new label", source: profileLabelFixture, profileID: "room.alternate", label: ""},
		{name: "overlong new label", source: profileLabelFixture, profileID: "room.alternate", label: strings.Repeat("a", config.MaximumLabelRunes+1)},
		{name: "control character in new label", source: profileLabelFixture, profileID: "room.alternate", label: "bad\nlabel"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := UpdateProfileLabel(test.source, test.profileID, test.label); err == nil {
				t.Fatal("UpdateProfileLabel unexpectedly accepted invalid input")
			}
		})
	}
}

func TestUpdateProfileLabelNoOpPreservesBytesAndOwnership(t *testing.T) {
	source := bytes.Clone(profileLabelFixture)
	got, err := UpdateProfileLabel(source, "room.alternate", "Alternate")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, source) {
		t.Fatal("no-op changed the source bytes")
	}
	if len(got) == 0 || &got[0] == &source[0] {
		t.Fatal("no-op result aliases source bytes")
	}
	got[0] = ' '
	if source[0] != '#' {
		t.Fatal("mutating no-op result changed the source bytes")
	}
}

func TestUpdateProfileLabelErrorsOmitSourceActionValues(t *testing.T) {
	sentinel := "SOURCE_ACTION_SENTINEL_9f4c"
	source := bytes.Replace(
		profileLabelFixture,
		[]byte("type = \"activate_profile\", gesture = \"release\", profile_id = \"primary\""),
		[]byte("type = \"type_text\", text = \""+sentinel+"\""),
		1,
	)
	if !bytes.Contains(source, []byte(sentinel)) {
		t.Fatal("sentinel action value was not inserted into the fixture")
	}
	if _, err := config.Decode(source); err != nil {
		t.Fatal("sentinel action fixture is not valid configuration")
	}

	malformedSource := append(bytes.Clone(source), []byte("\nunclosed = [")...)
	invalidSource := bytes.Replace(source, []byte("type = \"type_text\""), []byte("type = \"unknown_action\""), 1)
	for _, test := range []struct {
		name   string
		source []byte
		label  string
	}{
		{name: "malformed TOML", source: malformedSource, label: "Updated"},
		{name: "invalid TOML", source: invalidSource, label: "Updated"},
		{name: "invalid label edit", source: source, label: "bad\nlabel"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := UpdateProfileLabel(test.source, "room.alternate", test.label); err == nil {
				t.Fatal("UpdateProfileLabel unexpectedly accepted invalid input")
			} else if strings.Contains(err.Error(), sentinel) {
				t.Fatal("UpdateProfileLabel error included a source action value")
			}
		})
	}
}
