package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	nativeinput "hidhogg/spikes/go-native-input"
)

type backend interface {
	Check() (bool, error)
	Post(nativeinput.Action, time.Duration) error
	Benchmark(nativeinput.Action, int) (nativeinput.BenchmarkResult, error)
}

type optionsBackend interface {
	PostWithOptions(nativeinput.Action, time.Duration, nativeinput.EventOptions) error
	Inspect(nativeinput.Action, nativeinput.EventOptions) (nativeinput.InspectResult, error)
}

type backendFactory func() (backend, error)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, func() (backend, error) {
		return nativeinput.New()
	}))
}

func run(args []string, stdout, stderr io.Writer, factory backendFactory) int {
	flags := flag.NewFlagSet("native-input", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { printUsage(stderr) }
	check := flags.Bool("check", false, "check post-event permission without prompting or posting")
	benchmark := flags.Int("benchmark", -1, "construct and release text events N times without posting")
	inspect := flags.Bool("inspect", false, "construct events and report their fields without posting")
	text := flags.String("text", "", "insert TEXT as one Unicode keyboard event pair")
	key := flags.String("key", "", "post one key pair; only enter is supported")
	delay := flags.Duration("delay", 0, "wait this long for owner focus before posting")
	sourceName := flags.String("source", "default", "event source: default, private, combined, or hid")
	tapName := flags.String("tap", "hid", "event tap: hid, session, or annotated")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "unexpected positional arguments")
		printUsage(stderr)
		return 2
	}

	seen := map[string]bool{}
	flags.Visit(func(flag *flag.Flag) { seen[flag.Name] = true })
	modeCount := 0
	for _, name := range []string{"check", "benchmark", "text", "key"} {
		if seen[name] {
			modeCount++
		}
	}
	if modeCount == 0 {
		if seen["delay"] {
			return usageError(stderr, "--delay requires --text or --key enter")
		}
		if seen["inspect"] {
			return usageError(stderr, "--inspect requires --text or --key")
		}
		if seen["source"] || seen["tap"] {
			return usageError(stderr, "--source and --tap require --inspect, --text, or --key")
		}
		printUsage(stdout)
		return 0
	}
	if modeCount != 1 {
		return usageError(stderr, "--check, --benchmark, --text, and --key are mutually exclusive")
	}
	if seen["inspect"] && !*inspect {
		return usageError(stderr, "--inspect must be true when supplied")
	}
	if seen["inspect"] && (seen["check"] || seen["benchmark"]) {
		return usageError(stderr, "--inspect requires --text or --key and cannot be combined with --check or --benchmark")
	}
	if seen["check"] {
		if !*check {
			return usageError(stderr, "--check must be true when supplied")
		}
		if seen["delay"] || seen["source"] || seen["tap"] || seen["inspect"] {
			return usageError(stderr, "--check cannot be combined with --delay, --source, --tap, or --inspect")
		}
		return runCheck(stdout, stderr, factory)
	}
	if seen["benchmark"] {
		if seen["delay"] || seen["source"] || seen["tap"] || seen["inspect"] {
			return usageError(stderr, "--benchmark cannot be combined with --delay, --source, --tap, or --inspect")
		}
		if err := validateBenchmarkCount(*benchmark); err != nil {
			return usageError(stderr, err.Error())
		}
		return runBenchmark(*benchmark, stdout, stderr, factory)
	}
	if seen["delay"] {
		if err := validateDelay(*delay); err != nil {
			return usageError(stderr, err.Error())
		}
	}
	if seen["inspect"] && seen["delay"] {
		return usageError(stderr, "--inspect cannot be combined with --delay")
	}
	source, err := nativeinput.ParseEventSource(*sourceName)
	if err != nil {
		return usageError(stderr, err.Error())
	}
	tap, err := nativeinput.ParseEventTap(*tapName)
	if err != nil {
		return usageError(stderr, err.Error())
	}
	options := nativeinput.EventOptions{Source: source, Tap: tap}
	var action nativeinput.Action
	switch {
	case seen["text"]:
		action = nativeinput.Text(*text)
	case seen["key"]:
		if *key != "enter" {
			return usageError(stderr, `--key accepts only "enter"`)
		}
		action = nativeinput.Enter()
	}
	if err := action.Validate(); err != nil {
		return usageError(stderr, err.Error())
	}
	if seen["inspect"] {
		return runInspect(action, options, stdout, stderr, factory)
	}
	return runPost(action, *delay, options, stdout, stderr, factory)
}

func runCheck(stdout, stderr io.Writer, factory backendFactory) int {
	instance, err := factory()
	if err != nil {
		fmt.Fprintf(stderr, "backend unavailable: %v\n", err)
		return 1
	}
	allowed, err := instance.Check()
	if err != nil {
		fmt.Fprintf(stderr, "permission check failed: %v\n", err)
		return 1
	}
	if !allowed {
		fmt.Fprintln(stdout, "post-event permission: denied (preflight only; no prompt or event posted)")
		return 1
	}
	fmt.Fprintln(stdout, "post-event permission: granted (preflight only; no prompt or event posted)")
	return 0
}

func runBenchmark(iterations int, stdout, stderr io.Writer, factory backendFactory) int {
	instance, err := factory()
	if err != nil {
		fmt.Fprintf(stderr, "backend unavailable: %v\n", err)
		return 1
	}
	result, err := instance.Benchmark(nativeinput.Text("1"), iterations)
	if err != nil {
		fmt.Fprintf(stderr, "benchmark failed: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "benchmark: %d measured warm iterations (1 unmeasured warm-up); min=%s median=%s p95=%s max=%s; constructs/releases only, 0 events posted; not UI latency\n", result.Iterations, result.Minimum, result.Median, result.P95, result.Maximum)
	return 0
}

func runInspect(action nativeinput.Action, options nativeinput.EventOptions, stdout, stderr io.Writer, factory backendFactory) int {
	instance, err := factory()
	if err != nil {
		fmt.Fprintf(stderr, "backend unavailable: %v\n", err)
		return 1
	}
	probe, ok := instance.(optionsBackend)
	if !ok {
		fmt.Fprintln(stderr, "inspect unavailable: backend does not support event diagnostics")
		return 1
	}
	result, err := probe.Inspect(action, options)
	if err != nil {
		fmt.Fprintf(stderr, "inspect failed: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "inspect: source=%s tap=%s; constructed %d events; 0 events posted; no permission check\n", formatSource(result.Source), formatTap(result.Tap), len(result.Events))
	for index, event := range result.Events {
		match := "n/a"
		if event.UnicodeComparable {
			match = fmt.Sprintf("%t", event.UnicodeMatches)
		}
		fmt.Fprintf(stdout, "event[%d]: type=%s(%d) keycode=%d flags=0x%x unicode_readback_utf16=%s unicode_match=%s\n", index+1, eventTypeName(event.EventType), event.EventType, event.KeyCode, event.Flags, formatUTF16(event.Unicode), match)
	}
	return 0
}

func runPost(action nativeinput.Action, delay time.Duration, options nativeinput.EventOptions, stdout, stderr io.Writer, factory backendFactory) int {
	instance, err := factory()
	if err != nil {
		fmt.Fprintf(stderr, "backend unavailable: %v\n", err)
		return 1
	}
	var postErr error
	if options == (nativeinput.EventOptions{}) {
		postErr = instance.Post(action, delay)
	} else {
		configurable, ok := instance.(optionsBackend)
		if !ok {
			fmt.Fprintln(stderr, "post unavailable: backend does not support event source/tap selection")
			return 1
		}
		postErr = configurable.PostWithOptions(action, delay, options)
	}
	if postErr != nil {
		if errors.Is(postErr, nativeinput.ErrPermissionDenied) {
			fmt.Fprintln(stderr, "post refused: event-synthesizing permission is denied; no event was posted")
		} else {
			fmt.Fprintf(stderr, "post failed: %v\n", postErr)
		}
		return 1
	}
	if options == (nativeinput.EventOptions{}) {
		fmt.Fprintln(stdout, "posted one key down/up pair to the HID event tap; application delivery is unverified")
	} else {
		fmt.Fprintf(stdout, "posted one key down/up pair to the %s event tap using the %s event source; application delivery is unverified\n", formatTap(options.Tap), formatSource(options.Source))
	}
	return 0
}

func formatSource(source nativeinput.EventSource) string {
	if source == nativeinput.EventSourceDefault {
		return "default(null)"
	}
	stateID, valid := source.StateID()
	if !valid {
		return source.String() + "(invalid)"
	}
	return fmt.Sprintf("%s(%d)", source, stateID)
}

func formatTap(tap nativeinput.EventTap) string {
	tapID, valid := tap.ID()
	if !valid {
		return tap.String() + "(invalid)"
	}
	return fmt.Sprintf("%s(%d)", tap, tapID)
}

func eventTypeName(eventType uint32) string {
	switch eventType {
	case 10:
		return "keyDown"
	case 11:
		return "keyUp"
	default:
		return "unknown"
	}
}

func formatUTF16(units []uint16) string {
	if len(units) == 0 {
		return "[]"
	}
	parts := make([]string, len(units))
	for index, unit := range units {
		parts[index] = fmt.Sprintf("%04X", unit)
	}
	return "[" + strings.Join(parts, " ") + "]"
}

func validateBenchmarkCount(iterations int) error {
	if iterations <= 0 || iterations > nativeinput.MaximumBenchmarkIterations {
		return nativeinput.ErrInvalidBenchmarkCount
	}
	return nil
}

func validateDelay(delay time.Duration) error {
	if delay < 0 || delay > nativeinput.MaximumDelay {
		return nativeinput.ErrInvalidDelay
	}
	return nil
}

func usageError(stderr io.Writer, message string) int {
	fmt.Fprintln(stderr, message)
	printUsage(stderr)
	return 2
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, "usage: native-input --check | --benchmark N | [--inspect] --text TEXT [--source S] [--tap T] [--delay D] | [--inspect] --key enter [--source S] [--tap T] [--delay D]")
	fmt.Fprintln(writer, "--check performs only CGPreflightPostEventAccess; it never prompts or posts")
	fmt.Fprintln(writer, "--benchmark N constructs/releases a one-character Unicode event with one warm-up; it never posts and is not UI latency")
	fmt.Fprintln(writer, "--inspect constructs/releases the selected event pair and reports fields; it never checks permission or posts")
	fmt.Fprintln(writer, "--source selects default (null), private (-1), combined (0), or hid (1) event-source state")
	fmt.Fprintln(writer, "--tap selects hid (0), session (1), or annotated (2) posting tap")
}
