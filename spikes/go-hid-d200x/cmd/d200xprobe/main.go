package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"syscall"
	"time"

	d200x "hidhogg/spikes/go-hid-d200x"
)

type actionDefinition struct {
	command d200x.Command
	name    string
}

var (
	actionDefinitions = []actionDefinition{
		{d200x.CommandCompleteDisplayUpload, "complete-display-upload"},
		{d200x.CommandEnableInputStream, "enable-input-stream"},
		{d200x.CommandObservedHostLock, "observed-host-lock"},
		{d200x.CommandSmallWindowRefresh, "small-window-refresh"},
		{d200x.CommandBrightness, "brightness"},
		{d200x.CommandLabelStyle, "label-style"},
		{d200x.CommandPartialDisplayUpload, "partial-display-upload"},
		{d200x.CommandLockScreen, "lock-screen"},
		{d200x.CommandUnlockScreen, "unlock-screen"},
		{d200x.CommandInputEvent, "input-event"},
		{d200x.CommandAcknowledgement, "acknowledgement"},
		{d200x.CommandDeviceInformation, "device-information"},
	}
	canonicalBrightness = regexp.MustCompile(`^(0|[1-9][0-9]?|100)$`)
)

type optionalString struct {
	present bool
	value   string
}

func (value *optionalString) String() string { return value.value }
func (value *optionalString) Set(raw string) error {
	value.present = true
	value.value = raw
	return nil
}

type optionalBool struct {
	present bool
	value   bool
}

func (value *optionalBool) String() string { return strconv.FormatBool(value.value) }
func (value *optionalBool) Set(raw string) error {
	parsed, err := strconv.ParseBool(raw)
	if err != nil {
		return err
	}
	value.present = true
	value.value = parsed
	return nil
}
func (*optionalBool) IsBoolFlag() bool { return true }

type optionalDuration struct {
	present bool
	value   time.Duration
}

func (value *optionalDuration) String() string { return value.value.String() }
func (value *optionalDuration) Set(raw string) error {
	duration, err := time.ParseDuration(raw)
	if err != nil {
		return err
	}
	value.present = true
	value.value = duration
	return nil
}

func main() {
	os.Exit(run(os.Args[1:], d200x.NewHIDFactory(), os.Stdout, os.Stderr))
}

func run(args []string, factory d200x.TransportFactory, stdout, stderr io.Writer) int {
	return runWithClockAndRandom(args, factory, stdout, stderr, newListenSignalContext, time.Now, secureSyntheticMetricValue)
}

func runWithClock(args []string, factory d200x.TransportFactory, stdout, stderr io.Writer, signalContext listenSignalContext, now func() time.Time) int {
	return runWithClockAndRandom(args, factory, stdout, stderr, signalContext, now, secureSyntheticMetricValue)
}

func runWithClockAndRandom(args []string, factory d200x.TransportFactory, stdout, stderr io.Writer, signalContext listenSignalContext, now func() time.Time, source metricRandomSource) int {
	return runWithSignalContextAndClockAndRandom(args, factory, stdout, stderr, signalContext, now, source)
}

type listenSignalContext func(context.Context) (context.Context, context.CancelFunc)

func newListenSignalContext(parent context.Context) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)
}

func runWithSignalContext(args []string, factory d200x.TransportFactory, stdout, stderr io.Writer, signalContext listenSignalContext) int {
	return runWithSignalContextAndClockAndRandom(args, factory, stdout, stderr, signalContext, time.Now, secureSyntheticMetricValue)
}

func runWithSignalContextAndClock(args []string, factory d200x.TransportFactory, stdout, stderr io.Writer, signalContext listenSignalContext, now func() time.Time) int {
	return runWithSignalContextAndClockAndRandom(args, factory, stdout, stderr, signalContext, now, secureSyntheticMetricValue)
}

func runWithSignalContextAndClockAndRandom(args []string, factory d200x.TransportFactory, stdout, stderr io.Writer, signalContext listenSignalContext, now func() time.Time, source metricRandomSource) int {
	flags := flag.NewFlagSet("d200xprobe", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() {
		fmt.Fprintln(stderr, "Usage: d200xprobe --action <symbolic-name> [--parameters <value>]")
		fmt.Fprintln(stderr, "       d200xprobe --listen [--duration <positive-duration>]")
		flags.PrintDefaults()
		fmt.Fprintln(stderr, "complete-display-upload --parameters live-bulk sends one 0x0001 archive with all 14 positions.")
		fmt.Fprintln(stderr, "Expected device observation is bulk redraw, progressive redraw, or no visible change; host write success is not device acceptance.")
	}
	action := flags.String("action", "", "one symbolic D200X action")
	var parameters optionalString
	var listen optionalBool
	var duration optionalDuration
	flags.Var(&parameters, "parameters", "action parameters")
	flags.Var(&listen, "listen", "passively listen for device frames")
	flags.Var(&duration, "duration", "bounded passive listen duration")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "positional arguments are not accepted")
		return 2
	}
	if listen.present && (*action != "" || parameters.present) {
		fmt.Fprintln(stderr, "--listen is mutually exclusive with --action and --parameters")
		return 2
	}
	if duration.present && (!listen.present || !listen.value) {
		fmt.Fprintln(stderr, "--duration requires --listen")
		return 2
	}
	if listen.present && listen.value {
		if duration.present && duration.value <= 0 {
			fmt.Fprintln(stderr, "--duration must be a positive duration")
			return 2
		}
		return listenPassivelyWithSignalContext(factory, duration.value, stdout, stderr, signalContext)
	}
	if *action == "" {
		fmt.Fprintln(stderr, "exactly one of --action or --listen is required")
		return 2
	}

	frame, metrics, err := buildActionFrameWithClockAndRandom(*action, parameters, now, source)
	if err != nil {
		fmt.Fprintf(stderr, "invalid action request: %v\n", err)
		return 2
	}
	return sendActionFrameWithMetrics(context.Background(), factory, *action, frame, metrics, stdout, stderr)
}

func buildActionFrame(name string, parameters optionalString) (d200x.Frame, error) {
	return buildActionFrameWithClock(name, parameters, time.Now)
}

func buildActionFrameWithClock(name string, parameters optionalString, now func() time.Time) (d200x.Frame, error) {
	frame, _, err := buildActionFrameWithClockAndRandom(name, parameters, now, secureSyntheticMetricValue)
	return frame, err
}

func buildActionFrameWithClockAndRandom(name string, parameters optionalString, now func() time.Time, source metricRandomSource) (d200x.Frame, *syntheticMetricValues, error) {
	definition, ok := lookupAction(name)
	if !ok {
		return d200x.Frame{}, nil, errors.New("unknown action")
	}
	switch definition.command {
	case d200x.CommandSmallWindowRefresh:
		if !parameters.present {
			return d200x.NewFrame(definition.command, nil), nil, nil
		}
		return parseSmallWindowParametersWithClockAndRandom(parameters.value, now, source)
	case d200x.CommandBrightness:
		if !parameters.present || !canonicalBrightness.MatchString(parameters.value) {
			return d200x.Frame{}, nil, errors.New("brightness requires canonical decimal --parameters from 0 through 100")
		}
		percentage, _ := strconv.Atoi(parameters.value)
		return d200x.NewFrame(definition.command, []byte(strconv.Itoa(percentage))), nil, nil
	case d200x.CommandCompleteDisplayUpload:
		if !parameters.present {
			return d200x.Frame{}, nil, errors.New("complete-display-upload requires --parameters diagnostic or live-bulk")
		}
		switch parameters.value {
		case "diagnostic":
			frame, err := d200x.DiagnosticDisplayFrame()
			return frame, nil, err
		case d200x.LiveBulkDisplayPreset:
			frame, err := d200x.LiveBulkDisplayFrame()
			return frame, nil, err
		default:
			return d200x.Frame{}, nil, errors.New("complete-display-upload requires --parameters diagnostic or live-bulk")
		}
	case d200x.CommandPartialDisplayUpload:
		if !parameters.present {
			return d200x.Frame{}, nil, errors.New("partial-display-upload requires one of --parameters square-a, square-b, or wide")
		}
		frame, err := d200x.PartialDisplayUploadFrameForPreset(parameters.value)
		return frame, nil, err
	default:
		if parameters.present {
			return d200x.Frame{}, nil, fmt.Errorf("%s does not accept --parameters", name)
		}
		return d200x.NewFrame(definition.command, nil), nil, nil
	}
}

func lookupAction(name string) (actionDefinition, bool) {
	for _, definition := range actionDefinitions {
		if definition.name == name {
			return definition, true
		}
	}
	return actionDefinition{}, false
}

func sendActionFrame(ctx context.Context, factory d200x.TransportFactory, name string, frame d200x.Frame, stdout, stderr io.Writer) int {
	return sendActionFrameWithMetrics(ctx, factory, name, frame, nil, stdout, stderr)
}

func sendActionFrameWithMetrics(ctx context.Context, factory d200x.TransportFactory, name string, frame d200x.Frame, metrics *syntheticMetricValues, stdout, stderr io.Writer) int {
	candidate, err := selectCandidate(ctx, factory)
	if err != nil {
		fmt.Fprintln(stderr, "device selection failed")
		return 1
	}
	session := d200x.NewSession(factory)
	defer session.Close()
	if err := session.Replace(ctx, candidate); err != nil {
		fmt.Fprintln(stderr, "device open failed")
		return 1
	}
	writer := d200x.NewExperimentalProbeWriter(session)
	if err := writer.SendExperimentalFrame(ctx, frame); err != nil {
		fmt.Fprintln(stderr, "frame write failed")
		return 1
	}
	if metrics == nil {
		fmt.Fprintf(stdout, "write completed for %s (0x%04x); device behavior not asserted\n", name, uint16(frame.Command))
		return 0
	}
	fmt.Fprintf(stdout, "write completed for %s (0x%04x); synthetic metrics cpu=%d ram=%d gpu=%d; device behavior not asserted\n", name, uint16(frame.Command), metrics.cpu, metrics.ram, metrics.gpu)
	return 0
}

func listenPassively(factory d200x.TransportFactory, duration time.Duration, stdout, stderr io.Writer) int {
	return listenPassivelyWithSignalContext(factory, duration, stdout, stderr, newListenSignalContext)
}

func listenPassivelyWithSignalContext(factory d200x.TransportFactory, duration time.Duration, stdout, stderr io.Writer, signalContext listenSignalContext) int {
	if duration < 0 {
		fmt.Fprintln(stderr, "--duration must be a positive duration")
		return 2
	}
	if signalContext == nil {
		signalContext = newListenSignalContext
	}
	listenContext, stopSignals := signalContext(context.Background())
	if listenContext == nil || stopSignals == nil {
		fmt.Fprintln(stderr, "signal handling setup failed")
		return 1
	}
	defer stopSignals()

	ctx := listenContext
	var cancel context.CancelFunc
	if duration > 0 {
		ctx, cancel = context.WithTimeout(listenContext, duration)
		defer cancel()
	}

	candidate, err := selectCandidate(ctx, factory)
	if err != nil {
		if reason, ended := listenTerminationReason(ctx, listenContext); ended {
			fmt.Fprintln(stdout, passiveListenEndMessage(reason))
			return 0
		}
		fmt.Fprintln(stderr, "device selection failed")
		return 1
	}
	session := d200x.NewSession(factory)
	defer session.Close()
	if err := session.Replace(ctx, candidate); err != nil {
		if reason, ended := listenTerminationReason(ctx, listenContext); ended {
			fmt.Fprintln(stdout, passiveListenEndMessage(reason))
			return 0
		}
		fmt.Fprintln(stderr, "device open failed")
		return 1
	}
	fmt.Fprintln(stdout, "passive listen started; zero frames will be sent")

	report := make([]byte, d200x.TransportReportSize)
	var assembler *d200x.FrameAssembler
	for {
		if reason, ended := listenTerminationReason(ctx, listenContext); ended {
			return finishPassiveListen(assembler, reason, stdout, stderr)
		}
		n, readErr := session.Read(ctx, report)
		if reason, ended := listenTerminationReason(ctx, listenContext); ended && readErr != nil {
			return finishPassiveListen(assembler, reason, stdout, stderr)
		}
		if readErr != nil {
			fmt.Fprintln(stderr, "passive read failed")
			return 1
		}
		if n == 0 {
			continue
		}
		if assembler == nil {
			assembler, err = d200x.NewFrameAssembler(report[:n])
		} else {
			err = assembler.Append(report[:n])
		}
		if err != nil {
			fmt.Fprintf(stderr, "frame assembly failed: %v\n", err)
			return 1
		}
		if !assembler.Complete() {
			continue
		}
		frame, frameErr := assembler.Frame()
		if frameErr != nil {
			fmt.Fprintf(stderr, "frame completion failed: %v\n", frameErr)
			return 1
		}
		logFrame(stdout, frame)
		assembler = nil
	}
}

func listenTerminationReason(ctx, listenContext context.Context) (string, bool) {
	if listenContext.Err() != nil {
		return "signal", true
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return "duration", true
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		return "signal", true
	}
	return "", false
}

func passiveListenEndMessage(reason string) string {
	if reason == "signal" {
		return "passive listen stopped by signal"
	}
	return "passive listen duration elapsed"
}

func finishPassiveListen(assembler *d200x.FrameAssembler, reason string, stdout, stderr io.Writer) int {
	if assembler != nil && !assembler.Complete() {
		fmt.Fprintf(stderr, "passive listen ended with partial frame: received %d of %d payload bytes\n", assembler.ReceivedPayloadLength(), assembler.ExpectedPayloadLength())
		return 1
	}
	fmt.Fprintln(stdout, passiveListenEndMessage(reason))
	return 0
}

func logFrame(writer io.Writer, frame d200x.Frame) {
	digest := sha256.Sum256(frame.Payload)
	fmt.Fprintf(writer, "frame command=%s id=0x%04x payload-bytes=%d sha256=%x", frame.Command, uint16(frame.Command), len(frame.Payload), digest)
	event, input, err := d200x.DecodeInput(frame)
	if input && err == nil {
		fmt.Fprintf(writer, " input-index=%d marker=0x%02x action=0x%02x", event.WireIndex, byte(event.Marker), byte(event.Action))
	} else if input {
		fmt.Fprint(writer, " input=malformed")
	}
	fmt.Fprintln(writer)
}

func selectCandidate(ctx context.Context, factory d200x.TransportFactory) (d200x.Candidate, error) {
	candidates, err := factory.Enumerate(ctx)
	if err != nil {
		return d200x.Candidate{}, err
	}
	return d200x.SelectSingle(candidates)
}
