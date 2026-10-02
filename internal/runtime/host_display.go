package runtime

import (
	"context"
	"errors"
	"sync"

	"hidhogg/internal/d200x"
)

var errHostDisplayStatePending = errors.New("host display state policy is pending")

type hostDisplayStateResult struct {
	displayAwake bool
	changed      bool
}

type hostDisplayStateResponse struct {
	result hostDisplayStateResult
	err    error
}

type hostDisplayStateRequest struct {
	ctx          context.Context
	displayAwake bool
	result       chan hostDisplayStateResponse
	state        *idleSettingsRequestState
}

type hostDisplayStateBridge struct {
	requestMu  sync.Mutex
	mu         sync.Mutex
	policyMu   sync.RWMutex
	requests   chan hostDisplayStateRequest
	active     bool
	closed     bool
	activeDone chan struct{}
	pendingOff int
}

func newHostDisplayStateBridge() *hostDisplayStateBridge {
	return &hostDisplayStateBridge{requests: make(chan hostDisplayStateRequest)}
}

func (bridge *hostDisplayStateBridge) activate() {
	if bridge == nil {
		return
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.closed || bridge.active {
		return
	}
	bridge.active = true
	bridge.activeDone = make(chan struct{})
}

func (bridge *hostDisplayStateBridge) deactivate() {
	if bridge == nil {
		return
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if !bridge.active {
		return
	}
	bridge.active = false
	close(bridge.activeDone)
	bridge.activeDone = nil
}

func (bridge *hostDisplayStateBridge) close() {
	if bridge == nil {
		return
	}
	bridge.mu.Lock()
	bridge.closed = true
	if bridge.active {
		bridge.active = false
		close(bridge.activeDone)
		bridge.activeDone = nil
	}
	bridge.mu.Unlock()
}

func (bridge *hostDisplayStateBridge) set(ctx context.Context, displayAwake bool) (hostDisplayStateResult, error) {
	if bridge == nil {
		return hostDisplayStateResult{}, errHostDisplayStatePending
	}
	if ctx == nil {
		ctx = context.Background()
	}
	bridge.requestMu.Lock()
	defer bridge.requestMu.Unlock()
	if err := ctx.Err(); err != nil {
		return hostDisplayStateResult{}, err
	}
	bridge.mu.Lock()
	if bridge.closed || !bridge.active {
		bridge.mu.Unlock()
		return hostDisplayStateResult{}, errHostDisplayStatePending
	}
	done := bridge.activeDone
	bridge.mu.Unlock()
	if !displayAwake {
		if err := ctx.Err(); err != nil {
			return hostDisplayStateResult{}, err
		}
		bridge.admitPendingOff()
		defer bridge.releasePendingOff()
	}
	requestContext := ctx
	canceled := ctx.Done()
	if !displayAwake {
		requestContext = context.WithoutCancel(ctx)
		canceled = nil
	}
	request := hostDisplayStateRequest{
		ctx:          requestContext,
		displayAwake: displayAwake,
		result:       make(chan hostDisplayStateResponse, 1),
		state:        &idleSettingsRequestState{},
	}
	select {
	case <-done:
		return hostDisplayStateResult{}, errHostDisplayStatePending
	case <-canceled:
		return hostDisplayStateResult{}, ctx.Err()
	case bridge.requests <- request:
	}
	select {
	case response := <-request.result:
		return response.result, response.err
	case <-canceled:
		if request.state.abort() {
			return hostDisplayStateResult{}, ctx.Err()
		}
		response := <-request.result
		return response.result, response.err
	case <-done:
		if request.state.abort() {
			return hostDisplayStateResult{}, errHostDisplayStatePending
		}
		response := <-request.result
		return response.result, response.err
	}
}

func (bridge *hostDisplayStateBridge) hostOffPending() bool {
	if bridge == nil {
		return false
	}
	bridge.policyMu.RLock()
	defer bridge.policyMu.RUnlock()
	return bridge.pendingOff > 0
}

func (bridge *hostDisplayStateBridge) hostWriteBoundary() (bool, func()) {
	if bridge == nil {
		return false, func() {}
	}
	bridge.policyMu.RLock()
	return bridge.pendingOff > 0, bridge.policyMu.RUnlock
}

func (bridge *hostDisplayStateBridge) admitPendingOff() {
	bridge.policyMu.Lock()
	bridge.pendingOff++
	bridge.policyMu.Unlock()
}

func (bridge *hostDisplayStateBridge) releasePendingOff() {
	bridge.policyMu.Lock()
	if bridge.pendingOff > 0 {
		bridge.pendingOff--
	}
	bridge.policyMu.Unlock()
}

type hostDisplayWakeSender interface {
	SendStartupPageUpdate(context.Context, d200x.LivePageUpdate, int) error
}

type hostDisplayWakeSource interface {
	hostDisplayWakeState() (d200x.LivePageUpdate, int, error)
}

func (service *RuntimeProfileService) hostDisplayWakeState() (d200x.LivePageUpdate, int, error) {
	if service == nil {
		return d200x.LivePageUpdate{}, 0, ErrProfileServiceClosed
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return d200x.LivePageUpdate{}, 0, ErrProfileServiceClosed
	}
	update, err := buildNotificationUpdate(snapshot.current, snapshot.notifications)
	if err != nil {
		return d200x.LivePageUpdate{}, 0, err
	}
	return update, snapshot.settings.brightness, nil
}
