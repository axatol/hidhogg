//go:build !windows

package discovery

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"golang.org/x/sys/unix"
)

var (
	// ErrDirectoryBusy indicates that another cooperating runtime currently
	// owns the runtime directory lock.
	ErrDirectoryBusy = errors.New("runtime directory is already locked")
	// ErrMetadataExists indicates that no-replace metadata publication found an
	// existing runtime.json entry.
	ErrMetadataExists = errors.New("runtime metadata already exists")
)

// Options controls discovery lifecycle construction.
type Options struct {
	RuntimeDir string
	InstanceID string
	Random     io.Reader
}

// Generation owns one runtime directory lock and one generated instance. The
// lock remains held until Close has completed all guarded generation cleanup.
type Generation struct {
	paths       Paths
	directoryID Identity
	directory   *os.File
	lock        *os.File
	lockID      Identity
	instanceID  string

	mu                sync.Mutex
	closed            bool
	closeErr          error
	closeDone         chan struct{}
	socketID          Identity
	socketRecorded    bool
	metadataID        Identity
	metadataPublished bool
}

// Open validates and locks a pre-existing runtime directory, recovers valid
// stale generation entries while the lock is held, and selects a canonical
// instance ID. No device or IPC operation occurs here.
func Open(options Options) (*Generation, error) {
	paths, err := NewPaths(options.RuntimeDir)
	if err != nil {
		return nil, err
	}
	instanceID := options.InstanceID
	if instanceID == "" {
		instanceID, err = GenerateUUIDv4(options.Random)
	} else {
		instanceID, err = NormalizeInstanceID(instanceID)
	}
	if err != nil {
		return nil, err
	}
	directory, directoryID, err := openRuntimeDirectory(paths.RuntimeDir)
	if err != nil {
		return nil, err
	}
	lock, lockID, err := acquireLock(directory, paths, directoryID)
	if err != nil {
		_ = directory.Close()
		return nil, err
	}
	generation := &Generation{
		paths:       paths,
		directoryID: directoryID,
		directory:   directory,
		lock:        lock,
		lockID:      lockID,
		instanceID:  instanceID,
		closeDone:   make(chan struct{}),
	}
	if err := generation.recoverStaleEntries(); err != nil {
		_ = generation.Close()
		return nil, err
	}
	return generation, nil
}

// New is an alias for Open for callers that use constructor naming.
func New(options Options) (*Generation, error) {
	return Open(options)
}

func acquireLock(directory *os.File, paths Paths, directoryID Identity) (*os.File, Identity, error) {
	if _, err := validateDirectoryDescriptor(directory, paths.RuntimeDir, directoryID); err != nil {
		return nil, Identity{}, err
	}
	var file *os.File
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		file, err = openAtNoFollow(directory, LockFileName, unix.O_RDWR|unix.O_NONBLOCK, uint32(runtimeEntryMode.Perm()))
		if !errors.Is(err, unix.ENOENT) {
			break
		}
		file, err = openAtNoFollow(directory, LockFileName, unix.O_RDWR|unix.O_NONBLOCK|unix.O_CREAT|unix.O_EXCL, uint32(runtimeEntryMode.Perm()))
		if !errors.Is(err, unix.EEXIST) {
			break
		}
	}
	if err != nil {
		return nil, Identity{}, fmt.Errorf("open runtime lock: %w", err)
	}
	identity, err := validateRegularDescriptor(file, paths.LockPath, Identity{})
	if err != nil {
		_ = file.Close()
		return nil, Identity{}, fmt.Errorf("validate runtime lock: %w", err)
	}
	if _, err := validateDirectoryDescriptor(directory, paths.RuntimeDir, directoryID); err != nil {
		_ = file.Close()
		return nil, Identity{}, err
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = file.Close()
		if err == unix.EAGAIN || err == unix.EWOULDBLOCK {
			return nil, Identity{}, fmt.Errorf("%w: %v", ErrDirectoryBusy, err)
		}
		return nil, Identity{}, fmt.Errorf("lock runtime directory: %w", err)
	}
	if _, err := validateRegularDescriptor(file, paths.LockPath, identity); err != nil {
		_ = unix.Flock(int(file.Fd()), unix.LOCK_UN)
		_ = file.Close()
		return nil, Identity{}, fmt.Errorf("revalidate runtime lock: %w", err)
	}
	if _, err := validateDirectoryDescriptor(directory, paths.RuntimeDir, directoryID); err != nil {
		_ = unix.Flock(int(file.Fd()), unix.LOCK_UN)
		_ = file.Close()
		return nil, Identity{}, err
	}
	return file, identity, nil
}

func (generation *Generation) recoverStaleEntries() error {
	_, metadataID, metadataPresent, err := inspectMetadata(generation.paths.MetadataPath)
	if err != nil {
		return fmt.Errorf("inspect stale runtime metadata: %w", err)
	}
	socketID, socketPresent, err := inspectSocket(generation.paths.SocketPath)
	if err != nil {
		return fmt.Errorf("inspect stale runtime socket: %w", err)
	}
	if !metadataPresent && !socketPresent {
		return generation.assertGenerationEntriesAbsent()
	}
	// Validate every present entry before removing any one of them. This keeps
	// malformed or substituted state intact when recovery is refused.
	if metadataPresent {
		if err := removeIfIdentity(generation.paths.MetadataPath, metadataID, generation.paths.RuntimeDir, generation.directory, generation.directoryID, func(path string) (Identity, error) {
			_, identity, err := ValidateMetadata(path)
			return identity, err
		}); err != nil {
			return fmt.Errorf("remove stale runtime metadata: %w", err)
		}
	}
	if socketPresent {
		if err := removeIfIdentity(generation.paths.SocketPath, socketID, generation.paths.RuntimeDir, generation.directory, generation.directoryID, ValidateSocket); err != nil {
			return fmt.Errorf("remove stale runtime socket: %w", err)
		}
	}
	return generation.assertGenerationEntriesAbsent()
}

func inspectMetadata(path string) (Metadata, Identity, bool, error) {
	metadata, identity, err := ValidateMetadata(path)
	if err == nil {
		return metadata, identity, true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return Metadata{}, Identity{}, false, nil
	}
	return Metadata{}, Identity{}, false, err
}

func inspectSocket(path string) (Identity, bool, error) {
	identity, err := ValidateSocket(path)
	if err == nil {
		return identity, true, nil
	}
	if errors.Is(err, os.ErrNotExist) {
		return Identity{}, false, nil
	}
	return Identity{}, false, err
}

func (generation *Generation) assertGenerationEntriesAbsent() error {
	if _, err := validateDirectoryDescriptor(generation.directory, generation.paths.RuntimeDir, generation.directoryID); err != nil {
		return err
	}
	for _, path := range []string{generation.paths.MetadataPath, generation.paths.SocketPath} {
		if _, err := os.Lstat(path); err == nil {
			return fmt.Errorf("generation entry appeared during recovery: %s", filepath.Base(path))
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("check generation entry %s: %w", filepath.Base(path), err)
		}
	}
	return nil
}

// RuntimeDir returns the validated runtime directory path.
func (generation *Generation) RuntimeDir() string {
	return generation.paths.RuntimeDir
}

// Paths returns the fixed paths for this generation.
func (generation *Generation) Paths() Paths {
	return generation.paths
}

// InstanceID returns the canonical lowercase instance ID.
func (generation *Generation) InstanceID() string {
	generation.mu.Lock()
	defer generation.mu.Unlock()
	return generation.instanceID
}

// SocketPath returns the fixed runtime.sock path.
func (generation *Generation) SocketPath() string {
	return generation.paths.SocketPath
}

// MetadataPath returns the fixed runtime.json path.
func (generation *Generation) MetadataPath() string {
	return generation.paths.MetadataPath
}

// RecordSocket validates and records the socket after the IPC listener has
// bound it. The recorded identity is used by publication and guarded cleanup.
func (generation *Generation) RecordSocket() (Identity, error) {
	generation.mu.Lock()
	defer generation.mu.Unlock()
	if generation.closed {
		return Identity{}, errors.New("runtime generation is closed")
	}
	if _, err := validateDirectoryDescriptor(generation.directory, generation.paths.RuntimeDir, generation.directoryID); err != nil {
		return Identity{}, err
	}
	identity, err := ValidateSocket(generation.paths.SocketPath)
	if err != nil {
		return Identity{}, err
	}
	if generation.socketRecorded && !identity.Equal(generation.socketID) {
		return Identity{}, errors.New("runtime socket identity changed")
	}
	generation.socketID = identity
	generation.socketRecorded = true
	return identity, nil
}

// PublishMetadata atomically publishes the generation readiness record using
// a hard-link no-replace commit. It requires a previously recorded socket.
func (generation *Generation) PublishMetadata() error {
	generation.mu.Lock()
	defer generation.mu.Unlock()
	if generation.closed {
		return errors.New("runtime generation is closed")
	}
	if !generation.socketRecorded {
		return errors.New("runtime socket must be recorded before metadata publication")
	}
	if generation.metadataPublished {
		return ErrMetadataExists
	}
	if _, err := validateDirectoryDescriptor(generation.directory, generation.paths.RuntimeDir, generation.directoryID); err != nil {
		return err
	}
	socketID, err := ValidateSocket(generation.paths.SocketPath)
	if err != nil {
		return fmt.Errorf("validate runtime socket before metadata publication: %w", err)
	}
	if !socketID.Equal(generation.socketID) {
		return errors.New("runtime socket identity changed before metadata publication")
	}
	metadata, err := EncodeMetadata(Metadata{
		SchemaVersion: MetadataSchemaVersion,
		InstanceID:    generation.instanceID,
		SocketName:    SocketFileName,
	})
	if err != nil {
		return err
	}
	identity, err := publishNoReplace(generation.paths, generation.directory, generation.directoryID, metadata)
	if err != nil {
		return err
	}
	generation.metadataID = identity
	generation.metadataPublished = true
	return nil
}

func publishNoReplace(paths Paths, directory *os.File, directoryID Identity, encoded []byte) (Identity, error) {
	if _, err := validateDirectoryDescriptor(directory, paths.RuntimeDir, directoryID); err != nil {
		return Identity{}, err
	}
	temporary, err := os.CreateTemp(paths.RuntimeDir, ".runtime.json-*")
	if err != nil {
		return Identity{}, fmt.Errorf("create runtime metadata temporary file: %w", err)
	}
	temporaryPath := temporary.Name()
	_, temporaryID, err := lstatIdentity(temporaryPath)
	if err != nil {
		_ = temporary.Close()
		return Identity{}, fmt.Errorf("inspect temporary runtime metadata: %w", err)
	}
	removeTemporary := func() error {
		if currentErr := func() error {
			current, identityErr := validateRegularEntry(temporaryPath)
			if identityErr != nil {
				return identityErr
			}
			if !current.Equal(temporaryID) {
				return errors.New("temporary runtime metadata identity changed")
			}
			if err := os.Remove(temporaryPath); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			return nil
		}(); currentErr != nil && !errors.Is(currentErr, os.ErrNotExist) {
			return currentErr
		}
		return nil
	}
	defer removeTemporary()
	if err := temporary.Chmod(runtimeEntryMode); err != nil {
		_ = temporary.Close()
		return Identity{}, fmt.Errorf("set temporary metadata mode: %w", err)
	}
	if _, err := temporary.Write(encoded); err != nil {
		_ = temporary.Close()
		return Identity{}, fmt.Errorf("write temporary runtime metadata: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return Identity{}, fmt.Errorf("sync temporary runtime metadata: %w", err)
	}
	validatedTemporaryID, err := validateRegularDescriptor(temporary, temporaryPath, temporaryID)
	if err != nil {
		_ = temporary.Close()
		return Identity{}, err
	}
	temporaryID = validatedTemporaryID
	if err := temporary.Close(); err != nil {
		return Identity{}, fmt.Errorf("close temporary runtime metadata: %w", err)
	}
	if _, err := validateDirectoryDescriptor(directory, paths.RuntimeDir, directoryID); err != nil {
		return Identity{}, err
	}
	if _, err := os.Lstat(paths.MetadataPath); err == nil {
		return Identity{}, ErrMetadataExists
	} else if !errors.Is(err, os.ErrNotExist) {
		return Identity{}, fmt.Errorf("check existing runtime metadata: %w", err)
	}
	if err := unix.Link(temporaryPath, paths.MetadataPath); err != nil {
		if errors.Is(err, unix.EEXIST) {
			return Identity{}, ErrMetadataExists
		}
		return Identity{}, fmt.Errorf("commit runtime metadata without replacement: %w", err)
	}
	_, identity, err := ValidateMetadata(paths.MetadataPath)
	if err != nil {
		return Identity{}, fmt.Errorf("validate committed runtime metadata: %w", err)
	}
	if !identity.Equal(temporaryID) {
		return Identity{}, errors.New("committed runtime metadata identity changed")
	}
	if err := removeTemporary(); err != nil {
		return identity, fmt.Errorf("remove temporary runtime metadata: %w", err)
	}
	return identity, nil
}

func (generation *Generation) withdrawMetadataLocked() error {
	if !generation.metadataPublished {
		return nil
	}
	metadataID := generation.metadataID
	err := removeIfIdentity(generation.paths.MetadataPath, metadataID, generation.paths.RuntimeDir, generation.directory, generation.directoryID, func(path string) (Identity, error) {
		_, identity, err := ValidateMetadata(path)
		return identity, err
	})
	if err != nil {
		return err
	}
	generation.metadataID = Identity{}
	generation.metadataPublished = false
	return nil
}

// WithdrawMetadata guardedly removes this generation's recorded metadata while
// retaining its socket, lock, and runtime-directory ownership. It is
// idempotent after successful removal. A failed guarded removal leaves the
// recorded identity published so a later call or Close can retry it.
func (generation *Generation) WithdrawMetadata() error {
	generation.mu.Lock()
	if !generation.metadataPublished {
		generation.mu.Unlock()
		return nil
	}
	if generation.closed {
		done := generation.closeDone
		generation.mu.Unlock()
		<-done
		generation.mu.Lock()
		err := generation.closeErr
		generation.mu.Unlock()
		return err
	}
	err := generation.withdrawMetadataLocked()
	generation.mu.Unlock()
	return err
}

// Close removes only the socket and metadata identities recorded by this
// generation, then releases and closes the persistent lock. The lock path is
// never removed. Close is idempotent.
func (generation *Generation) Close() error {
	generation.mu.Lock()
	if generation.closed {
		done := generation.closeDone
		generation.mu.Unlock()
		<-done
		generation.mu.Lock()
		err := generation.closeErr
		generation.mu.Unlock()
		return err
	}
	generation.closed = true
	socketID, socketRecorded := generation.socketID, generation.socketRecorded
	lock := generation.lock
	directory := generation.directory
	closeErr := generation.withdrawMetadataLocked()
	generation.mu.Unlock()

	if socketRecorded {
		closeErr = errors.Join(closeErr, removeIfIdentity(generation.paths.SocketPath, socketID, generation.paths.RuntimeDir, directory, generation.directoryID, ValidateSocket))
	}
	if lock != nil {
		if err := unix.Flock(int(lock.Fd()), unix.LOCK_UN); err != nil {
			closeErr = errors.Join(closeErr, fmt.Errorf("unlock runtime directory: %w", err))
		}
		if err := lock.Close(); err != nil {
			closeErr = errors.Join(closeErr, fmt.Errorf("close runtime lock: %w", err))
		}
	}
	if directory != nil {
		if err := directory.Close(); err != nil {
			closeErr = errors.Join(closeErr, fmt.Errorf("close runtime directory: %w", err))
		}
	}
	generation.mu.Lock()
	generation.closeErr = closeErr
	close(generation.closeDone)
	generation.mu.Unlock()
	return closeErr
}
