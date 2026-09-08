package execution

import (
	"bytes"
	"regexp"
	"testing"
	"time"
)

func TestMonotonicUUIDsAreUniqueOrderedAndCanonical(t *testing.T) {
	ids, err := newMonotonicUUIDs(bytes.NewReader(bytes.Repeat([]byte{0x42}, 32)))
	if err != nil {
		t.Fatal(err)
	}
	now := time.UnixMilli(1_700_000_000_000)
	previous := ""
	pattern := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	seen := make(map[string]struct{}, 10_000)
	for index := 0; index < 10_000; index++ {
		current := ids.next(now)
		if !pattern.MatchString(current) {
			t.Fatalf("ID %q is not canonical UUIDv7", current)
		}
		if _, exists := seen[current]; exists {
			t.Fatalf("duplicate ID %q", current)
		}
		if previous != "" && current <= previous {
			t.Fatalf("IDs are not ordered: %q then %q", previous, current)
		}
		seen[current] = struct{}{}
		previous = current
	}
}

func TestUUIDEntropyCarriesExcludeReservedBits(t *testing.T) {
	tests := []struct {
		name     string
		entropy  [10]byte
		want     [10]byte
		overflow bool
	}{
		{
			name:    "rand_b low carry",
			entropy: [10]byte{0x01, 0x02, 0x03, 0, 0, 0, 0, 0, 0xff, 0xff},
			want:    [10]byte{0x01, 0x02, 0x03, 0, 0, 0, 0, 1, 0, 0},
		},
		{
			name:    "rand_b to rand_a carry ignores variant source bits",
			entropy: [10]byte{0x01, 0x02, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
			want:    [10]byte{0x01, 0x03, 0, 0, 0, 0, 0, 0, 0, 0},
		},
		{
			name:    "rand_a carry ignores version source bits",
			entropy: [10]byte{0xae, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
			want:    [10]byte{0x0f, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		},
		{
			name:     "74 bit overflow",
			entropy:  [10]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
			want:     [10]byte{},
			overflow: true,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			entropy := test.entropy
			if overflow := incrementEntropy(&entropy); overflow != test.overflow {
				t.Fatalf("overflow = %v", overflow)
			}
			if entropy != test.want {
				t.Fatalf("entropy = %x, want %x", entropy, test.want)
			}
		})
	}

	now := time.UnixMilli(1_700_000_000_000)
	ids := monotonicUUIDs{lastMillis: uint64(now.UnixMilli()), entropy: [10]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}}
	first := ids.next(now)
	second := ids.next(now)
	if second <= first {
		t.Fatalf("timestamp carry order = %q then %q", first, second)
	}
	pattern := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	if !pattern.MatchString(first) || !pattern.MatchString(second) {
		t.Fatalf("reserved UUID bits invalid after carry: %q %q", first, second)
	}
}
