package main

import (
	"bytes"
	"context"
	"strings"
	"testing"

	d200x "hidhogg/spikes/go-hid-d200x"
)

func TestRunRequiresAnExplicitAction(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run(nil, &stdout, &stderr); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "explicit --action is required") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestRunRequiresConfirmationBeforeOutboundActions(t *testing.T) {
	for _, action := range []string{"listen-input", "brightness", "diagnostic-display"} {
		var stdout, stderr bytes.Buffer
		args := []string{"--action", action}
		if action == "brightness" {
			args = append(args, "--brightness", "80")
		}
		if code := run(args, &stdout, &stderr); code != 2 {
			t.Fatalf("action %s exit code = %d, want 2", action, code)
		}
		if !strings.Contains(stderr.String(), "--confirm") {
			t.Fatalf("action %s stderr = %q", action, stderr.String())
		}
		if action == "diagnostic-display" && (!strings.Contains(stderr.String(), "0x0001") || !strings.Contains(stderr.String(), "0x0010")) {
			t.Fatalf("diagnostic-display gate omitted command sequence: %q", stderr.String())
		}
		if stdout.Len() != 0 {
			t.Fatalf("action %s touched HID before confirmation", action)
		}
	}
}

func TestDiagnosticDisplayCommandBuildsUploadAndUnlockFrames(t *testing.T) {
	display, err := d200x.DiagnosticDisplayFrame()
	if err != nil {
		t.Fatal(err)
	}
	if display.Command != d200x.CommandCompleteDisplayUpload || len(display.Payload) == 0 {
		t.Fatalf("display frame = %#v", display)
	}
	if unlock := d200x.UnlockScreenFrame(); unlock.Command != d200x.CommandUnlockScreen || len(unlock.Payload) != 0 {
		t.Fatalf("unlock frame = %#v", unlock)
	}
}

type recordingTransport struct {
	writes [][]byte
}

func (t *recordingTransport) Read(context.Context, []byte) (int, error) {
	return 0, context.DeadlineExceeded
}

func (t *recordingTransport) Write(_ context.Context, report []byte) (int, error) {
	t.writes = append(t.writes, append([]byte(nil), report...))
	return len(report), nil
}

func (t *recordingTransport) Close() error {
	return nil
}

type recordingFactory struct {
	candidate  d200x.Candidate
	transport  *recordingTransport
	openCalled bool
}

func (f *recordingFactory) Enumerate(context.Context) ([]d200x.Candidate, error) {
	return []d200x.Candidate{f.candidate}, nil
}

func (f *recordingFactory) Open(context.Context, d200x.Candidate) (d200x.Transport, error) {
	f.openCalled = true
	return f.transport, nil
}

func TestDiagnosticDisplayCommandSendsUploadThenUnlock(t *testing.T) {
	factory := &recordingFactory{
		candidate: d200x.NewCandidate("fake", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber),
		transport: &recordingTransport{},
	}
	var stdout, stderr bytes.Buffer
	if code := sendDiagnosticDisplay(context.Background(), factory, &stdout, &stderr); code != 0 {
		t.Fatalf("exit code = %d, stderr=%q", code, stderr.String())
	}
	if !factory.openCalled || len(factory.transport.writes) < 2 {
		t.Fatalf("open=%v writes=%d", factory.openCalled, len(factory.transport.writes))
	}
	last := len(factory.transport.writes) - 1
	display, err := d200x.DecodeFrame(factory.transport.writes[:last])
	if err != nil || display.Command != d200x.CommandCompleteDisplayUpload || len(display.Payload) == 0 {
		t.Fatalf("display writes decode = %#v, error=%v", display, err)
	}
	unlock, err := d200x.DecodeFrame(factory.transport.writes[last:])
	if err != nil || unlock.Command != d200x.CommandUnlockScreen || len(unlock.Payload) != 0 {
		t.Fatalf("unlock writes decode = %#v, error=%v", unlock, err)
	}
}

func TestRunRejectsOutOfRangeBrightnessBeforeOpening(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--action", "brightness", "--brightness", "101", "--confirm"}, &stdout, &stderr); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "between 0 and 100") {
		t.Fatalf("stderr = %q", stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatal("out-of-range brightness touched HID")
	}
}
