package ipc

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"time"
)

type ClientConfig struct {
	SocketPath   string
	Deadlines    Deadlines
	PeerVerifier func(net.Conn) error
}

type Client struct {
	socketPath   string
	deadlines    Deadlines
	peerVerifier func(net.Conn) error
}

func NewClient(config ClientConfig) (*Client, error) {
	if err := validateSocketPath(config.SocketPath); err != nil {
		return nil, err
	}
	peerVerifier := config.PeerVerifier
	if peerVerifier == nil {
		peerVerifier = verifyPeerUID
	}
	return &Client{socketPath: config.SocketPath, deadlines: config.Deadlines.normalized(), peerVerifier: peerVerifier}, nil
}

func (c *Client) Call(ctx context.Context, method Method, instanceID string) (Response, error) {
	requestID, err := NewUUID()
	if err != nil {
		return Response{}, err
	}
	return c.CallRequest(ctx, Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       requestID,
		Method:          method,
		InstanceID:      instanceID,
	})
}

// ListProfiles requests the ordered profile summaries from the runtime.
func (c *Client) ListProfiles(ctx context.Context, instanceID string) (Response, error) {
	return c.Call(ctx, MethodProfilesList, instanceID)
}

// ActivateProfile requests one case-sensitive profile activation.
func (c *Client) ActivateProfile(ctx context.Context, instanceID, profileID string) (Response, error) {
	requestID, err := NewUUID()
	if err != nil {
		return Response{}, err
	}
	return c.CallRequest(ctx, Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       requestID,
		Method:          MethodProfilesActivate,
		InstanceID:      instanceID,
		ProfileID:       profileID,
	})
}

// ProfilesList is an explicit alias for ListProfiles.
func (c *Client) ProfilesList(ctx context.Context, instanceID string) (Response, error) {
	return c.ListProfiles(ctx, instanceID)
}

// ProfilesActivate is an explicit alias for ActivateProfile.
func (c *Client) ProfilesActivate(ctx context.Context, instanceID, profileID string) (Response, error) {
	return c.ActivateProfile(ctx, instanceID, profileID)
}

// ListExecutions requests newest-first, output-free execution summaries. A
// zero limit selects the protocol default of twenty entries.
func (c *Client) ListExecutions(ctx context.Context, instanceID string, limit int) (Response, error) {
	requestID, err := NewUUID()
	if err != nil {
		return Response{}, err
	}
	return c.CallRequest(ctx, Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       requestID,
		Method:          MethodExecutionsList,
		InstanceID:      instanceID,
		Limit:           limit,
	})
}

// GetExecution requests one exact execution ID and its bounded output tails.
func (c *Client) GetExecution(ctx context.Context, instanceID, executionID string) (Response, error) {
	requestID, err := NewUUID()
	if err != nil {
		return Response{}, err
	}
	return c.CallRequest(ctx, Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       requestID,
		Method:          MethodExecutionsGet,
		InstanceID:      instanceID,
		ExecutionID:     executionID,
	})
}

// ExecutionsList is an explicit alias for ListExecutions.
func (c *Client) ExecutionsList(ctx context.Context, instanceID string, limit int) (Response, error) {
	return c.ListExecutions(ctx, instanceID, limit)
}

// ExecutionsGet is an explicit alias for GetExecution.
func (c *Client) ExecutionsGet(ctx context.Context, instanceID, executionID string) (Response, error) {
	return c.GetExecution(ctx, instanceID, executionID)
}

func (c *Client) CallRequest(ctx context.Context, request Request) (Response, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if request.ProtocolVersion == 0 {
		request.ProtocolVersion = ProtocolVersion
	}
	if !isCanonicalUUID(request.RequestID) || !isCanonicalUUID(request.InstanceID) {
		return Response{}, errors.New("request identifiers must be canonical UUIDs")
	}
	if !isSupportedMethod(request.Method) {
		return Response{}, errors.New("request method is not supported")
	}
	if err := validateRequestFields(request); err != nil {
		return Response{}, err
	}
	if _, err := validateGenerationDirectory(filepath.Dir(c.socketPath)); err != nil {
		return Response{}, err
	}
	if _, err := validateSocketEntry(c.socketPath, true); err != nil {
		return Response{}, err
	}
	frame, err := EncodeRequest(request)
	if err != nil {
		return Response{}, err
	}

	dialContext, cancel := context.WithTimeout(ctx, c.deadlines.Connect)
	defer cancel()
	dialer := net.Dialer{}
	connection, err := dialer.DialContext(dialContext, "unix", c.socketPath)
	if err != nil {
		return Response{}, fmt.Errorf("connect to IPC socket: %w", err)
	}
	defer connection.Close()
	if err := c.peerVerifier(connection); err != nil {
		return Response{}, err
	}
	if err := connection.SetWriteDeadline(earliestDeadline(ctx, c.deadlines.Write)); err != nil {
		return Response{}, fmt.Errorf("set IPC write deadline: %w", err)
	}
	if err := writeFrame(connection, frame); err != nil {
		return Response{}, fmt.Errorf("write IPC request: %w", err)
	}
	if err := connection.SetReadDeadline(earliestDeadline(ctx, c.deadlines.Read)); err != nil {
		return Response{}, fmt.Errorf("set IPC read deadline: %w", err)
	}
	responseFrame, err := readFrame(connection)
	if err != nil {
		return Response{}, fmt.Errorf("read IPC response: %w", err)
	}
	response, err := DecodeResponse(responseFrame, request.RequestID, string(request.Method), request.InstanceID)
	if err != nil {
		return Response{}, err
	}
	return response, nil
}

func earliestDeadline(ctx context.Context, duration time.Duration) time.Time {
	deadline := time.Now().Add(duration)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		return contextDeadline
	}
	return deadline
}

func NewUUID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", fmt.Errorf("generate UUID: %w", err)
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16]), nil
}
