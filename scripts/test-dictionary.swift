import Foundation

// Standalone checks of swift/Dictionary.swift: file format and replacement semantics.
@main struct DictionaryTests {
    static func dict(_ rules: [([String], String)]) -> ReplacementDictionary.Compiled {
        let d = ReplacementDictionary(rules: rules.map { DictionaryRule(variants: $0.0, replacement: $0.1) })
        do { try d.validate() } catch { fatalError("valid fixture rejected: \(error)") }
        return d.compile()
    }

    static func expect(_ got: String, _ want: String, _ what: String) {
        precondition(got == want, "\(what): got «\(got)», want «\(want)»")
    }

    static func rejects(_ json: String, _ what: String) {
        do {
            _ = try ReplacementDictionary.decode(Data(json.utf8))
            fatalError("\(what): accepted")
        } catch is DictionaryError {
        } catch { fatalError("\(what): unexpected \(error)") }
    }

    static func main() {
        // Cyrillic and Latin, case-insensitive, replacement keeps its own case.
        let d = dict([(["опен эй ай", "open ai"], "OpenAI"), (["кодекс"], "Codex")])
        expect(d.apply("Спроси Опен Эй Ай и кодекс."), "Спроси OpenAI и Codex.", "basic")
        expect(d.apply("OPEN AI"), "OpenAI", "upper case")
        // Word boundaries: no match inside a longer word.
        expect(d.apply("кодексы и кодекс"), "кодексы и Codex", "boundary")
        expect(d.apply("перекодекс"), "перекодекс", "prefix boundary")
        print("PASS cyrillic/latin, case-insensitive, word boundaries")

        // Decomposed input (й as и + combining breve) matches a precomposed variant.
        let y = dict([(["йод"], "Iodine")])
        expect(y.apply("и\u{0306}од есть"), "Iodine есть", "NFC input")
        let yo = dict([(["ёлка"], "Tree")])
        expect(yo.apply("елка"), "елка", "ё and е are different letters")
        print("PASS NFC, ё stays distinct from е")

        // Longest match at a position wins; replacement output is never rescanned.
        let o = dict([(["гига"], "Giga"), (["гига чат"], "GigaChat")])
        expect(o.apply("гига чат и гига"), "GigaChat и Giga", "longest first")
        let c = dict([(["кот"], "собака"), (["собака"], "волк")])
        expect(c.apply("кот и собака"), "собака и волк", "no cascade")
        let swap = dict([(["а1"], "б1"), (["б1"], "а1")])
        expect(swap.apply("а1 б1"), "б1 а1", "swap without cycle")
        print("PASS longest match, no cascades")

        // Replacement is literal; symbols at the edges are not word characters.
        let lit = dict([(["доллар один"], "$1 \\0")])
        expect(lit.apply("доллар один"), "$1 \\0", "literal $ and backslash")
        let cpp = dict([(["си плюс плюс"], "C++"), (["C#"], "C♯")])
        expect(cpp.apply("на си плюс плюс и C#."), "на C++ и C♯.", "C++ and C#")
        let snake = dict([(["foo"], "bar")])
        expect(snake.apply("foo_bar foo-bar foobar"), "bar_bar bar-bar foobar", "underscore and hyphen are boundaries")
        let src = dict([(["C++"], "Си++")])
        expect(src.apply("C++ C++17 XC++ (C++) C++/C#"), "Си++ C++17 XC++ (Си++) Си++/C#", "C++ as a source")
        let sharp = dict([(["C#"], "X")])
        expect(sharp.apply("C#developer C# C#."), "C#developer X X.", "C# needs a boundary after it")
        // The longest candidate fails its boundary; a shorter one that fits is chosen.
        let fit = dict([(["нью йорк"], "New York"), (["нью"], "New")])
        expect(fit.apply("нью йоркский"), "New йоркский", "shorter candidate when longer fails boundary")
        expect(fit.apply("ничего общего"), "ничего общего", "no match leaves text as is")
        print("PASS literal replacement, C++/C# as source and target, _ and - boundaries, fallback to shorter")

        // Case folding is per character, the same in keys and matching: ß and ss are different.
        let ss = dict([(["Straße"], "Street")])
        expect(ss.apply("STRASSE straße"), "STRASSE Street", "ß is not ss")
        for order in [[(["straße"], "S"), (["strasse"], "S")], [(["strasse"], "S"), (["straße"], "S")]] {
            expect(dict(order).apply("straße strasse STRASSE"), "S S S", "both spellings, any order")
        }
        // Output text outside replacements is NFC, byte for byte.
        let nfc = dict([(["кот"], "Cat")])
        expect(String(nfc.apply("и\u{0306} кот").unicodeScalars.map(Character.init)), "й Cat", "nfc output")
        precondition(Array(nfc.apply("и\u{0306} кот").unicodeScalars) == Array("й Cat".unicodeScalars), "NFC scalars")
        print("PASS per-character case folding, NFC output")

        // File format: JSON5 comments and trailing commas, strict schema.
        let json5 = """
        // словарь
        {version: 1, rules: [
          {variants: ['опен эй ай', "open ai",], replacement: "OpenAI", note: "компания",},
        ],}
        """
        do {
            let file = try ReplacementDictionary.decode(Data(json5.utf8))
            precondition(file.rules == [DictionaryRule(variants: ["опен эй ай", "open ai"], replacement: "OpenAI", note: "компания")])
            let again = try ReplacementDictionary.decode(try file.encode())
            precondition(again == file, "encode/decode round trip")
        } catch { fatalError("JSON5 rejected: \(error)") }
        rejects(#"{"version": 2, "rules": []}"#, "unknown version")
        rejects(#"{"version": 1.5, "rules": []}"#, "fractional version")
        rejects(#"{"version": 1.0, "rules": []}"#, "non-integer version")
        rejects(#"{"rules": []}"#, "missing version")
        rejects(#"{"version": 1}"#, "missing rules")
        rejects(#"[]"#, "array root")
        rejects(#"{"version": 1, "rules": {}}"#, "rules not an array")
        rejects(#"{"version": 1, "rules": [{"replacement": "b"}]}"#, "missing variants")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"]}]}"#, "missing replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": 1}]}"#, "number replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": true}]}"#, "bool replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": null}]}"#, "null replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": "b", "note": 1}]}"#, "number note")
        rejects(#"{"version": true, "rules": []}"#, "bool version")
        rejects(#"{"version": 1, "rules": [], "extra": 1}"#, "unknown root key")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": "b", "x": 1}]}"#, "unknown rule key")
        rejects(#"{"version": 1, "rules": [{"variants": [], "replacement": "b"}]}"#, "no variants")
        rejects(#"{"version": 1, "rules": [{"variants": ["  "], "replacement": "b"}]}"#, "blank variant")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": ""}]}"#, "empty replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["a"], "replacement": "b", "note": null}]}"#, "null note")
        rejects(#"{"version": 1, "rules": [{"variants": [1], "replacement": "b"}]}"#, "number variant")
        rejects(#"{"version": 1, "rules": [{"variants": ["Кот"], "replacement": "b"}, {"variants": ["кот"], "replacement": "c"}]}"#,
                "same variant, different replacements")
        do {
            let same = try ReplacementDictionary.decode(Data(#"{"version": 1, "rules": [{"variants": ["Кот"], "replacement": "b"}, {"variants": ["кот"], "replacement": "b"}]}"#.utf8))
            expect(same.compile().apply("кот"), "b", "duplicate with same replacement")
        } catch { fatalError("duplicate with same replacement rejected: \(error)") }
        let leading = ReplacementDictionary(rules: [DictionaryRule(variants: ["x"], replacement: " y ")])
        expect(leading.compile().apply("x"), " y ", "replacement is not trimmed")
        // encode never produces a file that decode would reject.
        let note = String(repeating: "н", count: ReplacementDictionary.maxNoteLength)
        let big = ReplacementDictionary(rules: (0..<1500).map {
            DictionaryRule(variants: ["вариант \($0)"], replacement: "замена \($0)", note: note)
        })
        do { _ = try big.encode(); fatalError("oversized encode accepted") } catch is DictionaryError {} catch {
            fatalError("oversized encode: unexpected \(error)")
        }
        func invalid(_ d: ReplacementDictionary, _ what: String) {
            do { try d.validate(); fatalError("\(what) accepted") } catch is DictionaryError {} catch {
                fatalError("\(what): unexpected \(error)")
            }
        }
        invalid(ReplacementDictionary(rules: [DictionaryRule(variants: ["a"], replacement: "b", note: note + "н")]), "long note")
        invalid(ReplacementDictionary(rules: [DictionaryRule(
            variants: [String(repeating: "a", count: ReplacementDictionary.maxVariantLength + 1)], replacement: "b")]), "long variant")
        invalid(ReplacementDictionary(rules: [DictionaryRule(
            variants: ["a"], replacement: String(repeating: "b", count: ReplacementDictionary.maxReplacementLength + 1))]), "long replacement")
        invalid(ReplacementDictionary(rules: (0...ReplacementDictionary.maxRules).map {
            DictionaryRule(variants: ["в\($0)"], replacement: "b") }), "too many rules")
        invalid(ReplacementDictionary(rules: [DictionaryRule(
            variants: (0...ReplacementDictionary.maxVariants).map { "в\($0)" }, replacement: "b")]), "too many variants")
        print("PASS JSON5 input, strict schema, round trip")

        storeLifecycle()
    }

    static func storeLifecycle() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("giga-dict-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictionary.json")
        let store = DictionaryStore(url: url)
        func write(_ s: String) { try! Data(s.utf8).write(to: url) }
        func check(_ input: String, _ want: String, problem: Bool, _ what: String) {
            let (compiled, issue) = store.refresh()
            expect(compiled.apply(input), want, what)
            precondition((issue != nil) == problem, "\(what): problem \(issue ?? "none")")
        }

        check("кот", "кот", problem: false, "missing file is an empty dictionary")
        write(#"{"version": 1, "rules": [{"variants": ["кот"], "replacement": "Cat"}]}"#)
        check("кот", "Cat", problem: false, "valid file")
        write(#"{"version": 1, "rules": [{"variants": ["кот"], "replacement": ""}]}"#)
        check("кот", "Cat", problem: true, "broken file keeps the last good snapshot")
        check("кот", "Cat", problem: false, "same broken file is reported once")
        write(#"{"version": 1, "rules": [{"variants": ["кот"]}]}"#)
        check("кот", "Cat", problem: true, "another broken version is reported again")
        write(#"{"version": 1, "rules": [{"variants": ["кот"], "replacement": "Kitty"}]}"#)
        check("кот", "Kitty", problem: false, "fixed file")
        write(String(repeating: " ", count: ReplacementDictionary.maxFileBytes + 1))
        check("кот", "Kitty", problem: true, "oversized file keeps the last good snapshot")
        let good = #"{"version": 1, "rules": [{"variants": ["кот"], "replacement": "Kitty"}]}"#
        let bad = #"{"version": 1, "rules": [{"variants": ["кот"], "replacement": ""}]}"#
        write(good); check("кот", "Kitty", problem: false, "back to good A")
        write(bad); check("кот", "Kitty", problem: true, "broken B")
        write(good); check("кот", "Kitty", problem: false, "good A again")
        write(bad); check("кот", "Kitty", problem: true, "broken B again is reported again")
        write(good); check("кот", "Kitty", problem: false, "good A once more")
        try! FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        check("кот", "Kitty", problem: true, "not a regular file")
        try! FileManager.default.removeItem(at: url)
        check("кот", "кот", problem: false, "deleted file clears the dictionary")
        print("PASS store: missing, valid, broken, fixed, oversized, deleted")

        // Spaces and hyphens inside a variant are optional in the text; none are invented elsewhere.
        let gap = dict([(["гит хаб"], "GitHub"), (["кот"], "Cat")])
        expect(gap.apply("гит хаб, гитхаб, гит-хаб, гит  хаб"), "GitHub, GitHub, GitHub, GitHub", "gap variants")
        expect(gap.apply("гитхабовский к от"), "гитхабовский к от", "gap keeps word boundaries, no gaps invented")
        let hyphen = dict([(["гит-хаб"], "GitHub")])
        expect(hyphen.apply("гитхаб и гит хаб"), "GitHub и GitHub", "hyphen in a variant is a gap too")
        print("PASS gaps: spaces and hyphens inside a variant")

        // The address «Писарь» is reserved; line breaks and control characters are refused.
        rejects(#"{"version": 1, "rules": [{"variants": ["пихарь"], "replacement": "Писарь"}]}"#, "reserved replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["писаря"], "replacement": "X"}]}"#, "reserved variant")
        rejects(#"{"version": 1, "rules": [{"variants": ["гига песарь"], "replacement": "X"}]}"#, "reserved inside a phrase")
        rejects(#"{"version": 1, "rules": [{"variants": ["привет"], "replacement": "привет\nrm -rf ~"}]}"#, "newline in replacement")
        rejects(#"{"version": 1, "rules": [{"variants": ["при\tвет"], "replacement": "x"}]}"#, "tab in variant")
        rejects(#"{"version": 1, "rules": [{"variants": ["x"], "replacement": "a\u202Eb"}]}"#, "bidi override")
        var sneaky = ReplacementDictionary()
        sneaky.rules = [DictionaryRule(variants: ["пихарь"], replacement: "Писарь"),
                        DictionaryRule(variants: ["эхо"], replacement: "echo\nx")]
        expect(sneaky.compile().apply("пихарь эхо"), "пихарь эхо", "unsafe rules never run even unvalidated")
        _ = dict([(["описание"], "Description")]) // «писа» inside a longer word is not the address
        print("PASS reserved «Писарь», control characters refused")

        // Case forms for a new word.
        func forms(_ h: String, _ w: String) -> String {
            WordForms.suggest(heard: h, write: w).map { "\($0.heard)>\($0.write)" }.joined(separator: " ")
        }
        expect(forms("джира", "Jira"), "джиры>Jira джире>Jira джиру>Jira джирой>Jira", "feminine, Latin replacement")
        expect(forms("саша", "Александр"), "саши>Александра саше>Александру сашу>Александра сашей>Александром", "declined name")
        expect(forms("гитхаб", "GitHub"), "гитхаба>GitHub гитхабу>GitHub гитхабом>GitHub гитхабе>GitHub", "masculine")
        expect(forms("гит хаб", "GitHub"), "", "phrase")
        expect(forms("опен и Ай", "Open AI"), "", "phrase with a short last word")
        expect(forms("чат", "Chat"), "", "short word")
        expect(forms("мария", "Мария"), "марии>Марии марию>Марию марией>Марией", "-ия")
        expect(forms("кино", "Kino"), "", "indeclinable")
        expect(forms("НАСА", "NASA"), "", "abbreviation")
        expect(forms("open ai", "OpenAI"), "", "Latin heard")
        print("PASS word forms")
    }
}
