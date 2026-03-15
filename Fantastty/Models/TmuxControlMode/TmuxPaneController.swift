import Foundation

final class TmuxPaneController {
    typealias Injector = (Data) -> Bool

    let paneID: Int
    private var injector: Injector?
    private var buffer: [Data] = []
    private var tornDown = false

    var bufferedOutputCount: Int { buffer.count }

    init(paneID: Int, injector: Injector?) {
        self.paneID = paneID
        self.injector = injector
    }

    func deliver(_ data: Data) {
        guard !tornDown else { return }

        if let injector, injector(data) {
            return
        }
        buffer.append(data)
    }

    func setInjector(_ injector: @escaping Injector) {
        self.injector = injector
        flushBuffer()
    }

    func teardown() {
        tornDown = true
        injector = nil
        buffer.removeAll()
    }

    private func flushBuffer() {
        guard let injector else { return }
        let pending = buffer
        buffer.removeAll()
        for data in pending {
            if !injector(data) {
                buffer.append(data)
            }
        }
    }
}
