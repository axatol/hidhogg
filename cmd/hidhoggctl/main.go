package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"hidhogg/internal/ipc"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	flags := flag.NewFlagSet("hidhoggctl", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	socketPath := flags.String("socket-path", "", "exact Unix socket endpoint")
	instanceID := flags.String("instance-id", "", "runtime generation UUID")
	methodFlag := flags.String("method", "health", "health or status")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return err
	}
	if *socketPath == "" || *instanceID == "" {
		return fmt.Errorf("--socket-path and --instance-id are required")
	}
	method := *methodFlag
	if flags.NArg() > 1 {
		return fmt.Errorf("at most one method argument is permitted")
	}
	if flags.NArg() == 1 {
		method = flags.Arg(0)
	}
	client, err := ipc.NewClient(ipc.ClientConfig{SocketPath: *socketPath})
	if err != nil {
		return err
	}
	response, err := client.Call(context.Background(), ipc.Method(method), *instanceID)
	if err != nil {
		return err
	}
	encoded, err := ipc.EncodeResponse(response)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(encoded)
	return err
}
