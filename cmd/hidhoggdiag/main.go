package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"

	"hidhogg/internal/d200x"
	"hidhogg/internal/diagnostic"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	return runWithDependencies(args, stdout, stderr, os.Stdin, d200x.NewHIDFactory())
}

func runWithDependencies(args []string, stdout, stderr io.Writer, reader io.Reader, factory d200x.TransportFactory) int {
	return runWithDependenciesAndCue(args, stdout, stderr, reader, factory, diagnostic.FixedEndpointCue{})
}

func runWithDependenciesAndCue(args []string, stdout, stderr io.Writer, reader io.Reader, factory d200x.TransportFactory, endpointCue diagnostic.EndpointCue) int {
	inputReader := newBufferedReadCloser(reader)
	defer inputReader.Close()
	flags := flag.NewFlagSet("hidhoggdiag", flag.ContinueOnError)
	flags.SetOutput(stderr)
	modeValue := flags.String("mode", "", "diagnostic mode: brightness-zero, firmware-wake, or keepalive-prevention")
	configPath := flags.String("config-path", "", "absolute TOML configuration path")
	wakeCandidateValue := flags.String("wake-candidate", "", "firmware-wake candidate: brightness, input-enable, unlock, or complete-page-upload")
	keepaliveInterval := flags.Duration("keepalive-interval", 0, "positive monotonic interval for keepalive-prevention")
	keepaliveDuration := flags.Duration("duration", 0, "positive bounded duration for keepalive-prevention")
	validateKeepaliveSchedule := flags.Bool("validate-keepalive-schedule", false, "validate the closed keepalive schedule without HID activity")
	preflightEndpointCue := flags.Bool("preflight-endpoint-cue", false, "run the fixed endpoint cue and verify that it was heard without HID activity")
	confirm := flags.Bool("confirm", false, "confirm that this diagnostic may enumerate, open, and write one D200X")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "positional arguments are not permitted")
		return 2
	}
	keepaliveIntervalSet := false
	keepaliveDurationSet := false
	configPathSet := false
	wakeCandidateSet := false
	confirmSet := false
	validateKeepaliveScheduleSet := false
	flags.Visit(func(flag *flag.Flag) {
		switch flag.Name {
		case "config-path":
			configPathSet = true
		case "wake-candidate":
			wakeCandidateSet = true
		case "keepalive-interval":
			keepaliveIntervalSet = true
		case "duration":
			keepaliveDurationSet = true
		case "confirm":
			confirmSet = true
		case "validate-keepalive-schedule":
			validateKeepaliveScheduleSet = true
		}
	})
	mode, err := diagnostic.ParseMode(*modeValue)
	if err != nil {
		fmt.Fprintln(stderr, err)
		printUsage(stderr)
		return 2
	}
	if *preflightEndpointCue {
		if mode != diagnostic.ModeKeepalivePrevention {
			fmt.Fprintln(stderr, "--preflight-endpoint-cue is only valid for keepalive-prevention")
			return 2
		}
		if configPathSet || wakeCandidateSet || keepaliveIntervalSet || keepaliveDurationSet || validateKeepaliveScheduleSet || confirmSet {
			fmt.Fprintln(stderr, "--preflight-endpoint-cue does not accept configuration, schedule, wake candidate, validation, or confirmation flags")
			return 2
		}
		return runEndpointCuePreflight(inputReader, stderr, endpointCue)
	}
	if *validateKeepaliveSchedule && mode != diagnostic.ModeKeepalivePrevention {
		fmt.Fprintln(stderr, "--validate-keepalive-schedule is only valid for keepalive-prevention")
		return 2
	}
	if *validateKeepaliveSchedule && (configPathSet || wakeCandidateSet || confirmSet) {
		fmt.Fprintln(stderr, "--validate-keepalive-schedule does not accept configuration, wake candidate, or confirmation flags")
		return 2
	}
	var wakeCandidate diagnostic.WakeCandidate
	if *wakeCandidateValue != "" {
		wakeCandidate, err = diagnostic.ParseWakeCandidate(*wakeCandidateValue)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
	}
	if mode == diagnostic.ModeFirmwareWake && wakeCandidate == "" {
		fmt.Fprintln(stderr, "--wake-candidate is required for firmware-wake")
		return 2
	}
	if mode == diagnostic.ModeBrightnessZero && wakeCandidate != "" {
		fmt.Fprintln(stderr, "--wake-candidate is only valid for firmware-wake")
		return 2
	}
	if mode != diagnostic.ModeKeepalivePrevention && (keepaliveIntervalSet || keepaliveDurationSet) {
		fmt.Fprintln(stderr, "--keepalive-interval and --duration are only valid for keepalive-prevention")
		return 2
	}
	if mode == diagnostic.ModeKeepalivePrevention {
		if err := diagnostic.ValidateKeepaliveSchedule(*keepaliveInterval, *keepaliveDuration); err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
	}
	if *validateKeepaliveSchedule {
		return 0
	}
	if mode == diagnostic.ModeKeepalivePrevention && *confirm {
		preflightStatus := runEndpointCuePreflight(inputReader, stderr, endpointCue)
		observationStatus := diagnostic.StatusPass
		if preflightStatus != 0 {
			observationStatus = diagnostic.StatusInvalidated
		}
		if err := json.NewEncoder(stdout).Encode(diagnostic.Observation{
			Event:  "diagnostic",
			Mode:   diagnostic.ModeKeepalivePrevention,
			Stage:  "keepalive-prevention-same-process-preflight",
			Status: observationStatus,
			Detail: "fixed endpoint cue and exact owner-heard token checked before runner construction",
		}); err != nil {
			fmt.Fprintln(stderr, "keepalive preflight observation failed")
			return 1
		}
		if preflightStatus != 0 {
			return preflightStatus
		}
	}
	runner, err := diagnostic.New(diagnostic.Options{
		Mode:              mode,
		ConfigPath:        *configPath,
		WakeCandidate:     wakeCandidate,
		KeepaliveInterval: *keepaliveInterval,
		KeepaliveDuration: *keepaliveDuration,
		Confirm:           *confirm,
		Factory:           factory,
		Reader:            inputReader,
		PromptWriter:      stderr,
		ObservationWriter: stdout,
		EndpointCue:       endpointCue,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	if !*confirm {
		fmt.Fprintln(stderr, "this diagnostic enumerates, opens, and writes one D200X; repeat with --confirm")
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	result, err := runner.Run(ctx)
	if err == nil {
		if result.Status == diagnostic.StatusPass {
			return 0
		}
		fmt.Fprintf(stderr, "diagnostic status: %s\n", result.Status)
		return 1
	}
	if errors.Is(err, diagnostic.ErrConfirmationRequired) {
		return 2
	}
	fmt.Fprintln(stderr, err)
	return 1
}

func runEndpointCuePreflight(reader *bufferedReadCloser, stderr io.Writer, endpointCue diagnostic.EndpointCue) int {
	if err := diagnostic.RunEndpointCue(context.Background(), endpointCue); err != nil {
		fmt.Fprintln(stderr, "fixed endpoint cue preflight failed")
		return 1
	}
	fmt.Fprintf(stderr, "Type exactly %q if the fixed endpoint cue was heard: ", diagnostic.EndpointCueHeardToken)
	line, err := reader.ReadString('\n')
	if err != nil && !(errors.Is(err, io.EOF) && line != "") {
		fmt.Fprintln(stderr, "endpoint cue owner-heard token was not received")
		return 2
	}
	if !diagnostic.EndpointCueHeard(line) {
		fmt.Fprintln(stderr, "endpoint cue owner-heard token did not match")
		return 2
	}
	fmt.Fprintln(stderr, "endpoint cue owner-heard token accepted")
	return 0
}

type bufferedReadCloser struct {
	reader    *bufio.Reader
	closer    io.Closer
	closeOnce sync.Once
	closeErr  error
}

func newBufferedReadCloser(reader io.Reader) *bufferedReadCloser {
	if reader == nil {
		reader = strings.NewReader("")
	}
	closer, _ := reader.(io.Closer)
	return &bufferedReadCloser{reader: bufio.NewReader(reader), closer: closer}
}

func (reader *bufferedReadCloser) Read(buffer []byte) (int, error) {
	return reader.reader.Read(buffer)
}

func (reader *bufferedReadCloser) ReadString(delimiter byte) (string, error) {
	return reader.reader.ReadString(delimiter)
}

func (reader *bufferedReadCloser) Close() error {
	reader.closeOnce.Do(func() {
		if reader.closer != nil {
			reader.closeErr = reader.closer.Close()
		}
	})
	return reader.closeErr
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, "usage: hidhoggdiag --mode brightness-zero --config-path /absolute/path.toml --confirm")
	fmt.Fprintln(writer, "   or: hidhoggdiag --mode firmware-wake --wake-candidate <candidate> --config-path /absolute/path.toml --confirm")
	fmt.Fprintln(writer, "   or: hidhoggdiag --mode keepalive-prevention --keepalive-interval <duration> --duration <duration> --config-path /absolute/path.toml --confirm")
	fmt.Fprintln(writer, "   or: hidhoggdiag --mode keepalive-prevention --keepalive-interval <duration> --duration <duration> --validate-keepalive-schedule")
	fmt.Fprintln(writer, "   or: hidhoggdiag --mode keepalive-prevention --preflight-endpoint-cue")
}
