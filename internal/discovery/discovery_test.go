//go:build !windows

package discovery

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

const testInstanceID = "11111111-1111-4111-8111-111111111111"

func secureRuntimeDir(t *testing.T) string {
	t.Helper()
	path, err := os.MkdirTemp(".", ".d-")
	if err != nil {
		t.Fatalf("create short runtime directory: %v", err)
	}
	absolutePath, err := filepath.Abs(path)
	if err != nil {
		_ = os.RemoveAll(path)
		t.Fatalf("resolve short runtime directory: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(absolutePath) })
	path = absolutePath
	if err := os.Chmod(path, 0o700); err != nil {
		t.Fatalf("chmod runtime directory: %v", err)
	}
	return path
}

func openTestGeneration(t *testing.T, runtimeDir string) *Generation {
	t.Helper()
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	t.Cleanup(func() {
		if err := generation.Close(); err != nil {
			t.Errorf("close generation: %v", err)
		}
	})
	return generation
}

func closeWithin(t *testing.T, generation *Generation) error {
	t.Helper()
	result := make(chan error, 1)
	go func() { result <- generation.Close() }()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case err := <-result:
		return err
	case <-timer.C:
		t.Fatal("generation close did not complete within 2 seconds")
		return nil
	}
}

func bindTestSocket(t *testing.T, path string) *net.UnixListener {
	t.Helper()
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatalf("bind Unix socket: %v", err)
	}
	listener.SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		t.Fatalf("chmod Unix socket: %v", err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
		_ = os.Remove(path)
	})
	return listener
}

func TestDirectoryAndPersistentLockLifecycle(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation := openTestGeneration(t, runtimeDir)
	paths := generation.Paths()
	lockInfo, err := os.Lstat(paths.LockPath)
	if err != nil {
		t.Fatalf("lstat runtime lock: %v", err)
	}
	if !lockInfo.Mode().IsRegular() || lockInfo.Mode().Perm() != 0o600 {
		t.Fatalf("runtime lock mode/type = %v, want regular 0600", lockInfo.Mode())
	}
	lockIdentity, err := ValidateLock(paths.LockPath)
	if err != nil {
		t.Fatalf("validate runtime lock: %v", err)
	}
	if err := generation.Close(); err != nil {
		t.Fatalf("close first generation: %v", err)
	}
	if _, err := os.Lstat(paths.LockPath); err != nil {
		t.Fatalf("persistent runtime lock missing after close: %v", err)
	}
	second, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("reuse persistent lock: %v", err)
	}
	defer second.Close()
	secondIdentity, err := ValidateLock(paths.LockPath)
	if err != nil {
		t.Fatalf("validate reused runtime lock: %v", err)
	}
	if !lockIdentity.Equal(secondIdentity) {
		t.Fatalf("persistent lock identity changed: first=%+v second=%+v", lockIdentity, secondIdentity)
	}
}

func TestDirectoryValidationRejectsUnsafeState(t *testing.T) {
	tests := []struct {
		name  string
		setup func(t *testing.T, path string)
	}{
		{name: "relative", setup: func(t *testing.T, path string) {}},
		{name: "symlink", setup: func(t *testing.T, path string) {
			target := secureRuntimeDir(t)
			if err := os.Symlink(target, path); err != nil {
				t.Fatalf("symlink runtime directory: %v", err)
			}
		}},
		{name: "wrong mode", setup: func(t *testing.T, path string) {
			if err := os.Mkdir(path, 0o755); err != nil {
				t.Fatalf("mkdir runtime directory: %v", err)
			}
		}},
		{name: "regular file", setup: func(t *testing.T, path string) {
			if err := os.WriteFile(path, []byte("x"), 0o700); err != nil {
				t.Fatalf("write runtime path: %v", err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if test.name == "relative" {
				if _, err := Open(Options{RuntimeDir: "relative", InstanceID: testInstanceID}); err == nil {
					t.Fatal("relative runtime directory unexpectedly accepted")
				}
				return
			}
			parent := t.TempDir()
			path := filepath.Join(parent, "runtime")
			test.setup(t, path)
			if _, err := Open(Options{RuntimeDir: path, InstanceID: testInstanceID}); err == nil {
				t.Fatal("unsafe runtime directory unexpectedly accepted")
			}
		})
	}
}

func TestLockContention(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	first := openTestGeneration(t, runtimeDir)
	defer first.Close()
	second, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: "22222222-2222-4222-8222-222222222222"})
	if !errors.Is(err, ErrDirectoryBusy) {
		t.Fatalf("second open error = %v, want ErrDirectoryBusy", err)
	}
	if second != nil {
		_ = second.Close()
		t.Fatal("second open returned a generation on contention")
	}
}

func TestLockReleasedOnProcessExit(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	command := exec.Command(os.Args[0], "-test.run=TestDiscoveryLockHelperProcess", "--", "--discovery-lock-helper", runtimeDir)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatalf("helper stdout pipe: %v", err)
	}
	if err := command.Start(); err != nil {
		t.Fatalf("start lock helper: %v", err)
	}
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil {
		t.Fatalf("read lock helper readiness: %v", err)
	}
	if strings.TrimSpace(line) != "locked" {
		t.Fatalf("lock helper readiness = %q", line)
	}
	if _, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID}); !errors.Is(err, ErrDirectoryBusy) {
		t.Fatalf("open during helper lifetime error = %v, want ErrDirectoryBusy", err)
	}
	if err := command.Wait(); err != nil {
		t.Fatalf("wait lock helper: %v", err)
	}
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open after helper exit: %v", err)
	}
	defer generation.Close()
}

func TestDiscoveryLockHelperProcess(t *testing.T) {
	arguments := os.Args
	for index, argument := range arguments {
		if argument != "--discovery-lock-helper" || index+1 >= len(arguments) {
			continue
		}
		generation, err := Open(Options{RuntimeDir: arguments[index+1], InstanceID: testInstanceID})
		if err != nil {
			t.Fatalf("helper open generation: %v", err)
		}
		_ = generation
		fmt.Fprintln(os.Stdout, "locked")
		return
	}
}

func TestUUIDGenerationAndNormalization(t *testing.T) {
	source := bytes.NewReader([]byte{
		0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
		0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
	})
	generated, err := GenerateUUIDv4(source)
	if err != nil {
		t.Fatalf("generate UUIDv4: %v", err)
	}
	if generated != "00112233-4455-4677-8899-aabbccddeeff" {
		t.Fatalf("generated UUID = %q", generated)
	}
	canonical, err := NormalizeInstanceID(strings.ToUpper(generated))
	if err != nil {
		t.Fatalf("normalize uppercase UUID: %v", err)
	}
	if canonical != generated {
		t.Fatalf("normalized UUID = %q, want %q", canonical, generated)
	}
	if _, err := GenerateUUIDv4(bytes.NewReader([]byte{1})); err == nil {
		t.Fatal("short UUID source unexpectedly accepted")
	}
	for _, invalid := range []string{"", "not-a-uuid", "001122334455-4677-8899-aabb-ccddeeff", "00112233-4455-4677-8899-aabbccddeefg"} {
		if _, err := NormalizeInstanceID(invalid); err == nil {
			t.Fatalf("invalid UUID %q unexpectedly accepted", invalid)
		}
	}
}

func TestOpenNormalizesExplicitUUIDAndInjectsGeneratedUUID(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	uppercaseGeneration, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: strings.ToUpper(testInstanceID)})
	if err != nil {
		t.Fatalf("open uppercase explicit UUID: %v", err)
	}
	if uppercaseGeneration.InstanceID() != testInstanceID {
		t.Fatalf("normalized explicit UUID = %q, want %q", uppercaseGeneration.InstanceID(), testInstanceID)
	}
	if err := uppercaseGeneration.Close(); err != nil {
		t.Fatalf("close uppercase generation: %v", err)
	}

	source := bytes.NewReader([]byte{
		0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
		0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
	})
	generatedGeneration, err := Open(Options{RuntimeDir: runtimeDir, Random: source})
	if err != nil {
		t.Fatalf("open deterministic UUID generation: %v", err)
	}
	defer generatedGeneration.Close()
	if generatedGeneration.InstanceID() != "00112233-4455-4677-8899-aabbccddeeff" {
		t.Fatalf("deterministic generated UUID = %q", generatedGeneration.InstanceID())
	}
}

func TestMetadataStrictness(t *testing.T) {
	metadata := Metadata{SchemaVersion: MetadataSchemaVersion, InstanceID: testInstanceID, SocketName: SocketFileName}
	encoded, err := EncodeMetadata(metadata)
	if err != nil {
		t.Fatalf("encode metadata: %v", err)
	}
	if string(encoded) != `{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock"}` {
		t.Fatalf("metadata JSON = %s", encoded)
	}
	decoded, err := DecodeMetadata(encoded)
	if err != nil || decoded != metadata {
		t.Fatalf("decode metadata = %+v, err=%v", decoded, err)
	}
	reordered := []byte("{\n  \"socket_name\": \"runtime.sock\",\n  \"instance_id\": \"11111111-1111-4111-8111-111111111111\",\n  \"schema_version\": 1\n}")
	if decoded, err := DecodeMetadata(reordered); err != nil || decoded != metadata {
		t.Fatalf("decode valid reordered metadata = %+v, err=%v", decoded, err)
	}
	invalid := [][]byte{
		[]byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock","extra":true}`),
		[]byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket":"runtime.sock"}`),
		[]byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock","socket_name":"runtime.sock"}`),
		[]byte(`{"schema_version":1.0,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock"}`),
		[]byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock"} trailing`),
		[]byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"wrong.sock"}`),
		[]byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111"}`),
	}
	for _, value := range invalid {
		if _, err := DecodeMetadata(value); err == nil {
			t.Fatalf("invalid metadata unexpectedly accepted: %s", value)
		}
	}
	if _, err := DecodeMetadata(bytes.Repeat([]byte{'x'}, MaxMetadataBytes+1)); err == nil {
		t.Fatal("oversized metadata unexpectedly accepted")
	}
}

func TestStaleRecoveryAndReadinessPublication(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	paths, err := NewPaths(runtimeDir)
	if err != nil {
		t.Fatalf("new paths: %v", err)
	}
	if err := os.WriteFile(paths.MetadataPath, []byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock"}`), 0o600); err != nil {
		t.Fatalf("write stale metadata: %v", err)
	}
	listener := bindTestSocket(t, paths.SocketPath)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("recover stale generation: %v", err)
	}
	if _, err := os.Lstat(paths.MetadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale metadata remains, lstat error = %v", err)
	}
	if _, err := os.Lstat(paths.SocketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale socket remains, lstat error = %v", err)
	}
	if _, err := generation.RecordSocket(); err == nil {
		t.Fatal("record socket after stale removal unexpectedly succeeded")
	}
	_ = listener.Close()
	_ = generation.Close()

	generation, err = Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open second generation: %v", err)
	}
	defer generation.Close()
	listener = bindTestSocket(t, paths.SocketPath)
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record bound socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish readiness metadata: %v", err)
	}
	resolved, err := Resolve(runtimeDir)
	if err != nil {
		t.Fatalf("resolve published generation: %v", err)
	}
	if resolved.Metadata.InstanceID != testInstanceID {
		t.Fatalf("resolved instance ID = %q", resolved.Metadata.InstanceID)
	}
	if err := resolved.Revalidate(); err != nil {
		t.Fatalf("revalidate published generation: %v", err)
	}
	if err := generation.PublishMetadata(); !errors.Is(err, ErrMetadataExists) {
		t.Fatalf("second metadata publication error = %v", err)
	}
}

func TestWithdrawMetadataBeforePublicationIsNoOp(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation := openTestGeneration(t, runtimeDir)
	paths := generation.Paths()
	if err := generation.WithdrawMetadata(); err != nil {
		t.Fatalf("withdraw before publication: %v", err)
	}
	if _, err := os.Lstat(paths.MetadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unexpected metadata after no-op withdrawal: %v", err)
	}
	if _, err := ValidateLock(paths.LockPath); err != nil {
		t.Fatalf("runtime lock changed after no-op withdrawal: %v", err)
	}
}

func TestWithdrawMetadataRetainsSocketAndLock(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	paths := generation.Paths()
	lockBefore, err := ValidateLock(paths.LockPath)
	if err != nil {
		t.Fatalf("validate lock before withdrawal: %v", err)
	}
	socketBefore, err := ValidateSocket(paths.SocketPath)
	if err != nil {
		t.Fatalf("validate socket before withdrawal: %v", err)
	}
	if err := generation.WithdrawMetadata(); err != nil {
		t.Fatalf("withdraw published metadata: %v", err)
	}
	if _, err := os.Lstat(paths.MetadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata remains after withdrawal: %v", err)
	}
	socketAfter, err := ValidateSocket(paths.SocketPath)
	if err != nil {
		t.Fatalf("validate socket after withdrawal: %v", err)
	}
	if !socketAfter.Equal(socketBefore) {
		t.Fatalf("socket identity changed after withdrawal: before=%+v after=%+v", socketBefore, socketAfter)
	}
	lockAfter, err := ValidateLock(paths.LockPath)
	if err != nil {
		t.Fatalf("validate lock after withdrawal: %v", err)
	}
	if !lockAfter.Equal(lockBefore) {
		t.Fatalf("lock identity changed after withdrawal: before=%+v after=%+v", lockBefore, lockAfter)
	}
	if err := generation.WithdrawMetadata(); err != nil {
		t.Fatalf("repeated withdrawal: %v", err)
	}
	if err := generation.Close(); err != nil {
		t.Fatalf("close after withdrawal: %v", err)
	}
	if _, err := os.Lstat(paths.SocketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket remains after close: %v", err)
	}
	if _, err := os.Lstat(paths.LockPath); err != nil {
		t.Fatalf("persistent lock missing after close: %v", err)
	}
	_ = listener
}

func TestCloseDirectlyWithdrawsPublishedMetadata(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	paths := generation.Paths()
	if err := closeWithin(t, generation); err != nil {
		t.Fatalf("direct close: %v", err)
	}
	if _, err := os.Lstat(paths.MetadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata remains after direct close: %v", err)
	}
	if _, err := os.Lstat(paths.SocketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket remains after direct close: %v", err)
	}
	if _, err := ValidateLock(paths.LockPath); err != nil {
		t.Fatalf("persistent lock changed after direct close: %v", err)
	}
	_ = listener
}

func TestCloseDirectlyPreservesSubstitutedMetadataAndReleasesLock(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	metadataBytes, err := os.ReadFile(generation.MetadataPath())
	if err != nil {
		t.Fatalf("read metadata: %v", err)
	}
	if err := os.Remove(generation.MetadataPath()); err != nil {
		t.Fatalf("remove metadata for substitution: %v", err)
	}
	if err := os.WriteFile(generation.MetadataPath(), metadataBytes, 0o600); err != nil {
		t.Fatalf("write substituted metadata: %v", err)
	}
	if err := closeWithin(t, generation); err == nil {
		t.Fatal("direct close after metadata substitution unexpectedly succeeded")
	}
	actual, err := os.ReadFile(generation.MetadataPath())
	if err != nil {
		t.Fatalf("read preserved metadata: %v", err)
	}
	if !bytes.Equal(actual, metadataBytes) {
		t.Fatalf("preserved metadata changed: %q", actual)
	}
	if err := os.Remove(generation.MetadataPath()); err != nil {
		t.Fatalf("remove questionable metadata: %v", err)
	}
	second, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open after failed direct close: %v", err)
	}
	defer second.Close()
	_ = listener
}

func TestWithdrawMetadataPreservesSubstitutionAndCloseRetries(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	metadataBytes, err := os.ReadFile(generation.MetadataPath())
	if err != nil {
		t.Fatalf("read metadata: %v", err)
	}
	if err := os.Remove(generation.MetadataPath()); err != nil {
		t.Fatalf("remove metadata for substitution: %v", err)
	}
	if err := os.WriteFile(generation.MetadataPath(), metadataBytes, 0o600); err != nil {
		t.Fatalf("write substituted metadata: %v", err)
	}
	if err := generation.WithdrawMetadata(); err == nil {
		t.Fatal("withdraw substituted metadata unexpectedly succeeded")
	}
	actual, err := os.ReadFile(generation.MetadataPath())
	if err != nil {
		t.Fatalf("read substituted metadata: %v", err)
	}
	if !bytes.Equal(actual, metadataBytes) {
		t.Fatalf("substituted metadata changed after failed withdrawal: %q", actual)
	}
	if err := generation.Close(); err == nil {
		t.Fatal("close after substituted metadata unexpectedly succeeded")
	}
	actual, err = os.ReadFile(generation.MetadataPath())
	if err != nil {
		t.Fatalf("read metadata after close retry: %v", err)
	}
	if !bytes.Equal(actual, metadataBytes) {
		t.Fatalf("substituted metadata changed after close retry: %q", actual)
	}
	if _, err := os.Lstat(generation.SocketPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket was not cleaned after metadata withdrawal failure: %v", err)
	}
	if _, err := ValidateLock(generation.Paths().LockPath); err != nil {
		t.Fatalf("persistent lock changed after metadata withdrawal failure: %v", err)
	}
	_ = listener
}

func TestWithdrawMetadataRetriesAfterValidationFailure(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	metadataPath := generation.MetadataPath()
	if err := os.Chmod(metadataPath, 0o644); err != nil {
		t.Fatalf("substitute metadata mode: %v", err)
	}
	if err := generation.WithdrawMetadata(); err == nil {
		t.Fatal("withdraw invalid metadata unexpectedly succeeded")
	}
	if _, err := os.Lstat(metadataPath); err != nil {
		t.Fatalf("metadata not preserved after failed withdrawal: %v", err)
	}
	if err := os.Chmod(metadataPath, 0o600); err != nil {
		t.Fatalf("restore metadata mode: %v", err)
	}
	if err := generation.WithdrawMetadata(); err != nil {
		t.Fatalf("withdraw after restoring metadata: %v", err)
	}
	if _, err := os.Lstat(metadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata remains after retry: %v", err)
	}
	if err := generation.Close(); err != nil {
		t.Fatalf("close after successful retry: %v", err)
	}
	_ = listener
}

func TestConcurrentWithdrawMetadataIsIdempotent(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	const callers = 8
	var waitGroup sync.WaitGroup
	errorsSeen := make(chan error, callers)
	start := make(chan struct{})
	for index := 0; index < callers; index++ {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			<-start
			errorsSeen <- generation.WithdrawMetadata()
		}()
	}
	close(start)
	completed := make(chan struct{})
	go func() {
		waitGroup.Wait()
		close(completed)
	}()
	select {
	case <-completed:
	case <-time.After(2 * time.Second):
		t.Fatal("concurrent withdrawal did not complete within 2 seconds")
	}
	close(errorsSeen)
	for err := range errorsSeen {
		if err != nil {
			t.Fatalf("concurrent withdrawal: %v", err)
		}
	}
	if _, err := os.Lstat(generation.MetadataPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata remains after concurrent withdrawal: %v", err)
	}
	if _, err := ValidateSocket(generation.SocketPath()); err != nil {
		t.Fatalf("socket changed after concurrent withdrawal: %v", err)
	}
	if _, err := ValidateLock(generation.Paths().LockPath); err != nil {
		t.Fatalf("lock changed after concurrent withdrawal: %v", err)
	}
	if err := generation.Close(); err != nil {
		t.Fatalf("close after concurrent withdrawal: %v", err)
	}
	_ = listener
}

func TestConcurrentWithdrawMetadataAndClose(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	const callers = 8
	var waitGroup sync.WaitGroup
	errorsSeen := make(chan error, callers)
	start := make(chan struct{})
	for index := 0; index < callers/2; index++ {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			<-start
			errorsSeen <- generation.WithdrawMetadata()
		}()
	}
	for index := 0; index < callers/2; index++ {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			<-start
			errorsSeen <- generation.Close()
		}()
	}
	close(start)
	completed := make(chan struct{})
	go func() {
		waitGroup.Wait()
		close(completed)
	}()
	select {
	case <-completed:
	case <-time.After(2 * time.Second):
		t.Fatal("concurrent withdrawal/close did not complete within 2 seconds")
	}
	close(errorsSeen)
	for err := range errorsSeen {
		if err != nil {
			t.Fatalf("concurrent withdrawal/close: %v", err)
		}
	}
	if err := generation.WithdrawMetadata(); err != nil {
		t.Fatalf("repeated withdrawal after close: %v", err)
	}
	if _, err := os.Lstat(generation.MetadataPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("metadata remains after concurrent close: %v", err)
	}
	if _, err := os.Lstat(generation.SocketPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket remains after concurrent close: %v", err)
	}
	if _, err := ValidateLock(generation.Paths().LockPath); err != nil {
		t.Fatalf("persistent lock changed after concurrent close: %v", err)
	}
	_ = listener
}

func TestMalformedRecoveryPreservesEntries(t *testing.T) {
	tests := []struct {
		name  string
		entry func(t *testing.T, paths Paths)
		check func(t *testing.T, paths Paths)
	}{
		{name: "malformed metadata", entry: func(t *testing.T, paths Paths) {
			if err := os.WriteFile(paths.MetadataPath, []byte("not-json"), 0o600); err != nil {
				t.Fatalf("write malformed metadata: %v", err)
			}
		}, check: func(t *testing.T, paths Paths) {
			assertEntryExists(t, paths.MetadataPath)
		}},
		{name: "substituted metadata", entry: func(t *testing.T, paths Paths) {
			if err := os.WriteFile(paths.MetadataPath, []byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock"}`), 0o644); err != nil {
				t.Fatalf("write substituted metadata: %v", err)
			}
		}, check: func(t *testing.T, paths Paths) {
			assertEntryExists(t, paths.MetadataPath)
		}},
		{name: "substituted socket", entry: func(t *testing.T, paths Paths) {
			if err := os.WriteFile(paths.SocketPath, []byte("not-a-socket"), 0o600); err != nil {
				t.Fatalf("write substituted socket: %v", err)
			}
		}, check: func(t *testing.T, paths Paths) {
			assertEntryExists(t, paths.SocketPath)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runtimeDir := secureRuntimeDir(t)
			paths, err := NewPaths(runtimeDir)
			if err != nil {
				t.Fatalf("new paths: %v", err)
			}
			test.entry(t, paths)
			if _, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID}); err == nil {
				t.Fatal("malformed or substituted generation unexpectedly recovered")
			}
			test.check(t, paths)
		})
	}
}

func assertEntryExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err != nil {
		t.Fatalf("entry %s was not preserved: %v", filepath.Base(path), err)
	}
}

func TestGuardedCleanupPreservesSubstitution(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	metadataBytes, err := os.ReadFile(generation.MetadataPath())
	if err != nil {
		t.Fatalf("read metadata: %v", err)
	}
	if err := os.Remove(generation.MetadataPath()); err != nil {
		t.Fatalf("remove metadata for substitution: %v", err)
	}
	if err := os.WriteFile(generation.MetadataPath(), metadataBytes, 0o600); err != nil {
		t.Fatalf("write substituted metadata: %v", err)
	}
	if err := generation.Close(); err == nil {
		t.Fatal("cleanup substitution unexpectedly succeeded")
	}
	assertEntryExists(t, generation.MetadataPath())
	if _, err := os.Lstat(filepath.Join(runtimeDir, LockFileName)); err != nil {
		t.Fatalf("persistent lock removed during guarded cleanup: %v", err)
	}
	_ = listener.Close()
	_ = os.Remove(generation.SocketPath())
}

func TestResolutionRevalidationDetectsIdentityAndContentChanges(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	resolved, err := Resolve(runtimeDir)
	if err != nil {
		t.Fatalf("resolve generation: %v", err)
	}
	if err := os.WriteFile(generation.MetadataPath(), []byte(`{"schema_version":1,"instance_id":"22222222-2222-4222-8222-222222222222","socket_name":"runtime.sock"}`), 0o600); err != nil {
		t.Fatalf("rewrite metadata: %v", err)
	}
	if err := resolved.Revalidate(); err == nil {
		t.Fatal("metadata content substitution unexpectedly revalidated")
	}
	_ = listener.Close()
	if err := os.Remove(generation.SocketPath()); err != nil {
		t.Fatalf("remove original socket: %v", err)
	}
	replacement := bindTestSocket(t, generation.SocketPath())
	if err := resolved.Revalidate(); err == nil {
		t.Fatal("socket identity substitution unexpectedly revalidated")
	}
	_ = replacement
	_ = generation.Close()
}

func TestResolutionRevalidationPreservesDirectoryPathSubstitution(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	resolved, err := Resolve(runtimeDir)
	if err != nil {
		t.Fatalf("resolve generation: %v", err)
	}
	movedPath := runtimeDir + "-moved"
	if err := os.Rename(runtimeDir, movedPath); err != nil {
		t.Fatalf("move runtime directory: %v", err)
	}
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatalf("substitute runtime directory pathname: %v", err)
	}
	if err := resolved.Revalidate(); err == nil {
		t.Fatal("directory pathname substitution unexpectedly revalidated")
	}
	if _, err := os.Lstat(runtimeDir); err != nil {
		t.Fatalf("directory replacement was not preserved: %v", err)
	}
	for _, path := range []string{
		filepath.Join(movedPath, LockFileName),
		filepath.Join(movedPath, MetadataFileName),
		filepath.Join(movedPath, SocketFileName),
	} {
		assertEntryExists(t, path)
	}
	_ = listener.Close()
	if err := generation.Close(); err == nil {
		t.Fatal("cleanup across directory pathname substitution unexpectedly succeeded")
	}
	if err := os.RemoveAll(movedPath); err != nil {
		t.Fatalf("remove moved runtime directory: %v", err)
	}
}

func TestResolutionRevalidationPreservesLockPathSubstitution(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open generation: %v", err)
	}
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	if err := generation.PublishMetadata(); err != nil {
		t.Fatalf("publish metadata: %v", err)
	}
	resolved, err := Resolve(runtimeDir)
	if err != nil {
		t.Fatalf("resolve generation: %v", err)
	}
	paths := generation.Paths()
	if err := os.Remove(paths.LockPath); err != nil {
		t.Fatalf("remove lock pathname for substitution: %v", err)
	}
	replacementBytes := []byte("replacement lock")
	if err := os.WriteFile(paths.LockPath, replacementBytes, 0o600); err != nil {
		t.Fatalf("write replacement lock: %v", err)
	}
	replacementIdentity, err := ValidateLock(paths.LockPath)
	if err != nil {
		t.Fatalf("validate replacement lock: %v", err)
	}
	if replacementIdentity.Equal(resolved.LockID) {
		t.Fatal("replacement lock unexpectedly retained the original identity")
	}
	if err := resolved.Revalidate(); err == nil {
		t.Fatal("lock pathname/inode substitution unexpectedly revalidated")
	}
	actual, err := os.ReadFile(paths.LockPath)
	if err != nil {
		t.Fatalf("read replacement lock: %v", err)
	}
	if !bytes.Equal(actual, replacementBytes) {
		t.Fatalf("replacement lock changed after revalidation: %q", actual)
	}
	_ = listener
	if err := generation.Close(); err != nil {
		t.Fatalf("close generation after lock substitution: %v", err)
	}
	if actual, err := os.ReadFile(paths.LockPath); err != nil || !bytes.Equal(actual, replacementBytes) {
		t.Fatalf("replacement lock was not preserved after close: %q, %v", actual, err)
	}
}

func TestTwoDirectoriesCanCoexist(t *testing.T) {
	firstDir := secureRuntimeDir(t)
	secondDir := secureRuntimeDir(t)
	first, err := Open(Options{RuntimeDir: firstDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open first directory: %v", err)
	}
	defer first.Close()
	second, err := Open(Options{RuntimeDir: secondDir, InstanceID: testInstanceID})
	if err != nil {
		t.Fatalf("open second directory: %v", err)
	}
	defer second.Close()
	if first.RuntimeDir() == second.RuntimeDir() {
		t.Fatal("distinct runtime directories collapsed")
	}
}

func TestAtomicPublicationDoesNotReplaceExistingMetadata(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation := openTestGeneration(t, runtimeDir)
	listener := bindTestSocket(t, generation.SocketPath())
	if _, err := generation.RecordSocket(); err != nil {
		t.Fatalf("record socket: %v", err)
	}
	existing := []byte(`{"schema_version":1,"instance_id":"22222222-2222-4222-8222-222222222222","socket_name":"runtime.sock"}`)
	if err := os.WriteFile(generation.MetadataPath(), existing, 0o600); err != nil {
		t.Fatalf("create pre-existing metadata: %v", err)
	}
	if err := generation.PublishMetadata(); !errors.Is(err, ErrMetadataExists) {
		t.Fatalf("publish over existing metadata error = %v", err)
	}
	actual, err := os.ReadFile(generation.MetadataPath())
	if err != nil {
		t.Fatalf("read existing metadata: %v", err)
	}
	if !bytes.Equal(actual, existing) {
		t.Fatalf("existing metadata changed: %s", actual)
	}
	_ = listener
}

func TestMetadataValidationRejectsSymlink(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	paths, err := NewPaths(runtimeDir)
	if err != nil {
		t.Fatalf("new paths: %v", err)
	}
	target := filepath.Join(runtimeDir, "metadata-target")
	if err := os.WriteFile(target, []byte(`{"schema_version":1,"instance_id":"11111111-1111-4111-8111-111111111111","socket_name":"runtime.sock"}`), 0o600); err != nil {
		t.Fatalf("write metadata target: %v", err)
	}
	if err := os.Symlink(target, paths.MetadataPath); err != nil {
		t.Fatalf("symlink metadata: %v", err)
	}
	if _, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID}); err == nil {
		t.Fatal("metadata symlink unexpectedly accepted")
	}
	assertEntryExists(t, paths.MetadataPath)
}

func TestCloseWithoutPublicationRetainsLock(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation := openTestGeneration(t, runtimeDir)
	paths := generation.Paths()
	if err := generation.Close(); err != nil {
		t.Fatalf("close generation: %v", err)
	}
	if _, err := os.Lstat(paths.LockPath); err != nil {
		t.Fatalf("runtime lock missing after close: %v", err)
	}
	if _, err := os.Lstat(paths.MetadataPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unexpected metadata after close: %v", err)
	}
}

func TestConcurrentCloseSharesCleanupResult(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	generation := openTestGeneration(t, runtimeDir)
	var waitGroup sync.WaitGroup
	errorsSeen := make(chan error, 8)
	for index := 0; index < 8; index++ {
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			errorsSeen <- generation.Close()
		}()
	}
	waitGroup.Wait()
	close(errorsSeen)
	for err := range errorsSeen {
		if err != nil {
			t.Fatalf("concurrent close error: %v", err)
		}
	}
}

func TestLockWrongTypeIsRejectedWithoutBlocking(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	paths, err := NewPaths(runtimeDir)
	if err != nil {
		t.Fatalf("new paths: %v", err)
	}
	if err := unix.Mkfifo(paths.LockPath, 0o600); err != nil {
		t.Fatalf("create FIFO lock entry: %v", err)
	}
	if _, err := Open(Options{RuntimeDir: runtimeDir, InstanceID: testInstanceID}); err == nil {
		t.Fatal("FIFO runtime lock unexpectedly accepted")
	}
	assertEntryExists(t, paths.LockPath)
}

func TestLockOpenUsesDirectoryDescriptorAndRejectsPathSubstitution(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	paths, err := NewPaths(runtimeDir)
	if err != nil {
		t.Fatalf("new paths: %v", err)
	}
	directory, directoryID, err := openRuntimeDirectory(runtimeDir)
	if err != nil {
		t.Fatalf("open runtime directory descriptor: %v", err)
	}
	defer directory.Close()
	movedPath := runtimeDir + "-moved"
	if err := os.Rename(runtimeDir, movedPath); err != nil {
		t.Fatalf("move opened runtime directory: %v", err)
	}
	if err := os.Mkdir(runtimeDir, 0o700); err != nil {
		t.Fatalf("substitute runtime directory pathname: %v", err)
	}
	if _, _, err := acquireLock(directory, paths, directoryID); err == nil {
		t.Fatal("lock acquisition across directory substitution unexpectedly succeeded")
	}
	if _, err := os.Lstat(filepath.Join(movedPath, LockFileName)); err == nil {
		t.Fatal("failed acquisition left a lock in the descriptor target")
	}
	if _, err := os.Lstat(filepath.Join(runtimeDir, LockFileName)); err == nil {
		t.Fatal("failed acquisition created a lock in the substituted pathname")
	}
	if err := os.RemoveAll(movedPath); err != nil {
		t.Fatalf("remove moved runtime directory: %v", err)
	}
}

func TestMetadataReadBounded(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	paths, err := NewPaths(runtimeDir)
	if err != nil {
		t.Fatalf("new paths: %v", err)
	}
	if err := os.WriteFile(paths.MetadataPath, bytes.Repeat([]byte{'x'}, MaxMetadataBytes+1), 0o600); err != nil {
		t.Fatalf("write oversized metadata: %v", err)
	}
	if _, _, err := ValidateMetadata(paths.MetadataPath); err == nil {
		t.Fatal("oversized metadata unexpectedly validated")
	}
}

func TestOpenRandomFailureLeavesNoGenerationEntries(t *testing.T) {
	runtimeDir := secureRuntimeDir(t)
	_, err := Open(Options{RuntimeDir: runtimeDir, Random: failingReader{}})
	if err == nil {
		t.Fatal("random source failure unexpectedly accepted")
	}
	paths, pathErr := NewPaths(runtimeDir)
	if pathErr != nil {
		t.Fatalf("new paths: %v", pathErr)
	}
	if _, statErr := os.Lstat(paths.LockPath); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("random failure created runtime lock: %v", statErr)
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) {
	return 0, io.ErrUnexpectedEOF
}
