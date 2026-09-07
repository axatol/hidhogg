package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"

	"hidhogg/internal/discovery"
	"hidhogg/internal/ipc"
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
	return runWithOutput(args, os.Stdout)
}

func runWithOutput(args []string, output io.Writer) error {
	flags := flag.NewFlagSet("hidhoggctl", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	runtimeDir := flags.String("runtime-dir", "", "secure runtime discovery directory")
	socketPath := flags.String("socket-path", "", "exact Unix socket endpoint")
	instanceID := flags.String("instance-id", "", "runtime generation UUID")
	profileID := flags.String("profile-id", "", "case-sensitive profile identifier")
	methodFlag := flags.String("method", "health", "health, status, profiles.list, or profiles.activate")
	if err := flags.Parse(args); err != nil {
		return err
	}
	method, commandProfileID, err := parseCommand(*methodFlag, *profileID, flags.Args())
	if err != nil {
		return err
	}
	if commandProfileID != "" {
		*profileID = commandProfileID
	}
	if *runtimeDir != "" && *socketPath != "" {
		return fmt.Errorf("--runtime-dir and --socket-path are mutually exclusive")
	}
	if *runtimeDir != "" && *instanceID != "" {
		return fmt.Errorf("--instance-id is only valid with --socket-path")
	}
	if *runtimeDir == "" && (*socketPath == "" || *instanceID == "") {
		return fmt.Errorf("--socket-path and --instance-id are required")
	}

	var resolved discovery.Resolved
	var discoveryMode bool
	if *runtimeDir != "" {
		discoveryMode = true
		var err error
		resolved, err = discovery.Resolve(*runtimeDir)
		if err != nil {
			return err
		}
		*socketPath = resolved.Paths.SocketPath
		*instanceID = resolved.Metadata.InstanceID
	} else {
		canonical, err := discovery.NormalizeInstanceID(*instanceID)
		if err != nil {
			return err
		}
		*instanceID = canonical
	}
	client, err := ipc.NewClient(ipc.ClientConfig{SocketPath: *socketPath})
	if err != nil {
		return err
	}
	var response ipc.Response
	if ipc.Method(method) == ipc.MethodProfilesActivate {
		response, err = client.ActivateProfile(context.Background(), *instanceID, *profileID)
	} else if ipc.Method(method) == ipc.MethodProfilesList {
		response, err = client.ListProfiles(context.Background(), *instanceID)
	} else {
		response, err = client.Call(context.Background(), ipc.Method(method), *instanceID)
	}
	if err != nil {
		return err
	}
	if discoveryMode {
		if err := resolved.Revalidate(); err != nil {
			return fmt.Errorf("runtime changed after IPC call: %w", err)
		}
	}
	encoded, err := ipc.EncodeResponse(response)
	if err != nil {
		return err
	}
	_, err = output.Write(encoded)
	return err
}

func parseCommand(defaultMethod, profileID string, args []string) (string, string, error) {
	commandArgs, commandProfileID, err := parseCommandFlags(args)
	if err != nil {
		return "", "", err
	}
	if commandProfileID != "" {
		if profileID != "" {
			return "", "", fmt.Errorf("--profile-id was provided more than once")
		}
		profileID = commandProfileID
	}
	method := defaultMethod
	switch len(commandArgs) {
	case 0:
	case 1:
		method = commandArgs[0]
	case 2:
		if commandArgs[0] == "profiles.activate" && commandArgs[1] != "" {
			if profileID != "" {
				return "", "", fmt.Errorf("profile ID was provided more than once")
			}
			return string(ipc.MethodProfilesActivate), commandArgs[1], nil
		}
		if commandArgs[0] != "profiles" {
			return "", "", fmt.Errorf("at most one method argument is permitted")
		}
		switch commandArgs[1] {
		case "list":
			method = string(ipc.MethodProfilesList)
		case "activate":
			method = string(ipc.MethodProfilesActivate)
		default:
			return "", "", fmt.Errorf("unknown profiles command %q", commandArgs[1])
		}
	case 3:
		if commandArgs[0] != "profiles" || commandArgs[1] != "activate" || commandArgs[2] == "" {
			return "", "", fmt.Errorf("profiles activate accepts one profile ID")
		}
		if profileID != "" {
			return "", "", fmt.Errorf("profile ID was provided more than once")
		}
		method = string(ipc.MethodProfilesActivate)
		profileID = commandArgs[2]
	default:
		return "", "", fmt.Errorf("at most one method argument is permitted")
	}

	switch ipc.Method(method) {
	case ipc.MethodProfilesList:
		if profileID != "" {
			return "", "", fmt.Errorf("--profile-id is only valid for profiles activate")
		}
	case ipc.MethodProfilesActivate:
		if profileID == "" {
			return "", "", fmt.Errorf("profiles activate requires --profile-id or a profile ID argument")
		}
	default:
		if profileID != "" {
			return "", "", fmt.Errorf("--profile-id is only valid for profiles activate")
		}
	}
	return method, profileID, nil
}

func parseCommandFlags(args []string) ([]string, string, error) {
	commandArgs := make([]string, 0, len(args))
	profileID := ""
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if arg == "--profile-id" {
			if index+1 >= len(args) || args[index+1] == "" {
				return nil, "", fmt.Errorf("--profile-id requires a value")
			}
			if profileID != "" {
				return nil, "", fmt.Errorf("--profile-id was provided more than once")
			}
			profileID = args[index+1]
			index++
			continue
		}
		const prefix = "--profile-id="
		if len(arg) > len(prefix) && arg[:len(prefix)] == prefix {
			if profileID != "" {
				return nil, "", fmt.Errorf("--profile-id was provided more than once")
			}
			profileID = arg[len(prefix):]
			if profileID == "" {
				return nil, "", fmt.Errorf("--profile-id requires a value")
			}
			continue
		}
		commandArgs = append(commandArgs, arg)
	}
	return commandArgs, profileID, nil
}
