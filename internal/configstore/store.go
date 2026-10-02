package configstore

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"

	"hidhogg/internal/config"
)

type Digest [sha256.Size]byte

func Hash(source []byte) Digest {
	return sha256.Sum256(source)
}

type Outcome uint8

const (
	OutcomeUnchanged Outcome = iota
	OutcomeCommitted
	OutcomeUncertain
)

type Result struct {
	Outcome Outcome
	Digest  Digest
	Bytes   []byte
}

type ErrorCode uint8

const (
	ErrorCodeStale ErrorCode = iota + 1
	ErrorCodeInvalidDestination
	ErrorCodeMutation
	ErrorCodeInvalidConfiguration
	ErrorCodeDisk
	ErrorCodeUncertain
)

type Error struct {
	code ErrorCode
}

func (e *Error) Error() string {
	if e == nil {
		return "configuration update failed"
	}

	switch e.code {
	case ErrorCodeStale:
		return "configuration changed since it was read"
	case ErrorCodeInvalidDestination:
		return "configuration destination is not a regular file"
	case ErrorCodeMutation:
		return "configuration mutation failed"
	case ErrorCodeInvalidConfiguration:
		return "edited configuration is invalid"
	case ErrorCodeDisk:
		return "configuration update failed"
	case ErrorCodeUncertain:
		return "configuration update outcome is uncertain"
	default:
		return "configuration update failed"
	}
}

func (e *Error) Code() ErrorCode {
	if e == nil {
		return 0
	}
	return e.code
}

func ErrorCodeOf(err error) (ErrorCode, bool) {
	var storeError *Error
	if !errors.As(err, &storeError) || storeError == nil {
		return 0, false
	}
	return storeError.Code(), true
}

// Apply mutates a caller-owned configuration path after verifying its exact
// source digest. The caller must hold the application's shared mutation and
// reload admission gate for the entire call; Apply intentionally has no
// process-local lock of its own.
//
// The callback must return prospective TOML bytes. Those bytes are strictly
// decoded before they can be staged. Bytes in Result are present only after a
// successful rename and are an independent copy suitable for an exact-byte
// runtime reload. Errors never include the path, source bytes, or callback or
// filesystem error text.
//
// A successful rename followed by a parent-directory sync failure has an
// uncertain durability outcome. Apply does not roll back in that case. The
// second digest check narrows but cannot eliminate the race with an external
// writer between that check and rename; this operation is not filesystem
// compare-and-swap.
func Apply(path string, expected Digest, mutate func([]byte) ([]byte, error)) (Result, error) {
	if mutate == nil {
		return unchanged(), newError(ErrorCodeMutation)
	}

	absPath, err := filepath.Abs(path)
	if err != nil {
		return unchanged(), newError(ErrorCodeDisk)
	}

	return apply(osFileSystem{}, absPath, expected, mutate)
}

func apply(fs fileSystem, path string, expected Digest, mutate func([]byte) ([]byte, error)) (Result, error) {
	source, originalMode, code := readDestination(fs, path)
	if code != 0 {
		return unchanged(), newError(code)
	}
	if Hash(source) != expected {
		return unchanged(), newError(ErrorCodeStale)
	}

	prospective, err := mutate(bytes.Clone(source))
	if err != nil {
		return unchanged(), newError(ErrorCodeMutation)
	}
	prospective = bytes.Clone(prospective)
	if _, err := config.Decode(prospective); err != nil {
		return unchanged(), newError(ErrorCodeInvalidConfiguration)
	}
	if bytes.Equal(prospective, source) {
		current, _, code := readDestination(fs, path)
		if code != 0 {
			return unchanged(), newError(code)
		}
		if Hash(current) != expected {
			return unchanged(), newError(ErrorCodeStale)
		}
		return Result{Outcome: OutcomeUnchanged, Digest: Hash(source)}, nil
	}

	temporary, err := fs.CreateTemp(filepath.Dir(path), ".hidhogg-config-*")
	if err != nil {
		return unchanged(), newError(ErrorCodeDisk)
	}
	temporaryPath := temporary.Name()
	renamed := false
	defer func() {
		if !renamed {
			_ = fs.Remove(temporaryPath)
		}
	}()

	if err := writeTemporary(temporary, prospective, originalMode); err != nil {
		return unchanged(), newError(ErrorCodeDisk)
	}

	current, _, code := readDestination(fs, path)
	if code != 0 {
		return unchanged(), newError(code)
	}
	if Hash(current) != expected {
		return unchanged(), newError(ErrorCodeStale)
	}
	if err := fs.Rename(temporaryPath, path); err != nil {
		return unchanged(), newError(ErrorCodeDisk)
	}
	renamed = true

	if !syncParentDirectory(fs, filepath.Dir(path)) {
		return applied(prospective, OutcomeUncertain), newError(ErrorCodeUncertain)
	}
	return applied(prospective, OutcomeCommitted), nil
}

func unchanged() Result {
	return Result{Outcome: OutcomeUnchanged}
}

func applied(source []byte, outcome Outcome) Result {
	return Result{
		Outcome: outcome,
		Digest:  Hash(source),
		Bytes:   bytes.Clone(source),
	}
}

func newError(code ErrorCode) *Error {
	return &Error{code: code}
}

func readDestination(fs fileSystem, path string) ([]byte, os.FileMode, ErrorCode) {
	before, err := fs.Lstat(path)
	if err != nil {
		return nil, 0, ErrorCodeDisk
	}
	if !before.Mode().IsRegular() {
		return nil, 0, ErrorCodeInvalidDestination
	}

	file, err := fs.Open(path)
	if err != nil {
		return nil, 0, ErrorCodeDisk
	}
	opened, statErr := file.Stat()
	if statErr != nil {
		_ = file.Close()
		return nil, 0, ErrorCodeDisk
	}
	if !opened.Mode().IsRegular() {
		_ = file.Close()
		return nil, 0, ErrorCodeInvalidDestination
	}
	if !os.SameFile(before, opened) {
		_ = file.Close()
		return nil, 0, ErrorCodeStale
	}

	data, readErr := io.ReadAll(file)
	closeErr := file.Close()
	if readErr != nil || closeErr != nil {
		return nil, 0, ErrorCodeDisk
	}

	after, err := fs.Lstat(path)
	if err != nil {
		return nil, 0, ErrorCodeDisk
	}
	if !after.Mode().IsRegular() {
		return nil, 0, ErrorCodeInvalidDestination
	}
	if !os.SameFile(opened, after) {
		return nil, 0, ErrorCodeStale
	}
	return data, before.Mode().Perm(), 0
}

func writeTemporary(temporary file, source []byte, mode os.FileMode) error {
	if _, err := io.Copy(temporary, bytes.NewReader(source)); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Chmod(mode); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	return temporary.Close()
}

func syncParentDirectory(fs fileSystem, directory string) bool {
	parent, err := fs.OpenDir(directory)
	if err != nil {
		return false
	}
	syncErr := parent.Sync()
	closeErr := parent.Close()
	return syncErr == nil && closeErr == nil
}

type file interface {
	io.Reader
	io.Writer
	Chmod(os.FileMode) error
	Close() error
	Name() string
	Stat() (os.FileInfo, error)
	Sync() error
}

type fileSystem interface {
	CreateTemp(directory, pattern string) (file, error)
	Lstat(path string) (os.FileInfo, error)
	Open(path string) (file, error)
	OpenDir(path string) (file, error)
	Remove(path string) error
	Rename(oldPath, newPath string) error
}

type osFileSystem struct{}

func (osFileSystem) CreateTemp(directory, pattern string) (file, error) {
	return os.CreateTemp(directory, pattern)
}

func (osFileSystem) Lstat(path string) (os.FileInfo, error) {
	return os.Lstat(path)
}

func (osFileSystem) Open(path string) (file, error) {
	return os.Open(path)
}

func (osFileSystem) OpenDir(path string) (file, error) {
	return os.Open(path)
}

func (osFileSystem) Remove(path string) error {
	return os.Remove(path)
}

func (osFileSystem) Rename(oldPath, newPath string) error {
	return os.Rename(oldPath, newPath)
}
