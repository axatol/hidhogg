package runtime

import (
	"context"
	"errors"

	"hidhogg/internal/ipc"
)

type Config struct {
	SocketPath string
	InstanceID string
	Deadlines  ipc.Deadlines
}

type Runtime struct {
	server *ipc.Server
}

func New(config Config) (*Runtime, error) {
	server, err := ipc.NewServer(ipc.ServerConfig{
		SocketPath: config.SocketPath,
		InstanceID: config.InstanceID,
		Deadlines:  config.Deadlines,
	})
	if err != nil {
		return nil, err
	}
	return &Runtime{server: server}, nil
}

func (r *Runtime) Start() error {
	if r == nil || r.server == nil {
		return errors.New("runtime is not initialized")
	}
	return r.server.Start()
}

func (r *Runtime) Run(ctx context.Context) error {
	if r == nil || r.server == nil {
		return errors.New("runtime is not initialized")
	}
	return r.server.Serve(ctx)
}

func (r *Runtime) Close() error {
	if r == nil || r.server == nil {
		return nil
	}
	return r.server.Close()
}
