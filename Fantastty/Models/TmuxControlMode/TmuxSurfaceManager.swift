import Foundation

/// Protocol for creating and injecting into surfaces.
/// Extracted for testability — production uses Ghostty, tests use mocks.
protocol TmuxSurfaceProviding: AnyObject {
    associatedtype Surface: AnyObject
    func createInertSurface(paneID: Int) -> Surface
    func destroySurface(_ surface: Surface)
    func injectOutput(_ surface: Surface, data: Data)
}

/// Generic surface manager, testable with mock providers.
class TmuxSurfaceManagerGeneric<Provider: TmuxSurfaceProviding> {
    private let provider: Provider
    private var surfaces: [Int: Provider.Surface] = [:]

    var paneIDs: Dictionary<Int, Provider.Surface>.Keys { surfaces.keys }

    init(provider: Provider) {
        self.provider = provider
    }

    @discardableResult
    func createSurface(paneID: Int) -> Provider.Surface {
        let surface = provider.createInertSurface(paneID: paneID)
        surfaces[paneID] = surface
        return surface
    }

    @discardableResult
    func removeSurface(paneID: Int) -> Provider.Surface? {
        guard let surface = surfaces.removeValue(forKey: paneID) else { return nil }
        provider.destroySurface(surface)
        return surface
    }

    func injectOutput(paneID: Int, data: Data) {
        guard let surface = surfaces[paneID] else { return }
        provider.injectOutput(surface, data: data)
    }

    func surface(forPaneID paneID: Int) -> Provider.Surface? {
        surfaces[paneID]
    }

    func removeAll() -> [Int: Provider.Surface] {
        let old = surfaces
        surfaces.removeAll()
        return old
    }
}
