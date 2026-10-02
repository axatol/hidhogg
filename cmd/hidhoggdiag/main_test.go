package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"hidhogg/internal/d200x"
	"hidhogg/internal/diagnostic"
)

func TestRunRejectsUnknownModeBeforeDeviceActivity(t *testing.T) {
	factory := &commandFactory{}
	var stdout, stderr bytes.Buffer
	if code := runWithDependencies([]string{
		"--mode", "arbitrary",
		"--config-path", "/private/tmp/config.toml",
		"--confirm",
	}, &stdout, &stderr, strings.NewReader(""), factory); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if len(factory.callsSnapshot()) != 0 {
		t.Fatalf("device calls after unknown mode = %v", factory.callsSnapshot())
	}
}

func TestRunRequiresConfirmationBeforeEnumeration(t *testing.T) {
	configurationPath := writeCommandConfiguration(t)
	factory := &commandFactory{}
	var stdout, stderr bytes.Buffer
	if code := runWithDependencies([]string{
		"--mode", "brightness-zero",
		"--config-path", configurationPath,
	}, &stdout, &stderr, strings.NewReader("\n\n\n\n"), factory); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "--confirm") {
		t.Fatalf("stderr = %q", stderr.String())
	}
	if got := factory.callsSnapshot(); len(got) != 0 {
		t.Fatalf("device calls before confirmation = %v", got)
	}
	if stdout.Len() != 0 {
		t.Fatal("observations emitted before confirmation")
	}
}

func TestRunRequiresWakeCandidateOnlyForFirmwareWake(t *testing.T) {
	configurationPath := writeCommandConfiguration(t)
	factory := &commandFactory{}
	var stdout, stderr bytes.Buffer
	if code := runWithDependencies([]string{
		"--mode", "firmware-wake",
		"--config-path", configurationPath,
		"--confirm",
	}, &stdout, &stderr, strings.NewReader(""), factory); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "--wake-candidate") {
		t.Fatalf("stderr = %q", stderr.String())
	}
	if len(factory.callsSnapshot()) != 0 {
		t.Fatalf("device calls before candidate validation = %v", factory.callsSnapshot())
	}
}

func TestRunRejectsRelativeConfigPath(t *testing.T) {
	factory := &commandFactory{}
	var stdout, stderr bytes.Buffer
	if code := runWithDependencies([]string{
		"--mode", "brightness-zero",
		"--config-path", "config.toml",
		"--confirm",
	}, &stdout, &stderr, strings.NewReader(""), factory); code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "absolute") {
		t.Fatalf("stderr = %q", stderr.String())
	}
	if len(factory.callsSnapshot()) != 0 {
		t.Fatalf("device calls after relative path = %v", factory.callsSnapshot())
	}
}

func TestRunRejectsInvalidKeepaliveArgumentsBeforeDeviceActivity(t *testing.T) {
	configurationPath := writeCommandConfiguration(t)
	tests := []struct {
		name      string
		args      []string
		wantError string
	}{
		{
			name: "missing interval",
			args: []string{"--mode", "keepalive-prevention", "--duration", "4s", "--config-path", configurationPath, "--confirm"},
		},
		{
			name: "missing duration",
			args: []string{"--mode", "keepalive-prevention", "--keepalive-interval", "1s", "--config-path", configurationPath, "--confirm"},
		},
		{
			name: "explicit zero interval",
			args: []string{"--mode", "keepalive-prevention", "--keepalive-interval", "0s", "--duration", "4s", "--config-path", configurationPath, "--confirm"},
		},
		{
			name: "negative duration",
			args: []string{"--mode", "keepalive-prevention", "--keepalive-interval", "1s", "--duration", "-4s", "--config-path", configurationPath, "--confirm"},
		},
		{
			name:      "ratio mismatch",
			args:      []string{"--mode", "keepalive-prevention", "--keepalive-interval", "1s", "--duration", "49s", "--config-path", configurationPath, "--confirm"},
			wantError: "four keepalive intervals",
		},
		{
			name:      "duration over sixty minutes",
			args:      []string{"--mode", "keepalive-prevention", "--keepalive-interval", "15m", "--duration", "60m0.000000001s", "--config-path", configurationPath, "--confirm"},
			wantError: "60 minutes",
		},
		{
			name: "zero experimental boundaries",
			args: []string{"--mode", "keepalive-prevention", "--keepalive-interval", "1s", "--duration", "500ms", "--config-path", configurationPath, "--confirm"},
		},
		{
			name: "mis-scoped interval",
			args: []string{"--mode", "brightness-zero", "--keepalive-interval", "1s", "--config-path", configurationPath, "--confirm"},
		},
		{
			name: "mis-scoped explicit zero",
			args: []string{"--mode", "brightness-zero", "--duration", "0s", "--config-path", configurationPath, "--confirm"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			factory := &commandFactory{}
			var stdout, stderr bytes.Buffer
			if code := runWithDependencies(test.args, &stdout, &stderr, strings.NewReader(""), factory); code != 2 {
				t.Fatalf("exit code = %d, want 2; stderr=%q", code, stderr.String())
			}
			if got := factory.callsSnapshot(); len(got) != 0 {
				t.Fatalf("device calls = %v, want none", got)
			}
			if stdout.Len() != 0 {
				t.Fatalf("observations before refusal = %q", stdout.String())
			}
			if test.wantError != "" && !strings.Contains(stderr.String(), test.wantError) {
				t.Fatalf("stderr = %q, want %q", stderr.String(), test.wantError)
			}
		})
	}
}

func TestRunValidatesClosedKeepaliveScheduleWithoutDeviceActivity(t *testing.T) {
	tests := []struct {
		name      string
		interval  string
		duration  string
		extraArgs []string
		wantCode  int
		wantError string
	}{
		{name: "valid", interval: "15m", duration: "60m", wantCode: 0},
		{name: "ratio mismatch", interval: "1s", duration: "5s", wantCode: 2},
		{name: "duration cap", interval: "15m", duration: "60m0.000000001s", wantCode: 2},
		{name: "explicit empty config", interval: "1s", duration: "4s", extraArgs: []string{"--config-path="}, wantCode: 2, wantError: "does not accept"},
		{name: "explicit empty wake candidate", interval: "1s", duration: "4s", extraArgs: []string{"--wake-candidate="}, wantCode: 2, wantError: "does not accept"},
		{name: "explicit false confirmation", interval: "1s", duration: "4s", extraArgs: []string{"--confirm=false"}, wantCode: 2, wantError: "does not accept"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			factory := &commandFactory{}
			var stdout, stderr bytes.Buffer
			args := []string{
				"--mode", "keepalive-prevention",
				"--keepalive-interval", test.interval,
				"--duration", test.duration,
				"--validate-keepalive-schedule",
			}
			args = append(args, test.extraArgs...)
			code := runWithDependencies(args, &stdout, &stderr, strings.NewReader(""), factory)
			if code != test.wantCode {
				t.Fatalf("exit code = %d, want %d; stderr=%q", code, test.wantCode, stderr.String())
			}
			if got := factory.callsSnapshot(); len(got) != 0 {
				t.Fatalf("device calls = %v, want none", got)
			}
			if stdout.Len() != 0 {
				t.Fatalf("stdout = %q, want empty", stdout.String())
			}
			if test.wantError != "" && !strings.Contains(stderr.String(), test.wantError) {
				t.Fatalf("stderr = %q, want %q", stderr.String(), test.wantError)
			}
		})
	}
}

func TestRunRequiresConfirmationForKeepaliveBeforeDeviceActivity(t *testing.T) {
	configurationPath := writeCommandConfiguration(t)
	factory := &commandFactory{}
	var stdout, stderr bytes.Buffer
	code := runWithDependencies([]string{
		"--mode", "keepalive-prevention",
		"--keepalive-interval", "1s",
		"--duration", "4s",
		"--config-path", configurationPath,
	}, &stdout, &stderr, strings.NewReader(""), factory)
	if code != 2 {
		t.Fatalf("exit code = %d, want 2", code)
	}
	if got := factory.callsSnapshot(); len(got) != 0 {
		t.Fatalf("device calls = %v, want none", got)
	}
	if !strings.Contains(stderr.String(), "--confirm") {
		t.Fatalf("stderr = %q", stderr.String())
	}
}

func TestRunEndpointCuePreflightCompletesBeforeDeviceActivity(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		cueError  error
		wantCode  int
		wantError string
	}{
		{name: "accepted", input: "CUE_HEARD\n", wantCode: 0, wantError: "accepted"},
		{name: "wrong token", input: "cue_heard\n", wantCode: 2, wantError: "did not match"},
		{name: "cue failure", input: "CUE_HEARD\n", cueError: errors.New("private process failure"), wantCode: 1, wantError: "preflight failed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			factory := &commandFactory{}
			cueRuns := 0
			cue := diagnostic.EndpointCueFunc(func(context.Context) error {
				cueRuns++
				return test.cueError
			})
			var stdout, stderr bytes.Buffer
			code := runWithDependenciesAndCue([]string{
				"--mode", "keepalive-prevention",
				"--preflight-endpoint-cue",
			}, &stdout, &stderr, strings.NewReader(test.input), factory, cue)
			if code != test.wantCode {
				t.Fatalf("exit code = %d, want %d; stderr=%q", code, test.wantCode, stderr.String())
			}
			if cueRuns != 1 {
				t.Fatalf("cue runs = %d, want 1", cueRuns)
			}
			if got := factory.callsSnapshot(); len(got) != 0 {
				t.Fatalf("device calls = %v, want none", got)
			}
			if stdout.Len() != 0 || !strings.Contains(stderr.String(), test.wantError) {
				t.Fatalf("stdout=%q stderr=%q", stdout.String(), stderr.String())
			}
		})
	}
}

func TestBufferedReadCloserPreservesPreflightReadAheadAndClosesSourceOnce(t *testing.T) {
	source := &trackedDiagnosticInput{data: []byte("CUE_HEARD\nnext-line\n")}
	reader := newBufferedReadCloser(source)
	var stderr bytes.Buffer
	if code := runEndpointCuePreflight(reader, &stderr, diagnostic.EndpointCueFunc(func(context.Context) error {
		return nil
	})); code != 0 {
		t.Fatalf("preflight exit code = %d; stderr=%q", code, stderr.String())
	}
	if got := source.readCountValue(); got != 1 {
		t.Fatalf("source reads = %d, want one buffered read", got)
	}
	line, err := reader.ReadString('\n')
	if err != nil || line != "next-line\n" {
		t.Fatalf("read-ahead line/error = %q/%v, want next-line/ nil", line, err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if got := source.closeCountValue(); got != 1 {
		t.Fatalf("source closes = %d, want exactly one", got)
	}
}

func TestBufferedReadCloserDelegatesReadAndClose(t *testing.T) {
	source := &trackedDiagnosticInput{data: []byte("input")}
	reader := newBufferedReadCloser(source)
	buffer := make([]byte, len("input"))
	if n, err := reader.Read(buffer); err != nil || string(buffer[:n]) != "input" {
		t.Fatalf("delegated read = %q/%v, want input/nil", buffer[:], err)
	}
	if got := source.readCountValue(); got != 1 {
		t.Fatalf("source reads = %d, want one", got)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if got := source.closeCountValue(); got != 1 {
		t.Fatalf("source closes = %d, want exactly one", got)
	}
}

func TestPhysicalKeepaliveRequiresSameProcessCueBeforeRunnerOrHID(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		cueError   error
		wantCode   int
		wantStatus string
	}{
		{name: "accepted before runner validation", input: "CUE_HEARD\n", wantCode: 2, wantStatus: `"status":"pass"`},
		{name: "wrong token", input: "wrong\n", wantCode: 2, wantStatus: `"status":"invalidated"`},
		{name: "cue failure", input: "CUE_HEARD\n", cueError: errors.New("cue failed"), wantCode: 1, wantStatus: `"status":"invalidated"`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			factory := &commandFactory{}
			cueRuns := 0
			var stdout, stderr bytes.Buffer
			code := runWithDependenciesAndCue([]string{
				"--mode", "keepalive-prevention",
				"--keepalive-interval", "1s",
				"--duration", "4s",
				"--config-path", "relative.toml",
				"--confirm",
			}, &stdout, &stderr, strings.NewReader(test.input), factory, diagnostic.EndpointCueFunc(func(context.Context) error {
				cueRuns++
				return test.cueError
			}))
			if code != test.wantCode || cueRuns != 1 {
				t.Fatalf("code=%d cue_runs=%d stderr=%q", code, cueRuns, stderr.String())
			}
			if got := factory.callsSnapshot(); len(got) != 0 {
				t.Fatalf("device calls before same-process preflight = %v", got)
			}
			if !strings.Contains(stdout.String(), `"stage":"keepalive-prevention-same-process-preflight"`) || !strings.Contains(stdout.String(), test.wantStatus) {
				t.Fatalf("stdout=%q", stdout.String())
			}
		})
	}
}

func TestRunEndpointCuePreflightRejectsAdditionalSurfacesBeforeCueOrDevice(t *testing.T) {
	for _, extra := range [][]string{
		{"--config-path="},
		{"--keepalive-interval", "1s"},
		{"--duration", "4s"},
		{"--confirm=false"},
		{"--wake-candidate="},
		{"--validate-keepalive-schedule=false"},
	} {
		t.Run(strings.Join(extra, "_"), func(t *testing.T) {
			factory := &commandFactory{}
			cueRuns := 0
			args := append([]string{"--mode", "keepalive-prevention", "--preflight-endpoint-cue"}, extra...)
			var stdout, stderr bytes.Buffer
			code := runWithDependenciesAndCue(args, &stdout, &stderr, strings.NewReader("CUE_HEARD\n"), factory, diagnostic.EndpointCueFunc(func(context.Context) error {
				cueRuns++
				return nil
			}))
			if code != 2 || cueRuns != 0 || len(factory.callsSnapshot()) != 0 || stdout.Len() != 0 {
				t.Fatalf("code=%d cue_runs=%d calls=%v stdout=%q stderr=%q", code, cueRuns, factory.callsSnapshot(), stdout.String(), stderr.String())
			}
		})
	}
}

func writeCommandConfiguration(t *testing.T) string {
	t.Helper()
	var builder strings.Builder
	builder.WriteString("schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = 73\ndefault_profile_id = \"default\"\n\n[profiles.\"default\"]\nlabel = \"Default\"\n\n")
	for index, spec := range d200x.SupportedPositions() {
		builder.WriteString("[profiles.\"default\".positions.\"" + spec.Name + "\"]\n")
		builder.WriteString("label = \"Tile " + string(rune('0'+index)) + "\"\n")
		builder.WriteString("background = \"#102030\"\n\n")
	}
	path := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(path, []byte(builder.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

type commandFactory struct {
	mu    sync.Mutex
	calls []string
}

func (factory *commandFactory) Enumerate(context.Context) ([]d200x.Candidate, error) {
	factory.mu.Lock()
	factory.calls = append(factory.calls, "enumerate")
	factory.mu.Unlock()
	return nil, errors.New("not expected in argument validation tests")
}

func (factory *commandFactory) Open(context.Context, d200x.Candidate) (d200x.Transport, error) {
	factory.mu.Lock()
	factory.calls = append(factory.calls, "open")
	factory.mu.Unlock()
	return nil, errors.New("not expected")
}

func (factory *commandFactory) callsSnapshot() []string {
	factory.mu.Lock()
	defer factory.mu.Unlock()
	return append([]string(nil), factory.calls...)
}

type commandTransport struct{}

func (commandTransport) Read(context.Context, []byte) (int, error) { return 0, io.EOF }
func (commandTransport) Write(context.Context, []byte) (int, error) {
	return 0, errors.New("not expected")
}
func (commandTransport) Close() error { return nil }

var _ d200x.TransportFactory = (*commandFactory)(nil)
var _ d200x.Transport = commandTransport{}

type trackedDiagnosticInput struct {
	mu         sync.Mutex
	data       []byte
	readCount  int
	closeCount int
}

func (reader *trackedDiagnosticInput) Read(buffer []byte) (int, error) {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	reader.readCount++
	if len(reader.data) == 0 {
		return 0, io.EOF
	}
	n := copy(buffer, reader.data)
	reader.data = reader.data[n:]
	return n, nil
}

func (reader *trackedDiagnosticInput) Close() error {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	reader.closeCount++
	return nil
}

func (reader *trackedDiagnosticInput) readCountValue() int {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	return reader.readCount
}

func (reader *trackedDiagnosticInput) closeCountValue() int {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	return reader.closeCount
}
