/// Key names accepted in the config file, mapped to macOS virtual key codes.
public enum KeyNames {
    /// Every accepted spelling, lowercase.
    public static let codes: [String: Int] = {
        var m: [String: Int] = [:]
        let letters: [(String, Int)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (n, c) in letters { m[n] = c }
        let digits: [(String, Int)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
        ]
        for (n, c) in digits { m[n] = c }
        let others: [(String, Int)] = [
            ("left", 123), ("right", 124), ("up", 126), ("down", 125), ("pageup", 116), ("pagedown", 121),
            ("esc", 53), ("escape", 53), ("tab", 48), ("return", 36), ("enter", 36), ("space", 49),
            ("equal", 24), ("minus", 27), ("leftbracket", 33), ("rightbracket", 30), ("comma", 43),
            ("period", 47), ("slash", 44), ("semicolon", 41), ("quote", 39),
        ]
        for (n, c) in others { m[n] = c }
        let symbols: [(String, Int)] = [
            ("=", 24), ("-", 27), ("[", 33), ("]", 30), (",", 43), (".", 47), ("/", 44), (";", 41), ("'", 39),
        ]
        for (n, c) in symbols { m[n] = c }
        return m
    }()

    /// The spelling written into generated files.
    public static func name(of code: Int) -> String? { canonical[code] }

    private static let canonical: [Int: String] = {
        var m: [Int: String] = [:]
        for (name, code) in codes where name.count == 1 && name.first!.isLetter || name.first!.isNumber && name.count == 1 {
            m[code] = name
        }
        let words = ["left", "right", "up", "down", "pageup", "pagedown", "esc", "tab", "return", "space", "equal",
                     "minus", "leftbracket", "rightbracket", "comma", "period", "slash", "semicolon", "quote"]
        for w in words { if let c = codes[w] { m[c] = w } }
        return m
    }()
}
