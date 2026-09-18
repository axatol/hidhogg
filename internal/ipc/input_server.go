package ipc

import (
	"context"
	"errors"
)

func (s *Server) handleInputRequest(request Request) Response {
	if s.config.InputService == nil {
		return internalResponse(request.RequestID)
	}
	result := Result{InstanceID: request.InstanceID}
	switch request.Method {
	case MethodInputStatus:
		status := s.config.InputService.Status()
		result.Input = &status
	case MethodInputRequestPermission:
		status, err := s.config.InputService.RequestPermission(context.Background())
		if err != nil {
			if errors.Is(err, ErrBusy) || errors.Is(err, ErrShuttingDown) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return configErrorResponse(request.RequestID, err)
			}
			return internalResponse(request.RequestID)
		}
		result.Input = &status
	case MethodDoctor:
		doctor := s.config.InputService.Doctor()
		result.Doctor = &doctor
	default:
		return internalResponse(request.RequestID)
	}
	if err := validateResultForMethod(result, request.Method, request.InstanceID); err != nil {
		return internalResponse(request.RequestID)
	}
	requestID := request.RequestID
	return Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &result}
}
