#if os(iOS)
import ActivityKit

// The only place ActivityKit is imported by this package. The attribute types stay plain Codable
// values elsewhere so the macOS `swift test` run can build and test them.
extension RequestActivityAttributes: ActivityAttributes {}
#endif
