import Foundation

enum TranscriptScript {
    /// AWS may split Japanese into kana-only tokens; joining them with English word spaces corrupts the text.
    static func isUnspaced(_ character: Character?) -> Bool {
        character?.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value)
                || (0xFF66...0xFF9F).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                || (0x20000...0x3134F).contains($0.value)
        } ?? false
    }
}
