package configstore

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/config"
)

func TestApplyPreservesSchemaV4Source(t *testing.T) {
	source := validConfiguration(t)
	path := writeConfiguration(t, source, 0o600)
	want := editedLabel(source, `label = "Edited Clock"`)

	result, err := Apply(path, Hash(source), editClockLabel)
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if result.Outcome != OutcomeCommitted {
		t.Fatalf("Apply() outcome = %v, want committed", result.Outcome)
	}
	if result.Digest != Hash(want) || !bytes.Equal(result.Bytes, want) {
		t.Fatal("result does not contain the exact validated replacement and digest")
	}
	if !bytes.Contains(result.Bytes, []byte("# Compact schema-v4 Ulanzi D200X configuration")) {
		t.Fatal("source comment was not preserved")
	}

	result.Bytes[0] = '!'
	got := readConfiguration(t, path)
	if !bytes.Equal(got, want) {
		t.Fatal("mutating result bytes changed the committed file")
	}
}

func TestApplyIdenticalMutationDoesNotReplaceSource(t *testing.T) {
	source := validConfiguration(t)
	path := writeConfiguration(t, source, 0o600)
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	createdTemporary := false
	fileSystem := testFileSystem{
		fileSystem: osFileSystem{},
		createTempFn: func(string, string) (file, error) {
			createdTemporary = true
			return nil, errors.New("no-op must not stage a file")
		},
	}

	result, err := apply(fileSystem, absolutePath(t, path), Hash(source), func(source []byte) ([]byte, error) {
		return source, nil
	})
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if result.Outcome != OutcomeUnchanged || result.Digest != Hash(source) || len(result.Bytes) != 0 {
		t.Fatalf("no-op result = %#v, want unchanged with digest and no bytes", result)
	}
	if createdTemporary {
		t.Fatal("no-op mutation staged a temporary file")
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) || !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("no-op mutation changed the destination identity or modification time")
	}
}

func TestApplyRefusesStaleSourceWithoutChangingDestination(t *testing.T) {
	source := validConfiguration(t)
	path := writeConfiguration(t, source, 0o600)
	external := append(bytes.Clone(source), []byte("# comment-only external edit\n")...)
	originalConfig, err := config.Decode(source)
	if err != nil {
		t.Fatal(err)
	}
	externalConfig, err := config.Decode(external)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(originalConfig, externalConfig) {
		t.Fatal("comment-only source change unexpectedly changed configuration semantics")
	}
	if err := os.WriteFile(path, external, 0o600); err != nil {
		t.Fatal(err)
	}
	called := false

	result, err := Apply(path, Hash(source), func([]byte) ([]byte, error) {
		called = true
		return nil, nil
	})
	assertErrorCode(t, err, ErrorCodeStale)
	if result.Outcome != OutcomeUnchanged || len(result.Bytes) != 0 {
		t.Fatalf("stale result = %#v, want unchanged with no bytes", result)
	}
	if called {
		t.Fatal("mutation callback ran for a stale source")
	}
	if got := readConfiguration(t, path); !bytes.Equal(got, external) {
		t.Fatal("stale refusal changed the destination")
	}
}

func TestApplyRefusesChangeBetweenDigestChecks(t *testing.T) {
	source := validConfiguration(t)
	path := writeConfiguration(t, source, 0o600)
	external := append(bytes.Clone(source), []byte("# external edit before final check\n")...)
	fileSystem := testFileSystem{
		fileSystem: osFileSystem{},
		createTempFn: func(directory, pattern string) (file, error) {
			temporary, err := os.CreateTemp(directory, pattern)
			if err != nil {
				return nil, err
			}
			if err := os.WriteFile(path, external, 0o600); err != nil {
				_ = temporary.Close()
				_ = os.Remove(temporary.Name())
				return nil, err
			}
			return temporary, nil
		},
	}

	result, err := apply(fileSystem, absolutePath(t, path), Hash(source), editClockLabel)
	assertErrorCode(t, err, ErrorCodeStale)
	if result.Outcome != OutcomeUnchanged || len(result.Bytes) != 0 {
		t.Fatalf("result = %#v, want unchanged with no bytes", result)
	}
	if got := readConfiguration(t, path); !bytes.Equal(got, external) {
		t.Fatal("change between digest checks was overwritten")
	}
	assertNoTemporaryFiles(t, filepath.Dir(path))
}

func TestApplyPreservesPermissionBits(t *testing.T) {
	source := validConfiguration(t)
	path := writeConfiguration(t, source, 0o640)
	if _, err := Apply(path, Hash(source), editClockLabel); err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o640 {
		t.Fatalf("destination mode = %04o, want 0640", got)
	}
}

func TestApplyRejectsInvalidProspectiveConfiguration(t *testing.T) {
	source := validConfiguration(t)
	path := writeConfiguration(t, source, 0o600)

	result, err := Apply(path, Hash(source), func([]byte) ([]byte, error) {
		return []byte("schema_version = 3\n"), nil
	})
	assertErrorCode(t, err, ErrorCodeInvalidConfiguration)
	if result.Outcome != OutcomeUnchanged {
		t.Fatalf("Apply() outcome = %v, want unchanged", result.Outcome)
	}
	if got := readConfiguration(t, path); !bytes.Equal(got, source) {
		t.Fatal("invalid prospective configuration changed the destination")
	}
	assertNoTemporaryFiles(t, filepath.Dir(path))
}

func TestApplyRejectsSymlinkAndNonregularDestination(t *testing.T) {
	source := validConfiguration(t)
	target := writeConfiguration(t, source, 0o600)

	result, err := Apply(filepath.Dir(target), Hash(source), editClockLabel)
	assertErrorCode(t, err, ErrorCodeInvalidDestination)
	if result.Outcome != OutcomeUnchanged {
		t.Fatalf("directory result outcome = %v, want unchanged", result.Outcome)
	}

	if runtime.GOOS == "windows" {
		return
	}
	link := filepath.Join(filepath.Dir(target), "config-link.toml")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	result, err = Apply(link, Hash(source), editClockLabel)
	assertErrorCode(t, err, ErrorCodeInvalidDestination)
	if result.Outcome != OutcomeUnchanged {
		t.Fatalf("symlink result outcome = %v, want unchanged", result.Outcome)
	}
	if got := readConfiguration(t, target); !bytes.Equal(got, source) {
		t.Fatal("symlink destination target changed")
	}
}

func TestApplySanitizesMutationErrors(t *testing.T) {
	source := validConfiguration(t)
	path := writeConfiguration(t, source, 0o600)
	privateFailure := errors.New("private path and source contents")

	result, err := Apply(path, Hash(source), func([]byte) ([]byte, error) {
		return nil, privateFailure
	})
	assertErrorCode(t, err, ErrorCodeMutation)
	if result.Outcome != OutcomeUnchanged {
		t.Fatalf("Apply() outcome = %v, want unchanged", result.Outcome)
	}
	if strings.Contains(err.Error(), path) || strings.Contains(err.Error(), privateFailure.Error()) {
		t.Fatalf("public error contains private data: %q", err.Error())
	}
}

func TestApplyCleansTemporaryAfterFileSyncAndRenameFailures(t *testing.T) {
	source := validConfiguration(t)
	tests := []struct {
		name     string
		fileSys  testFileSystem
		wantCode ErrorCode
	}{
		{
			name: "file sync",
			fileSys: testFileSystem{
				fileSystem: osFileSystem{},
				createTempFn: func(directory, pattern string) (file, error) {
					created, err := os.CreateTemp(directory, pattern)
					if err != nil {
						return nil, err
					}
					return &hookedFile{
						file:   created,
						syncFn: func() error { return errors.New("private sync failure") },
					}, nil
				},
			},
			wantCode: ErrorCodeDisk,
		},
		{
			name: "rename",
			fileSys: testFileSystem{
				fileSystem: osFileSystem{},
				renameFn: func(string, string) error {
					return errors.New("private rename failure")
				},
			},
			wantCode: ErrorCodeDisk,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			path := writeConfiguration(t, source, 0o600)
			result, err := apply(test.fileSys, absolutePath(t, path), Hash(source), editClockLabel)
			assertErrorCode(t, err, test.wantCode)
			if result.Outcome != OutcomeUnchanged {
				t.Fatalf("Apply() outcome = %v, want unchanged", result.Outcome)
			}
			if strings.Contains(err.Error(), path) || strings.Contains(err.Error(), "private") {
				t.Fatalf("public error contains private data: %q", err.Error())
			}
			if got := readConfiguration(t, path); !bytes.Equal(got, source) {
				t.Fatal("pre-rename failure changed the destination")
			}
			assertNoTemporaryFiles(t, filepath.Dir(path))
		})
	}
}

func TestApplyCleansTemporaryAfterWriteAndCloseFailures(t *testing.T) {
	source := validConfiguration(t)
	tests := []struct {
		name      string
		failWrite bool
		failClose bool
	}{
		{name: "write", failWrite: true},
		{name: "close", failClose: true},
	}

	for _, testCase := range tests {
		t.Run(testCase.name, func(t *testing.T) {
			path := writeConfiguration(t, source, 0o600)
			fileSystem := testFileSystem{
				fileSystem: osFileSystem{},
				createTempFn: func(directory, pattern string) (file, error) {
					created, err := os.CreateTemp(directory, pattern)
					if err != nil {
						return nil, err
					}
					wrapped := &hookedFile{file: created}
					if testCase.failWrite {
						wrapped.writeFn = func([]byte) (int, error) {
							return 0, errors.New("private write failure")
						}
					}
					if testCase.failClose {
						wrapped.closeFn = func() error {
							if err := created.Close(); err != nil {
								return err
							}
							return errors.New("private close failure")
						}
					}
					return wrapped, nil
				},
			}

			result, err := apply(fileSystem, absolutePath(t, path), Hash(source), editClockLabel)
			assertErrorCode(t, err, ErrorCodeDisk)
			if result.Outcome != OutcomeUnchanged {
				t.Fatalf("Apply() outcome = %v, want unchanged", result.Outcome)
			}
			if strings.Contains(err.Error(), "private") {
				t.Fatalf("public error contains injected failure text: %q", err.Error())
			}
			if got := readConfiguration(t, path); !bytes.Equal(got, source) {
				t.Fatal("pre-rename failure changed the destination")
			}
			assertNoTemporaryFiles(t, filepath.Dir(path))
		})
	}
}

func TestApplyReturnsUncertainWithoutRollbackAfterParentSyncFailure(t *testing.T) {
	source := validConfiguration(t)
	want := editedLabel(source, `label = "Edited Clock"`)
	path := writeConfiguration(t, source, 0o600)
	fileSystem := testFileSystem{
		fileSystem: osFileSystem{},
		openDirFn: func(directory string) (file, error) {
			opened, err := os.Open(directory)
			if err != nil {
				return nil, err
			}
			return &hookedFile{
				file:    opened,
				syncFn:  func() error { return errors.New("private directory sync failure") },
				closeFn: opened.Close,
			}, nil
		},
	}

	result, err := apply(fileSystem, absolutePath(t, path), Hash(source), editClockLabel)
	assertErrorCode(t, err, ErrorCodeUncertain)
	if result.Outcome != OutcomeUncertain || result.Digest != Hash(want) || !bytes.Equal(result.Bytes, want) {
		t.Fatalf("uncertain result = %#v, want exact renamed bytes and digest", result)
	}
	if got := readConfiguration(t, path); !bytes.Equal(got, want) {
		t.Fatal("parent sync failure triggered rollback or changed committed bytes")
	}
	assertNoTemporaryFiles(t, filepath.Dir(path))
}

func TestApplyReadersSeeOnlyCompleteOldOrNewSource(t *testing.T) {
	source := validConfiguration(t)
	want := editedLabel(source, `label = "Edited Clock"`)
	path := writeConfiguration(t, source, 0o600)
	renameStarted := make(chan struct{})
	allowRename := make(chan struct{})
	renameFinished := make(chan struct{})
	allowReturn := make(chan struct{})
	fileSystem := testFileSystem{
		fileSystem: osFileSystem{},
		renameFn: func(oldPath, newPath string) error {
			close(renameStarted)
			<-allowRename
			err := os.Rename(oldPath, newPath)
			close(renameFinished)
			<-allowReturn
			return err
		},
	}
	resultCh := make(chan Result, 1)
	errCh := make(chan error, 1)
	absPath := absolutePath(t, path)
	go func() {
		result, err := apply(fileSystem, absPath, Hash(source), editClockLabel)
		resultCh <- result
		errCh <- err
	}()
	select {
	case <-renameStarted:
	case err := <-errCh:
		t.Fatalf("Apply() returned before rename: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for rename")
	}

	readerDone := make(chan struct{})
	readerExited := make(chan struct{})
	readerSawOld := make(chan struct{})
	readerSawNew := make(chan struct{})
	readerErr := make(chan error, 1)
	var stopReaderOnce sync.Once
	stopReader := func() {
		stopReaderOnce.Do(func() { close(readerDone) })
		select {
		case <-readerExited:
		case <-time.After(5 * time.Second):
			t.Error("reader did not stop")
		}
	}
	go func() {
		defer close(readerExited)
		oldSeen := false
		newSeen := false
		for {
			current, err := os.ReadFile(path)
			if err != nil {
				readerErr <- err
				return
			}
			switch {
			case bytes.Equal(current, source):
				if !oldSeen {
					oldSeen = true
					close(readerSawOld)
				}
			case bytes.Equal(current, want):
				if !newSeen {
					newSeen = true
					close(readerSawNew)
				}
			default:
				readerErr <- errors.New("reader observed a partial configuration")
				return
			}
			select {
			case <-readerDone:
				return
			default:
			}
		}
	}()
	defer stopReader()

	waitFor(t, readerSawOld, readerErr)
	close(allowRename)
	<-renameFinished
	waitFor(t, readerSawNew, readerErr)
	close(allowReturn)

	result := <-resultCh
	if err := <-errCh; err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if result.Outcome != OutcomeCommitted {
		t.Fatalf("Apply() outcome = %v, want committed", result.Outcome)
	}
	stopReader()
}

func TestApplyDocumentsResidualExternalWriterRace(t *testing.T) {
	source := validConfiguration(t)
	external := editedLabel(source, `label = "External Clock"`)
	want := editedLabel(source, `label = "Edited Clock"`)
	path := writeConfiguration(t, source, 0o600)
	fileSystem := testFileSystem{
		fileSystem: osFileSystem{},
		renameFn: func(oldPath, newPath string) error {
			if err := os.WriteFile(newPath, external, 0o600); err != nil {
				return err
			}
			return os.Rename(oldPath, newPath)
		},
	}

	result, err := apply(fileSystem, absolutePath(t, path), Hash(source), editClockLabel)
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if result.Outcome != OutcomeCommitted {
		t.Fatalf("Apply() outcome = %v, want committed", result.Outcome)
	}
	if got := readConfiguration(t, path); !bytes.Equal(got, want) {
		t.Fatal("injected writer was not overwritten in the documented check-to-rename race")
	}
}

func validConfiguration(t *testing.T) []byte {
	t.Helper()
	source, err := os.ReadFile(filepath.Join("..", "config", "testdata", "valid.toml"))
	if err != nil {
		t.Fatal(err)
	}
	return source
}

func editedLabel(source []byte, replacement string) []byte {
	return bytes.Replace(source, []byte(`label = "Clock"`), []byte(replacement), 1)
}

func editClockLabel(source []byte) ([]byte, error) {
	return editedLabel(source, `label = "Edited Clock"`), nil
}

func writeConfiguration(t *testing.T, source []byte, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, source, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func readConfiguration(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func absolutePath(t *testing.T, path string) string {
	t.Helper()
	absPath, err := filepath.Abs(path)
	if err != nil {
		t.Fatal(err)
	}
	return absPath
}

func assertErrorCode(t *testing.T, err error, want ErrorCode) {
	t.Helper()
	if err == nil {
		t.Fatalf("error = nil, want code %d", want)
	}
	got, ok := ErrorCodeOf(err)
	if !ok || got != want {
		t.Fatalf("error code = %d, present = %t, want %d", got, ok, want)
	}
}

func assertNoTemporaryFiles(t *testing.T, directory string) {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".hidhogg-config-") {
			t.Fatalf("temporary file remains after failure: %q", entry.Name())
		}
	}
}

func waitFor(t *testing.T, target <-chan struct{}, failures <-chan error) {
	t.Helper()
	select {
	case <-target:
	case err := <-failures:
		t.Fatalf("reader failed: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for reader observation")
	}
}

type testFileSystem struct {
	fileSystem
	createTempFn func(directory, pattern string) (file, error)
	openDirFn    func(path string) (file, error)
	renameFn     func(oldPath, newPath string) error
}

func (fs testFileSystem) CreateTemp(directory, pattern string) (file, error) {
	if fs.createTempFn != nil {
		return fs.createTempFn(directory, pattern)
	}
	return fs.fileSystem.CreateTemp(directory, pattern)
}

func (fs testFileSystem) OpenDir(path string) (file, error) {
	if fs.openDirFn != nil {
		return fs.openDirFn(path)
	}
	return fs.fileSystem.OpenDir(path)
}

func (fs testFileSystem) Rename(oldPath, newPath string) error {
	if fs.renameFn != nil {
		return fs.renameFn(oldPath, newPath)
	}
	return fs.fileSystem.Rename(oldPath, newPath)
}

type hookedFile struct {
	file
	writeFn func([]byte) (int, error)
	syncFn  func() error
	closeFn func() error
}

func (f *hookedFile) Write(source []byte) (int, error) {
	if f.writeFn != nil {
		return f.writeFn(source)
	}
	return f.file.Write(source)
}

func (f *hookedFile) Sync() error {
	if f.syncFn != nil {
		return f.syncFn()
	}
	return f.file.Sync()
}

func (f *hookedFile) Close() error {
	if f.closeFn != nil {
		return f.closeFn()
	}
	return f.file.Close()
}
