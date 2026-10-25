import AppKit

/// The login screen: whether it is up, and unlocking it remotely.
enum LockScreen {
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    /// Wakes the display and types `password` into the lock screen. It types
    /// only while the screen is really locked, so the password can never end
    /// up in an ordinary app. Main thread; `completion` is called on main.
    static func unlock(password: String, input: InputInjector, completion: @escaping (UnlockResult) -> Void) {
        PowerAssertion.wakeDisplay(reason: "Pult unlock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard isLocked else { return completion(.notLocked) }
            // A pointer nudge brings up the password field after a wake.
            input.moveMouse(x: Float(input.displayBounds.width / 2), y: Float(input.displayBounds.height / 2))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard isLocked else { return completion(.notLocked) }
                input.type(password + "\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    completion(isLocked ? .stillLocked : .unlocked)
                }
            }
        }
    }

    /// Reports lock and unlock while a client is connected (polled at 2 Hz).
    final class Monitor {
        var onChange: ((Bool) -> Void)?
        private var timer: Timer?
        private var last: Bool?

        func start() {
            last = nil
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
            poll()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func poll() {
            let locked = LockScreen.isLocked
            guard locked != last else { return }
            last = locked
            onChange?(locked)
        }
    }
}
