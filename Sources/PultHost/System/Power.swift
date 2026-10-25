import Foundation
import IOKit.pwr_mgt

/// A power assertion, released when the object goes away.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0

    private init?(type: String, reason: String) {
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          reason as CFString, &id) == kIOReturnSuccess else { return nil }
    }

    deinit { IOPMAssertionRelease(id) }

    /// Keeps the Mac awake and reachable (the display may still sleep).
    static func preventIdleSleep(reason: String) -> PowerAssertion? {
        PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: reason)
    }

    /// Keeps the display on: nothing is captured while it sleeps.
    static func keepDisplayOn(reason: String) -> PowerAssertion? {
        PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: reason)
    }

    /// Wakes a sleeping display, as if someone touched the keyboard.
    static func wakeDisplay(reason: String) {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id)
    }
}
