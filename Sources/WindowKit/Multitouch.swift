import Foundation

/// Raw trackpad contacts from Apple's private MultitouchSupport framework, through
/// MTDeviceCreateList, MTRegisterContactFrameCallback, MTDeviceStart, MTDeviceStop.
///
/// The framework is opened at runtime, so nothing private is linked. Public gesture events
/// only reach the app under the pointer; these contacts arrive whichever app is in front.
@MainActor
public final class Multitouch {
    /// Positions (0…1, y up) of fingers touching now, and the frame time in seconds.
    public var onFrame: ([(x: Double, y: Double)], Double) -> Void = { _, _ in }

    private var devices: [UnsafeMutableRawPointer] = []
    private var stop: StopFn?
    nonisolated(unsafe) fileprivate static var current: Multitouch?

    private typealias Callback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias StopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

    public init() {}

    /// Starts listening. Returns false when the framework or a trackpad is missing.
    @discardableResult
    public func start() -> Bool {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let lib = dlopen(path, RTLD_NOW),
              let createSym = dlsym(lib, "MTDeviceCreateList"),
              let registerSym = dlsym(lib, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(lib, "MTDeviceStart"),
              let stopSym = dlsym(lib, "MTDeviceStop") else { return false }
        let create = unsafeBitCast(createSym, to: CreateListFn.self)
        let register = unsafeBitCast(registerSym, to: RegisterFn.self)
        let startDevice = unsafeBitCast(startSym, to: StartFn.self)
        stop = unsafeBitCast(stopSym, to: StopFn.self)

        guard let list = create()?.takeRetainedValue() else { return false }
        Self.current = self
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, contactCallback)
            startDevice(device, 0)
            devices.append(device)
        }
        return !devices.isEmpty
    }

    fileprivate func deliver(_ touches: [(x: Double, y: Double)], _ t: Double) { onFrame(touches, t) }
}

/// One finger in MultitouchSupport's 96-byte contact record.
private enum Touch {
    static let stride = 96
    static let stateOffset = 20
    static let xOffset = 32
    static let yOffset = 36
    /// "Make touch" and "touching": a finger resting on the pad.
    static let touchingStates: Set<Int32> = [3, 4]
}

/// Runs on MultitouchSupport's own thread, so it copies the touches and hops to the main thread.
private let contactCallback: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32 = { _, data, count, timestamp, _ in
    guard let data, count > 0 else {
        DispatchQueue.main.async { MainActor.assumeIsolated { Multitouch.current?.deliver([], timestamp) } }
        return 0
    }
    var touches: [(x: Double, y: Double)] = []
    for i in 0..<Int(count) {
        let base = data + i * Touch.stride
        let state = base.load(fromByteOffset: Touch.stateOffset, as: Int32.self)
        guard Touch.touchingStates.contains(state) else { continue }
        let x = Double(base.load(fromByteOffset: Touch.xOffset, as: Float.self))
        let y = Double(base.load(fromByteOffset: Touch.yOffset, as: Float.self))
        touches.append((x, y))
    }
    let frame = touches
    DispatchQueue.main.async { MainActor.assumeIsolated { Multitouch.current?.deliver(frame, timestamp) } }
    return 0
}
