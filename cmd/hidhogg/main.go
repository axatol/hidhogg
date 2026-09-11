package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"hidhogg/internal/discovery"
	"hidhogg/internal/runtime"
)

func main() {
	os.Exit(exitCode(os.Args[1:], os.Stderr))
}

func run() error {
	return runArgs(os.Args[1:])
}

func exitCode(args []string, stderr io.Writer) int {
	if err := runArgs(args); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

func runArgs(args []string) error {
	config, err := parseArgs(args)
	if err != nil {
		return err
	}
	runtimeProcess, err := runtime.New(config)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return runtimeProcess.Run(ctx)
}

func parseArgs(args []string) (runtime.Config, error) {
	flags := flag.NewFlagSet("hidhogg", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	runtimeDir := flags.String("runtime-dir", "", "secure runtime discovery directory")
	socketPath := flags.String("socket-path", "", "exact Unix socket endpoint")
	instanceID := flags.String("instance-id", "", "canonical UUID for this runtime generation")
	configPath := flags.String("config-path", "", "absolute TOML configuration path")
	verbose := flags.Bool("verbose", false, "emit bounded D200X diagnostics to stderr")
	if err := flags.Parse(args); err != nil {
		return runtime.Config{}, err
	}
	if flags.NArg() != 0 {
		return runtime.Config{}, fmt.Errorf("positional arguments are not permitted")
	}
	if *runtimeDir != "" && *socketPath != "" {
		return runtime.Config{}, fmt.Errorf("--runtime-dir and --socket-path are mutually exclusive")
	}
	if *configPath == "" {
		return runtime.Config{}, fmt.Errorf("--config-path is required")
	}
	if !filepath.IsAbs(*configPath) {
		return runtime.Config{}, fmt.Errorf("--config-path must be an absolute path")
	}
	config := runtime.Config{ConfigPath: *configPath, Verbose: *verbose}
	if *runtimeDir != "" {
		if _, err := discovery.NewPaths(*runtimeDir); err != nil {
			return runtime.Config{}, err
		}
		if *instanceID != "" {
			canonical, err := discovery.NormalizeInstanceID(*instanceID)
			if err != nil {
				return runtime.Config{}, err
			}
			config.InstanceID = canonical
		}
		config.RuntimeDir = *runtimeDir
	} else {
		if *socketPath == "" || *instanceID == "" {
			return runtime.Config{}, fmt.Errorf("--socket-path and --instance-id are required")
		}
		canonical, err := discovery.NormalizeInstanceID(*instanceID)
		if err != nil {
			return runtime.Config{}, err
		}
		config.SocketPath = *socketPath
		config.InstanceID = canonical
	}
	return config, nil
}
