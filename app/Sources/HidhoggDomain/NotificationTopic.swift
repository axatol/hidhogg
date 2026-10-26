public enum NotificationTopic {
    public static let maximumLength = 64

    public static func isValidTopic(_ topic: String) -> Bool {
        isValidName(topic, allowsWildcard: false)
    }

    public static func isValidFilter(_ filter: String) -> Bool {
        isValidName(filter, allowsWildcard: true)
    }

    public static func matches(_ topic: String, filter: String) -> Bool {
        guard isValidTopic(topic), isValidFilter(filter) else { return false }

        let topicBytes = Array(topic.utf8)
        let filterBytes = Array(filter.utf8)
        var topicIndex = 0
        var filterIndex = 0
        var wildcardIndex: Int?
        var topicIndexAfterWildcard = 0

        while topicIndex < topicBytes.count {
            if filterIndex < filterBytes.count,
               filterBytes[filterIndex] != 42,
               filterBytes[filterIndex] == topicBytes[topicIndex] {
                topicIndex += 1
                filterIndex += 1
            } else if filterIndex < filterBytes.count, filterBytes[filterIndex] == 42 {
                wildcardIndex = filterIndex
                filterIndex += 1
                topicIndexAfterWildcard = topicIndex
            } else if let wildcardIndex {
                topicIndexAfterWildcard += 1
                topicIndex = topicIndexAfterWildcard
                filterIndex = wildcardIndex + 1
            } else {
                return false
            }
        }

        while filterIndex < filterBytes.count, filterBytes[filterIndex] == 42 {
            filterIndex += 1
        }
        return filterIndex == filterBytes.count
    }

    private static func isValidName(_ value: String, allowsWildcard: Bool) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maximumLength).contains(bytes.count), let firstByte = bytes.first else { return false }
        guard isAlphanumeric(firstByte) || (allowsWildcard && firstByte == 42) else { return false }
        return bytes.allSatisfy { byte in
            isAlphanumeric(byte) || [45, 46, 95].contains(Int(byte)) || (allowsWildcard && byte == 42)
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
