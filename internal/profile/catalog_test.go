package profile

import (
	"fmt"
	"strings"
	"testing"
)

func TestNewCatalogPreservesOrderAndResolvesForwardActions(t *testing.T) {
	definitions := validProfiles()
	definitions[0].Values[0].Action = &Action{Type: ActivateProfileType, Gesture: PressGesture, ProfileID: "alternate"}
	catalog, err := NewCatalog("default", definitions)
	if err != nil {
		t.Fatal(err)
	}
	ordered := catalog.OrderedProfiles()
	if len(ordered) != 2 || ordered[0].ID != "default" || ordered[1].ID != "alternate" {
		t.Fatalf("ordered profiles = %#v", ordered)
	}
	if catalog.Count() != 2 || catalog.DefaultProfileID() != "default" {
		t.Fatalf("catalog metadata = %d/%q", catalog.Count(), catalog.DefaultProfileID())
	}
	defaultProfile, ok := catalog.DefaultProfile()
	if !ok || defaultProfile.ID != "default" {
		t.Fatalf("default profile = %#v, %v", defaultProfile, ok)
	}
	action := defaultProfile.Values[0].Action
	if action == nil {
		t.Fatal("default action missing")
	}
	target, ok := catalog.ResolveActionTarget(*action)
	if !ok || target.ID != "alternate" {
		t.Fatalf("action target = %#v, %v", target, ok)
	}
	bindings := defaultProfile.Bindings()
	if len(bindings) != 1 || bindings[0].Position != "0_0" || bindings[0].Action.ProfileID != "alternate" {
		t.Fatalf("bindings = %#v", bindings)
	}
}

func TestCatalogDefensivelyCopiesNestedValues(t *testing.T) {
	definitions := validProfiles()
	definitions[0].Values[0].Action = &Action{Type: ActivateProfileType, Gesture: PressGesture, ProfileID: "alternate"}
	definitions[1].Values[0].Action = &Action{Type: ActivateProfileType, Gesture: PressGesture, ProfileID: "default"}
	catalog, err := NewCatalog("default", definitions)
	if err != nil {
		t.Fatal(err)
	}
	definitions[0].Values[0].Label = "changed source"
	definitions[0].Values[0].Action.ProfileID = "changed source"
	definitions[0].Values = definitions[0].Values[:1]

	returned := catalog.Profiles()
	returned[0].Values[0].Label = "changed result"
	returned[0].Values[0].Action.ProfileID = "changed result"
	returned[0].Values = returned[0].Values[:1]
	lookup, ok := catalog.Lookup("default")
	if !ok || len(lookup.Values) != RequiredValueCount || lookup.Values[0].Label != "Default 0_0" || lookup.Values[0].Action.ProfileID != "alternate" {
		t.Fatalf("catalog was mutable through copies: %#v, %v", lookup, ok)
	}
	resolved, ok := catalog.ResolveActionTarget(*lookup.Values[0].Action)
	if !ok {
		t.Fatal("ResolveActionTarget did not resolve alternate profile")
	}
	resolved.Values[0].Label = "changed target"
	if resolved.Values[0].Action != nil {
		resolved.Values[0].Action.ProfileID = "changed target"
	}
	resolvedAgain, ok := catalog.ResolveTarget("alternate")
	if !ok || resolvedAgain.Values[0].Label != "Default 0_0" || resolvedAgain.Values[0].Action == nil || resolvedAgain.Values[0].Action.ProfileID != "default" {
		t.Fatalf("catalog was mutable through ResolveActionTarget result: %#v, %v", resolvedAgain, ok)
	}
}

func TestCatalogPreservesAndCopiesExecuteAction(t *testing.T) {
	profiles := validProfiles()
	profiles[0].Values[0].Action = &Action{
		Type:       ExecuteActionType,
		Gesture:    PressGesture,
		Executable: "/bin/echo",
		Arguments:  []string{"--mode", "test"},
	}
	catalog, err := NewCatalog("default", profiles)
	if err != nil {
		t.Fatal(err)
	}
	profiles[0].Values[0].Action.Arguments[0] = "changed source"
	returned, ok := catalog.Default()
	if !ok || returned.Values[0].Action == nil {
		t.Fatalf("default profile = %#v, %v", returned, ok)
	}
	returnedAction := returned.Values[0].Action
	if returnedAction.Type != ExecuteActionType || returnedAction.Gesture != PressGesture || returnedAction.Executable != "/bin/echo" || returnedAction.TimeoutSeconds != DefaultExecuteTimeoutSeconds || len(returnedAction.Arguments) != 2 || returnedAction.Arguments[0] != "--mode" {
		t.Fatalf("execute action = %#v", returnedAction)
	}
	returnedAction.Arguments[0] = "changed result"
	returnedActionAgain, ok := catalog.Default()
	if !ok || returnedActionAgain.Values[0].Action == nil || returnedActionAgain.Values[0].Action.Arguments[0] != "--mode" {
		t.Fatalf("catalog action changed through returned copy: %#v, %v", returnedActionAgain, ok)
	}
	bindings := returnedActionAgain.Bindings()
	if len(bindings) != 1 || bindings[0].Action.Executable != "/bin/echo" || len(bindings[0].Action.Arguments) != 2 || bindings[0].Action.Arguments[1] != "test" {
		t.Fatalf("execute bindings = %#v", bindings)
	}
	bindings[0].Action.Arguments[0] = "changed binding"
	final, ok := catalog.Default()
	if !ok || final.Values[0].Action.Arguments[0] != "--mode" {
		t.Fatalf("catalog action changed through binding copy: %#v, %v", final, ok)
	}
}

func TestNewCatalogRejectsInvalidDefinitions(t *testing.T) {
	tests := []struct {
		name string
		edit func([]Profile) (string, []Profile)
		want string
	}{
		{
			name: "zero profiles",
			edit: func(_ []Profile) (string, []Profile) { return "default", nil },
			want: "between 1 and",
		},
		{
			name: "too many profiles",
			edit: func(source []Profile) (string, []Profile) {
				profiles := append([]Profile(nil), source...)
				for len(profiles) <= MaximumProfileCount {
					copyOfDefault := profiles[0]
					copyOfDefault.ID = fmt.Sprintf("profile-%02d", len(profiles))
					profiles = append(profiles, copyOfDefault)
				}
				return "default", profiles
			},
			want: "between 1 and",
		},
		{
			name: "duplicate ID",
			edit: func(source []Profile) (string, []Profile) {
				profiles := append([]Profile(nil), source...)
				profiles[1].ID = profiles[0].ID
				return "default", profiles
			},
			want: "duplicated",
		},
		{
			name: "unsupported position",
			edit: func(source []Profile) (string, []Profile) {
				profiles := cloneProfiles(source)
				profiles[0].Values[0].Position = "4_2"
				return "default", profiles
			},
			want: "unsupported position",
		},
		{
			name: "invalid profile ID",
			edit: func(source []Profile) (string, []Profile) {
				profiles := cloneProfiles(source)
				profiles[0].ID = "invalid profile"
				return "invalid profile", profiles
			},
			want: "invalid ID",
		},
		{
			name: "invalid profile label",
			edit: func(source []Profile) (string, []Profile) {
				profiles := cloneProfiles(source)
				profiles[0].Label = "\u200b"
				return "default", profiles
			},
			want: "invalid label",
		},
		{
			name: "invalid action type",
			edit: func(source []Profile) (string, []Profile) {
				profiles := cloneProfiles(source)
				profiles[0].Values[0].Action = &Action{Type: "run", Gesture: PressGesture, ProfileID: "alternate"}
				return "default", profiles
			},
			want: "type must be",
		},
		{
			name: "invalid action gesture",
			edit: func(source []Profile) (string, []Profile) {
				profiles := cloneProfiles(source)
				profiles[0].Values[0].Action = &Action{Type: ActivateProfileType, Gesture: "release", ProfileID: "alternate"}
				return "default", profiles
			},
			want: "gesture must be",
		},
		{
			name: "unknown action target",
			edit: func(source []Profile) (string, []Profile) {
				profiles := cloneProfiles(source)
				profiles[0].Values[0].Action = &Action{Type: ActivateProfileType, Gesture: PressGesture, ProfileID: "missing"}
				return "default", profiles
			},
			want: "target",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			defaultID, profiles := test.edit(validProfiles())
			_, err := NewCatalog(defaultID, profiles)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("NewCatalog error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestNewCatalogAcceptsMaximumProfileAndLabelBoundaries(t *testing.T) {
	profiles := validProfiles()
	for len(profiles) < MaximumProfileCount {
		copyOfLast := cloneProfile(profiles[len(profiles)-1])
		copyOfLast.ID = fmt.Sprintf("profile-%02d", len(profiles))
		profiles = append(profiles, copyOfLast)
	}
	maximumID := strings.Repeat("a", MaximumStableIDRunes)
	maximumLabel := strings.Repeat("😀", MaximumLabelRunes)
	profiles[0].ID = maximumID
	profiles[0].Label = maximumLabel
	profiles[0].Values[0].ID = maximumID
	profiles[0].Values[0].Label = maximumLabel
	catalog, err := NewCatalog(maximumID, profiles)
	if err != nil {
		t.Fatalf("maximum profile/label boundaries rejected: %v", err)
	}
	if catalog.Count() != MaximumProfileCount {
		t.Fatalf("catalog count = %d, want %d", catalog.Count(), MaximumProfileCount)
	}
}

func TestNewCatalogRejectsOverflowAndInvisibleLabels(t *testing.T) {
	profiles := validProfiles()
	for len(profiles) <= MaximumProfileCount {
		copyOfLast := cloneProfile(profiles[len(profiles)-1])
		copyOfLast.ID = fmt.Sprintf("profile-%02d", len(profiles))
		profiles = append(profiles, copyOfLast)
	}
	if _, err := NewCatalog("default", profiles); err == nil {
		t.Fatal("catalog accepted more than maximum profile count")
	}
	tooLong := strings.Repeat("a", MaximumStableIDRunes+1)
	for _, edit := range []func([]Profile){
		func(value []Profile) { value[0].ID = tooLong },
		func(value []Profile) { value[0].Label = tooLong },
		func(value []Profile) { value[0].Values[0].ID = tooLong },
		func(value []Profile) { value[0].Values[0].Label = tooLong },
		func(value []Profile) {
			value[0].Values[0].Action = &Action{Type: ActivateProfileType, Gesture: PressGesture, ProfileID: tooLong}
		},
	} {
		profiles := validProfiles()
		edit(profiles)
		if _, err := NewCatalog("default", profiles); err == nil {
			t.Fatalf("catalog accepted oversized value from %T", edit)
		}
	}

	for _, label := range []string{"\u0000", "\u200b", "\u202e", "\u0301", " \t "} {
		profiles := validProfiles()
		profiles[0].Label = label
		if _, err := NewCatalog("default", profiles); err == nil {
			t.Fatalf("catalog accepted invisible profile label %q", label)
		}

		profiles = validProfiles()
		profiles[0].Values[0].Label = label
		if _, err := NewCatalog("default", profiles); err == nil {
			t.Fatalf("catalog accepted invisible value label %q", label)
		}
	}
}

func validProfiles() []Profile {
	values := make([]Value, 0, RequiredValueCount)
	for index, position := range supportedPositions {
		values = append(values, Value{
			ID:         fmt.Sprintf("value-%02d", index),
			Position:   position,
			Label:      "Default " + position,
			Background: "#102030",
		})
	}
	return []Profile{
		{ID: "default", Label: "Default", Values: values},
		{ID: "alternate", Label: "Alternate", Values: cloneValues(values)},
	}
}
