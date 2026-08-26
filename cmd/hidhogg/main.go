package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
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
	return runArgs(os.Args[1:])
}

func runArgs(args []string) error {
	flags := flag.NewFlagSet("hidhogg", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	socketPath := flags.String("socket-path", "", "exact Unix socket endpoint")
	instanceID := flags.String("instance-id", "", "canonical UUID for this runtime generation")
	configPath := flags.String("config-path", "", "absolute TOML configuration path")
	verbose := flags.Bool("verbose", false, "emit bounded D200X diagnostics to stderr")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("positional arguments are not permitted")
	}
	if *socketPath == "" || *instanceID == "" || *configPath == "" {
		return fmt.Errorf("--socket-path, --instance-id, and --config-path are required")
	}
	if !filepath.IsAbs(*configPath) {
		return fmt.Errorf("--config-path must be an absolute path")
	}
	runtimeProcess, err := runtime.New(runtime.Config{
		SocketPath: *socketPath,
		InstanceID: *instanceID,
		ConfigPath: *configPath,
		Verbose:    *verbose,
	})
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return runtimeProcess.Run(ctx)
}
