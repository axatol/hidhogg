// Package notification defines the device-independent notification contract.
package notification

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"regexp"
	"unicode"
	"unicode/utf8"
)

const (
	MaximumSourceRunes = 64
	MaximumTextRunes   = 64
	MaximumTextBytes   = 256
	MinimumTTLSeconds  = 1
	MaximumTTLSeconds  = 86400
)

var (
	ErrInvalid   = errors.New("invalid notification")
	ErrBusy      = errors.New("notification service is busy")
	ErrClosed    = errors.New("notification service is closed")
	ErrUncertain = errors.New("notification device state is uncertain")
)

var sourcePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
var canonicalIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

type EmitRequest struct {
	Source     string
	Text       string
	TTLSeconds *int
}

type EmitResult struct {
	NotificationID string
	MatchedCount   int
}

type ClearResult struct {
	ClearedCount int
}

func ValidateEmit(request EmitRequest) error {
	if !ValidSource(request.Source) || !validText(request.Text) {
		return ErrInvalid
	}
	if request.TTLSeconds != nil && (*request.TTLSeconds < MinimumTTLSeconds || *request.TTLSeconds > MaximumTTLSeconds) {
		return ErrInvalid
	}
	return nil
}

func CloneEmitRequest(request EmitRequest) EmitRequest {
	clone := request
	if request.TTLSeconds != nil {
		ttl := *request.TTLSeconds
		clone.TTLSeconds = &ttl
	}
	return clone
}

func ValidSource(source string) bool {
	return sourcePattern.MatchString(source) && utf8.ValidString(source)
}

func ValidateNotificationID(id string) error {
	if !canonicalIDPattern.MatchString(id) {
		return ErrInvalid
	}
	return nil
}

func ValidNotificationID(id string) bool {
	return ValidateNotificationID(id) == nil
}

func NewNotificationID() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	raw[6] = raw[6]&0x0f | 0x40
	raw[8] = raw[8]&0x3f | 0x80
	encoded := make([]byte, 36)
	hex.Encode(encoded[0:8], raw[0:4])
	encoded[8] = '-'
	hex.Encode(encoded[9:13], raw[4:6])
	encoded[13] = '-'
	hex.Encode(encoded[14:18], raw[6:8])
	encoded[18] = '-'
	hex.Encode(encoded[19:23], raw[8:10])
	encoded[23] = '-'
	hex.Encode(encoded[24:36], raw[10:16])
	return string(encoded), nil
}

func validText(text string) bool {
	if text == "" || !utf8.ValidString(text) || utf8.RuneCountInString(text) > MaximumTextRunes || len([]byte(text)) > MaximumTextBytes {
		return false
	}
	visible := false
	for _, character := range text {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) || unicode.Is(unicode.Zl, character) || unicode.Is(unicode.Zp, character) {
			return false
		}
		if !unicode.IsSpace(character) && !unicode.Is(unicode.Mn, character) && !unicode.Is(unicode.Me, character) && !unicode.Is(unicode.Cn, character) && !unicode.Is(unicode.Co, character) && !unicode.Is(unicode.Cs, character) {
			visible = true
		}
	}
	return visible
}
