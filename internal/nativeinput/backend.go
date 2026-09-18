package nativeinput

import "context"

type Backend interface {
	CheckPermission() (bool, error)
	RequestPermission(context.Context) (bool, error)
	Post(context.Context, Request) error
}

type closableBackend interface {
	Close() error
}
