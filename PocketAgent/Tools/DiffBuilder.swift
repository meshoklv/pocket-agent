//
//  DiffBuilder.swift
//  PocketAgent
//
//  Построчный дифф «до / после» для карточки подтверждения.
//  Без внешних зависимостей. Три ступени, чтобы не съесть память телефона:
//    1) срезаем одинаковое начало и хвост;
//    2) маленькая середина — точная наибольшая общая подпоследовательность (LCS);
//    3) большая середина — разбиваем по строкам, встречающимся ровно один раз в обоих
//       текстах, и считаем куски отдельно (иначе матрица LCS растёт квадратично).
//  Алгоритм проверен прогоном на модельных случаях: восстановление старого и нового текста
//  из диффа, сплошная нумерация строк, файлы до 6000 строк с точечными правками.
//

import Foundation

public enum DiffBuilder {

    /// Сколько неизменённых строк показываем вокруг каждого изменения.
    public static let defaultContext = 3

    /// Предел размера матрицы LCS. 4 млн ячеек * 4 байта = 16 МБ — потолок для телефона.
    private static let lcsCellBudget = 4_000_000

    /// Глубина разбиения по опорным строкам. Защита от вырожденной рекурсии.
    private static let maxRecursionDepth = 12

    // MARK: - Главная функция

    /// Построить дифф. Ничего не читает с диска и ничего не пишет.
    /// - Parameters:
    ///   - oldText: содержимое «до»; nil — файла ещё нет, он будет создан.
    ///   - newText: ровно тот текст, который запишем.
    ///   - baseModificationDate: дата изменения файла на момент построения — перед записью сверяем.
    public static func build(relativePath: String,
                             oldText: String?,
                             newText: String,
                             baseModificationDate: Date? = nil,
                             createdDirectories: [String] = [],
                             context: Int = defaultContext,
                             maxLines: Int = AgentLimits.maxDiffLines) -> FileDiff {

        // Сравнение ПОБАЙТОВОЕ и ДО всякой нормализации: построчный дифф считается
        // по приведённым к \n строкам, и файл с виндовыми переводами строк давал
        // «изменений нет», хотя на диск уходил переписанный целиком текст.
        let isIdentical = (oldText == newText)

        let oldLines = oldText.map { splitLines($0) } ?? []
        let newLines = splitLines(newText)

        let ops = diffCore(oldLines, newLines, oldOffset: 0, newOffset: 0, depth: 0)

        var added = 0
        var removed = 0
        for op in ops {
            switch op.kind {
            case .added:   added += 1
            case .removed: removed += 1
            case .context: break
            }
        }

        let (hunks, isTruncated) = makeHunks(ops: ops, context: context, maxLines: maxLines)

        return FileDiff(relativePath: relativePath,
                        isNewFile: oldText == nil,
                        oldText: oldText,
                        newText: newText,
                        hunks: hunks,
                        addedCount: added,
                        removedCount: removed,
                        baseModificationDate: baseModificationDate,
                        isTruncated: isTruncated,
                        isIdenticalToDisk: isIdentical,
                        createdDirectories: createdDirectories)
    }

    /// Текстовое представление диффа — для ленты чата и для отладки.
    public static func plainText(_ diff: FileDiff) -> String {
        var out: [String] = []
        out.append("--- \(diff.relativePath)\(diff.isNewFile ? " (новый файл)" : "")")
        out.append("+\(diff.addedCount) −\(diff.removedCount)")
        for hunk in diff.hunks {
            out.append("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
            for line in hunk.lines {
                switch line.kind {
                case .added:   out.append("+" + line.text)
                case .removed: out.append("-" + line.text)
                case .context: out.append(" " + line.text)
                }
            }
        }
        if diff.isTruncated {
            out.append("… дифф показан не целиком, но применится целиком")
        }
        if diff.hasInvisibleChangesOnly {
            out.append("… построчных изменений нет: меняются только переводы строк")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Разбор на строки

    /// Разбивает текст на строки ВМЕСТЕ с их переводами строк: каждая строка отдаётся
    /// ровно в том виде, в каком лежит в файле, включая свой перевод строки (или без него —
    /// у последней строки файла его может не быть).
    ///
    /// ⚠️ ЗАЧЕМ ОТДЕЛЬНАЯ ФУНКЦИЯ, ЕСЛИ ЕСТЬ splitLines. Замена по номерам строк собирает
    /// новый текст файла из старых строк и присланного куска. Если брать строки из
    /// splitLines, из файла с виндовыми переводами строк соберётся файл с обычными:
    /// правка в пять строк молча превратится в перезапись всего файла, а в карточке
    /// человек увидит «изменений нет». Здесь переводы строк сохраняются побайтово.
    ///
    /// Количество строк совпадает с splitLines — иначе номера строк в выдаче read_file
    /// разошлись бы с номерами, по которым идёт замена.
    public static func splitPreservingLineBreaks(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            // Ровно те же три перевода строки, что режет splitLines. Character.isNewline
            // брать нельзя: он считает переводом ещё и редкие знаки (U+2028 и подобные),
            // и нумерация строк разъехалась бы с чтением.
            if character == "\n" || character == "\r\n" || character == "\r" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Перевод строки, которым заканчивается строка («\n», «\r\n», «\r» или пусто).
    public static func lineBreak(of line: String) -> String {
        if line.hasSuffix("\r\n") { return "\r\n" }
        if line.hasSuffix("\n") { return "\n" }
        if line.hasSuffix("\r") { return "\r" }
        return ""
    }

    /// Разбивает текст на строки. Переводы строк приводим к \n ТОЛЬКО для показа —
    /// на диск уходит ровно тот текст, что дала модель.
    public static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        // Завершающий перевод строки даёт лишний пустой элемент — он не строка файла
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Внутреннее представление

    private struct RawLine {
        let kind: DiffLineKind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
    }

    // MARK: - Сам дифф

    /// Порядок действий:
    ///   1) срезаем одинаковое начало и хвост — это почти всегда основная масса файла;
    ///   2) середина маленькая → точный LCS;
    ///   3) середина большая → разбиваем её по ОПОРНЫМ строкам (встречаются ровно один раз
    ///      и там, и там) и считаем каждый кусок отдельно. Так правка в файле на 6000 строк
    ///      остаётся правкой на несколько строк, а не «файл заменён целиком»;
    ///   4) опорных строк нет и куски огромные → честно показываем «заменено целиком».
    private static func diffCore(_ a: [String], _ b: [String],
                                 oldOffset: Int, newOffset: Int, depth: Int) -> [RawLine] {
        var out: [RawLine] = []

        // Одинаковое начало
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }

        // Одинаковый хвост (не залезая в уже съеденное начало)
        var suffix = 0
        while suffix < a.count - prefix,
              suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        for i in 0..<prefix {
            out.append(RawLine(kind: .context,
                               oldNumber: oldOffset + i + 1,
                               newNumber: newOffset + i + 1,
                               text: a[i]))
        }

        let aMid = Array(a[prefix..<(a.count - suffix)])
        let bMid = Array(b[prefix..<(b.count - suffix)])
        let midOld = oldOffset + prefix
        let midNew = newOffset + prefix

        if aMid.isEmpty || bMid.isEmpty {
            out.append(contentsOf: replaceBlock(aMid, bMid, oldOffset: midOld, newOffset: midNew))
        } else if aMid.count * bMid.count <= lcsCellBudget {
            out.append(contentsOf: lcsDiff(aMid, bMid, oldOffset: midOld, newOffset: midNew))
        } else if depth >= maxRecursionDepth {
            out.append(contentsOf: replaceBlock(aMid, bMid, oldOffset: midOld, newOffset: midNew))
        } else {
            let found = anchors(aMid, bMid)
            if found.isEmpty {
                out.append(contentsOf: replaceBlock(aMid, bMid, oldOffset: midOld, newOffset: midNew))
            } else {
                var ai = 0
                var bj = 0
                for anchor in found {
                    out.append(contentsOf: diffCore(Array(aMid[ai..<anchor.oldIndex]),
                                                    Array(bMid[bj..<anchor.newIndex]),
                                                    oldOffset: midOld + ai,
                                                    newOffset: midNew + bj,
                                                    depth: depth + 1))
                    out.append(RawLine(kind: .context,
                                       oldNumber: midOld + anchor.oldIndex + 1,
                                       newNumber: midNew + anchor.newIndex + 1,
                                       text: aMid[anchor.oldIndex]))
                    ai = anchor.oldIndex + 1
                    bj = anchor.newIndex + 1
                }
                out.append(contentsOf: diffCore(Array(aMid[ai...]),
                                                Array(bMid[bj...]),
                                                oldOffset: midOld + ai,
                                                newOffset: midNew + bj,
                                                depth: depth + 1))
            }
        }

        for k in 0..<suffix {
            let oldIndex = a.count - suffix + k
            let newIndex = b.count - suffix + k
            out.append(RawLine(kind: .context,
                               oldNumber: oldOffset + oldIndex + 1,
                               newNumber: newOffset + newIndex + 1,
                               text: a[oldIndex]))
        }

        return out
    }

    /// Кусок заменён целиком: сначала все старые строки, потом все новые.
    private static func replaceBlock(_ a: [String], _ b: [String],
                                     oldOffset: Int, newOffset: Int) -> [RawLine] {
        var out: [RawLine] = []
        out.reserveCapacity(a.count + b.count)
        for (i, line) in a.enumerated() {
            out.append(RawLine(kind: .removed, oldNumber: oldOffset + i + 1, newNumber: nil, text: line))
        }
        for (j, line) in b.enumerated() {
            out.append(RawLine(kind: .added, oldNumber: nil, newNumber: newOffset + j + 1, text: line))
        }
        return out
    }

    /// Опорные строки: встречаются РОВНО ОДИН раз и в старом, и в новом тексте.
    /// Из них берём самую длинную возрастающую цепочку — это скелет, вокруг которого
    /// правки разбиваются на мелкие независимые куски.
    private static func anchors(_ a: [String], _ b: [String]) -> [(oldIndex: Int, newIndex: Int)] {
        var countA: [String: Int] = [:]
        var countB: [String: Int] = [:]
        for line in a { countA[line, default: 0] += 1 }
        for line in b { countB[line, default: 0] += 1 }

        var positionInB: [String: Int] = [:]
        for (j, line) in b.enumerated() where countB[line] == 1 {
            positionInB[line] = j
        }

        var pairs: [(old: Int, new: Int)] = []
        for (i, line) in a.enumerated() where countA[line] == 1 {
            if let j = positionInB[line] { pairs.append((i, j)) }
        }
        guard !pairs.isEmpty else { return [] }

        // Наибольшая возрастающая подпоследовательность по позициям в новом тексте
        var tails: [Int] = []       // сами позиции
        var tailPairIndex: [Int] = [] // индексы в pairs
        var previous = [Int](repeating: -1, count: pairs.count)

        for (k, pair) in pairs.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if tails[mid] < pair.new { low = mid + 1 } else { high = mid }
            }
            if low == tails.count {
                tails.append(pair.new)
                tailPairIndex.append(k)
            } else {
                tails[low] = pair.new
                tailPairIndex[low] = k
            }
            previous[k] = low > 0 ? tailPairIndex[low - 1] : -1
        }

        var chain: [(oldIndex: Int, newIndex: Int)] = []
        var cursor = tailPairIndex[tailPairIndex.count - 1]
        while cursor != -1 {
            chain.append((pairs[cursor].old, pairs[cursor].new))
            cursor = previous[cursor]
        }
        return Array(chain.reversed())
    }

    private static func lcsDiff(_ a: [String], _ b: [String],
                                oldOffset: Int, newOffset: Int) -> [RawLine] {
        let n = a.count
        let m = b.count
        let width = m + 1

        // dp[i][j] — длина наибольшей общей подпоследовательности хвостов a[i...] и b[j...]
        var dp = [Int32](repeating: 0, count: (n + 1) * width)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                let row = i * width
                let next = row + width
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[row + j] = dp[next + j + 1] + 1
                    } else {
                        dp[row + j] = max(dp[next + j], dp[row + j + 1])
                    }
                }
            }
        }

        var out: [RawLine] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                out.append(RawLine(kind: .context,
                                   oldNumber: oldOffset + i + 1,
                                   newNumber: newOffset + j + 1,
                                   text: a[i]))
                i += 1
                j += 1
            } else if dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
                out.append(RawLine(kind: .removed,
                                   oldNumber: oldOffset + i + 1,
                                   newNumber: nil,
                                   text: a[i]))
                i += 1
            } else {
                out.append(RawLine(kind: .added,
                                   oldNumber: nil,
                                   newNumber: newOffset + j + 1,
                                   text: b[j]))
                j += 1
            }
        }
        while i < n {
            out.append(RawLine(kind: .removed, oldNumber: oldOffset + i + 1, newNumber: nil, text: a[i]))
            i += 1
        }
        while j < m {
            out.append(RawLine(kind: .added, oldNumber: nil, newNumber: newOffset + j + 1, text: b[j]))
            j += 1
        }
        return out
    }

    // MARK: - Группировка в хунки

    private static func makeHunks(ops: [RawLine],
                                  context: Int,
                                  maxLines: Int) -> ([DiffHunk], Bool) {
        let changedIndexes = ops.indices.filter { ops[$0].kind != .context }
        guard !changedIndexes.isEmpty else { return ([], false) }

        // Расширяем каждое изменение на контекст и склеиваем пересекающиеся куски
        var ranges: [(start: Int, end: Int)] = []
        for index in changedIndexes {
            let start = max(0, index - context)
            let end = min(ops.count - 1, index + context)
            if let last = ranges.last, start <= last.end + 1 {
                ranges[ranges.count - 1].end = max(last.end, end)
            } else {
                ranges.append((start, end))
            }
        }

        var hunks: [DiffHunk] = []
        var lineID = 0
        var used = 0
        var isTruncated = false

        for (hunkIndex, range) in ranges.enumerated() {
            if used >= maxLines {
                isTruncated = true
                break
            }
            var slice = Array(ops[range.start...range.end])
            if used + slice.count > maxLines {
                slice = Array(slice.prefix(maxLines - used))
                isTruncated = true
            }
            guard !slice.isEmpty else {
                isTruncated = true
                break
            }

            var lines: [DiffLine] = []
            lines.reserveCapacity(slice.count)
            for raw in slice {
                lines.append(DiffLine(id: lineID,
                                      kind: raw.kind,
                                      oldNumber: raw.oldNumber,
                                      newNumber: raw.newNumber,
                                      text: raw.text))
                lineID += 1
            }

            let oldNumbers = slice.compactMap(\.oldNumber)
            let newNumbers = slice.compactMap(\.newNumber)

            hunks.append(DiffHunk(id: hunkIndex,
                                  oldStart: oldNumbers.first ?? 0,
                                  oldCount: oldNumbers.count,
                                  newStart: newNumbers.first ?? 0,
                                  newCount: newNumbers.count,
                                  lines: lines))

            used += slice.count
            if isTruncated { break }
        }

        return (hunks, isTruncated)
    }
}
