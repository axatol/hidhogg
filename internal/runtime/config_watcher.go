package runtime

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/fsnotify/fsnotify"
)

const configReloadDebounce = 200 * time.Millisecond

type configWatchSource interface {
	Add(string) error
	Close() error
	Events() <-chan fsnotify.Event
	Errors() <-chan error
}

type fsnotifyConfigWatchSource struct {
	watcher *fsnotify.Watcher
}

func newFSNotifyConfigWatchSource() (configWatchSource, error) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	return &fsnotifyConfigWatchSource{watcher: watcher}, nil
}

func (source *fsnotifyConfigWatchSource) Add(path string) error {
	return source.watcher.Add(path)
}

func (source *fsnotifyConfigWatchSource) Close() error {
	return source.watcher.Close()
}

func (source *fsnotifyConfigWatchSource) Events() <-chan fsnotify.Event {
	return source.watcher.Events
}

func (source *fsnotifyConfigWatchSource) Errors() <-chan error {
	return source.watcher.Errors
}

func (r *Runtime) startConfigWatcher(ctx context.Context) <-chan struct{} {
	done := make(chan struct{})
	r.mu.Lock()
	factory := r.configWatchFactory
	configPath := r.config.ConfigPath
	r.mu.Unlock()
	if factory == nil {
		factory = newFSNotifyConfigWatchSource
	}
	source, err := factory()
	if err != nil || source == nil {
		r.logConfigWatcherDisabled("setup")
		close(done)
		return done
	}
	if err := source.Add(filepath.Dir(configPath)); err != nil {
		_ = source.Close()
		r.logConfigWatcherDisabled("setup")
		close(done)
		return done
	}
	go func() {
		defer close(done)
		defer source.Close()
		if runConfigWatcher(ctx, r.clock, source, filepath.Base(configPath), r.signalAutomaticReload) {
			r.logConfigWatcherDisabled("runtime")
		}
	}()
	return done
}

func runConfigWatcher(ctx context.Context, clock Clock, source configWatchSource, basename string, dirty func()) bool {
	var debounce Timer
	defer stopTimer(debounce)
	for {
		select {
		case <-ctx.Done():
			return false
		case _, ok := <-source.Errors():
			if !ok && ctx.Err() != nil {
				return false
			}
			return true
		case event, ok := <-source.Events():
			if !ok {
				return ctx.Err() == nil
			}
			if !relevantConfigEvent(event, basename) {
				continue
			}
			stopTimer(debounce)
			debounce = clock.NewTimer(configReloadDebounce)
		case <-timerChannel(debounce):
			stopTimer(debounce)
			debounce = nil
			dirty()
		}
	}
}

func relevantConfigEvent(event fsnotify.Event, basename string) bool {
	if filepath.Base(filepath.Clean(event.Name)) != basename {
		return false
	}
	return event.Has(fsnotify.Create) || event.Has(fsnotify.Write) || event.Has(fsnotify.Rename) || event.Has(fsnotify.Remove)
}

func (r *Runtime) signalAutomaticReload() {
	if r == nil || r.automaticReload == nil {
		return
	}
	select {
	case r.automaticReload <- struct{}{}:
	default:
	}
}

func (r *Runtime) runAutomaticReloads(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-r.automaticReload:
			r.reloadAutomatically(ctx)
		}
	}
}

func (r *Runtime) logConfigWatcherDisabled(stage string) {
	if r == nil || !r.config.Verbose || r.stderr == nil {
		return
	}
	_, _ = fmt.Fprintf(r.stderr, "runtime config watcher disabled: %s failure\n", stage)
}
