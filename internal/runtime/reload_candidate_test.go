package runtime

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	appconfig "hidhogg/internal/config"
)

func TestBuildReloadCandidateRejectsInvalidAndUnreadableConfiguration(t *testing.T) {
	base := reloadTestConfiguration()

	for _, test := range []struct {
		name     string
		data     []byte
		path     string
		category appconfig.DiagnosticCategory
	}{
		{name: "invalid", data: bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 101"), 1), category: appconfig.DiagnosticValidation},
		{name: "unreadable", path: filepath.Join(t.TempDir(), "missing.toml"), category: appconfig.DiagnosticReadNotFound},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := test.path
			if path == "" {
				path = writeReloadConfiguration(t, test.data)
			}
			_, err := buildReloadCandidate(path, "default")
			var diagnostic *appconfig.Diagnostic
			if !errors.As(err, &diagnostic) || diagnostic.Category != test.category || diagnostic.Path != path {
				t.Fatalf("buildReloadCandidate diagnostic = %#v, %v", diagnostic, err)
			}
		})
	}
}

func TestReloadCandidateAndEffectsIdenticalConfiguration(t *testing.T) {
	base := reloadTestConfiguration()
	current := buildReloadCandidateForTest(t, base, "default")
	candidate := buildReloadCandidateForTest(t, base, "default")

	diff := compareReloadCandidate(current, candidate)
	if diff.Effect() != reloadEffectUnchanged {
		t.Fatalf("effect = %q, want %q", diff.Effect(), reloadEffectUnchanged)
	}
	if diff.anyChanged() {
		t.Fatalf("identical diff = %#v", diff)
	}
	if candidate.CurrentProfileFallback() {
		t.Fatal("identical candidate unexpectedly fell back")
	}
}

func TestBuildReloadCandidateFromBytesMatchesPathCandidate(t *testing.T) {
	data := reloadTestConfiguration()
	pathCandidate := buildReloadCandidateForTest(t, data, "default")
	byteCandidate, err := buildReloadCandidateFromBytes(data, "default")
	if err != nil {
		t.Fatal(err)
	}
	assertReloadCandidatesEqual(t, pathCandidate, byteCandidate)
}

func TestBuildReloadCandidateFromBytesMatchesPathFallback(t *testing.T) {
	data := runtimeTestConfiguration()
	pathCandidate := buildReloadCandidateForTest(t, data, "removed")
	byteCandidate, err := buildReloadCandidateFromBytes(data, "removed")
	if err != nil {
		t.Fatal(err)
	}
	assertReloadCandidatesEqual(t, pathCandidate, byteCandidate)
	if !byteCandidate.CurrentProfileFallback() {
		t.Fatal("byte candidate did not report current-profile fallback")
	}
}

func TestBuildReloadCandidateFromBytesRejectsInvalidConfiguration(t *testing.T) {
	data := bytes.Replace(reloadTestConfiguration(), []byte("brightness = 73"), []byte("brightness = 101"), 1)
	if _, err := buildReloadCandidateFromBytes(data, "default"); err == nil {
		t.Fatal("buildReloadCandidateFromBytes accepted invalid configuration")
	}
}

func assertReloadCandidatesEqual(t *testing.T, want, got reloadCandidate) {
	t.Helper()
	if !reflect.DeepEqual(want.Catalog(), got.Catalog()) {
		t.Fatal("profile catalogs differ")
	}
	if !reflect.DeepEqual(want.CurrentProfile(), got.CurrentProfile()) {
		t.Fatal("current profiles differ")
	}
	if want.CurrentProfileID() != got.CurrentProfileID() || want.DefaultProfileID() != got.DefaultProfileID() {
		t.Fatalf("profile IDs = %q/%q, want %q/%q", got.CurrentProfileID(), got.DefaultProfileID(), want.CurrentProfileID(), want.DefaultProfileID())
	}
	if want.Settings() != got.Settings() {
		t.Fatalf("settings = %#v, want %#v", got.Settings(), want.Settings())
	}
	if want.CurrentProfileFallback() != got.CurrentProfileFallback() {
		t.Fatalf("fallback = %t, want %t", got.CurrentProfileFallback(), want.CurrentProfileFallback())
	}
	if !reflect.DeepEqual(want.Page(), got.Page()) {
		t.Fatalf("page = %#v, want %#v", got.Page(), want.Page())
	}
	if !bytes.Equal(want.RenderedPage(), got.RenderedPage()) {
		t.Fatal("rendered page differs")
	}
	if !reflect.DeepEqual(want.LivePageUpdate(), got.LivePageUpdate()) {
		t.Fatal("live page update differs")
	}
}

func TestReloadCandidateClassifiesActionOnlyChange(t *testing.T) {
	base := reloadTestConfiguration()
	defaultFirstPosition := []byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\n\n")
	defaultFirstPositionWithAction := []byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\n\n[profiles.\"default\".positions.\"0_0\".action]\ntype = \"activate_profile\"\ngesture = \"press\"\nprofile_id = \"alternate\"\n\n")
	changed := bytes.Replace(base, defaultFirstPosition, defaultFirstPositionWithAction, 1)
	current := buildReloadCandidateForTest(t, base, "default")
	candidate := buildReloadCandidateForTest(t, changed, "default")

	diff := compareReloadCandidate(current, candidate)
	if diff.Effect() != reloadEffectActionOnly {
		t.Fatalf("effect = %q, want %q", diff.Effect(), reloadEffectActionOnly)
	}
	if !diff.ActionChanged() || diff.DisplayChanged() || diff.BrightnessChanged() || diff.IdleChanged() || diff.DefaultChanged() {
		t.Fatalf("action-only diff = %#v", diff)
	}
	if !diff.CatalogChanged() {
		t.Fatal("action-only change did not change catalog")
	}
}

func TestReloadCandidateClassifiesDisplayBrightnessIdleDefaultAndCatalogChanges(t *testing.T) {
	base := reloadTestConfiguration()
	current := buildReloadCandidateForTest(t, base, "default")
	tests := []struct {
		name       string
		changed    []byte
		wantEffect reloadEffectKind
		check      func(t *testing.T, diff reloadEffects)
	}{
		{
			name:       "display",
			changed:    bytes.Replace(base, []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1),
			wantEffect: reloadEffectDisplay,
			check: func(t *testing.T, diff reloadEffects) {
				t.Helper()
				if !diff.DisplayChanged() || !diff.CatalogChanged() {
					t.Fatalf("display diff = %#v", diff)
				}
			},
		},
		{
			name: "label style",
			changed: bytes.Replace(
				base,
				[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\n\n"),
				[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\nlabel_alignment = \"center\"\nlabel_size = 24\n\n"),
				1,
			),
			wantEffect: reloadEffectDisplay,
			check: func(t *testing.T, diff reloadEffects) {
				t.Helper()
				if !diff.DisplayChanged() || !diff.CatalogChanged() || !diff.CurrentProfileChanged() {
					t.Fatalf("label style diff = %#v", diff)
				}
			},
		},
		{
			name:       "brightness",
			changed:    bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 74"), 1),
			wantEffect: reloadEffectBrightness,
			check: func(t *testing.T, diff reloadEffects) {
				t.Helper()
				if !diff.BrightnessChanged() || diff.DisplayChanged() {
					t.Fatalf("brightness diff = %#v", diff)
				}
			},
		},
		{
			name:       "idle",
			changed:    bytes.Replace(base, []byte("brightness = 73\n"), []byte("brightness = 73\nidle_timeout_seconds = 120\n"), 1),
			wantEffect: reloadEffectIdle,
			check: func(t *testing.T, diff reloadEffects) {
				t.Helper()
				if !diff.IdleChanged() || diff.DisplayChanged() {
					t.Fatalf("idle diff = %#v", diff)
				}
			},
		},
		{
			name:       "default",
			changed:    bytes.Replace(base, []byte("default_profile_id = \"default\""), []byte("default_profile_id = \"alternate\""), 1),
			wantEffect: reloadEffectDefault,
			check: func(t *testing.T, diff reloadEffects) {
				t.Helper()
				if !diff.DefaultChanged() || diff.CurrentProfileFallback() || diff.DisplayChanged() {
					t.Fatalf("default diff = %#v", diff)
				}
			},
		},
		{
			name:       "catalog",
			changed:    bytes.Replace(base, []byte("label = \"alternate\""), []byte("label = \"renamed\""), 1),
			wantEffect: reloadEffectCatalog,
			check: func(t *testing.T, diff reloadEffects) {
				t.Helper()
				if !diff.CatalogChanged() || diff.DisplayChanged() || diff.ActionChanged() {
					t.Fatalf("catalog diff = %#v", diff)
				}
			},
		},
		{
			name: "notification sources",
			changed: bytes.Replace(
				base,
				[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\n\n"),
				[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\nnotification_sources = [\"clock\"]\n\n"),
				1,
			),
			wantEffect: reloadEffectCatalog,
			check: func(t *testing.T, diff reloadEffects) {
				t.Helper()
				if !diff.CatalogChanged() || diff.DisplayChanged() || diff.ActionChanged() || !diff.CurrentProfileChanged() {
					t.Fatalf("notification source diff = %#v", diff)
				}
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			candidate := buildReloadCandidateForTest(t, test.changed, "default")
			diff := compareReloadCandidate(current, candidate)
			if diff.Effect() != test.wantEffect {
				t.Fatalf("effect = %q, want %q; diff = %#v", diff.Effect(), test.wantEffect, diff)
			}
			test.check(t, diff)
		})
	}
}

func TestReloadCandidateCarriesLabelStyleToCurrentPage(t *testing.T) {
	base := reloadTestConfiguration()
	styled := bytes.Replace(
		base,
		[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\n\n"),
		[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\nlabel_alignment = \"center\"\nlabel_size = 24\n\n"),
		1,
	)
	candidate := buildReloadCandidateForTest(t, styled, "default")
	position := candidate.Page().Positions[0]
	if position.LabelAlignment != appconfig.LabelAlignmentCenter || position.LabelSize != 24 {
		t.Fatalf("current page label style = %s/%d, want %s/24", position.LabelAlignment, position.LabelSize, appconfig.LabelAlignmentCenter)
	}
	defaultCandidate := buildReloadCandidateForTest(t, base, "default")
	defaultPosition := defaultCandidate.Page().Positions[0]
	if defaultPosition.LabelAlignment != appconfig.DefaultLabelAlignment || defaultPosition.LabelSize != appconfig.DefaultLabelSize {
		t.Fatalf("default current page label style = %s/%d, want %s/%d", defaultPosition.LabelAlignment, defaultPosition.LabelSize, appconfig.DefaultLabelAlignment, appconfig.DefaultLabelSize)
	}
}

func TestReloadCandidateFallsBackWhenCurrentProfileIsRemoved(t *testing.T) {
	base := reloadTestConfiguration()
	current := buildReloadCandidateForTest(t, base, "alternate")
	candidate := buildReloadCandidateForTest(t, runtimeTestConfiguration(), "alternate")

	if candidate.CurrentProfileID() != "default" {
		t.Fatalf("candidate current profile = %q, want default", candidate.CurrentProfileID())
	}
	if !candidate.CurrentProfileFallback() {
		t.Fatal("candidate did not report current-profile fallback")
	}
	diff := compareReloadCandidate(current, candidate)
	if !diff.CurrentProfileFallback() || !diff.CurrentProfileChanged() || !diff.CatalogChanged() {
		t.Fatalf("fallback diff = %#v", diff)
	}
}

func TestBuildReloadCandidateEmptyCurrentProfileUsesDefault(t *testing.T) {
	candidate := buildReloadCandidateForTest(t, reloadTestConfiguration(), "")
	defaultProfile, ok := candidate.Catalog().Default()
	if !ok {
		t.Fatal("candidate default profile is unavailable")
	}
	if candidate.CurrentProfileID() != candidate.DefaultProfileID() {
		t.Fatalf("candidate current profile = %q, default = %q", candidate.CurrentProfileID(), candidate.DefaultProfileID())
	}
	if !candidate.CurrentProfileFallback() {
		t.Fatal("empty current profile did not report fallback")
	}
	if !equalProfiles(candidate.CurrentProfile(), defaultProfile) {
		t.Fatalf("candidate current profile = %#v, want default profile %#v", candidate.CurrentProfile(), defaultProfile)
	}
}

func TestReloadCandidateComparesRenderedPages(t *testing.T) {
	base := reloadTestConfiguration()
	current := buildReloadCandidateForTest(t, base, "default")
	changed := reorderReloadPositions(base)
	candidate := buildReloadCandidateForTest(t, changed, "default")
	diff := compareReloadCandidate(current, candidate)
	if diff.DisplayChanged() {
		t.Fatal("equivalent rendered page was classified as changed")
	}
	if diff.CatalogChanged() || diff.Effect() != reloadEffectUnchanged {
		t.Fatalf("reordered catalog diff = %#v", diff)
	}
}

func TestReloadCandidateDefensiveCopies(t *testing.T) {
	base := reloadTestConfiguration()
	candidate := buildReloadCandidateForTest(t, base, "default")

	catalog := candidate.Catalog()
	profiles := catalog.Profiles()
	profiles[0].Label = "mutated"
	profiles[0].Values[0].Label = "mutated"
	profilesAgain := candidate.Catalog().Profiles()
	if profilesAgain[0].Label == "mutated" || profilesAgain[0].Values[0].Label == "mutated" {
		t.Fatal("catalog defensive copy failed")
	}

	profileCopy := candidate.CurrentProfile()
	profileCopy.Label = "mutated"
	profileCopy.Values[0].Label = "mutated"
	currentAgain := candidate.CurrentProfile()
	if currentAgain.Label == "mutated" || currentAgain.Values[0].Label == "mutated" {
		t.Fatal("current profile defensive copy failed")
	}

	pageCopy := candidate.Page()
	pageCopy.Positions[0].Label = "mutated"
	if candidate.Page().Positions[0].Label == "mutated" {
		t.Fatal("page defensive copy failed")
	}

	renderedCopy := candidate.RenderedPage()
	renderedCopy[0] ^= 0xff
	if candidate.RenderedPage()[0] == renderedCopy[0] {
		t.Fatal("rendered page defensive copy failed")
	}

	frame := candidate.LivePageUpdate().Frame()
	frame.Payload[0] ^= 0xff
	if candidate.LivePageUpdate().Frame().Payload[0] == frame.Payload[0] {
		t.Fatal("live page update defensive copy failed")
	}
}

func buildReloadCandidateForTest(t *testing.T, data []byte, currentProfileID string) reloadCandidate {
	t.Helper()
	candidate, err := buildReloadCandidate(writeReloadConfiguration(t, data), currentProfileID)
	if err != nil {
		t.Fatal(err)
	}
	return candidate
}

func writeReloadConfiguration(t *testing.T, data []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func reorderReloadPositions(data []byte) []byte {
	firstMarker := []byte("[profiles.\"default\".positions.\"0_0\"]")
	secondMarker := []byte("[profiles.\"default\".positions.\"1_0\"]")
	thirdMarker := []byte("[profiles.\"default\".positions.\"2_0\"]")
	firstStart := bytes.Index(data, firstMarker)
	secondStart := bytes.Index(data, secondMarker)
	thirdStart := bytes.Index(data, thirdMarker)
	if firstStart < 0 || secondStart < 0 || thirdStart < 0 || firstStart >= secondStart || secondStart >= thirdStart {
		return append([]byte(nil), data...)
	}
	prefix := data[:firstStart]
	first := data[firstStart:secondStart]
	second := data[secondStart:thirdStart]
	suffix := data[thirdStart:]
	result := make([]byte, 0, len(data))
	result = append(result, prefix...)
	result = append(result, second...)
	result = append(result, first...)
	result = append(result, suffix...)
	return result
}

func reloadTestConfiguration() []byte {
	return runtimeMultiProfileConfiguration()
}
