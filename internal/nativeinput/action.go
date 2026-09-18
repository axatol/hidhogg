package nativeinput

import (
	"errors"
	"fmt"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

const (
	MaximumTextUTF16Units = 64
	QueueCapacity         = 16

	KeyEnter = "enter"

	ActionTypeText     = "type_text"
	ActionTypeKeyPress = "key_press"
)

var (
	ErrInvalidRequest        = errors.New("invalid native input request")
	ErrPermissionDenied      = errors.New("post-event permission is denied")
	ErrPermissionCheckFailed = errors.New("post-event permission check failed")
	ErrEventAllocation       = errors.New("keyboard event allocation failed")
	ErrUnsupportedPlatform   = errors.New("native input is unsupported on this platform")
	ErrInitializationFailed  = errors.New("native input initialization failed")
	ErrClosed                = errors.New("native input worker is closed")
	ErrBusy                  = errors.New("native input permission request is in progress")
	ErrQueueFull             = errors.New("native input queue is full")
	ErrClosePending          = errors.New("native input close is pending native completion")
	ErrPending               = ErrClosePending
)

type Request struct {
	ProfileID  string
	PositionID string
	Text       string
	Key        string
}

type action struct {
	text    string
	keyCode uint16
}

const keyCodeEnter uint16 = 36

func validateRequest(request Request) (action, string, error) {
	if !validMetadata(request.ProfileID) || !validMetadata(request.PositionID) {
		return action{}, "", fmt.Errorf("%w: profile and position IDs must be stable ASCII IDs up to 64 characters", ErrInvalidRequest)
	}
	if request.Text != "" && request.Key != "" {
		return action{}, "", fmt.Errorf("%w: text and key are mutually exclusive", ErrInvalidRequest)
	}
	if request.Text == "" && request.Key == "" {
		return action{}, "", fmt.Errorf("%w: exactly one of text or key is required", ErrInvalidRequest)
	}
	if request.Key != "" {
		if request.Key != KeyEnter {
			return action{}, "", fmt.Errorf("%w: unsupported key %q", ErrInvalidRequest, request.Key)
		}
		return action{keyCode: keyCodeEnter}, ActionTypeKeyPress, nil
	}
	if !utf8.ValidString(request.Text) || strings.ContainsRune(request.Text, '\x00') {
		return action{}, "", fmt.Errorf("%w: text must be valid UTF-8 without NUL", ErrInvalidRequest)
	}
	if len(utf16.Encode([]rune(request.Text))) > MaximumTextUTF16Units {
		return action{}, "", fmt.Errorf("%w: text exceeds the UTF-16 unit limit", ErrInvalidRequest)
	}
	return action{text: request.Text}, ActionTypeText, nil
}

func validMetadata(value string) bool {
	if len(value) == 0 || len(value) > 64 || !utf8.ValidString(value) || strings.ContainsRune(value, '\x00') {
		return false
	}
	for _, character := range []byte(value) {
		if (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '.' || character == '_' || character == '-' {
			continue
		}
		return false
	}
	first := value[0]
	if (first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z') || (first >= '0' && first <= '9') {
		return true
	}
	return false
}

func actionUnits(value string) []uint16 {
	if value == "" {
		return nil
	}
	return utf16.Encode([]rune(value))
}
