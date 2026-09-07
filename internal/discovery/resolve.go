//go:build !windows

package discovery

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// Resolved is a client-side snapshot of one ready runtime generation. Callers
// should invoke Revalidate after connecting or issuing an IPC request before
// trusting the snapshot's identity.
type Resolved struct {
	Paths       Paths
	Metadata    Metadata
	DirectoryID Identity
	LockID      Identity
	MetadataID  Identity
	SocketID    Identity
}

// Resolve validates the secure directory, persistent lock, readiness metadata,
// and fixed socket, returning all identities needed for post-call checks.
func Resolve(runtimeDir string) (Resolved, error) {
	paths, err := NewPaths(runtimeDir)
	if err != nil {
		return Resolved{}, err
	}
	directory, directoryID, err := openRuntimeDirectory(paths.RuntimeDir)
	if err != nil {
		return Resolved{}, err
	}
	defer directory.Close()
	lockID, err := validateLockAt(directory, paths, directoryID)
	if err != nil {
		return Resolved{}, fmt.Errorf("validate runtime lock: %w", err)
	}
	metadata, metadataID, err := ValidateMetadata(paths.MetadataPath)
	if err != nil {
		return Resolved{}, fmt.Errorf("validate runtime metadata: %w", err)
	}
	socketID, err := ValidateSocket(paths.SocketPath)
	if err != nil {
		return Resolved{}, fmt.Errorf("validate runtime socket: %w", err)
	}
	resolved := Resolved{
		Paths:       paths,
		Metadata:    metadata,
		DirectoryID: directoryID,
		LockID:      lockID,
		MetadataID:  metadataID,
		SocketID:    socketID,
	}
	if err := resolved.Revalidate(); err != nil {
		return Resolved{}, err
	}
	return resolved, nil
}

func validateLockAt(directory *os.File, paths Paths, directoryID Identity) (Identity, error) {
	if _, err := validateDirectoryDescriptor(directory, paths.RuntimeDir, directoryID); err != nil {
		return Identity{}, err
	}
	identity, err := ValidateLock(paths.LockPath)
	if err != nil {
		return Identity{}, err
	}
	file, err := openAtNoFollow(directory, LockFileName, unix.O_RDONLY|unix.O_NONBLOCK, 0)
	if err != nil {
		return Identity{}, fmt.Errorf("open runtime lock: %w", err)
	}
	defer file.Close()
	validated, err := validateRegularDescriptor(file, paths.LockPath, identity)
	if err != nil {
		return Identity{}, err
	}
	if _, err := validateDirectoryDescriptor(directory, paths.RuntimeDir, directoryID); err != nil {
		return Identity{}, err
	}
	return validated, nil
}

// Revalidate checks that the directory, persistent lock, metadata contents,
// metadata identity, and socket identity still match the original snapshot.
func (resolved Resolved) Revalidate() error {
	directory, directoryID, err := openRuntimeDirectory(resolved.Paths.RuntimeDir)
	if err != nil {
		return err
	}
	defer directory.Close()
	if !directoryID.Equal(resolved.DirectoryID) {
		return errors.New("runtime directory identity changed")
	}
	lockID, err := validateLockAt(directory, resolved.Paths, resolved.DirectoryID)
	if err != nil {
		return fmt.Errorf("revalidate runtime lock: %w", err)
	}
	if !lockID.Equal(resolved.LockID) {
		return errors.New("runtime lock identity changed")
	}
	metadata, metadataID, err := ValidateMetadata(resolved.Paths.MetadataPath)
	if err != nil {
		return fmt.Errorf("revalidate runtime metadata: %w", err)
	}
	if metadata != resolved.Metadata || !metadataID.Equal(resolved.MetadataID) {
		return errors.New("runtime metadata changed")
	}
	socketID, err := ValidateSocket(resolved.Paths.SocketPath)
	if err != nil {
		return fmt.Errorf("revalidate runtime socket: %w", err)
	}
	if !socketID.Equal(resolved.SocketID) {
		return errors.New("runtime socket identity changed")
	}
	return nil
}
