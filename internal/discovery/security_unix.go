//go:build !windows

package discovery

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

const (
	runtimeDirectoryMode os.FileMode = 0o700
	runtimeEntryMode     os.FileMode = 0o600
)

// Identity identifies one filesystem object without exposing its pathname.
// Device and inode are the stable identity used by the lifecycle guards.
type Identity struct {
	Device uint64
	Inode  uint64
	UID    uint32
}

// Equal reports whether two identities refer to the same filesystem object.
func (identity Identity) Equal(other Identity) bool {
	return identity.Device == other.Device && identity.Inode == other.Inode
}

func currentUID() uint32 {
	return uint32(unix.Geteuid())
}

func inspectFile(info os.FileInfo) (Identity, error) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return Identity{}, errors.New("file metadata has an unsupported type")
	}
	return Identity{Device: uint64(stat.Dev), Inode: uint64(stat.Ino), UID: uint32(stat.Uid)}, nil
}

func exactMode(mode os.FileMode, expected os.FileMode) bool {
	const specialBits = os.ModeSetuid | os.ModeSetgid | os.ModeSticky
	return mode&(os.ModePerm|specialBits) == expected
}

func validateRuntimePath(path string) (string, error) {
	if path == "" {
		return "", errors.New("runtime directory is required")
	}
	if filepath.IsAbs(path) == false {
		return "", errors.New("runtime directory must be absolute")
	}
	if containsNUL(path) {
		return "", errors.New("runtime directory contains NUL")
	}
	return filepath.Clean(path), nil
}

func containsNUL(path string) bool {
	for index := 0; index < len(path); index++ {
		if path[index] == 0 {
			return true
		}
	}
	return false
}

// ValidateDirectory verifies the fixed security policy for a runtime
// directory. The final pathname component is inspected with Lstat, so a
// symlink is never accepted as the directory itself.
func ValidateDirectory(path string) (Identity, error) {
	path, err := validateRuntimePath(path)
	if err != nil {
		return Identity{}, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return Identity{}, fmt.Errorf("lstat runtime directory: %w", err)
	}
	identity, err := inspectFile(info)
	if err != nil {
		return Identity{}, fmt.Errorf("inspect runtime directory: %w", err)
	}
	if !info.IsDir() || !exactMode(info.Mode(), runtimeDirectoryMode) || identity.UID != currentUID() {
		return Identity{}, errors.New("runtime directory must be an effective-UID-owned directory with mode 0700")
	}
	return identity, nil
}

func openRuntimeDirectory(path string) (*os.File, Identity, error) {
	path, err := validateRuntimePath(path)
	if err != nil {
		return nil, Identity{}, err
	}
	expected, err := ValidateDirectory(path)
	if err != nil {
		return nil, Identity{}, err
	}
	directory, err := openNoFollow(path, unix.O_RDONLY|unix.O_DIRECTORY, 0)
	if err != nil {
		return nil, Identity{}, fmt.Errorf("open runtime directory: %w", err)
	}
	identity, err := validateDirectoryDescriptor(directory, path, expected)
	if err != nil {
		_ = directory.Close()
		return nil, Identity{}, err
	}
	return directory, identity, nil
}

func validateDirectoryIdentity(path string, expected Identity) error {
	current, err := ValidateDirectory(path)
	if err != nil {
		return err
	}
	if !current.Equal(expected) {
		return errors.New("runtime directory identity changed")
	}
	return nil
}

func lstatIdentity(path string) (os.FileInfo, Identity, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, Identity{}, err
	}
	identity, err := inspectFile(info)
	if err != nil {
		return nil, Identity{}, err
	}
	return info, identity, nil
}

func validateRegularEntry(path string) (Identity, error) {
	info, identity, err := lstatIdentity(path)
	if err != nil {
		return Identity{}, err
	}
	if !info.Mode().IsRegular() || !exactMode(info.Mode(), runtimeEntryMode) || identity.UID != currentUID() {
		return Identity{}, errors.New("entry must be an effective-UID-owned regular file with mode 0600")
	}
	return identity, nil
}

// ValidateLock verifies a persistent runtime.lock entry without opening or
// locking it. Open acquires the lock after repeating this validation on the
// descriptor and pathname.
func ValidateLock(path string) (Identity, error) {
	return validateRegularEntry(path)
}

// ValidateSocket verifies an owner-only Unix socket entry.
func ValidateSocket(path string) (Identity, error) {
	info, identity, err := lstatIdentity(path)
	if err != nil {
		return Identity{}, err
	}
	if info.Mode()&os.ModeSocket != os.ModeSocket || !exactMode(info.Mode(), runtimeEntryMode) || identity.UID != currentUID() {
		return Identity{}, errors.New("socket must be an effective-UID-owned Unix socket with mode 0600")
	}
	return identity, nil
}

func openNoFollow(path string, flags int, mode uint32) (*os.File, error) {
	fd, err := unix.Open(path, flags|unix.O_CLOEXEC|unix.O_NOFOLLOW, mode)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = unix.Close(fd)
		return nil, errors.New("create file descriptor wrapper")
	}
	return file, nil
}

func validateDescriptorPath(file *os.File, path string, expected Identity, expectedMode os.FileMode, expectedType func(os.FileInfo) bool) (Identity, error) {
	info, err := file.Stat()
	if err != nil {
		return Identity{}, fmt.Errorf("fstat %s: %w", path, err)
	}
	identity, err := inspectFile(info)
	if err != nil {
		return Identity{}, fmt.Errorf("inspect descriptor %s: %w", path, err)
	}
	if !expectedType(info) || !exactMode(info.Mode(), expectedMode) || identity.UID != currentUID() {
		return Identity{}, fmt.Errorf("descriptor %s has an invalid type, owner, or mode", path)
	}
	if expected.Inode != 0 && !identity.Equal(expected) {
		return Identity{}, fmt.Errorf("descriptor %s identity changed", path)
	}
	_, pathIdentity, err := lstatIdentity(path)
	if err != nil {
		return Identity{}, fmt.Errorf("lstat %s after open: %w", path, err)
	}
	if !identity.Equal(pathIdentity) {
		return Identity{}, fmt.Errorf("descriptor %s does not match pathname", path)
	}
	return identity, nil
}

func validateRegularDescriptor(file *os.File, path string, expected Identity) (Identity, error) {
	return validateDescriptorPath(file, path, expected, runtimeEntryMode, func(info os.FileInfo) bool {
		return info.Mode().IsRegular()
	})
}

func validateDirectoryDescriptor(file *os.File, path string, expected Identity) (Identity, error) {
	return validateDescriptorPath(file, path, expected, runtimeDirectoryMode, func(info os.FileInfo) bool {
		return info.IsDir()
	})
}

func openAtNoFollow(directory *os.File, name string, flags int, mode uint32) (*os.File, error) {
	fd, err := unix.Openat(int(directory.Fd()), name, flags|unix.O_CLOEXEC|unix.O_NOFOLLOW, mode)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), name)
	if file == nil {
		_ = unix.Close(fd)
		return nil, errors.New("create file descriptor wrapper")
	}
	return file, nil
}

func removeIfIdentity(path string, expected Identity, directory string, directoryFile *os.File, directoryID Identity, validate func(string) (Identity, error)) error {
	if _, err := validateDirectoryDescriptor(directoryFile, directory, directoryID); err != nil {
		return err
	}
	current, err := validate(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if !current.Equal(expected) {
		return errors.New("entry identity changed before removal")
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove %s: %w", filepath.Base(path), err)
	}
	return nil
}
