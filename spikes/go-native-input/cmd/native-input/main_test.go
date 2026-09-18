package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
	"time"

	nativeinput "hidhogg/spikes/go-native-input"
)

type fakeBackend struct {
	checkResult    bool
	checkErr       error
	postErr        error
	benchResult    nativeinput.BenchmarkResult
	benchErr       error
	inspectResult  nativeinput.InspectResult
	inspectErr     error
	checks         int
	posts          int
	optionPosts    int
	benchmarks     int
	inspects       int
	action         nativeinput.Action
	delay          time.Duration
	iterations     int
	options        nativeinput.EventOptions
	inspectOptions nativeinput.EventOptions
}

func (f *fakeBackend) Check() (bool, error) {
	f.checks++
	return f.checkResult, f.checkErr
}

func (f *fakeBackend) Post(action nativeinput.Action, delay time.Duration) error {
	f.posts++
	f.action = action
	f.delay = delay
	return f.postErr
}

func (f *fakeBackend) PostWithOptions(action nativeinput.Action, delay time.Duration, options nativeinput.EventOptions) error {
	f.optionPosts++
	f.action = action
	f.delay = delay
	f.options = options
	return f.postErr
}

func (f *fakeBackend) Benchmark(action nativeinput.Action, iterations int) (nativeinput.BenchmarkResult, error) {
	f.benchmarks++
	f.action = action
	f.iterations = iterations
	return f.benchResult, f.benchErr
}

func (f *fakeBackend) Inspect(action nativeinput.Action, options nativeinput.EventOptions) (nativeinput.InspectResult, error) {
	f.inspects++
	f.action = action
	f.inspectOptions = options
	return f.inspectResult, f.inspectErr
}

func factoryFor(fake *fakeBackend) backendFactory {
	return func() (backend, error) { return fake, nil }
}

func TestDefaultPrintsUsageWithoutCreatingBackend(t *testing.T) {
	var stdout, stderr bytes.Buffer
	created := false
	code := run(nil, &stdout, &stderr, func() (backend, error) {
		created = true
		return nil, errors.New("must not create backend")
	})
	if code != 0 || created || !strings.Contains(stdout.String(), "usage:") || stderr.Len() != 0 {
		t.Fatalf("code=%d created=%t stdout=%q stderr=%q", code, created, stdout.String(), stderr.String())
	}
}

func TestCheckNeverPostsOrPrompts(t *testing.T) {
	fake := &fakeBackend{checkResult: true}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--check"}, &stdout, &stderr, factoryFor(fake))
	if code != 0 || fake.checks != 1 || fake.posts != 0 || fake.benchmarks != 0 {
		t.Fatalf("code=%d checks=%d posts=%d benchmarks=%d", code, fake.checks, fake.posts, fake.benchmarks)
	}
	if !strings.Contains(stdout.String(), "preflight only") || !strings.Contains(stdout.String(), "no prompt or event posted") {
		t.Fatalf("stdout=%q", stdout.String())
	}
}

func TestDeniedCheckReturnsFailureWithoutPosting(t *testing.T) {
	fake := &fakeBackend{}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--check"}, &stdout, &stderr, factoryFor(fake))
	if code != 1 || fake.checks != 1 || fake.posts != 0 || !strings.Contains(stdout.String(), "denied") {
		t.Fatalf("code=%d checks=%d posts=%d stdout=%q", code, fake.checks, fake.posts, stdout.String())
	}
}

func TestBenchmarkUsesEnterAndReportsNoPost(t *testing.T) {
	fake := &fakeBackend{benchResult: nativeinput.BenchmarkResult{Iterations: 3}}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--benchmark", "3"}, &stdout, &stderr, factoryFor(fake))
	if code != 0 || fake.benchmarks != 1 || fake.posts != 0 || fake.iterations != 3 {
		t.Fatalf("code=%d benchmarks=%d posts=%d iterations=%d", code, fake.benchmarks, fake.posts, fake.iterations)
	}
	if fake.action != nativeinput.Text("1") || !strings.Contains(stdout.String(), "not UI latency") || !strings.Contains(stdout.String(), "0 events posted") {
		t.Fatalf("action=%+v stdout=%q", fake.action, stdout.String())
	}
}

func TestTextPostPassesActionAndDelay(t *testing.T) {
	fake := &fakeBackend{}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--text", "hé", "--delay", "2ms"}, &stdout, &stderr, factoryFor(fake))
	if code != 0 || fake.posts != 1 || fake.action.Kind != nativeinput.ActionText || fake.action.Text != "hé" || fake.delay != 2*time.Millisecond {
		t.Fatalf("code=%d posts=%d action=%+v delay=%s", code, fake.posts, fake.action, fake.delay)
	}
	if !strings.Contains(stdout.String(), "application delivery is unverified") {
		t.Fatalf("stdout=%q", stdout.String())
	}
}

func TestEnterPostPassesKeyAction(t *testing.T) {
	fake := &fakeBackend{}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--key", "enter"}, &stdout, &stderr, factoryFor(fake))
	if code != 0 || fake.posts != 1 || fake.action != nativeinput.Enter() || fake.delay != 0 {
		t.Fatalf("code=%d posts=%d action=%+v delay=%s", code, fake.posts, fake.action, fake.delay)
	}
}

func TestInspectConstructsWithoutPostingAndReportsReadback(t *testing.T) {
	fake := &fakeBackend{inspectResult: nativeinput.InspectResult{
		Source: nativeinput.EventSourceCombined,
		Tap:    nativeinput.EventTapSession,
		Events: []nativeinput.EventInspection{
			{EventType: 10, KeyCode: 0, Flags: 0, Unicode: []uint16{0x0068}, UnicodeComparable: true, UnicodeMatches: true},
			{EventType: 11, KeyCode: 0, Flags: 0, Unicode: []uint16{0x0068}, UnicodeComparable: true, UnicodeMatches: false},
		},
	}}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--inspect", "--text", "h", "--source", "combined", "--tap", "session"}, &stdout, &stderr, factoryFor(fake))
	if code != 0 || fake.inspects != 1 || fake.posts != 0 || fake.optionPosts != 0 {
		t.Fatalf("code=%d inspects=%d posts=%d optionPosts=%d", code, fake.inspects, fake.posts, fake.optionPosts)
	}
	wantOptions := nativeinput.EventOptions{Source: nativeinput.EventSourceCombined, Tap: nativeinput.EventTapSession}
	if fake.action != nativeinput.Text("h") || fake.inspectOptions != wantOptions {
		t.Fatalf("action=%+v options=%+v, want %+v %+v", fake.action, fake.inspectOptions, nativeinput.Text("h"), wantOptions)
	}
	output := stdout.String()
	for _, fragment := range []string{
		"source=combined(0)",
		"tap=session(1)",
		"0 events posted",
		"type=keyDown(10)",
		"keycode=0",
		"flags=0x0",
		"unicode_readback_utf16=[0068]",
		"unicode_match=true",
		"unicode_match=false",
	} {
		if !strings.Contains(output, fragment) {
			t.Fatalf("stdout=%q, missing %q", output, fragment)
		}
	}
}

func TestInspectEnterMarksUnicodeComparisonNotApplicable(t *testing.T) {
	fake := &fakeBackend{inspectResult: nativeinput.InspectResult{
		Source: nativeinput.EventSourceDefault,
		Tap:    nativeinput.EventTapHID,
		Events: []nativeinput.EventInspection{{EventType: 10, KeyCode: 36, Unicode: []uint16{0x000d}}},
	}}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--inspect", "--key", "enter"}, &stdout, &stderr, factoryFor(fake))
	if code != 0 || fake.inspects != 1 || fake.posts != 0 || !strings.Contains(stdout.String(), "unicode_match=n/a") {
		t.Fatalf("code=%d inspects=%d posts=%d stdout=%q", code, fake.inspects, fake.posts, stdout.String())
	}
}

func TestSelectedSourceAndTapPassToPostingBackend(t *testing.T) {
	fake := &fakeBackend{}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--key", "enter", "--source", "hid", "--tap", "annotated", "--delay", "2ms"}, &stdout, &stderr, factoryFor(fake))
	if code != 0 || fake.posts != 0 || fake.optionPosts != 1 || fake.options != (nativeinput.EventOptions{Source: nativeinput.EventSourceHID, Tap: nativeinput.EventTapAnnotated}) || fake.delay != 2*time.Millisecond {
		t.Fatalf("code=%d posts=%d optionPosts=%d options=%+v delay=%s", code, fake.posts, fake.optionPosts, fake.options, fake.delay)
	}
	if !strings.Contains(stdout.String(), "annotated(2) event tap") || !strings.Contains(stdout.String(), "hid(1) event source") || !strings.Contains(stdout.String(), "delivery is unverified") {
		t.Fatalf("stdout=%q", stdout.String())
	}
}

func TestIncompatibleAndInvalidFlagsDoNotCreateBackend(t *testing.T) {
	tests := [][]string{
		{"--check", "--benchmark", "3"},
		{"--benchmark", "0"},
		{"--key", "space"},
		{"--delay", "1s"},
		{"--text", ""},
		{"--inspect"},
		{"--inspect", "--text", "A", "--delay", "1s"},
		{"--text", "A", "--source", "invalid"},
		{"--text", "A", "--tap", "invalid"},
		{"--benchmark", "3", "--source", "private"},
	}
	for _, args := range tests {
		t.Run(strings.Join(args, "_"), func(t *testing.T) {
			created := false
			var stdout, stderr bytes.Buffer
			code := run(args, &stdout, &stderr, func() (backend, error) {
				created = true
				return nil, errors.New("must not create backend")
			})
			if code != 2 || created {
				t.Fatalf("args=%v code=%d created=%t stdout=%q stderr=%q", args, code, created, stdout.String(), stderr.String())
			}
		})
	}
}
