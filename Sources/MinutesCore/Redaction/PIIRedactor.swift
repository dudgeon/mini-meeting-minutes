import Foundation
import NaturalLanguage

/// Kinds of personal information the redactor can remove.
public enum PIICategory: String, CaseIterable, Sendable, Codable {
    case name
    case email
    case phone
    case address
    case governmentID = "id"
    case card
    case account
    case ipAddress = "ip"

    public var placeholder: String {
        switch self {
        case .name: "[NAME]"
        case .email: "[EMAIL]"
        case .phone: "[PHONE]"
        case .address: "[ADDRESS]"
        case .governmentID: "[ID]"
        case .card: "[CARD]"
        case .account: "[ACCOUNT]"
        case .ipAddress: "[IP]"
        }
    }

    public var displayName: String {
        switch self {
        case .name: "person names"
        case .email: "email addresses"
        case .phone: "phone numbers"
        case .address: "street addresses"
        case .governmentID: "ID numbers"
        case .card: "card numbers"
        case .account: "account numbers"
        case .ipAddress: "IP addresses"
        }
    }

    /// When detections overlap, the more specific category wins.
    fileprivate var priority: Int {
        switch self {
        case .email: 8
        case .card: 7
        case .governmentID: 6
        case .phone: 5
        case .account: 4
        case .ipAddress: 3
        case .address: 2
        case .name: 1
        }
    }
}

/// Removes personal information from transcript text, entirely on device.
///
/// Person names come from Apple's on-device named-entity recognizer (NaturalLanguage) plus a
/// lexicon of about 20,000 first names, which catches names the recognizer misses in context or
/// in lowercase. Street addresses and phone numbers come from Foundation's data detectors, and
/// the rest from patterns that also cover spoken and misrecognized forms ("john dot smith at
/// gmail dot com", "jane.doatexample.com", "415. 555, 0132"). Organization and place names are
/// kept: they rarely identify a person on their own and are usually what minutes are about.
///
/// Misspelled names ("Praya" for Priya) and surnames on their own can still slip through.
public struct PIIRedactor: Sendable {
    public let categories: Set<PIICategory>

    public init(categories: Set<PIICategory> = Set(PIICategory.allCases)) {
        self.categories = categories
    }

    public func redact(_ text: String) -> String {
        guard !categories.isEmpty, !text.isEmpty else { return text }
        let spans = merge(detect(in: text))
        guard !spans.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for span in spans.reversed() {
            result.replaceCharacters(in: span.range, with: span.category.placeholder)
        }
        return result as String
    }

    /// Every detection in `text`, before overlap resolution. Exposed for tests.
    func detect(in text: String) -> [Span] {
        let nsText = text as NSString
        let whole = NSRange(location: 0, length: nsText.length)
        var spans: [Span] = []

        for pattern in Self.patterns where categories.contains(pattern.category) {
            for match in pattern.regex.matches(in: text, range: whole) {
                let range = pattern.captureGroup > 0 ? match.range(at: pattern.captureGroup) : match.range
                guard range.location != NSNotFound else { continue }
                if let validate = pattern.validate, !validate(nsText.substring(with: range)) { continue }
                spans.append(Span(range: range, category: pattern.category))
            }
        }

        if categories.contains(.phone) || categories.contains(.address), let detector = Self.detector {
            for match in detector.matches(in: text, range: whole) {
                switch match.resultType {
                case .phoneNumber where categories.contains(.phone):
                    // Data detectors read many digit runs as phone numbers; require enough digits.
                    let digits = nsText.substring(with: match.range).filter(\.isNumber).count
                    if digits >= 7 { spans.append(Span(range: match.range, category: .phone)) }
                case .address where categories.contains(.address):
                    spans.append(Span(range: match.range, category: .address))
                default:
                    break
                }
            }
        }

        if categories.contains(.name) {
            var placesAndOrganizations: [NSRange] = []
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options
            ) { tag, range in
                switch tag {
                case .personalName: spans.append(Span(range: NSRange(range, in: text), category: .name))
                case .placeName, .organizationName: placesAndOrganizations.append(NSRange(range, in: text))
                default: break
                }
                return true
            }
            spans += lexiconNames(in: nsText, excluding: placesAndOrganizations)
        }
        return spans
    }

    /// First names from the lexicon. Mid-sentence capitalized words count; at the start of a
    /// sentence or in lowercase, only if the word isn't also an everyday word ("Will you…").
    private func lexiconNames(in text: NSString, excluding vetoed: [NSRange]) -> [Span] {
        var spans: [Span] = []
        for match in Self.wordPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let word = text.substring(with: match.range)
            let lower = word.lowercased()
            guard FirstNames.all.contains(Substring(lower)) else { continue }
            guard !vetoed.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            if word.count > 1 && word == word.uppercased() { continue }  // an acronym
            let capitalized = word.first?.isUppercase == true
            if capitalized && !Self.startsSentence(text, at: match.range.location) {
                spans.append(Span(range: match.range, category: .name))
            } else if !CommonWords.contains(lower) {
                spans.append(Span(range: match.range, category: .name))
            }
        }
        return spans
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\p{L}[\p{L}'’-]*"#)

    static func startsSentence(_ text: NSString, at location: Int) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = text.character(at: index)
            if let scalar = Unicode.Scalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar)
                || "\"'“‘(".unicodeScalars.contains(scalar)
            {
                index -= 1
                continue
            }
            return ".!?:;…".utf16.contains(character)
        }
        return true
    }

    struct Span: Equatable {
        var range: NSRange
        var category: PIICategory
    }

    /// Sorts spans and merges overlapping ones, keeping the most specific category.
    private func merge(_ spans: [Span]) -> [Span] {
        let sorted = spans.sorted {
            $0.range.location == $1.range.location
                ? $0.range.length > $1.range.length : $0.range.location < $1.range.location
        }
        var merged: [Span] = []
        for span in sorted {
            if var last = merged.last, span.range.location < NSMaxRange(last.range) {
                let end = max(NSMaxRange(last.range), NSMaxRange(span.range))
                last.range = NSRange(location: last.range.location, length: end - last.range.location)
                if span.category.priority > last.category.priority { last.category = span.category }
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    // MARK: - Patterns

    private struct Pattern: Sendable {
        let category: PIICategory
        let regex: NSRegularExpression
        var captureGroup = 0
        var validate: (@Sendable (String) -> Bool)?

        init(
            _ category: PIICategory, _ pattern: String, caseInsensitive: Bool = true, captureGroup: Int = 0,
            validate: (@Sendable (String) -> Bool)? = nil
        ) {
            self.category = category
            // Patterns are literals; a failure here is a programming error caught by the tests.
            self.regex = try! NSRegularExpression(
                pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            self.captureGroup = captureGroup
            self.validate = validate
        }
    }

    private static let digitWord = "(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)"
    private static let topLevelDomains =
        "(?:com|org|net|edu|gov|io|co|us|uk|ca|au|de|fr|nl|ie|in|ai|app|dev|me|info|biz)"

    private static let patterns: [Pattern] = [
        // Written email addresses.
        Pattern(.email, #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#),
        // Half-transcribed ones: "jane.doe at example.com", "jane at example.com".
        Pattern(
            .email,
            #"\b[\p{L}0-9._%+-]+\s+at\s*[\p{L}0-9-]+(?:\.[\p{L}0-9-]+)*\."# + topLevelDomains + #"\b"#),
        // Run together by the recognizer: "jane.doatexample.com".
        Pattern(
            .email,
            #"\b[\p{L}0-9_%+-]+(?:\.[\p{L}0-9_%+-]+)+at[\p{L}0-9-]+\."# + topLevelDomains + #"\b"#),
        // Spoken email addresses: "jane dot doe at example dot com".
        Pattern(
            .email,
            #"\b[\p{L}0-9]+(?:\s+(?:dot|underscore|dash|hyphen)\s+[\p{L}0-9]+)*\s+at\s+[\p{L}0-9]+(?:\s+(?:dot|dash)\s+[\p{L}0-9]+)*\s+dot\s+"#
                + topLevelDomains + #"\b"#),
        // US social security numbers in their usual format.
        Pattern(.governmentID, #"(?<![\d-])\d{3}-\d{2}-\d{4}(?![\d-])"#),
        // Nine digits right after an SSN keyword, however they were spoken or written.
        Pattern(
            .governmentID,
            #"\b(?:ssn|social security(?: number)?|social)\b[^\d]{0,24}(\d{3}[ -]?\d{2}[ -]?\d{4})(?!\d)"#,
            captureGroup: 1),
        // Card numbers: 13–19 digits, grouped or not, that pass the Luhn checksum.
        Pattern(.card, #"(?<![\d])(?:\d[ -]?){12,18}\d(?![\d])"#, validate: { luhnValid($0) }),
        // IBANs.
        Pattern(.account, #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#, caseInsensitive: false),
        // Long unbroken digit runs: account, policy and similar numbers.
        Pattern(.account, #"(?<![\d.,])\d{8,}(?![\d.,])"#),
        // Written phone numbers: North American and international formats.
        Pattern(.phone, #"(?<![\d])(?:\+?1[ .-]?)?(?:\(\d{3}\)|\d{3})[ .-]?\d{3}[ .-]?\d{4}(?![\d])"#),
        // Digit groups the recognizer punctuated: "415. 555, 0132" (plain thousands separators
        // like "10,000,000" don't match).
        Pattern(.phone, #"(?<![\d,.])\d{3}(?:[.,]?\s|[.-])\d{3}(?:[.,]?\s|[.-])\d{4}(?![\d])"#),
        // Digits spoken one at a time: "4 1 5 5 5 5 0 1 3 2".
        Pattern(.phone, #"(?<![\d])(?:\d[\s,.-]{1,2}){6,}\d(?![\d])"#),
        Pattern(.phone, #"(?<![\w+])\+\d{1,3}(?:[ .-]?\d{2,4}){2,5}(?![\d])"#),
        // Spoken digit strings of seven or more digits: phone numbers, account numbers, codes.
        Pattern(.phone, #"\b(?:"# + digitWord + #"[\s,.-]+(?:(?:double|triple)\s+)?){6,}"# + digitWord + #"\b"#),
        // IPv4 addresses.
        Pattern(
            .ipAddress,
            #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d|\.\d)"#),
    ]

    private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue)

    static func luhnValid(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

/// Everyday English words (lowercase entries of the system word list), so names that are also
/// words aren't redacted where capitalization can't tell them apart.
enum CommonWords {
    static func contains(_ word: String) -> Bool { words.contains(word) }

    private static let words: Set<String> = {
        guard let list = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var words = Set<String>()
        for line in list.split(separator: "\n") where line.first?.isLowercase == true {
            words.insert(String(line))
        }
        return words
    }()
}
