import Foundation
import NaturalLanguage
import PDFKit
import UIKit

/// Key Points: an on-device, extractive pass over a document's
/// text. It does NOT summarize and does NOT use any AI model or
/// network service — it scores the document's own sentences with
/// plain, explainable rules and picks the winners:
///
///   * sentences that use the document's most frequent content
///     words score higher (the classic term-frequency signal);
///   * the first sentence of each page gets a lead bonus;
///   * sentences carrying figures, money amounts, dates,
///     percentages (NSDataDetector / patterns), or named people,
///     places, and organizations (NLTagger) get boosts — in most
///     documents those are the facts a reader is hunting for.
///
/// Two outputs are built from the same analysis: a copy of the
/// document with the winning sentences highlighted in yellow at
/// their real text bounds, and an "Essentials Only" PDF that
/// quotes just the winning sentences, page by page, in the
/// original words. Everything is deterministic: the same document
/// always produces the same key points.
enum KeyPoints {

    /// The plain-language explanation shown in the tools sheet and
    /// printed on the Essentials PDF. Deliberately free of AI
    /// claims — this is scoring, not a model.
    static let explanation = "Key Points picks the sentences that look most important using on-device analysis — figures, dates, and names get priority. It doesn't rewrite anything; the Essentials PDF quotes the original words."

    // MARK: - Analysis result

    struct Sentence {
        /// 0-based page the sentence came from.
        let pageIndex: Int
        /// Position among that page's sentences (reading order).
        let order: Int
        /// The sentence, verbatim from the page's text.
        let text: String
        /// Character range within the page's own text string —
        /// valid against the same document the analysis ran on,
        /// which is what places the highlight at the sentence's
        /// real bounds.
        let range: NSRange
        let score: Double
    }

    struct PageResult {
        let pageIndex: Int
        /// The page's key sentences, in reading order.
        let sentences: [Sentence]
    }

    struct Analysis {
        /// Only pages that produced at least one key sentence.
        let pages: [PageResult]
        var sentenceCount: Int {
            pages.reduce(0) { $0 + $1.sentences.count }
        }
    }

    // MARK: - Text coverage

    /// Pages (of the given 0-based indexes) whose text layer is
    /// missing or trivial — the same >20-character bar the OCR
    /// engine uses. The Key Points flow runs those pages through
    /// OCR first, exactly like Make Searchable does.
    static func pagesMissingText(_ document: PDFDocument,
                                 pageIndexes: [Int]) -> [Int] {
        pageIndexes.filter { index in
            guard let page = document.page(at: index) else { return false }
            let text = page.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.count <= 20
        }
    }

    // MARK: - Analysis

    /// Scores every sentence on the given pages and selects each
    /// page's key sentences: roughly the top 30% per page, at
    /// least one per page that has any. Returns nil when no page
    /// yields a single selectable sentence (blank pages, pictures
    /// only, OCR found nothing).
    static func analyze(document: PDFDocument, pageIndexes: [Int]) -> Analysis? {
        // Split every page into sentences first: the term
        // frequencies are document-wide, so scoring needs all of
        // them before any sentence can be scored.
        var rawPages: [(pageIndex: Int, sentences: [RawSentence])] = []
        var frequencies: [String: Int] = [:]
        for index in pageIndexes {
            guard let page = document.page(at: index),
                  let text = page.string, !text.isEmpty else { continue }
            let sentences = splitSentences(text)
                .enumerated()
                .map { order, piece in
                    RawSentence(pageIndex: index, order: order,
                                text: piece.text, range: piece.range,
                                words: contentWords(piece.text))
                }
            guard !sentences.isEmpty else { continue }
            for sentence in sentences {
                for word in sentence.words {
                    frequencies[word, default: 0] += 1
                }
            }
            rawPages.append((index, sentences))
        }
        guard !rawPages.isEmpty else { return nil }

        var results: [PageResult] = []
        for (pageIndex, sentences) in rawPages {
            let scored = sentences.map { raw -> Sentence in
                Sentence(pageIndex: pageIndex, order: raw.order,
                         text: raw.text, range: raw.range,
                         score: score(raw, frequencies: frequencies))
            }
            // Very short fragments ("Yes.", a page number, a
            // running head) are never the point of a page; if a
            // page has nothing longer, fall back to all of them so
            // the page still gets its minimum one.
            let substantial = scored.filter { wordCount($0.text) >= 4 }
            let candidates = substantial.isEmpty ? scored : substantial
            let quota = max(1, Int((Double(scored.count) * 0.30).rounded(.up)))
            let winners = candidates
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.order < rhs.order
                }
                .prefix(quota)
                .sorted { $0.order < $1.order }
            if !winners.isEmpty {
                results.append(PageResult(pageIndex: pageIndex,
                                          sentences: Array(winners)))
            }
        }
        return results.isEmpty ? nil : Analysis(pages: results)
    }

    private struct RawSentence {
        let pageIndex: Int
        let order: Int
        let text: String
        let range: NSRange
        let words: [String]
    }

    /// Sentence boundaries from the Natural Language tokenizer,
    /// over the page's own text — so each range is valid against
    /// that same string for highlight placement.
    private static func splitSentences(_ text: String) -> [(text: String, range: NSRange)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var pieces: [(text: String, range: NSRange)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = String(text[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                pieces.append((piece, NSRange(range, in: text)))
            }
            return true
        }
        return pieces
    }

    /// The words a sentence is scored on: lowercased word tokens
    /// with letters in them, minus the stopwords that carry no
    /// topic signal.
    private static func contentWords(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            if word.count > 1,
               word.contains(where: { $0.isLetter }),
               !stopwords.contains(word) {
                words.append(word)
            }
            return true
        }
        return words
    }

    private static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    /// The score itself — kept small and explainable on purpose.
    /// Term frequency is log-dampened and length-normalized so a
    /// long rambling sentence can't win on bulk alone; the boosts
    /// are flat additions for the fact-shaped signals.
    private static func score(_ sentence: RawSentence,
                              frequencies: [String: Int]) -> Double {
        var total = 0.0
        // Summed in the sentence's own word order — never by
        // iterating the frequency dictionary — so the result is
        // identical on every run.
        for word in sentence.words {
            total += log(1 + Double(frequencies[word] ?? 0))
        }
        var value = total / sqrt(Double(max(wordCount(sentence.text), 1)))
        if sentence.order == 0 { value += 0.75 }       // leads its page
        if sentence.text.range(of: numberPattern, options: .regularExpression) != nil {
            value += 0.75                              // any figure
        }
        if sentence.text.range(of: moneyPattern, options: .regularExpression) != nil {
            value += 1.0                               // money amount
        }
        if sentence.text.range(of: percentPattern, options: .regularExpression) != nil {
            value += 0.75                              // percentage
        }
        if hasDate(sentence.text) { value += 1.0 }     // a date
        if hasNamedEntity(sentence.text) { value += 0.75 } // a name
        return value
    }

    private static let numberPattern = #"\d"#
    private static let moneyPattern = #"\$\s?\d|\b\d[\d,]*(\.\d{2})?\s?(dollars|usd)\b"#
    private static let percentPattern = #"\d+(\.\d+)?\s?%|\bper\s?cent\b"#

    private static let dateDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func hasDate(_ text: String) -> Bool {
        guard let detector = dateDetector else { return false }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return detector.numberOfMatches(in: text, range: fullRange) > 0
    }

    /// People, places, and organizations, via NLTagger's name
    /// recognition — on-device, no model download, no network.
    private static func hasNamedEntity(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, _ in
            if tag != nil {
                found = true
                return false
            }
            return true
        }
        return found
    }

    /// Common English words that say nothing about what a
    /// sentence is about.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "else",
        "when", "while", "of", "at", "by", "for", "with", "about",
        "against", "between", "into", "through", "during", "before",
        "after", "above", "below", "to", "from", "up", "down", "in",
        "out", "on", "off", "over", "under", "again", "further",
        "once", "here", "there", "all", "any", "both", "each",
        "few", "more", "most", "other", "some", "such", "no", "nor",
        "not", "only", "own", "same", "so", "than", "too", "very",
        "can", "will", "just", "should", "now", "is", "are", "was",
        "were", "be", "been", "being", "have", "has", "had",
        "having", "do", "does", "did", "doing", "would", "could",
        "shall", "may", "might", "must", "it", "its", "this",
        "that", "these", "those", "i", "you", "he", "she", "we",
        "they", "them", "his", "her", "their", "our", "your", "my",
        "me", "him", "us", "as", "are", "was", "were", "been",
        "also", "one", "two", "first", "second", "per", "via",
    ]

    // MARK: - Output A: highlight in a copy

    /// Paints real yellow highlight annotations over every key
    /// sentence, at the sentence's own text bounds (line by line,
    /// the same way the reader's manual highlight works), on the
    /// document the analysis ran on. The caller passes a document
    /// it loaded fresh (or the OCR output) and registers the
    /// result as a new library document — the source file is never
    /// written by this. Returns how many sentences got a
    /// highlight; a sentence whose bounds can't be located is
    /// skipped, not faked.
    @discardableResult
    static func addHighlights(to document: PDFDocument,
                              analysis: Analysis) -> Int {
        var highlighted = 0
        for pageResult in analysis.pages {
            guard let page = document.page(at: pageResult.pageIndex) else { continue }
            for sentence in pageResult.sentences {
                guard let selection = page.selection(for: sentence.range) else { continue }
                var placed = false
                for line in selection.selectionsByLine() {
                    for linePage in line.pages where linePage === page {
                        let bounds = line.bounds(for: page)
                        guard bounds.width > 0, bounds.height > 0 else { continue }
                        let annotation = PDFAnnotation(bounds: bounds,
                                                       forType: .highlight,
                                                       withProperties: nil)
                        annotation.color = UIColor(red: 1.0, green: 0.85,
                                                   blue: 0.25, alpha: 1.0)
                        annotation.userName = "PVKeyPoint"
                        page.addAnnotation(annotation)
                        placed = true
                    }
                }
                if placed { highlighted += 1 }
            }
        }
        return highlighted
    }

    // MARK: - Output B: Essentials Only PDF

    /// Builds the "filler thrown out" document: a clean, newly
    /// typeset PDF that quotes ONLY the key sentences — a title
    /// line naming the source document, the honest explanation,
    /// then a "Page N" heading per source page with its key
    /// sentences as a bullet list, in the original words.
    static func essentialsDocument(analysis: Analysis,
                                   documentName: String) -> PDFDocument? {
        guard analysis.sentenceCount > 0 else { return nil }

        let content = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 4
        content.append(NSAttributedString(
            string: "Key Points — \(documentName)\n",
            attributes: [
                .font: UIFont.boldSystemFont(ofSize: 20),
                .foregroundColor: UIColor.black,
                .paragraphStyle: titleStyle,
            ]))
        let noteStyle = NSMutableParagraphStyle()
        noteStyle.paragraphSpacing = 14
        content.append(NSAttributedString(
            string: explanation + "\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: 10.5),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: noteStyle,
            ]))

        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 10
        headingStyle.paragraphSpacing = 4
        let bulletStyle = NSMutableParagraphStyle()
        bulletStyle.headIndent = 14
        bulletStyle.paragraphSpacing = 4
        for pageResult in analysis.pages {
            content.append(NSAttributedString(
                string: "Page \(pageResult.pageIndex + 1)\n",
                attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: headingStyle,
                ]))
            for sentence in pageResult.sentences {
                content.append(NSAttributedString(
                    string: "• \(sentence.text)\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 11.5),
                        .foregroundColor: UIColor.black,
                        .paragraphStyle: bulletStyle,
                    ]))
            }
        }

        // Typeset onto letter pages with TextKit: one text
        // container per page, glyphs drawn in reading order.
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let textRect = pageRect.insetBy(dx: 54, dy: 54)
        let storage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            var glyphRange = NSRange(location: 0, length: 0)
            while glyphRange.location < layoutManager.numberOfGlyphs {
                let container = NSTextContainer(size: textRect.size)
                layoutManager.addTextContainer(container)
                context.beginPage()
                glyphRange = layoutManager.glyphRange(for: container)
                guard glyphRange.length > 0 else { break }
                layoutManager.drawBackground(forGlyphRange: glyphRange,
                                             at: textRect.origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange,
                                         at: textRect.origin)
            }
        }
        guard !data.isEmpty else { return nil }
        return PDFDocument(data: data)
    }
}
