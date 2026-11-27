import Foundation

/// Hermes Neo: the caption of a reply as it is spoken, for upstream Talk's captions (`TalkDisplay.caption`): only the
/// sentence being spoken now, its words already heard settled and the rest of it lighter. Sentences follow one by
/// one as the reply plays. Pure, tested.
public enum CallCaptionProgress {
    /// `text`: the reply; `progress`: how much of it has been heard, 0...1.
    public static func split(_ text: String, progress: Double) -> (settled: String, lighter: String) {
        let sentences = Self.sentences(text)
        guard !sentences.isEmpty else { return ("", "") }
        let total = sentences.reduce(0) { $0 + $1.count }
        guard total > 0 else { return ("", "") }
        let heard = Int((min(max(progress, 0), 1) * Double(total)).rounded())
        var before = 0
        for (index, sentence) in sentences.enumerated() {
            let last = index == sentences.count - 1
            if heard < before + sentence.count || last {
                let into = min(max(heard - before, 0), sentence.count)
                // Whole words only: the settled part ends at the last space before the point reached.
                let cut = Self.wordBoundary(in: sentence, at: into)
                let settled = String(sentence.prefix(cut))
                return (settled, String(sentence.dropFirst(cut)))
            }
            before += sentence.count
        }
        return ("", "")
    }

    /// The reply cut after each `.`, `!`, `?` or `…` that is followed by a space (the space stays with the sentence).
    static func sentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var previous: Character?
        for character in trimmed {
            if character.isWhitespace, let previous, ".!?…".contains(previous), !current.isEmpty {
                result.append(current)
                current = ""
                continue
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func wordBoundary(in sentence: String, at offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        guard offset < sentence.count else { return sentence.count }
        let characters = Array(sentence)
        var index = offset
        while index > 0, !characters[index - 1].isWhitespace { index -= 1 }
        return index
    }
}
