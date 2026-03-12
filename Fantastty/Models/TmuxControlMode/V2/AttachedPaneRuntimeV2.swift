import Foundation

struct AttachedPaneRuntimeV2 {
    private(set) var bufferedOutput: [Data] = []

    mutating func appendOutput(_ data: Data) {
        bufferedOutput.append(data)
    }

    mutating func drainOutput() -> [Data] {
        defer { bufferedOutput.removeAll(keepingCapacity: true) }
        return bufferedOutput
    }

    mutating func clear() {
        bufferedOutput.removeAll(keepingCapacity: false)
    }
}
