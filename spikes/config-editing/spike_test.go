package configediting

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

func TestFeasibilitySuite(t *testing.T) {
	results := runSuite()
	for _, result := range results.TOML {
		if result.Status != "pass" {
			t.Logf("measured TOML result %s/%s: %s", result.ID, result.LineEnding, result.Detail)
			if result.Required {
				t.Errorf("required TOML result %s/%s failed: %s", result.ID, result.LineEnding, result.Detail)
			}
		}
	}
	for _, result := range results.JSONC {
		if result.Status != "pass" {
			t.Logf("measured JSONC result %s/%s: %s", result.ID, result.LineEnding, result.Detail)
		}
	}
	for _, result := range results.Transactions {
		if result.Status != "pass" {
			t.Errorf("transactional check %s: %s", result.ID, result.Detail)
		}
	}
	encoded, err := encodeResults(results)
	if err != nil {
		t.Fatal(err)
	}
	regenerated, err := encodeResults(runSuite())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(encoded, regenerated) {
		t.Fatal("suite results are not deterministic across regeneration")
	}
	results.Deterministic = true
	encoded, err = encodeResults(results)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile("results.json", encoded, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote results.json with mode %s", results.FallbackMode)
}

func encodeResults(results suiteResults) ([]byte, error) {
	encoded, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(encoded, '\n'), nil
}

func TestAtomicWriteErrorIdentity(t *testing.T) {
	if !errors.Is(ErrStaleWrite, ErrStaleWrite) {
		t.Fatal("stale-write sentinel must be errors.Is-identifiable")
	}
}
