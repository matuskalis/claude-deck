import Foundation

/// Fires `onChange` when a directory's contents change, debounced so a burst of
/// writes produces one refresh.
final class DirWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "claude-deck.dirwatcher")
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject
    private nonisolated(unsafe) var generation = 0

    init?(url: URL, debounce: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            generation += 1
            let current = generation
            queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
                guard let self, current == generation else { return }
                onChange()
            }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
