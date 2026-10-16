/// A saved window slot: a place in a saved layout that one live window can fill.
public struct LayoutSlot: Hashable, Sendable {
    public var display: String
    public var strip: Int
    /// Nil for the strip's floating list.
    public var column: Int?
    public var index: Int
}

public struct LiveWindow: Equatable, Sendable {
    public var id: String
    public var descriptor: WindowDescriptor

    public init(id: String, descriptor: WindowDescriptor) { self.id = id; self.descriptor = descriptor }
}

/// Pairs running windows with saved slots, each slot and each window used once.
public enum LayoutMatcher {
    /// Titles at least this alike (0 to 1) count as the same window.
    public static let similarityThreshold = 0.5

    public static func assign(slots: [(LayoutSlot, WindowDescriptor)], windows: [LiveWindow]) -> [String: LayoutSlot] {
        var result: [String: LayoutSlot] = [:]
        var freeSlots = Array(slots.indices)
        var freeWindows = Array(windows.indices)

        func take(_ accept: (WindowDescriptor, WindowDescriptor) -> Bool) {
            for w in freeWindows {
                guard let s = freeSlots.first(where: { accept(slots[$0].1, windows[w].descriptor) }) else { continue }
                result[windows[w].id] = slots[s].0
                freeSlots.removeAll { $0 == s }
                freeWindows.removeAll { $0 == w }
            }
        }

        // The window number alone can repeat after a reboot, so pid and app must agree too.
        take { s, w in
            s.windowNumber != nil && s.windowNumber == w.windowNumber && s.pid == w.pid && s.bundleID == w.bundleID
        }
        take { s, w in s.bundleID != nil && s.bundleID == w.bundleID && !s.title.isEmpty && s.title == w.title }

        // Each title's letter pairs are counted once, not again for every pair it is compared in.
        let windowPairs = Dictionary(uniqueKeysWithValues: freeWindows.map { ($0, LetterPairs(windows[$0].descriptor.title)) })
        var pairs: [(score: Double, slot: Int, window: Int)] = []
        for s in freeSlots {
            let a = slots[s].1
            guard a.bundleID != nil else { continue }
            let slotPairs = LetterPairs(a.title)
            for w in freeWindows where windows[w].descriptor.bundleID == a.bundleID {
                let score = slotPairs.similarity(to: windowPairs[w]!)
                if score >= similarityThreshold { pairs.append((score, s, w)) }
            }
        }
        // Best pairs first; ties keep saved order.
        var openSlots = Set(freeSlots), openWindows = Set(freeWindows)
        for p in pairs.sorted(by: { ($0.score, -$0.slot, -$0.window) > ($1.score, -$1.slot, -$1.window) }) {
            guard openSlots.contains(p.slot), openWindows.contains(p.window) else { continue }
            result[windows[p.window].id] = slots[p.slot].0
            openSlots.remove(p.slot)
            openWindows.remove(p.window)
        }
        return result
    }

    /// Dice coefficient over letter pairs, ignoring case. Empty titles are never alike.
    public static func similarity(_ a: String, _ b: String) -> Double {
        LetterPairs(a).similarity(to: LetterPairs(b))
    }

    /// A title's adjacent letter pairs, lowercased, with how often each occurs. A one-letter
    /// title counts as its one letter.
    private struct LetterPairs {
        let counts: [String: Int]
        let total: Int

        init(_ s: String) {
            let c = Array(s.lowercased())
            let pairs = c.count < 2 ? c.map { String($0) } : (0..<(c.count - 1)).map { String(c[$0...$0 + 1]) }
            counts = pairs.reduce(into: [:]) { $0[$1, default: 0] += 1 }
            total = pairs.count
        }

        func similarity(to other: LetterPairs) -> Double {
            guard total > 0, other.total > 0 else { return 0 }
            let shared = counts.reduce(0) { $0 + min($1.value, other.counts[$1.key] ?? 0) }
            return 2 * Double(shared) / Double(total + other.total)
        }
    }
}

public struct LayoutPlan: Equatable, Sendable {
    /// The rebuilt workspaces of each display that got at least one window back.
    public var workspaces: [String: Workspaces] = [:]
    /// Windows no saved slot claimed, in the order they were given.
    public var unplaced: [String] = []
}

extension SavedLayout {
    /// Slots of the given displays in saved order: strips top to bottom, columns left to right,
    /// then floating windows.
    public func slots(for displays: [String]) -> [(LayoutSlot, WindowDescriptor)] {
        var out: [(LayoutSlot, WindowDescriptor)] = []
        for d in displays {
            guard let w = self.displays[d] else { continue }
            for (si, s) in w.strips.enumerated() {
                for (ci, c) in s.columns.enumerated() {
                    for (wi, desc) in c.windows.enumerated() {
                        out.append((LayoutSlot(display: d, strip: si, column: ci, index: wi), desc))
                    }
                }
                for (fi, desc) in s.floating.enumerated() {
                    out.append((LayoutSlot(display: d, strip: si, column: nil, index: fi), desc))
                }
            }
        }
        return out
    }

    /// Rebuilds the layout of `displays` around the running windows. Saved slots with no window
    /// are dropped. Windows in `floating` stay floating even where they were tiled.
    public func plan(displays: [String], windows: [LiveWindow], floating: Set<String> = []) -> LayoutPlan {
        let assigned = LayoutMatcher.assign(slots: slots(for: displays), windows: windows)
        var byDisplay: [String: [LayoutSlot: String]] = [:]
        for (id, slot) in assigned { byDisplay[slot.display, default: [:]][slot] = id }

        var plan = LayoutPlan()
        plan.unplaced = windows.map(\.id).filter { assigned[$0] == nil }
        var serial = 0
        for d in displays {
            guard let saved = self.displays[d], let slotted = byDisplay[d] else { continue }
            var strips: [Strip] = []
            var active = saved.active
            for (si, s) in saved.strips.enumerated() {
                var strip = Strip()
                strip.scroll = s.scroll
                var focusedColumn: Int?
                var nearest: (distance: Int, index: Int)?
                var floats: [String] = []
                for (ci, c) in s.columns.enumerated() {
                    var ids: [String] = [], focused = 0
                    for wi in c.windows.indices {
                        guard let id = slotted[LayoutSlot(display: d, strip: si, column: ci, index: wi)] else { continue }
                        if floating.contains(id) { floats.append(id); continue }
                        if wi <= c.focused { focused = ids.count }
                        ids.append(id)
                    }
                    guard !ids.isEmpty else { continue }
                    serial += 1
                    var column = Column(id: "r\(serial)", windows: ids, width: max(0.05, c.width), focused: focused)
                    column.widthBeforeFull = c.widthBeforeFull
                    let index = strip.columns.count
                    strip.columns.append(column)
                    let want = s.focusedColumn ?? 0
                    if ci == want { focusedColumn = index }
                    if nearest == nil || abs(ci - want) < nearest!.distance { nearest = (abs(ci - want), index) }
                }
                strip.focusedColumn = focusedColumn ?? nearest?.index
                for fi in s.floating.indices {
                    if let id = slotted[LayoutSlot(display: d, strip: si, column: nil, index: fi)] { floats.append(id) }
                }
                strip.floating = floats
                strips.append(strip)
            }
            if strips.isEmpty { continue }
            active = max(0, min(strips.count - 1, active))
            if strips[active].isEmpty, let near = strips.indices.filter({ !strips[$0].isEmpty })
                .min(by: { abs($0 - active) < abs($1 - active) }) { active = near }
            var w = Workspaces()
            w.strips = strips
            w.active = active
            w.normalize()
            plan.workspaces[d] = w
        }
        return plan
    }
}
