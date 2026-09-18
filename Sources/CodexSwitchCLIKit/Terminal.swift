import Foundation

public enum Style {
    public static var colored = true

    private static func wrap(_ text: String, _ code: String) -> String {
        guard colored, !text.isEmpty else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    public static func bold(_ text: String) -> String { wrap(text, "1") }
    public static func faint(_ text: String) -> String { wrap(text, "2") }
    public static func red(_ text: String) -> String { wrap(text, "31") }
    public static func green(_ text: String) -> String { wrap(text, "32") }
    public static func yellow(_ text: String) -> String { wrap(text, "33") }
    public static func blue(_ text: String) -> String { wrap(text, "34") }
}

public enum Layout {
    /// Column width as the terminal sees it: escape sequences take no columns,
    /// and CJK glyphs take two.
    public static func width(_ text: String) -> Int {
        plain(text).unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    public static func plain(_ text: String) -> String {
        guard text.contains("\u{001B}") else { return text }

        var result = ""
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{001B}" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let bracket = scalars.next(), bracket == "[" else { continue }
            while let parameter = scalars.next() {
                if ("A"..."Z").contains(parameter) || ("a"..."z").contains(parameter) { break }
            }
        }
        return result
    }

    public static func padRight(_ text: String, _ column: Int) -> String {
        text + String(repeating: " ", count: max(0, column - width(text)))
    }

    public static func padLeft(_ text: String, _ column: Int) -> String {
        String(repeating: " ", count: max(0, column - width(text))) + text
    }

    public static func clip(_ text: String, _ column: Int) -> String {
        guard width(text) > column, column > 1 else { return text }
        var result = ""
        for character in text {
            if width(result) + width(String(character)) > column - 1 { break }
            result.append(character)
        }
        return result + "…"
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

public enum Clock {
    public static func lasting(_ seconds: Int64) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    public static func until(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int64(date.timeIntervalSince(now))
        return seconds > 0 ? lasting(seconds) : "now"
    }

    public static func since(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = Int64(now.timeIntervalSince(date))
        return seconds < 60 ? "just now" : "\(lasting(seconds)) ago"
    }

    /// Absolute local time, because "in 6d" does not tell you whether that lands
    /// on a Monday morning or a Friday night.
    public static func stamp(_ date: Date?, now: Date = Date(), zone: TimeZone = .current) -> String? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "'today' HH:mm" : "EEE MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public static func compact(_ value: Int64) -> String {
        let amount = Double(value)
        switch amount {
        case 1_000_000_000...: return String(format: "%.1fB", amount / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", amount / 1_000_000)
        case 1_000...: return String(format: "%.1fk", amount / 1_000)
        default: return "\(value)"
        }
    }
}

public enum Term {
    public static var interactive: Bool {
        isatty(fileno(stdin)) == 1 && isatty(fileno(stdout)) == 1
    }

    public static func say(_ text: String = "") {
        print(text)
    }

    public static func warn(_ text: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    public static func confirm(_ question: String, standard: Bool = false) -> Bool {
        print("\(question) \(standard ? "[Y/n]" : "[y/N]") ", terminator: "")
        guard let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return standard
        }
        if answer.isEmpty { return standard }
        return answer == "y" || answer == "yes"
    }

    public static func ask(_ question: String) -> String? {
        print("\(question) ", terminator: "")
        return readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    public static func copyToClipboard(_ text: String) -> Bool {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        process.standardInput = input
        guard (try? process.run()) != nil else { return false }
        input.fileHandleForWriting.write(Data(text.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    public static func emit<T: Encodable>(_ payload: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}")
    }
}
