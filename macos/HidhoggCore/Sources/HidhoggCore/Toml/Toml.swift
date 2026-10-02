public enum Toml {
    public struct ParseError: Error, CustomStringConvertible, Equatable, Sendable {
        public let line: Int
        public let column: Int
        public let message: String

        public init(line: Int, column: Int = 0, message: String) {
            self.line = line
            self.column = column
            self.message = message
        }

        public var description: String {
            "line \(line): \(message)"
        }
    }
}
