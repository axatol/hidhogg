package configediting

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
)

func runTransactionalChecks() []checkResult {
	results := []checkResult{
		{ID: "content-hash.stale-write-refusal"},
		{ID: "content-hash.toctou-boundary"},
		{ID: "atomic.same-directory-replacement"},
	}
	directory, err := os.MkdirTemp("", "hidhogg-config-edit-")
	if err != nil {
		for i := range results {
			results[i].Status = "fail"
			results[i].Detail = err.Error()
		}
		return results
	}
	defer os.RemoveAll(directory)
	path := filepath.Join(directory, "config.toml")
	initial := []byte("version = 1\n")
	if err := os.WriteFile(path, initial, 0o600); err != nil {
		for i := range results {
			results[i].Status = "fail"
			results[i].Detail = err.Error()
		}
		return results
	}
	expectedHash := ContentHash(initial)
	external := []byte("version = 2\n")
	if err := os.WriteFile(path, external, 0o600); err != nil {
		for i := range results {
			results[i].Status = "fail"
			results[i].Detail = err.Error()
		}
		return results
	}
	staleErr := WriteIfUnchanged(path, expectedHash, []byte("version = 3\n"))
	got, readErr := os.ReadFile(path)
	if errors.Is(staleErr, ErrStaleWrite) && readErr == nil && bytes.Equal(got, external) {
		results[0].Status = "pass"
		results[0].Detail = "hash mismatch refused replacement and preserved newer bytes"
	} else {
		results[0].Status = "fail"
		results[0].Detail = "stale write was not refused without changing the newer file"
	}
	tracedBaseline := []byte("version = race-baseline\n")
	if err := os.WriteFile(path, tracedBaseline, 0o600); err != nil {
		for i := range results {
			results[i].Status = "fail"
			results[i].Detail = err.Error()
		}
		return results
	}
	tracedReplacement := []byte("version = race-writer\n")
	interveningEditor := []byte("version = intervening-editor\n")
	tracedErr := writeIfUnchanged(path, ContentHash(tracedBaseline), tracedReplacement, func() error {
		return os.WriteFile(path, interveningEditor, 0o600)
	})
	got, readErr = os.ReadFile(path)
	if tracedErr == nil && readErr == nil && bytes.Equal(got, tracedReplacement) {
		results[1].Status = "pass"
		results[1].Detail = "injected editor write after hash check was overwritten; compare-and-swap is not claimed"
	} else {
		results[1].Status = "fail"
		results[1].Detail = "injected post-check write did not demonstrate the documented TOCTOU boundary"
	}
	replacement := []byte("version = 4\n")
	if err := AtomicReplace(path, replacement); err != nil {
		results[2].Status = "fail"
		results[2].Detail = err.Error()
		return results
	}
	got, readErr = os.ReadFile(path)
	entries, entriesErr := os.ReadDir(directory)
	temporaryLeft := false
	for _, entry := range entries {
		if len(entry.Name()) >= len(".hidhogg-config-") && entry.Name()[:len(".hidhogg-config-")] == ".hidhogg-config-" {
			temporaryLeft = true
		}
	}
	if readErr == nil && entriesErr == nil && bytes.Equal(got, replacement) && !temporaryLeft {
		results[2].Status = "pass"
		results[2].Detail = "same-directory temporary was atomically renamed with no leftover"
	} else {
		results[2].Status = "fail"
		results[2].Detail = "replacement bytes or temporary cleanup check failed"
	}
	return results
}
