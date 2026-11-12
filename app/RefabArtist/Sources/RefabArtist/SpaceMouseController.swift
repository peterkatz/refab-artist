import AppKit
import Foundation

/// 3Dconnexion SpaceMouse support via the classic ConnexionClient C API.
/// The framework is loaded dynamically at runtime, so machines without the
/// 3Dconnexion driver are completely unaffected (every call no-ops).
///
/// Motion events are normalized and published on the main thread; the
/// viewport subscribes and maps translation to pan/zoom and rotation to
/// orbit.
final class SpaceMouseController: @unchecked Sendable {
    /// Mutable state is only touched from start()/stop() on the main thread
    /// and the driver's callback, which we immediately bounce to main.
    static let shared = SpaceMouseController()

    struct Motion {
        /// Driver axis order is documented in the SDK header as `x, y, z`:
        /// tx = slide left/right, ty = slide up/down, tz = push/pull (in-out).
        /// Roughly -350...350 per event from the driver.
        var tx: Double
        var ty: Double
        var tz: Double
        /// Rotation `rx, ry, rz`: rx = pitch, ry = yaw, rz = roll.
        var rx: Double
        var ry: Double
        var rz: Double
    }

    static let motionNotification = Notification.Name("SpaceMouseMotionNotification")

    private typealias MessageHandler = @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
    private typealias SetHandlersFn = @convention(c) (MessageHandler?, (@convention(c) (UInt32) -> Void)?, (@convention(c) (UInt32) -> Void)?, Bool) -> Int16
    private typealias RegisterFn = @convention(c) (UInt32, UnsafePointer<UInt8>?, UInt16, UInt32) -> UInt16
    private typealias UnregisterFn = @convention(c) (UInt16) -> Void
    private typealias CleanupFn = @convention(c) () -> Void

    private static let frameworkPath = "/Library/Frameworks/3DconnexionClient.framework/3DconnexionClient"
    private static let deviceStateMessage: UInt32 = 0x3364_5352 // '3dSR'
    private static let modeTakeOver: UInt16 = 1
    private static let maskAllAxes: UInt32 = 0x3F00

    private var clientID: UInt16 = 0
    private var unregister: UnregisterFn?
    private var cleanup: CleanupFn?
    private(set) var isActive = false

    /// Idempotent; safe to call on every launch.
    func start() {
        guard !isActive else { return }
        guard FileManager.default.fileExists(atPath: Self.frameworkPath),
              let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            return
        }
        guard let setSym = dlsym(handle, "SetConnexionHandlers"),
              let registerSym = dlsym(handle, "RegisterConnexionClient") else {
            return
        }
        let setHandlers = unsafeBitCast(setSym, to: SetHandlersFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        if let unregisterSym = dlsym(handle, "UnregisterConnexionClient") {
            unregister = unsafeBitCast(unregisterSym, to: UnregisterFn.self)
        }
        if let cleanupSym = dlsym(handle, "CleanupConnexionHandlers") {
            cleanup = unsafeBitCast(cleanupSym, to: CleanupFn.self)
        }

        guard setHandlers(spaceMouseMessageFunnel, nil, nil, false) == 0 else { return }
        // Wildcard signature + take-over mode + all six axes: receive motion
        // whenever our app is frontmost.
        clientID = register(0, nil, Self.modeTakeOver, Self.maskAllAxes)
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        unregister?(clientID)
        cleanup?()
        isActive = false
    }

    fileprivate func deliver(axis: [Int16]) {
        guard axis.count == 6 else { return }
        // Clamp to the device's full-deflection range (~±350, spec headroom
        // to ±500) as a sanity guard against any stray out-of-range report.
        func sane(_ value: Int16) -> Double {
            max(-500, min(500, Double(value)))
        }
        let motion = Motion(
            tx: sane(axis[0]),
            ty: sane(axis[1]),
            tz: sane(axis[2]),
            rx: sane(axis[3]),
            ry: sane(axis[4]),
            rz: sane(axis[5])
        )
        // Ignore the all-zero "released" event.
        guard motion.tx != 0 || motion.ty != 0 || motion.tz != 0
            || motion.rx != 0 || motion.ry != 0 || motion.rz != 0 else { return }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.motionNotification, object: motion)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.motionNotification, object: motion)
            }
        }
    }
}

/// C-callback funnel (no context pointer available in the classic API).
private func spaceMouseMessageFunnel(_ productID: UInt32, _ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
    guard messageType == 0x3364_5352, let argument else { return }
    // ConnexionDeviceState layout — the struct is `#pragma pack(push,2)`, so
    // `uint64_t time` is 2-byte aligned (NO 4-byte pad after `value`). Offsets
    // verified with `offsetof` compiled against the installed SDK header:
    //   version@0 client@2 command@4 param@6 value@8 time@12 report@20
    //   buttons8@28 axis@30 (6 x int16) address@42 buttons@44.
    // The old code read axis@34 — assuming natural 8-byte alignment for `time`
    // — which was 2 slots too far, so it parsed {z, rx, ry, rz, address,
    // buttons} instead of {x, y, z, rx, ry, rz}. That dropped the X/Y
    // translations entirely and fed the USB address + button bits to the
    // camera; NEO-98's "axis transpose" was that garbage misread as a rotation.
    let axisBase = argument.advanced(by: 30)
    var axis: [Int16] = []
    axis.reserveCapacity(6)
    for index in 0..<6 {
        axis.append(axisBase.load(fromByteOffset: index * 2, as: Int16.self))
    }
    SpaceMouseController.shared.deliver(axis: axis)
}
