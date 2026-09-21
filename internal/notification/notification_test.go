package notification

import (
	"strings"
	"testing"
)

func TestValidateEmitBoundaries(t *testing.T) {
	tests := []struct {
		name    string
		request EmitRequest
		valid   bool
	}{
		{name: "source case variants", request: EmitRequest{Source: "Source.ID-1_a", Text: "visible"}, valid: true},
		{name: "source maximum length", request: EmitRequest{Source: "a" + strings.Repeat("-", 63), Text: "visible"}, valid: true},
		{name: "source too long", request: EmitRequest{Source: "a" + strings.Repeat("-", 64), Text: "visible"}},
		{name: "source leading punctuation", request: EmitRequest{Source: ".source", Text: "visible"}},
		{name: "source non ASCII", request: EmitRequest{Source: "sourcé", Text: "visible"}},
		{name: "text maximum runes and bytes", request: EmitRequest{Source: "source", Text: strings.Repeat("😀", 64)}, valid: true},
		{name: "text too many runes", request: EmitRequest{Source: "source", Text: strings.Repeat("a", 65)}},
		{name: "text empty", request: EmitRequest{Source: "source"}},
		{name: "text spaces only", request: EmitRequest{Source: "source", Text: " \t"}},
		{name: "text combining only", request: EmitRequest{Source: "source", Text: "\u0301"}},
		{name: "text private use", request: EmitRequest{Source: "source", Text: "\uE000"}},
		{name: "text control", request: EmitRequest{Source: "source", Text: "line\nfeed"}},
		{name: "text format", request: EmitRequest{Source: "source", Text: "zero\u200Dwidth"}},
		{name: "text line separator", request: EmitRequest{Source: "source", Text: "line\u2028separator"}},
		{name: "text paragraph separator", request: EmitRequest{Source: "source", Text: "paragraph\u2029separator"}},
		{name: "text invalid UTF8", request: EmitRequest{Source: "source", Text: string([]byte{0xff})}},
		{name: "TTL minimum", request: EmitRequest{Source: "source", Text: "visible", TTLSeconds: intPointer(MinimumTTLSeconds)}, valid: true},
		{name: "TTL maximum", request: EmitRequest{Source: "source", Text: "visible", TTLSeconds: intPointer(MaximumTTLSeconds)}, valid: true},
		{name: "TTL below minimum", request: EmitRequest{Source: "source", Text: "visible", TTLSeconds: intPointer(0)}},
		{name: "TTL above maximum", request: EmitRequest{Source: "source", Text: "visible", TTLSeconds: intPointer(MaximumTTLSeconds + 1)}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := ValidateEmit(test.request)
			if test.valid && err != nil {
				t.Fatalf("ValidateEmit() = %v, want nil", err)
			}
			if !test.valid && err != ErrInvalid {
				t.Fatalf("ValidateEmit() = %v, want ErrInvalid", err)
			}
		})
	}
}

func TestCloneEmitRequestOwnsTTL(t *testing.T) {
	ttl := 17
	original := EmitRequest{Source: "source", Text: "visible", TTLSeconds: &ttl}
	clone := CloneEmitRequest(original)
	if clone.TTLSeconds == original.TTLSeconds {
		t.Fatal("CloneEmitRequest retained the caller TTL pointer")
	}
	ttl = 29
	if *clone.TTLSeconds != 17 {
		t.Fatalf("cloned TTL = %d, want 17", *clone.TTLSeconds)
	}
	if got := CloneEmitRequest(EmitRequest{Source: "source", Text: "visible"}); got.TTLSeconds != nil {
		t.Fatal("nil TTL became non-nil")
	}
}

func TestNotificationIDValidation(t *testing.T) {
	for _, id := range []string{
		"00000000-0000-0000-0000-000000000000",
		"ffffffff-ffff-ffff-ffff-ffffffffffff",
	} {
		if err := ValidateNotificationID(id); err != nil {
			t.Fatalf("ValidateNotificationID(%q) = %v", id, err)
		}
	}
	for _, id := range []string{
		"00000000-0000-0000-0000-00000000000G",
		"00000000-0000-0000-0000-000000000000\n",
		"00000000-0000-0000-0000-00000000000A",
		"000000000000-0000-0000-0000-000000000000",
	} {
		if err := ValidateNotificationID(id); err != ErrInvalid {
			t.Fatalf("ValidateNotificationID(%q) = %v, want ErrInvalid", id, err)
		}
	}
	id, err := NewNotificationID()
	if err != nil {
		t.Fatal(err)
	}
	if !ValidNotificationID(id) {
		t.Fatalf("generated notification ID %q failed canonical validation", id)
	}
}

func intPointer(value int) *int {
	return &value
}
