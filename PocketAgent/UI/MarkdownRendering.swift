//
//  MarkdownRendering.swift
//  PocketAgent
//
//  Разбор и показ разметки, которой пишет МОДЕЛЬ: звёздочки для жирного и курсива,
//  списки, заголовки, куски кода в обратных кавычках, ссылки. До этого файла всё
//  это показывалось сырым текстом со звёздочками — и выглядело как мусор.
//
//  ⚠️ РАЗМЕТКА ТОЛЬКО ДЛЯ ОТВЕТОВ МОДЕЛИ. Реплики человека, служебные строки и вывод
//  инструментов сюда не попадают — разметки там не бывает (путь к файлу вроде
//  «Models/*.swift» не должен превращаться в курсив), и вызывающая сторона
//  (`ChatMessageRow` в ChatView.swift) сама решает, кому это показывать.
//
//  ⚠️ ГЛАВНОЕ ПРАВИЛО РАЗБОРА: КРИВАЯ РАЗМЕТКА НЕ ЛОМАЕТ ВИД. Модель маленькая —
//  она регулярно не закрывает звёздочку и обрывает блок кода на середине (кончились
//  токены). Разбор здесь НИКОГДА не бросает исключение наружу и никогда не показывает
//  пустоту: не получилось понять кусок — он идёт как обычный текст, оборванный блок
//  кода — берём всё до конца ответа, а не выбрасываем остаток как мусор.
//
//  Блочную структуру (заголовки/списки/код) парсим сами построчно — этого системный
//  парсер не рисует. А вот жирный, курсив, участок кода ВНУТРИ строки и ссылки —
//  готовый разбор Foundation (`AttributedString(markdown:)`), он уже умеет ровно то,
//  что нужно, и сторонней библиотеки для этого тащить не за чем.
//
//  Стекла здесь нет и быть не может — это контент ленты, а не плавающий слой
//  (см. docs/LIQUID-GLASS.md).
//

import SwiftUI

// MARK: - Разобранный документ

/// Один блок разобранного ответа модели.
enum MarkdownBlock {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case listItem(marker: String, text: AttributedString)
    /// `language` — то, что модель написала после открывающих ```, может быть пустым.
    case codeBlock(language: String?, code: String)
}

enum MarkdownDocument {

    /// Разобрать ответ модели на блоки. Построчный разбор — специально: маленькая
    /// модель не пишет вложенную разметку (цитаты внутри списков и т.п.), а построчный
    /// разбор проще и предсказуемее полноценного парсера CommonMark и не падает
    /// на половинчатом синтаксисе.
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.components(separatedBy: "\n")
        var index = 0
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: "\n")
            blocks.append(.paragraph(inline(text)))
            paragraphLines.removeAll()
        }

        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Пустая строка — граница абзаца, сама по себе блоком не становится.
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Блок кода: ```язык (необязателен) … закрывающие ```.
            if let language = codeFenceLanguage(trimmed) {
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces) == "```" {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                // Нет закрывающих ``` — не беда: модель просто оборвалась на середине
                // блока кода (кончился лимит ответа). Берём всё, что успела написать,
                // до конца сообщения, а не превращаем хвост ответа в мусор со звёздочками.
                blocks.append(.codeBlock(language: language.isEmpty ? nil : language,
                                          code: codeLines.joined(separator: "\n")))
                continue
            }

            // Заголовок: от одной до шести решёток и пробел.
            if let heading = headingInfo(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: inline(heading.text)))
                index += 1
                continue
            }

            // Элемент списка: «- », «* », «+ » или «12. ».
            if let item = listItemInfo(trimmed) {
                flushParagraph()
                blocks.append(.listItem(marker: item.marker, text: inline(item.text)))
                index += 1
                continue
            }

            paragraphLines.append(rawLine)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// `nil` — не открывающая строка блока кода. `""` — открывающая строка без имени языка.
    private static func codeFenceLanguage(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("```") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    private static func headingInfo(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        var rest = Substring(trimmed)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0 else { return nil }
        // «#хэштег» без пробела после решёток — не заголовок, а обычный текст.
        guard rest.isEmpty || rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func listItemInfo(_ trimmed: String) -> (marker: String, text: String)? {
        for bullet in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(bullet) {
                // Хвост подрезаем: модели любят писать «*   текст» с несколькими
                // пробелами после звёздочки, а эти пробелы разбор строки сохраняет —
                // и текст пункта уезжал вправо от своего же маркера рваной лесенкой.
                let text = trimmed.dropFirst(bullet.count).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return ("•", text)
            }
        }
        // «12. текст» — нумерованный пункт. Ищем первую «. » и проверяем, что перед
        // ней только цифры — иначе «3.5 кг стали» превратилось бы в список.
        guard let dotSpace = trimmed.range(of: ". ") else { return nil }
        let numberPart = trimmed[trimmed.startIndex..<dotSpace.lowerBound]
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber) else { return nil }
        let text = trimmed[dotSpace.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return ("\(numberPart).", text)
    }

    /// Жирный/курсив/код в строке/ссылки — системным разбором Foundation.
    ///
    /// ⚠️ `.returnPartiallyParsedIfPossible` — ровно для случая незакрытой звёздочки:
    /// Apple сама называет эту настройку решением для «текста, который ещё печатается»
    /// (наш случай — маленькая модель, а не потоковый вывод, но природа та же:
    /// синтаксис недописан). Если даже с этим разбор не удался — берём текст как есть,
    /// без единой попытки показать пустоту вместо ответа модели.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: text, options: options) {
            return parsed
        }
        return AttributedString(text)
    }
}

// MARK: - Показ разобранного документа

/// Показывает разобранный ответ модели: заголовки скромным шрифтом, списки
/// с маркером, абзацы с жирным/курсивом/кодом в строке/ссылками, блоки кода —
/// моноширинным шрифтом с прокруткой вбок и кнопкой «Скопировать».
struct MarkdownContent: View {

    let blocks: [MarkdownBlock]
    /// Цвет обычного текста пузыря (свой/чужой — разный).
    let textColor: Color
    /// Цвет ссылок и кнопки «Показать полностью» — тоже разный для своего/чужого пузыря.
    let linkColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(styled(text))
                .font(.body)
                .foregroundStyle(textColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(styled(text))
                .font(headingFont(level))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 2 : 0)

        case .listItem(let marker, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(marker)
                    .font(.body)
                    .foregroundStyle(textColor.opacity(0.7))
                    .frame(minWidth: Theme.Metrics.compactIconGutterWidth, alignment: .leading)
                Text(styled(text))
                    .font(.body)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .codeBlock(let language, let code):
            MarkdownCodeBlockView(language: language, code: code)
        }
    }

    /// Заголовки — скромные: это ответ в пузыре чата на телефоне, а не документ
    /// на мониторе. Даже первый уровень лишь немного заметнее обычного текста.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return Theme.Fonts.sectionTitle       // .headline — как заголовок карточки
        case 2:  return .subheadline.bold()
        default: return .footnote.bold()
        }
    }

    /// Доводка разобранной строки: ссылки — своим цветом, кусок кода в обратных
    /// кавычках — моноширинным шрифтом.
    ///
    /// Ссылки красим потому, что иначе они лежат тем же цветом, что и текст вокруг,
    /// и на пузыре не видно, что по ним вообще можно нажать.
    ///
    /// ⚠️ Моноширинный шрифт куску кода назначаем ЗДЕСЬ, руками. Системный разбор
    /// обратные кавычки съедает и помечает кусок как код, но сам шрифт при показе
    /// не меняет — и «прочитал файл `03-здоровье.md`» выглядел как обычная фраза,
    /// в которой просто пропали кавычки. Ставим шрифт явно: если система когда-то
    /// начнёт делать это сама, вид от нашей строчки не изменится.
    ///
    /// Диапазоны сперва собираем, потом применяем: менять строку прямо в обходе её
    /// же кусков — способ однажды получить съехавшие границы на ровном месте.
    private func styled(_ text: AttributedString) -> AttributedString {
        var copy = text
        let linkRanges = copy.runs.filter { $0.link != nil }.map(\.range)
        let codeRanges = copy.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)

        for range in linkRanges { copy[range].foregroundColor = linkColor }
        for range in codeRanges { copy[range].font = Theme.Fonts.code }
        return copy
    }
}

// MARK: - Блок кода

/// Блок кода: моноширинный шрифт, прокрутка ВБОК для длинных строк, кнопка
/// «Скопировать». Прокручивается только сам блок — пузырь и лента чата остаются
/// на месте: строка кода не оборачивается, а уезжает за край и тянется пальцем.
private struct MarkdownCodeBlockView: View {

    let language: String?
    let code: String

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.bold())
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            HStack(alignment: .center, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(Theme.Fonts.code)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        // ⚠️ Строка НЕ переносится — именно это и даёт горизонтальную
                        // прокрутку вместо переноса на десять строк или растягивания
                        // пузыря на весь экран.
                        .fixedSize()
                }
                // ⚠️ ЭТО ЕДИНСТВЕННОЕ МЕСТО ВО ВСЁМ ПРИЛОЖЕНИИ, ГДЕ ЧТО-ТО ЕЗДИТ ВБОК.
                // По умолчанию прокрутка пружинит ВСЕГДА — даже когда возить нечем:
                // короткая строка кода всё равно уползала бы за пальцем и возвращалась.
                // Со стороны это ровно та жалоба, ради которой заведён раздел 3
                // дорожной карты: «свайп влево-вправо таскает текст». Пружиним только
                // тогда, когда строка действительно длиннее пузыря.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                Button {
                    copy()
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(width: Theme.Metrics.minimumTapTarget,
                               height: Theme.Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "Код скопирован" : "Скопировать код")
            }
        }
        .padding(.horizontal, Theme.Metrics.toolRowPaddingHorizontal)
        .padding(.vertical, Theme.Metrics.toolRowPaddingVertical)
        .background(Theme.Colors.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.diffCorner, style: .continuous))
    }

    /// Тот же единственный вход в буфер обмена, что и у остальной ленты
    /// (`DiagnosticsClipboard` в EngineJournalSheet.swift) — своего `UIPasteboard`
    /// здесь не заводим.
    private func copy() {
        DiagnosticsClipboard.copy(code)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}
