struct NavigationHistory<Route: Hashable> {
    static var capacity: Int { 64 }

    private(set) var current: Route
    private(set) var backRoutes: [Route] = []
    private(set) var forwardRoutes: [Route] = []

    var canGoBack: Bool { !backRoutes.isEmpty }
    var canGoForward: Bool { !forwardRoutes.isEmpty }

    init(initialRoute: Route) {
        current = initialRoute
    }

    mutating func navigate(to route: Route) {
        guard route != current else { return }
        backRoutes.append(current)
        if backRoutes.count > Self.capacity { backRoutes.removeFirst(backRoutes.count - Self.capacity) }
        forwardRoutes.removeAll(keepingCapacity: true)
        current = route
    }

    mutating func replaceCurrent(with route: Route) {
        current = route
    }

    @discardableResult
    mutating func goBack() -> Bool {
        guard let route = backRoutes.popLast() else { return false }
        forwardRoutes.append(current)
        current = route
        return true
    }

    @discardableResult
    mutating func goForward() -> Bool {
        guard let route = forwardRoutes.popLast() else { return false }
        backRoutes.append(current)
        if backRoutes.count > Self.capacity { backRoutes.removeFirst(backRoutes.count - Self.capacity) }
        current = route
        return true
    }
}
