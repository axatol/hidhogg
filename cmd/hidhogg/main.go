package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"hidhogg/internal/runtime"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	flags := flag.NewFlagSet("hidhogg", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	socketPath := flags.String("socket-path", "", "exact Unix socket endpoint")
	instanceID := flags.String("instance-id", "", "canonical UUID for this runtime generation")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("positional arguments are not permitted")
	}
	if *socketPath == "" || *instanceID == "" {
		return fmt.Errorf("--socket-path and --instance-id are required")
	}
	runtimeProcess, err := runtime.New(runtime.Config{SocketPath: *socketPath, InstanceID: *instanceID})
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return runtimeProcess.Run(ctx)
}
