import AppKit

/// Watches the system pointer so the client can draw it locally: reports
/// moves made by anyone at the Mac's own mouse, and every shape change
/// (arrow, I-beam, resize…). Runs on the main thread.
final class CursorTracker {
    /// Position in display points, relative to the streamed display.
    var onMove: ((CGPoint) -> Void)?
    var onImage: ((CursorImage) -> Void)?

    private var displayBounds: CGRect = .zero
    private var timer: Timer?
    private var tick = 0
    private var lastPosition: CGPoint?
    private var lastImageHash: Int?

    func start(displayBounds: CGRect) {
        self.displayBounds = displayBounds
        lastPosition = nil
        lastImageHash = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Our own injected move: don't echo it back to the client.
    func noteInjected(_ position: CGPoint?) {
        if let position { lastPosition = position }
    }

    private func poll() {
        if let location = CGEvent(source: nil)?.location,
           lastPosition.map({ hypot($0.x - location.x, $0.y - location.y) > 0.5 }) ?? true {
            lastPosition = location
            onMove?(CGPoint(x: location.x - displayBounds.minX, y: location.y - displayBounds.minY))
        }

        // The shape changes rarely; check it at 10 Hz.
        tick += 1
        guard tick % 6 == 0, let cursor = NSCursor.currentSystem,
              let tiff = cursor.image.tiffRepresentation else { return }
        let hash = tiff.hashValue ^ Int(cursor.hotSpot.x * 1000) ^ Int(cursor.hotSpot.y)
        guard hash != lastImageHash,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        lastImageHash = hash
        onImage?(CursorImage(hotSpot: cursor.hotSpot, size: cursor.image.size, png: png))
    }
}
