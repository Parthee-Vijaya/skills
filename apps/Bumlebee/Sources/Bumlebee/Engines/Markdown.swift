import AppKit

/// A deliberately small Markdown bridge: enough for headings, emphasis, code, links and lists.
enum Markdown {
    static func html(from markdown: String) -> String {
        var html: [String] = []
        var inList: String?
        var inCode = false
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
                paragraph = []
            }
        }
        func closeList() {
            if let tag = inList { html.append("</\(tag)>"); inList = nil }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph(); closeList()
                html.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode { html.append(escape(rawLine)); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }

            if let heading = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[heading] == " " {
                flushParagraph(); closeList()
                let level = min(line.distance(from: line.startIndex, to: heading), 6)
                html.append("<h\(level)>\(inline(String(line[heading...]).trimmingCharacters(in: .whitespaces)))</h\(level)>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                if inList != "ul" { closeList(); html.append("<ul>"); inList = "ul" }
                html.append("<li>\(inline(String(line.dropFirst(2))))</li>")
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                flushParagraph()
                if inList != "ol" { closeList(); html.append("<ol>"); inList = "ol" }
                html.append("<li>\(inline(String(line[line.index(dot, offsetBy: 2)...])))</li>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>\(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else if line == "---" || line == "***" {
                flushParagraph(); closeList()
                html.append("<hr>")
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flushParagraph(); closeList()
        if inCode { html.append("</code></pre>") }
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica; font-size: 12pt; }
        code, pre { font-family: Menlo, monospace; font-size: 10.5pt; }
        </style></head><body>\(html.joined(separator: "\n"))</body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ text: String) -> String {
        var result = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"\*([^*]+)\*"#, "<i>$1</i>"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result
    }

    /// Turns styled text back into Markdown, keeping headings (by font size), bold and italic.
    static func markdown(from text: NSAttributedString) -> String {
        var output = ""
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            guard range.length > 0 else { output += "\n"; return }
            var line = ""
            var largest: CGFloat = 0
            text.enumerateAttributes(in: range) { attributes, runRange, _ in
                let run = string.substring(with: runRange)
                let font = attributes[.font] as? NSFont
                largest = max(largest, font?.pointSize ?? 12)
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                let trimmed = run.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { line += run; return }
                if traits.contains(.bold) { line += "**\(run)**" } else if traits.contains(.italic) { line += "*\(run)*" } else { line += run }
            }
            if largest >= 20 { line = "# " + line.replacingOccurrences(of: "**", with: "") }
            else if largest >= 16 { line = "## " + line.replacingOccurrences(of: "**", with: "") }
            output += line + "\n\n"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
