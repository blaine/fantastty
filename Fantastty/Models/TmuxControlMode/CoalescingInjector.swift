import Foundation
import GhosttyKit

/// Coalesces tmux output data and limits to ONE in-flight
/// `ghostty_surface_inject_output` call at a time.
///
/// Ghostty's internal termio mailbox uses a BlockingQueue(64). When the queue
/// is full, `push()` blocks BEFORE `notify()` fires, so the io thread never
/// wakes to drain it — a deadlock. Without coalescing, a burst of `%output`
/// events dispatches dozens of concurrent inject calls that immediately fill
/// the queue. With coalescing, queue occupancy stays at 0-1 per surface.
///
/// **Threading contract:** `enqueue(_:)` must be called from the main thread.
/// The actual inject call is dispatched to a private serial queue.
final class CoalescingInjector {
    private let queue: DispatchQueue
    private var buffer = Data()
    private var inFlight = false
    private weak var surface: Ghostty.SurfaceView?

    init(paneID: Int, surface: Ghostty.SurfaceView? = nil) {
        self.queue = DispatchQueue(label: "com.fantastty.tmux-inject-pane-\(paneID)")
        self.surface = surface
    }

    func updateSurface(_ surface: Ghostty.SurfaceView) {
        self.surface = surface
    }

    /// Append output data and kick the drain loop if idle.
    /// Must be called from the main thread.
    func enqueue(_ data: Data) {
        buffer.append(data)
        drainIfIdle()
    }

    func cancel() {
        buffer.removeAll()
        surface = nil
    }

    // MARK: - Private

    private func drainIfIdle() {
        guard !inFlight, !buffer.isEmpty else { return }
        guard let surface, surface.surface != nil else {
            buffer.removeAll()
            return
        }

        inFlight = true
        let chunk = buffer
        buffer = Data()

        queue.async { [weak self, weak surface] in
            if let surface, let cSurface = surface.surface {
                chunk.withUnsafeBytes { buf in
                    guard let ptr = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                    ghostty_surface_inject_output(cSurface, ptr, UInt(buf.count))
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.inFlight = false
                self?.drainIfIdle()
            }
        }
    }
}
