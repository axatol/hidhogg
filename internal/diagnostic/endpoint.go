package diagnostic

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"
)

const (
	endpointCuePath       = "/usr/bin/say"
	endpointCueText       = "Check D two hundred X now"
	EndpointCueHeardToken = "CUE_HEARD"

	EndpointCueTimeout    = 12 * time.Second
	EndpointCaptureWindow = 5 * time.Second
)

var ErrEndpointCueUnsupported = errors.New("endpoint cue is unsupported")

type EndpointAttestation string

const (
	EndpointActiveAtCue      EndpointAttestation = "ACTIVE_AT_CUE"
	EndpointScreensaverAtCue EndpointAttestation = "SCREENSAVER_AT_CUE"
	EndpointUncertain        EndpointAttestation = "UNCERTAIN"
)

func ParseEndpointAttestation(line string) (EndpointAttestation, bool) {
	line = strings.TrimSuffix(line, "\n")
	line = strings.TrimSuffix(line, "\r")
	attestation := EndpointAttestation(line)
	switch attestation {
	case EndpointActiveAtCue, EndpointScreensaverAtCue, EndpointUncertain:
		return attestation, true
	default:
		return "", false
	}
}

func EndpointCueHeard(line string) bool {
	line = strings.TrimSuffix(line, "\n")
	line = strings.TrimSuffix(line, "\r")
	return line == EndpointCueHeardToken
}

// EndpointCue plays the fixed local cue used by the keepalive endpoint. The
// cue implementation owns its invocation boundary; callers cannot provide a
// command, path, text, environment, or shell.
type EndpointCue interface {
	Cue(context.Context) error
}

// EndpointCueFunc adapts a function to EndpointCue for deterministic tests.
type EndpointCueFunc func(context.Context) error

func (cue EndpointCueFunc) Cue(ctx context.Context) error {
	if cue == nil {
		return ErrEndpointCueUnsupported
	}
	return cue(ctx)
}

type endpointProcess interface {
	Run() error
}

type endpointCommandContext func(context.Context, string, ...string) endpointProcess

// FixedEndpointCue invokes the macOS system speech utility with the one
// protocol-approved path and text. exec.CommandContext does not invoke a
// shell and terminates the child when the context is canceled.
type FixedEndpointCue struct {
	commandContext endpointCommandContext
}

func (cue FixedEndpointCue) Cue(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	commandContext := cue.commandContext
	if commandContext == nil {
		commandContext = func(ctx context.Context, name string, arguments ...string) endpointProcess {
			return exec.CommandContext(ctx, name, arguments...)
		}
	}
	return commandContext(ctx, endpointCuePath, endpointCueText).Run()
}

func RunEndpointCue(ctx context.Context, cue EndpointCue) error {
	if cue == nil {
		return ErrEndpointCueUnsupported
	}
	if ctx == nil {
		ctx = context.Background()
	}
	cueContext, cancel := context.WithTimeout(ctx, EndpointCueTimeout)
	defer cancel()
	if err := cue.Cue(cueContext); err != nil {
		return err
	}
	return cueContext.Err()
}
