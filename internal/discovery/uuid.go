//go:build !windows

package discovery

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strings"
)

// GenerateUUIDv4 returns a lowercase RFC 4122 UUIDv4 using the supplied
// source. A nil source uses crypto/rand.Reader.
func GenerateUUIDv4(source io.Reader) (string, error) {
	if source == nil {
		source = rand.Reader
	}
	var value [16]byte
	if _, err := io.ReadFull(source, value[:]); err != nil {
		return "", fmt.Errorf("generate UUIDv4: %w", err)
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	var encoded [36]byte
	hex.Encode(encoded[0:8], value[0:4])
	encoded[8] = '-'
	hex.Encode(encoded[9:13], value[4:6])
	encoded[13] = '-'
	hex.Encode(encoded[14:18], value[6:8])
	encoded[18] = '-'
	hex.Encode(encoded[19:23], value[8:10])
	encoded[23] = '-'
	hex.Encode(encoded[24:36], value[10:16])
	return string(encoded[:]), nil
}

// NormalizeInstanceID validates a canonical UUID spelling without treating
// hexadecimal case as identity. The returned value is always lowercase. An
// explicit override may use any UUID version; generated IDs are always v4.
func NormalizeInstanceID(value string) (string, error) {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return "", errors.New("instance ID must be a canonical UUID")
	}
	for index, character := range []byte(value) {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if !isHex(character) {
			return "", errors.New("instance ID must be a canonical UUID")
		}
	}
	return strings.ToLower(value), nil
}

func isHex(character byte) bool {
	return character >= '0' && character <= '9' || character >= 'a' && character <= 'f' || character >= 'A' && character <= 'F'
}
