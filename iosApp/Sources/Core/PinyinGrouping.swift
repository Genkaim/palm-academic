import CoreFoundation
import Foundation

/// Initial-letter grouping for the school list.
///
/// The Android client groups by the first character's GBK code and walks a 23-entry table of
/// pinyin boundaries. CoreFoundation already knows how to transliterate a Han character to Latin,
/// so this does the same job without hard-coding a table that would have to be maintained against
/// an encoding: `CFStringTransform` with `kCFStringTransformToLatin` gives the pinyin spelling
/// (with tone marks), which is then folded to a bare ASCII letter.
///
/// Anything that does not transliterate to an ASCII letter -- digits, punctuation, symbols --
/// lands in `#`, and `#` sorts last, as it does on Android.
enum PinyinGrouping {
    static func key(for name: String) -> String {
        guard let first = name.first else { return otherSection }
        // CFStringTransform mutates the string in place and needs a mutable copy; the return value
        // is the same buffer, so the conversion below reads the transformed text.
        let mutable = NSMutableString(string: String(first))
        // The 16.5 SDK declares the range as a pointer, unlike the value form later SDKs import.
        var range = CFRange(location: 0, length: mutable.length)
        let ok = CFStringTransform(
            mutable as CFMutableString,
            &range,
            kCFStringTransformToLatin,
            false
        )
        let transformed = ok ? (mutable as String) : String(first)

        // `ā` folds to `a`; a digit or a symbol has no ASCII letter to fold to.
        let folded = transformed.folding(
            options: String.CompareOptions.diacriticInsensitive.union(.caseInsensitive),
            locale: nil
        )
        guard let scalar = folded.first, scalar.isASCII, scalar.isLetter else { return otherSection }
        return String(scalar).uppercased()
    }

    static let otherSection = "#"

    /// Sorts section headers with `A`..`Z` first and `#` last.
    static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return false }
        if lhs == otherSection { return false }
        if rhs == otherSection { return true }
        return lhs < rhs
    }
}
