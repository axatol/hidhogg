package configediting

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

var ErrStaleWrite = errors.New("configuration changed since it was read")

func ContentHash(source []byte) [32]byte {
	return sha256.Sum256(source)
}

func WriteIfUnchanged(path string, expectedHash [32]byte, replacement []byte) error {
	return writeIfUnchanged(path, expectedHash, replacement, nil)
}

func writeIfUnchanged(path string, expectedHash [32]byte, replacement []byte, afterHashCheck func() error) error {
	current, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if ContentHash(current) != expectedHash {
		return ErrStaleWrite
	}
	if afterHashCheck != nil {
		if err := afterHashCheck(); err != nil {
			return err
		}
	}
	return AtomicReplace(path, replacement)
}

func AtomicReplace(path string, replacement []byte) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".hidhogg-config-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(info.Mode().Perm()); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(replacement); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("replace %q: %w", path, err)
	}
	removeTemporary = false
	return nil
}
