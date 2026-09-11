package runtime

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildReloadCandidateRejectsInvalidAndUnreadableConfiguration(t *testing.T) {
	base := reloadTestConfiguration()

	for _, test := range []struct {
		name string
		data []byte
		path string
		want string
	}{
		{name: "invalid", data: bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 101"), 1), want: "invalid configuration"},
		{name: "unreadable", path: filepath.Join(t.TempDir(), "missing.toml"), want: "configuration could not be loaded"},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := test.path
			if path == "" {
				path = writeReloadConfiguration(t, test.data)
			}
			_, err := buildReloadCandidate(path, "default")
			if err == nil || err.Error() != test.want {
				t.Fatalf("buildReloadCandidate error = %v, want %q", err, test.want)
			}
			if strings.Contains(err.Error(), path) {
				t.Fatalf("error exposed configuration path: %q", err)
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

func TestReloadCandidateClassifiesActionOnlyChange(t *testing.T) {
	base := reloadTestConfiguration()
	changed := bytes.Replace(base, []byte("background = \"#102030\"\n\n"), []byte("background = \"#102030\"\n\n[profiles.positions.action]\ntype = \"activate_profile\"\ngesture = \"press\"\nprofile_id = \"alternate\"\n\n"), 1)
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
	if !diff.CatalogChanged() || diff.Effect() != reloadEffectCatalog {
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
	marker := []byte("[[profiles.positions]]")
	starts := make([]int, 0, 3)
	for offset := 0; ; {
		index := bytes.Index(data[offset:], marker)
		if index < 0 {
			break
		}
		index += offset
		starts = append(starts, index)
		offset = index + len(marker)
	}
	if len(starts) < 3 {
		return append([]byte(nil), data...)
	}
	prefix := data[:starts[0]]
	first := data[starts[0]:starts[1]]
	second := data[starts[1]:starts[2]]
	suffix := data[starts[2]:]
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
