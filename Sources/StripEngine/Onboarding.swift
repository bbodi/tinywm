/// What the first-run window shows, decided from permission flags so it can be tested without AppKit.
public enum Onboarding {
    public enum Step: Equatable {
        /// Nothing works until Accessibility is granted.
        case needsAccessibility
        /// Tiling runs; Screen Recording only adds smooth motion.
        case canStart
        case allSet
    }

    public static func step(accessibility: Bool, screenRecording: Bool) -> Step {
        guard accessibility else { return .needsAccessibility }
        return screenRecording ? .allSet : .canStart
    }

    public static func shouldShowOnLaunch(seenBefore: Bool) -> Bool { !seenBefore }

    public static func primaryButtonTitle(_ step: Step) -> String {
        step == .needsAccessibility ? "Start tinywm" : "Done"
    }

    public static func primaryButtonEnabled(_ step: Step) -> Bool { step != .needsAccessibility }

    /// macOS applies a new Screen Recording grant only to processes started afterwards.
    public static func needsRestart(screenRecordingAtLaunch: Bool, screenRecordingNow: Bool, inBundle: Bool) -> Bool {
        inBundle && screenRecordingNow && !screenRecordingAtLaunch
    }
}

/// The Open at Login switch, independent of ServiceManagement.
public enum LoginItemState: Equatable, Sendable {
    /// Not running from an app bundle, so there is nothing to register.
    case unavailable
    case off
    case on
    /// Registered, but the user still has to allow it in Login Items settings.
    case needsApproval

    public enum Action: Equatable, Sendable { case register, unregister, openSettings, none }

    public var isChecked: Bool { self == .on || self == .needsApproval }

    public var action: Action {
        switch self {
        case .unavailable: .none
        case .off: .register
        case .on: .unregister
        case .needsApproval: .openSettings
        }
    }
}
