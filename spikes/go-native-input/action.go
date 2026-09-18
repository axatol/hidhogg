package nativeinput

import (
	"errors"
	"fmt"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

const (
	MaximumTextUTF16Units      = 64
	MaximumBenchmarkIterations = 100_000
	MaximumDelay               = 30 * time.Second
)

type ActionKind uint8

const (
	ActionText ActionKind = iota + 1
	ActionEnter
)

type Action struct {
	Kind    ActionKind
	Text    string
	KeyCode uint16
}

const KeyCodeEnter uint16 = 36

func Text(value string) Action {
	return Action{Kind: ActionText, Text: value}
}

func Enter() Action {
	return Action{Kind: ActionEnter, KeyCode: KeyCodeEnter}
}

var (
	ErrInvalidAction         = errors.New("invalid keyboard action")
	ErrInvalidText           = errors.New("text is not valid UTF-8 or is empty")
	ErrTextTooLong           = errors.New("text exceeds the UTF-16 unit limit")
	ErrInvalidBenchmarkCount = errors.New("benchmark iteration count is outside the supported limit")
	ErrInvalidDelay          = errors.New("delay is outside the supported limit")
	ErrPermissionDenied      = errors.New("post-event permission is denied")
	ErrEventAllocation       = errors.New("Core Graphics keyboard event allocation failed")
	ErrSourceAllocation      = errors.New("Core Graphics event source allocation failed")
	ErrUnicodeReadback       = errors.New("Core Graphics Unicode readback failed")
	ErrInvalidEventSource    = errors.New("invalid event source")
	ErrInvalidEventTap       = errors.New("invalid event tap")
	ErrUnsupportedPlatform   = errors.New("native input spike is unsupported on this target")
)

func (a Action) Validate() error {
	switch a.Kind {
	case ActionText:
		if a.KeyCode != 0 {
			return fmt.Errorf("%w: text action must not set a key code", ErrInvalidAction)
		}
		if a.Text == "" || !utf8.ValidString(a.Text) {
			return ErrInvalidText
		}
		if len(utf16.Encode([]rune(a.Text))) > MaximumTextUTF16Units {
			return ErrTextTooLong
		}
		return nil
	case ActionEnter:
		if a.Text != "" || a.KeyCode != KeyCodeEnter {
			return fmt.Errorf("%w: enter action must use key code %d and no text", ErrInvalidAction, KeyCodeEnter)
		}
		return nil
	default:
		return fmt.Errorf("%w: unknown action kind %d", ErrInvalidAction, a.Kind)
	}
}

func (a Action) utf16Units() ([]uint16, error) {
	if err := a.Validate(); err != nil {
		return nil, err
	}
	if a.Kind != ActionText {
		return nil, nil
	}
	units := utf16.Encode([]rune(a.Text))
	return units, nil
}

func validateBenchmarkIterations(iterations int) error {
	if iterations <= 0 || iterations > MaximumBenchmarkIterations {
		return ErrInvalidBenchmarkCount
	}
	return nil
}

func validateDelay(delay time.Duration) error {
	if delay < 0 || delay > MaximumDelay {
		return ErrInvalidDelay
	}
	return nil
}
