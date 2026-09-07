package diagnostic

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

func TestFixedEndpointCueUsesOnlyApprovedDirectInvocation(t *testing.T) {
	process := &fakeEndpointProcess{}
	var gotPath string
	var gotArguments []string
	cue := FixedEndpointCue{commandContext: func(_ context.Context, path string, arguments ...string) endpointProcess {
		gotPath = path
		gotArguments = append([]string(nil), arguments...)
		return process
	}}

	if err := RunEndpointCue(context.Background(), cue); err != nil {
		t.Fatal(err)
	}
	if gotPath != endpointCuePath || !reflect.DeepEqual(gotArguments, []string{endpointCueText}) {
		t.Fatalf("invocation = %q %q", gotPath, gotArguments)
	}
	if process.runs != 1 {
		t.Fatalf("process runs = %d, want 1", process.runs)
	}
}

func TestRunEndpointCueSuppliesFixedTimeoutContext(t *testing.T) {
	err := RunEndpointCue(context.Background(), EndpointCueFunc(func(ctx context.Context) error {
		deadline, ok := ctx.Deadline()
		if !ok {
			t.Fatal("cue context has no deadline")
		}
		remaining := time.Until(deadline)
		if remaining <= 0 || remaining > EndpointCueTimeout {
			t.Fatalf("cue deadline remaining = %s", remaining)
		}
		return context.DeadlineExceeded
	}))
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("cue error = %v", err)
	}
}

func TestRunEndpointCueRejectsNilSuccessAfterContextExpiry(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := RunEndpointCue(ctx, EndpointCueFunc(func(context.Context) error {
		return nil
	}))
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cue error = %v, want cancellation", err)
	}
}

func TestFixedEndpointCuePassesCancellationToTheProcess(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	process := &contextEndpointProcess{}
	cue := FixedEndpointCue{commandContext: func(processContext context.Context, _ string, _ ...string) endpointProcess {
		process.ctx = processContext
		return process
	}}

	if err := RunEndpointCue(ctx, cue); !errors.Is(err, context.Canceled) {
		t.Fatalf("cue error = %v", err)
	}
	if process.runs != 1 {
		t.Fatalf("process runs = %d, want 1", process.runs)
	}
}

func TestEndpointTokensAreExact(t *testing.T) {
	if !EndpointCueHeard("CUE_HEARD\n") || EndpointCueHeard(" CUE_HEARD\n") {
		t.Fatal("owner-heard token matching was not exact")
	}
	for _, token := range []EndpointAttestation{EndpointActiveAtCue, EndpointScreensaverAtCue, EndpointUncertain} {
		if got, ok := ParseEndpointAttestation(string(token) + "\n"); !ok || got != token {
			t.Fatalf("attestation %q parsed as %q/%t", token, got, ok)
		}
	}
	if _, ok := ParseEndpointAttestation("ACTIVE_AT_CUE \n"); ok {
		t.Fatal("attestation parser accepted trailing whitespace")
	}
}

type fakeEndpointProcess struct {
	runs int
}

type contextEndpointProcess struct {
	ctx  context.Context
	runs int
}

func (process *contextEndpointProcess) Run() error {
	process.runs++
	<-process.ctx.Done()
	return process.ctx.Err()
}

func (process *fakeEndpointProcess) Run() error {
	process.runs++
	return nil
}
