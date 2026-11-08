import Foundation

struct NotebookSourceRange: Decodable, Equatable {
    let start_line: Int, start_column: Int, end_line: Int, end_column: Int
    let whole_line: Bool
}

struct NotebookSourceDiagnostic: Decodable, Equatable {
    let message: String
    let range: NotebookSourceRange?
}

struct NotebookModuleError: Decodable {
    let module_id: String, source: String, message: String
    let ranges: [NotebookSourceRange]
}

struct NotebookSourceSelection: Equatable {
    let source: String
    let range: NotebookSourceRange
    let id = UUID()
}

struct NotebookSourceLines {
    let lines: [Range<Int>]

    init(_ source: String) {
        var lines: [Range<Int>] = []
        var start = 0
        var offset = 0
        var previousCR = false
        for unit in source.utf16 {
            if unit == 13 || (unit == 10 && !previousCR) {
                lines.append(start..<offset)
                start = offset + 1
            } else if unit == 10 {
                start = offset + 1
            }
            offset += 1
            previousCR = unit == 13
        }
        lines.append(start..<offset)
        self.lines = lines
    }

    func line(at offset: Int) -> Int {
        var low = 0, high = lines.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lines[middle].lowerBound <= offset { low = middle }
            else { high = middle }
        }
        return low
    }

    func decoration(for range: NotebookSourceRange, in source: NSString) -> (rows: ClosedRange<Int>, characters: NSRange?)? {
        guard let selection = selection(for: range, in: source) else { return nil }
        let last = range.whole_line || range.end_column > 0 ? range.end_line : max(range.start_line, range.end_line - 1)
        return (range.start_line...last, range.whole_line || selection.length == 0 ? nil : selection)
    }

    func selection(for range: NotebookSourceRange, in source: NSString) -> NSRange? {
        guard lines.indices.contains(range.start_line), lines.indices.contains(range.end_line),
              range.start_line <= range.end_line else { return nil }
        if range.whole_line {
            let start = lines[range.start_line].lowerBound
            return NSRange(location: start, length: lines[range.end_line].upperBound - start)
        }

        func offset(line: Int, column: Int, isEnd: Bool) -> Int? {
            guard column >= 0 else { return nil }
            let bounds = lines[line]
            var offset = bounds.lowerBound
            var remaining = column
            while remaining > 0 && offset < bounds.upperBound {
                let unit = source.character(at: offset)
                offset += (0xd800...0xdbff).contains(unit) ? 2 : 1
                remaining -= 1
            }
            // The compiler can extend a point at end of line by one column.
            return remaining == 0 || (isEnd && remaining == 1) ? offset : nil
        }

        guard let start = offset(line: range.start_line, column: range.start_column, isEnd: false),
              let end = offset(line: range.end_line, column: range.end_column, isEnd: true),
              start <= end else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
