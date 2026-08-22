package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	d200x "hidhogg/spikes/go-hid-d200x"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("d200x", flag.ContinueOnError)
	flags.SetOutput(stderr)
	action := flags.String("action", "", "explicit action: enumerate, open-close-loop, listen-input, brightness, diagnostic-display, reconnect-observation")
	iterations := flags.Int("iterations", 20, "open-close iterations")
	duration := flags.Duration("duration", 30*time.Second, "bounded observation/listen duration")
	brightness := flags.Int("brightness", -1, "brightness percentage, 0 through 100")
	confirm := flags.Bool("confirm", false, "confirm an explicit outbound device command")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *action == "" {
		printUsage(stderr)
		return 2
	}

	factory := d200x.NewHIDFactory()
	switch *action {
	case "enumerate":
		return enumerate(context.Background(), factory, stdout, stderr)
	case "open-close-loop":
		if *iterations <= 0 {
			fmt.Fprintln(stderr, "--iterations must be greater than zero")
			return 2
		}
		return openCloseLoop(context.Background(), factory, *iterations, stdout, stderr)
	case "listen-input":
		if !*confirm {
			fmt.Fprintln(stderr, "listen-input sends command 0x0002; repeat with --confirm")
			return 2
		}
		if *duration <= 0 {
			fmt.Fprintln(stderr, "--duration must be greater than zero")
			return 2
		}
		return listenInput(factory, *duration, stdout, stderr)
	case "brightness":
		if !*confirm {
			fmt.Fprintln(stderr, "brightness sends command 0x000a; repeat with --confirm")
			return 2
		}
		if *brightness < 0 || *brightness > 100 {
			fmt.Fprintln(stderr, "--brightness must be between 0 and 100")
			return 2
		}
		return sendOneFrame(context.Background(), factory, d200x.BrightnessFrame(*brightness), "brightness", stdout, stderr)
	case "diagnostic-display":
		if !*confirm {
			fmt.Fprintln(stderr, "diagnostic-display sends a numbered display upload (0x0001) and unlock (0x0010); repeat with --confirm")
			return 2
		}
		return sendDiagnosticDisplay(context.Background(), factory, stdout, stderr)
	case "reconnect-observation":
		if *duration <= 0 {
			fmt.Fprintln(stderr, "--duration must be greater than zero")
			return 2
		}
		return reconnectObservation(factory, *duration, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown --action %q\n", *action)
		printUsage(stderr)
		return 2
	}
}

func printUsage(writer io.Writer) {
	fmt.Fprintln(writer, "an explicit --action is required")
	fmt.Fprintln(writer, "actions: enumerate | open-close-loop | listen-input | brightness | diagnostic-display | reconnect-observation")
}

func enumerate(ctx context.Context, factory d200x.TransportFactory, stdout, stderr io.Writer) int {
	candidates, err := factory.Enumerate(ctx)
	if err != nil {
		fmt.Fprintf(stderr, "enumeration failed: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "matching interface-0 devices: %d\n", len(candidates))
	for index, candidate := range candidates {
		// Candidate.Summary deliberately excludes path and serial-number data.
		fmt.Fprintf(stdout, "candidate %d: %s\n", index+1, candidate.Summary())
	}
	if len(candidates) > 1 {
		fmt.Fprintln(stdout, "selection: refused until one matching interface-0 device remains")
	}
	return 0
}

func openCloseLoop(ctx context.Context, factory d200x.TransportFactory, iterations int, stdout, stderr io.Writer) int {
	candidate, err := selectCandidate(ctx, factory)
	if err != nil {
		fmt.Fprintf(stderr, "open-close selection failed: %v\n", err)
		return 1
	}
	for iteration := 1; iteration <= iterations; iteration++ {
		transport, err := factory.Open(ctx, candidate)
		if err != nil {
			fmt.Fprintf(stderr, "open-close iteration %d failed: %v\n", iteration, err)
			return 1
		}
		if err := transport.Close(); err != nil {
			fmt.Fprintf(stderr, "close iteration %d failed: %v\n", iteration, err)
			return 1
		}
		fmt.Fprintf(stdout, "open-close %d/%d: ok\n", iteration, iterations)
	}
	return 0
}

func listenInput(factory d200x.TransportFactory, duration time.Duration, stdout, stderr io.Writer) int {
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	candidate, err := selectCandidate(ctx, factory)
	if err != nil {
		fmt.Fprintf(stderr, "listen selection failed: %v\n", err)
		return 1
	}
	session := d200x.NewSession(factory)
	defer session.Close()
	if err := session.Replace(ctx, candidate); err != nil {
		fmt.Fprintf(stderr, "listen open failed: %v\n", err)
		return 1
	}
	if err := session.SendFrame(ctx, d200x.EnableInputStreamFrame()); err != nil {
		fmt.Fprintf(stderr, "input enable failed: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "input listening; no serial-number data is logged")

	report := make([]byte, d200x.TransportReportSize)
	var assembler *d200x.FrameAssembler
	for {
		n, err := session.Read(ctx, report)
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			if assembler != nil && !assembler.Complete() {
				fmt.Fprintf(stderr, "listen ended with incomplete frame: received %d of %d bytes\n", assembler.ReceivedPayloadLength(), assembler.ExpectedPayloadLength())
				return 1
			}
			fmt.Fprintln(stdout, "listen duration elapsed")
			return 0
		}
		if err != nil {
			fmt.Fprintf(stderr, "input read failed: %v\n", err)
			return 1
		}
		if n == 0 {
			continue
		}
		currentReport := report[:n]
		if assembler == nil {
			assembler, err = d200x.NewFrameAssembler(currentReport)
		} else {
			err = assembler.Append(currentReport)
		}
		if err != nil {
			fmt.Fprintf(stderr, "input frame failed: %v\n", err)
			return 1
		}
		if assembler == nil || !assembler.Complete() {
			continue
		}
		frame, err := assembler.Frame()
		if err != nil {
			fmt.Fprintf(stderr, "input frame assembly failed: %v\n", err)
			return 1
		}
		if event, ok, err := d200x.DecodeInput(frame); err != nil {
			fmt.Fprintf(stderr, "input decode failed: %v\n", err)
			return 1
		} else if ok {
			fmt.Fprintf(stdout, "input index=%d marker=0x%02x action=0x%02x payload-bytes=%d\n", event.WireIndex, byte(event.Marker), byte(event.Action), len(event.RawPayload))
		} else {
			fmt.Fprintf(stdout, "frame command=%s payload-bytes=%d\n", frame.Command, len(frame.Payload))
		}
		assembler = nil
	}
}

func sendOneFrame(ctx context.Context, factory d200x.TransportFactory, frame d200x.Frame, label string, stdout, stderr io.Writer) int {
	candidate, err := selectCandidate(ctx, factory)
	if err != nil {
		fmt.Fprintf(stderr, "%s selection failed: %v\n", label, err)
		return 1
	}
	session := d200x.NewSession(factory)
	defer session.Close()
	if err := session.Replace(ctx, candidate); err != nil {
		fmt.Fprintf(stderr, "%s open failed: %v\n", label, err)
		return 1
	}
	if err := session.SendFrame(ctx, frame); err != nil {
		fmt.Fprintf(stderr, "%s write failed: %v\n", label, err)
		return 1
	}
	fmt.Fprintf(stdout, "%s command 0x%04x sent to one matching interface-0 device\n", label, uint16(frame.Command))
	return 0
}

func sendDiagnosticDisplay(ctx context.Context, factory d200x.TransportFactory, stdout, stderr io.Writer) int {
	displayFrame, err := d200x.DiagnosticDisplayFrame()
	if err != nil {
		fmt.Fprintf(stderr, "diagnostic display archive failed: %v\n", err)
		return 1
	}
	candidate, err := selectCandidate(ctx, factory)
	if err != nil {
		fmt.Fprintf(stderr, "diagnostic display selection failed: %v\n", err)
		return 1
	}
	session := d200x.NewSession(factory)
	defer session.Close()
	if err := session.Replace(ctx, candidate); err != nil {
		fmt.Fprintf(stderr, "diagnostic display open failed: %v\n", err)
		return 1
	}
	if err := session.SendFrame(ctx, displayFrame); err != nil {
		fmt.Fprintf(stderr, "diagnostic display upload failed: %v\n", err)
		return 1
	}
	if err := session.SendFrame(ctx, d200x.UnlockScreenFrame()); err != nil {
		fmt.Fprintf(stderr, "diagnostic display unlock failed: %v\n", err)
		return 1
	}
	fmt.Fprintln(stdout, "diagnostic numbered display uploaded and unlocked on one matching interface-0 device")
	return 0
}

func reconnectObservation(factory d200x.HIDFactory, duration time.Duration, stdout, stderr io.Writer) int {
	watcher, err := factory.Watch()
	if err != nil {
		fmt.Fprintf(stderr, "reconnect watcher failed: %v\n", err)
		return 1
	}
	defer watcher.Close()

	session := d200x.NewSession(factory)
	defer session.Close()
	var initialCandidates []d200x.Candidate
	initialCandidates = append(initialCandidates, watcher.Snapshot()...)
	fmt.Fprintf(stdout, "initial matching interface-0 devices: %d\n", len(initialCandidates))
	if len(initialCandidates) == 1 {
		if err := session.Replace(context.Background(), initialCandidates[0]); err != nil {
			fmt.Fprintf(stderr, "initial replacement open failed: %v\n", err)
			return 1
		}
	} else if len(initialCandidates) > 1 {
		fmt.Fprintln(stdout, "initial connection replacement: refused while multiple matching devices are present")
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	for {
		select {
		case <-ctx.Done():
			fmt.Fprintln(stdout, "reconnect observation duration elapsed")
			return 0
		case event, ok := <-watcher.Listen():
			if !ok {
				fmt.Fprintln(stderr, "reconnect watcher stopped")
				return 1
			}
			fmt.Fprintf(stdout, "matching device event: %s (%s)\n", event.Type, event.Candidate.Summary())
			if event.Type != d200x.ConnectionConnected {
				continue
			}
			candidates, err := factory.Enumerate(ctx)
			if err != nil {
				fmt.Fprintf(stderr, "reconnect enumeration failed: %v\n", err)
				return 1
			}
			selected, err := d200x.SelectSingle(candidates)
			if err != nil {
				fmt.Fprintf(stderr, "reconnect selection refused: %v\n", err)
				continue
			}
			if err := session.Replace(ctx, selected); err != nil {
				fmt.Fprintf(stderr, "reconnect replacement open failed: %v\n", err)
				return 1
			}
			fmt.Fprintln(stdout, "connection replacement: active")
		}
	}
}

func selectCandidate(ctx context.Context, factory d200x.TransportFactory) (d200x.Candidate, error) {
	candidates, err := factory.Enumerate(ctx)
	if err != nil {
		return d200x.Candidate{}, err
	}
	return d200x.SelectSingle(candidates)
}
