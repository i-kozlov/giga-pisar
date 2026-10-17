// Other case forms of a new dictionary word, so nobody has to type «джиру»
// and «джире» by hand. Plain ending rules, no model and no network: good
// enough for names and terms, and every suggestion comes with a checkbox.
// Only Foundation.

import Foundation

enum WordForms {
    /// Extra pairs for «heard → write»: genitive, dative, accusative,
    /// instrumental and prepositional of the word. A Cyrillic replacement
    /// is declined in the same case; anything else («Jira») stays as written.
    /// Phrases («опен и ай») and short words get nothing: the ending rules
    /// guess wrong there («опен и Ая»). Spaces do not matter when matching,
    /// so «гитхаб» with its forms still covers «гит хабе».
    static func suggest(heard: String, write: String) -> [(heard: String, write: String)] {
        let heard = heard.trimmingCharacters(in: .whitespaces)
        let write = write.trimmingCharacters(in: .whitespaces)
        guard let (heardHead, heardWord) = split(heard), heardHead.isEmpty, heardWord.count >= 4,
              let heardForms = decline(heardWord) else { return [] }
        let writeForms = split(write).flatMap { head, word in decline(word).map { forms in forms.map { $0.map { head + $0 } } } }
        var seen: Set<String> = [heard.lowercased()]
        var out: [(heard: String, write: String)] = []
        for (k, form) in heardForms.enumerated() {
            guard let form else { continue }
            let h = heardHead + form
            guard seen.insert(h.lowercased()).inserted else { continue }
            // A capitalised masculine replacement is a name, an animate noun:
            // its accusative is the genitive («сашу → Александра»).
            let animate = k == 2 && write.first?.isUppercase == true ? writeForms?[0] : nil
            out.append((h, writeForms?[k] ?? animate ?? write))
        }
        return out
    }

    /// Everything before the last word, and the last word itself.
    private static func split(_ s: String) -> (String, String)? {
        guard let last = s.split(whereSeparator: { $0 == " " || $0 == "-" }).last else { return nil }
        return (String(s.dropLast(last.count)), String(last))
    }

    private static let cyrillic = CharacterSet(charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
    private static let consonants = Set("бвгджзклмнпрстфхцчшщ")

    /// Five forms, nil where the case looks like the plain word or the word
    /// does not decline by these rules (adjectives, plurals, «кино», Latin).
    static func decline(_ word: String) -> [String?]? {
        let w = word.lowercased()
        guard w.count >= 2, w.unicodeScalars.allSatisfy({ cyrillic.contains($0) }) else { return nil }
        for adj in ["ый", "ой", "ая", "яя", "ое", "ее", "ие", "ые"] where w.hasSuffix(adj) { return nil }
        let chars = Array(w)
        let last = chars[chars.count - 1], prev = chars[chars.count - 2]
        // Abbreviations («НАСА», «МГУ») do not decline.
        guard word != word.uppercased() else { return nil }
        func stem(_ drop: Int) -> String { String(word.dropLast(drop)) }
        func f(_ base: String, _ ending: String) -> String { base + ending }

        switch last {
        case "а":
            let s = stem(1)
            return [f(s, "гкхжшщч".contains(prev) ? "и" : "ы"), f(s, "е"), f(s, "у"),
                    f(s, "жшщчц".contains(prev) ? "ей" : "ой"), f(s, "е")]
        case "я":
            let s = stem(1)
            if prev == "и" { return [f(s, "и"), f(s, "и"), f(s, "ю"), f(s, "ей"), f(s, "и")] }
            return [f(s, "и"), f(s, "е"), f(s, "ю"), f(s, "ей"), f(s, "е")]
        case "й":
            let s = stem(1)
            return [f(s, "я"), f(s, "ю"), nil, f(s, "ем"), f(s, prev == "и" ? "и" : "е")]
        case "ь":
            let s = stem(1)
            return [f(s, "я"), f(s, "ю"), nil, f(s, "ем"), f(s, "е")]
        case let c where consonants.contains(c):
            let s = word
            return [f(s, "а"), f(s, "у"), nil, f(s, "жшщчц".contains(c) ? "ем" : "ом"), f(s, "е")]
        default:
            return nil
        }
    }
}
