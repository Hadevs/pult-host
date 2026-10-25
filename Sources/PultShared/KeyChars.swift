import Foundation

/// Which physical Mac key (US ANSI kVK code) a character sits on, and
/// whether ⇧ is needed. Typed text carries its exact characters anyway;
/// this makes it press the right key too, because games read key codes.
enum KeyChars {
    static let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    static let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]   // 0...9

    private static let plain: [Character: UInt16] = [
        "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, "`": 50, ",": 43, ".": 47, "/": 44, " ": 49,
    ]
    private static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28, "(": 25, ")": 29,
        "_": 27, "+": 24, "{": 33, "}": 30, "|": 42, ":": 41, "\"": 39, "~": 50, "<": 43, ">": 47, "?": 44,
    ]
    /// ЙЦУКЕН → the Latin key in the same place.
    private static let russian: [Character: Character] = [
        "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y", "г": "u", "ш": "i", "щ": "o", "з": "p", "х": "[", "ъ": "]",
        "ф": "a", "ы": "s", "в": "d", "а": "f", "п": "g", "р": "h", "о": "j", "л": "k", "д": "l", "ж": ";", "э": "'",
        "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n", "ь": "m", "б": ",", "ю": ".", "ё": "`",
    ]

    static func key(for ch: Character) -> (code: UInt16, shift: Bool)? {
        if let code = plain[ch] { return (code, false) }
        if let code = shifted[ch] { return (code, true) }
        let lower = Character(ch.lowercased())
        let upper = ch != lower
        let latin = russian[lower] ?? lower
        if let a = latin.asciiValue {
            if (97...122).contains(a) { return (letters[Int(a - 97)], upper) }
            if (48...57).contains(a) { return (digits[Int(a - 48)], false) }
        }
        if let code = plain[latin] { return (code, upper) }   // Cyrillic letters on punctuation keys (х, ж, б…)
        return nil
    }
}
