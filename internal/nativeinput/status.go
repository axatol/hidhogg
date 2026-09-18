package nativeinput

type BackendState string

const (
	BackendReady                BackendState = "ready"
	BackendUnsupported          BackendState = "unsupported"
	BackendInitializationFailed BackendState = "initialization_failed"
	BackendClosed               BackendState = "closed"
)

type Permission string

const (
	PermissionGranted     Permission = "granted"
	PermissionNotGranted  Permission = "not_granted"
	PermissionCheckFailed Permission = "check_failed"
)

type Status struct {
	BackendState      BackendState
	Permission        Permission
	Ready             bool
	QueueDepth        int
	QueueCapacity     int
	RequestInProgress bool
	Detail            string
}

const (
	detailUnsupported       = "native keyboard input requires macOS arm64 or amd64"
	detailInitialization    = "native keyboard input could not initialize; restart Hidhogg and verify macOS support"
	detailClosed            = "native keyboard input is closed"
	detailPermission        = "allow Hidhogg keyboard control in System Settings > Privacy & Security > Accessibility"
	detailPermissionCheck   = "permission status could not be checked; verify Accessibility settings and retry"
	detailPermissionRequest = "keyboard-control permission request is in progress"
)
