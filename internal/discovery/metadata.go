//go:build !windows

package discovery

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"golang.org/x/sys/unix"
)

const (
	MetadataSchemaVersion = 1
	MaxMetadataBytes      = 1024
)

// Metadata is the readiness record published after the runtime has bound its
// fixed socket and completed initialization. Its JSON representation is the
// strict v1 schema {schema_version, instance_id, socket_name}.
type Metadata struct {
	SchemaVersion int    `json:"schema_version"`
	InstanceID    string `json:"instance_id"`
	SocketName    string `json:"socket_name"`
}

func (metadata Metadata) validate() error {
	if metadata.SchemaVersion != MetadataSchemaVersion {
		return errors.New("metadata schema version is unsupported")
	}
	canonical, err := NormalizeInstanceID(metadata.InstanceID)
	if err != nil {
		return err
	}
	if canonical != metadata.InstanceID {
		return errors.New("metadata instance ID must be lowercase")
	}
	if metadata.SocketName != SocketFileName {
		return errors.New("metadata socket must be runtime.sock")
	}
	return nil
}

// EncodeMetadata encodes one bounded, canonical metadata object.
func EncodeMetadata(metadata Metadata) ([]byte, error) {
	if err := metadata.validate(); err != nil {
		return nil, err
	}
	encoded, err := json.Marshal(metadata)
	if err != nil {
		return nil, fmt.Errorf("encode runtime metadata: %w", err)
	}
	if len(encoded) > MaxMetadataBytes {
		return nil, errors.New("runtime metadata exceeds size bound")
	}
	return encoded, nil
}

// DecodeMetadata validates bounded JSON syntax, rejects duplicate and unknown
// fields, and requires the canonical lowercase v1 representation.
func DecodeMetadata(encoded []byte) (Metadata, error) {
	if len(encoded) == 0 || len(encoded) > MaxMetadataBytes {
		return Metadata{}, errors.New("runtime metadata is empty or exceeds size bound")
	}
	fields, err := decodeObjectFields(encoded)
	if err != nil {
		return Metadata{}, err
	}
	if len(fields) != 3 {
		return Metadata{}, errors.New("runtime metadata has an invalid field set")
	}
	var metadata Metadata
	if err := json.Unmarshal(fields["schema_version"], &metadata.SchemaVersion); err != nil {
		return Metadata{}, errors.New("runtime metadata schema_version must be an integer")
	}
	if err := json.Unmarshal(fields["instance_id"], &metadata.InstanceID); err != nil {
		return Metadata{}, errors.New("runtime metadata instance_id must be a string")
	}
	if err := json.Unmarshal(fields["socket_name"], &metadata.SocketName); err != nil {
		return Metadata{}, errors.New("runtime metadata socket_name must be a string")
	}
	if err := metadata.validate(); err != nil {
		return Metadata{}, err
	}
	return metadata, nil
}

func decodeObjectFields(encoded []byte) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	token, err := decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("decode runtime metadata object: %w", err)
	}
	delimiter, ok := token.(json.Delim)
	if !ok || delimiter != '{' {
		return nil, errors.New("runtime metadata must be a JSON object")
	}
	fields := make(map[string]json.RawMessage, 3)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("decode runtime metadata key: %w", err)
		}
		key, ok := keyToken.(string)
		if !ok {
			return nil, errors.New("runtime metadata object key is not a string")
		}
		if _, exists := fields[key]; exists {
			return nil, errors.New("runtime metadata contains duplicate fields")
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, fmt.Errorf("decode runtime metadata field %q: %w", key, err)
		}
		if key != "schema_version" && key != "instance_id" && key != "socket_name" {
			return nil, fmt.Errorf("runtime metadata contains unknown field %q", key)
		}
		fields[key] = raw
	}
	if token, err := decoder.Token(); err != nil {
		return nil, fmt.Errorf("close runtime metadata object: %w", err)
	} else if delimiter, ok := token.(json.Delim); !ok || delimiter != '}' {
		return nil, errors.New("runtime metadata object is malformed")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return nil, errors.New("runtime metadata contains trailing JSON")
		}
		return nil, fmt.Errorf("runtime metadata has trailing bytes: %w", err)
	}
	return fields, nil
}

// ValidateMetadata verifies an owner-only metadata regular file, reads its
// bounded contents without following a symlink, and returns its identity.
func ValidateMetadata(path string) (Metadata, Identity, error) {
	info, identity, err := lstatIdentity(path)
	if err != nil {
		return Metadata{}, Identity{}, err
	}
	if !info.Mode().IsRegular() || !exactMode(info.Mode(), runtimeEntryMode) || identity.UID != currentUID() {
		return Metadata{}, Identity{}, errors.New("metadata must be an effective-UID-owned regular file with mode 0600")
	}
	file, err := openNoFollow(path, unix.O_RDONLY, 0)
	if err != nil {
		return Metadata{}, Identity{}, fmt.Errorf("open runtime metadata: %w", err)
	}
	defer file.Close()
	openedIdentity, err := validateRegularDescriptor(file, path, identity)
	if err != nil {
		return Metadata{}, Identity{}, err
	}
	encoded, err := io.ReadAll(io.LimitReader(file, MaxMetadataBytes+1))
	if err != nil {
		return Metadata{}, Identity{}, fmt.Errorf("read runtime metadata: %w", err)
	}
	if len(encoded) > MaxMetadataBytes {
		return Metadata{}, Identity{}, errors.New("runtime metadata exceeds size bound")
	}
	metadata, err := DecodeMetadata(encoded)
	if err != nil {
		return Metadata{}, Identity{}, err
	}
	_, currentIdentity, err := lstatIdentity(path)
	if err != nil {
		return Metadata{}, Identity{}, fmt.Errorf("lstat runtime metadata after read: %w", err)
	}
	if !openedIdentity.Equal(currentIdentity) {
		return Metadata{}, Identity{}, errors.New("runtime metadata identity changed while reading")
	}
	return metadata, openedIdentity, nil
}
