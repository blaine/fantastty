import Foundation

enum SessionBackingState: Equatable {
    case available
    case missingAttachedBacking(reason: String?)
}
