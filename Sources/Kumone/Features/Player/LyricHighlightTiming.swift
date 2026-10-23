import Foundation

/// Shared by immersive and trailing lyrics. This is a pure sampling function:
/// seeking backwards or repeatedly sampling a paused time needs no reset and
/// produces the same result at 60Hz, 120Hz, or any other display cadence.
enum LyricHighlightTiming {
    static let unsungOpacity = 0.28

    static func alphas(for line: LyricLine, words: [LyricWord], at time: TimeInterval) -> [Double] {
        var out: [Double] = []
        for word in words {
            let chars = Array(word.text)
            let per = chars.isEmpty ? word.duration : word.duration / Double(chars.count)
            for index in chars.indices {
                let charStart = word.start + per * Double(index)
                let fraction = per > 0 ? min(max((time - charStart) / per, 0), 1)
                                      : (time >= charStart ? 1 : 0)
                out.append(unsungOpacity + (1 - unsungOpacity) * fraction)
            }
        }
        // Parser trims the joined YRC text. Drop its leading whitespace so
        // character opacities still line up with the actual displayed glyphs.
        let joined = words.map(\.text).joined()
        guard joined.count != line.text.count else { return out }
        let leading = joined.count - joined.drop(while: \.isWhitespace).count
        return Array(out.dropFirst(leading).prefix(line.text.count))
    }
}
