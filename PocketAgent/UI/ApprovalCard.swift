//
//  ApprovalCard.swift
//  PocketAgent
//
//  ГЛАВНЫЙ экран продукта: карточка предложенной правки.
//  Пока человек не нажал «Применить», на диск ничего не записывается.
//
//  Задача карточки — чтобы на маленьком экране одним взглядом читалось:
//  какой файл · новый он или существующий · сколько строк прибавится и убавится ·
//  что именно меняется · и две крупные кнопки под палец.
//
//  ⚠️ Карточка — это КОНТЕНТ, а не плавающий навигационный слой,
//  поэтому стекла на ней нет и быть не должно: только Theme.surface.
//
//  ⚠️ ЗАПИСЬ ФАЙЛА НАЧИНАЕТСЯ РОВНО В ОДНОМ МЕСТЕ ЭТОГО ФАЙЛА — в действии кнопки
//  «Применить» (`approveButton`). Больше `onApprove` не зовёт никто: ни жест,
//  ни меню по долгому нажатию, ни анимация, ни двойное нажатие. Меню карточки
//  умеет только копировать и показывать. Проверяется поиском: вне комментариев
//  `onApprove` встречается ДВАЖДЫ — объявление свойства и одна-единственная кнопка.
//
//  ⚠️ ЧТО ЧЕЛОВЕК ДОЛЖЕН ПОНЯТЬ ЗА ОДИН ВЗГЛЯД (сверху вниз, в этом порядке):
//  1) у него спрашивают — плашка «Нужно ваше решение»;
//  2) какой файл и где лежит — крупное имя и путь под ним;
//  3) насколько крупная правка — «+12 −3» и строка «Меняются строки 12–18 и 40–44.
//     Было 42 строки, станет 45»;
//  4) не сносит ли она полфайла — красная рамка и отдельная фраза;
//  5) что именно меняется — сам дифф;
//  6) две кнопки.
//
//  ⚠️⚠️ ДО КНОПОК ОБЯЗАНО ХВАТАТЬ ЭКРАНА. Снимок с симулятора 09.08.2026 (iPhone 17 Pro,
//  iOS 26.3) показал карточку, у которой «Отклонить» и «Применить» уехали под панель
//  ввода и под вкладки: видно размытые пятна, надписи не читаются, нажать нельзя.
//  Виноваты были две вещи сразу, и починены обе: панель ввода теперь на время решения
//  с экрана убирается (ChatView.bottomLayer), а дифф на карточке подрезан до
//  `cardDiffLines` строк вместо 28. Карточка — место, где РЕШАЮТ; читать файл целиком
//  здесь не нужно, для этого есть «Показать весь дифф» отдельной страницей.
//  Делая карточку выше (новая строка, новый значок, больше диффа), проверяй снимком,
//  что кнопки по-прежнему видны целиком — иначе ломается главное обещание продукта.
//

import SwiftUI

struct ApprovalCard: View {

    /// О чём спрашивают. Карточка одна на оба случая — и это главное:
    /// возврат правки для человека выглядит ровно так же, как сама правка,
    /// потому что это то же самое решение о его файлах.
    enum Intent {
        /// Правку предложила модель.
        case change
        /// Возврат к прежнему тексту файла.
        case undoRestore
        /// Возврат правки, которая создала файл: возврат его удалит.
        case undoDelete

        var isUndo: Bool { self != .change }
    }

    let action: PendingAction
    let isApplying: Bool
    /// По умолчанию — обычная правка от модели: так эту карточку зовут почти везде.
    var intent: Intent = .change
    let onApprove: () -> Void
    let onReject: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Длинный текстовый предпросмотр открыт отдельной страницей.
    @State private var isFullTextShown = false
    /// Дифф открыт целиком отдельной страницей (пункт меню по долгому нажатию).
    @State private var isFullDiffShown = false
    /// Счётчик копирований — по нему даём короткий отклик в палец.
    @State private var copyCount = 0

    /// Плитка с иконкой файла. Растёт вместе с системным шрифтом — иначе рядом
    /// с раздутым заголовком она оставалась крошечной.
    @ScaledMetric(relativeTo: .title3) private var fileIconSize: CGFloat
        = Theme.Metrics.circleButtonSize

    /// Сколько строк текстового предпросмотра показываем прямо в карточке.
    private static let previewLineLimit = 14

    /// Сколько строк диффа показываем прямо в карточке. Остальное — по кнопке
    /// «Показать весь дифф», отдельной страницей со своей прокруткой.
    ///
    /// ⚠️ ЭТО ЧИСЛО РЕШАЕТ, ВИДНО ЛИ ВООБЩЕ КНОПКИ. Раньше здесь работало значение
    /// по умолчанию — 28 строк, — и карточка не помещалась на экран ни при каких
    /// условиях: на снимке 09.08.2026 (iPhone 17 Pro) человек видел шапку, дифф
    /// и обрезанные снизу кнопки. Кнопки — это и есть карточка; дифф на ней нужен,
    /// чтобы решить, а не чтобы читать файл целиком. Число то же, что и у диффа
    /// в ленте (`ChatMessageRow.timelineDiffLines`), — на одном экране два разных
    /// показа одного и того же диффа выглядели бы случайностью.
    private static let cardDiffLines = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            attentionBadge
            // Меню по долгому нажатию висит на ШАПКЕ, а не на всей карточке:
            // ниже лежат кнопки решения и раскрывающиеся куски диффа, и долгое
            // нажатие по ним должно означать ровно то, что означает, — ничего.
            head
                .contextMenu { headMenu }
            previewBody
            footer
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner, style: .continuous)
                .stroke(borderColor.opacity(isApplying ? 0.0 : borderOpacity),
                        lineWidth: Theme.Metrics.hairlineWidth)
        )
        // Карточка — единый смысловой блок для VoiceOver: сначала он слышит,
        // что именно ему предлагают, и только потом ходит по строкам диффа.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        // «Жду решения» → «Применяю»: рамка гаснет, кнопки сменяются надписью
        // с кружком ожидания. Плавно и быстро — но самое главное, НА МЕСТЕ:
        // высота карточки при этом почти не меняется, и лента не дёргается
        // ровно в тот момент, когда человек смотрит на свой файл.
        .animation(motion(Theme.Motion.smooth), value: isApplying)
        // ⚠️ Тактильного отклика НА НАЖАТИЕ здесь НЕТ намеренно.
        // Он даётся по ИСХОДУ действия и живёт на экране чата (ChatView.outcomeToken):
        // карточка знает только про начало записи, а «успех» в палец в момент нажатия —
        // это враньё, если запись потом упадёт. Отклик ниже — только на копирование
        // из меню: там действие и правда закончилось в тот же миг.
        .sensoryFeedback(.success, trigger: copyCount)
        // Весь дифф целиком — отдельной страницей, из меню по долгому нажатию.
        .sheet(isPresented: $isFullDiffShown) {
            if let diff = fileDiff {
                FullDiffSheet(diff: diff)
            }
        }
    }

    /// Анимация, которой может и не быть: при включённом «Уменьшении движения»
    /// возвращаем nil, и SwiftUI меняет состояние мгновенно.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// В буфер обмена уходит РОВНО то, что показано, без невидимых мест переноса.
    private func copy(_ text: String) {
        DiagnosticsClipboard.copy(text)
        copyCount += 1
    }

    /// Что услышит человек, попав на карточку: файл и масштаб правки одной фразой.
    private var accessibilitySummary: String {
        switch action.preview {
        case .diff(let diff):
            // Предупреждение о массовом удалении читается ВСЛУХ тоже: незрячий человек
            // мелкие счётчики не видит вообще, и без этой фразы он подтверждал бы
            // удаление половины файла, ничего о нём не услышав.
            let warning = diff.massiveRemovalNotice.map { " \($0)" } ?? ""
            // Место правки читается вслух наравне с масштабом: «в каких строках» —
            // такой же ответ на «пускать ли это в мои файлы», как «сколько строк».
            let scope = scopeText(for: diff).map { " \($0)" } ?? ""
            let opening: String
            switch intent {
            case .change:      opening = "Предложенная правка файла \(diff.relativePath): "
            case .undoRestore: opening = "Возврат файла \(diff.relativePath) к прежнему тексту: "
            case .undoDelete:  opening = "Возврат удалит файл \(diff.relativePath): "
            }
            return opening
                + "добавится строк \(diff.addedCount), удалится строк \(diff.removedCount)."
                + scope
                + warning
                + " Нужно ваше решение."
        case .text:
            return "\(action.title). Нужно ваше решение."
        }
    }

    /// Дифф этой правки, если действие — запись файла.
    private var fileDiff: FileDiff? {
        if case .diff(let diff) = action.preview { return diff }
        return nil
    }

    /// Рамка карточки. У правки, которая сносит треть файла и больше, она красная
    /// и заметная — это не украшение, а единственное отличие такой карточки от обычной.
    private var borderColor: Color {
        (fileDiff?.isMassiveRemoval ?? false) ? Theme.Colors.danger : Theme.Colors.warning
    }

    private var borderOpacity: Double {
        (fileDiff?.isMassiveRemoval ?? false) ? 0.9 : 0.35
    }

    // MARK: - «Нужно ваше решение»

    private var attentionBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.raised.fill")
                .font(.caption2)
            Text("Нужно ваше решение")
                .font(.caption.bold())
        }
        .foregroundStyle(Theme.Colors.warning)
        .padding(.horizontal, Theme.Metrics.badgePaddingHorizontal)
        .padding(.vertical, Theme.Metrics.badgePaddingVertical)
        .background(Theme.Colors.warning.opacity(0.14), in: Capsule())
    }

    // MARK: - Шапка: что за файл и насколько меняется

    @ViewBuilder
    private var head: some View {
        switch action.preview {
        case .diff(let diff):
            VStack(alignment: .leading, spacing: 10) {
                fileLine(for: diff)
                countersLine(for: diff)

                // ⚠️ ГДЕ ИМЕННО МЕНЯЕТСЯ ФАЙЛ — ОДНОЙ ФРАЗОЙ, ДО ВСЯКОГО ДИФФА.
                // Счётчики «+12 −3» говорят, СКОЛЬКО, но не говорят, ГДЕ: правка
                // в трёх строках посреди файла и правка, переписывающая его целиком,
                // выглядели одинаково, пока человек не долистает дифф. Здесь сразу
                // видно и место («строки 12–18 и 40–44»), и масштаб («было 42, станет 45»).
                if let scope = scopeText(for: diff) {
                    Text(scope)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // ⚠️ САМЫЙ ОПАСНЫЙ СЛУЧАЙ ПРОДУКТА, И ГОВОРИМ О НЁМ ПРЯМО.
                // Модель прочитала файл не целиком и вернула «полное» содержимое из тех
                // строк, что видела, — то есть предлагает снести остальное. Мелкие
                // счётчики «+3 −180» человек на ходу не читает; здесь нужна фраза.
                if let notice = diff.massiveRemovalNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.bold())
                        .foregroundStyle(Theme.Colors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // ⚠️ ПРО НЕВОЗМОЖНОСТЬ ВЕРНУТЬ ГОВОРИМ ДО НАЖАТИЯ, А НЕ ПОСЛЕ.
                // Прежнее содержимое приложение сохраняет само, но у очень большого
                // файла — не сохраняет (RestorePointStore.maxTextBytes). Узнать об этом
                // из отсутствия кнопки «Вернуть, как было» человек не должен: обещание
                // отменяемости либо честное, либо его нет.
                if let notice = undoUnavailableNotice(for: diff) {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Главное обещание продукта — на самом видном месте, а не в мелком примечании.
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .font(.title3.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// «Вернуть, как было» после этой правки не получится — и вот почему.
    /// nil — получится (или спрашивают уже про сам возврат).
    private func undoUnavailableNotice(for diff: FileDiff) -> String? {
        guard intent == .change, !diff.isNewFile else { return nil }
        guard !RestorePointStore.canKeep(previousText: diff.oldText) else { return nil }
        return UndoTexts.tooBigToKeep
    }

    private func fileLine(for diff: FileDiff) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: diff.isNewFile ? "doc.badge.plus" : "doc.text")
                // Роль, а не размер в точках: иконка растёт вместе с заголовком.
                .font(.title3.weight(.semibold))
                .foregroundStyle(diff.isNewFile ? Theme.added : Theme.textPrimary)
                .frame(width: fileIconSize, height: fileIconSize)
                .background(Theme.surfaceHigh,
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.diffCorner, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                // Имя файла — в одну строку и с обрезкой ПОСЕРЕДИНЕ: у длинного имени
                // важны и начало, и расширение в конце, а не первые двадцать знаков.
                Text(fileName(of: diff.relativePath))
                    .font(.title3.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                pathLine(for: diff.relativePath)
            }

            Spacer(minLength: 0)
        }
        // Имя и путь читаются одной фразой, а не по кусочкам.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Файл \(diff.relativePath)")
    }

    // MARK: - Меню по долгому нажатию

    /// ⚠️ ЗДЕСЬ ТОЛЬКО «СКОПИРОВАТЬ» И «ПОКАЗАТЬ». Пункта, который применяет правку,
    /// в этом меню нет и быть не может: применение живёт ровно за кнопкой «Применить»,
    /// и другого пути к записи файла в приложении не существует.
    @ViewBuilder
    private var headMenu: some View {
        switch action.preview {
        case .diff(let diff):
            Button {
                copy(diff.relativePath)
            } label: {
                Label("Скопировать путь к файлу", systemImage: "text.quote")
            }

            // ⚠️ Подпись честная: это ещё НЕ содержимое файла на диске, а то, что
            // модель предлагает записать. Пока «Применить» не нажато, на диске старое.
            if !diff.newText.isEmpty {
                Button {
                    copy(diff.newText)
                } label: {
                    Label("Скопировать предложенный текст", systemImage: "doc.on.doc")
                }
            }

            if !diff.hunks.isEmpty {
                Button {
                    isFullDiffShown = true
                } label: {
                    Label("Показать все изменения", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }

        case .text(_, let text):
            if !text.isEmpty {
                Button {
                    copy(text)
                } label: {
                    Label("Скопировать текст", systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// Где лежит файл.
    ///
    /// ⚠️ Путь и фраза обычным языком — РАЗНЫЕ вещи, и набраны они по-разному.
    /// Путь — тем же моноширинным, что и код (для него в Theme специально заведён
    /// `Fonts.code`), в две строки и с обрезкой С ГОЛОВЫ: в глубокой вложенности
    /// важен хвост `.../Header/index.tsx`, а не первые буквы. Для корня папки
    /// остаётся человеческая фраза — и она набрана обычным шрифтом и тише,
    /// чтобы «путь» и «не путь» различались с первого взгляда.
    @ViewBuilder
    private func pathLine(for path: String) -> some View {
        if let folder = directory(of: path) {
            // ⚠️ `PathDisplay.wrappable` добавляет НЕВИДИМЫЕ места переноса после «/»,
            // «_» и «-». Без них длинный путь рвался посреди имени папки — читать его
            // на карточке, где решают судьбу файла, было мучением. В буфер обмена
            // и в озвучку уходит чистый путь (см. `headMenu` и `fileLine`).
            Text(PathDisplay.wrappable(folder))
                .font(Theme.Fonts.code)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("в корне папки проекта")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Где и насколько меняется файл

    /// Одна фраза о месте и масштабе правки: «Меняются строки 12–18 и 40–44.
    /// Было 42 строки, станет 45». Для нового файла — «Новый файл — 45 строк».
    /// `nil` — сказать нечего (изменений построчно нет, об этом скажет сам дифф).
    private func scopeText(for diff: FileDiff) -> String? {
        let after = Self.lineCount(in: diff.newText)

        // Файл не «станет пустым», а исчезнет — путать это нельзя.
        if intent == .undoDelete {
            return "Файл исчезнет целиком — сейчас в нём \(HumanFormat.lines(diff.oldLineCount))."
        }
        if diff.isNewFile {
            return "Новый файл — \(HumanFormat.lines(after))."
        }
        guard !diff.hunks.isEmpty else { return nil }

        var phrase = ""
        if let places = Self.changedPlacesText(diff.hunks) {
            phrase += "Меняются строки \(places). "
        }
        phrase += "Было \(HumanFormat.lines(diff.oldLineCount)), станет \(after)."
        return phrase
    }

    /// Перечисление мест правки по номерам строк НОВОГО файла: «12–18 и 40–44».
    ///
    /// ⚠️ Границы берутся из кусков диффа, а не из отдельных строк. У удалённой строки
    /// номера в новом файле нет вовсе, и складывать её старый номер с новыми номерами
    /// соседей — значит показать человеку место, которого не существует.
    /// Куски чуть шире самой правки (в них входит и контекст) — зато честны.
    private static func changedPlacesText(_ hunks: [DiffHunk]) -> String? {
        guard !hunks.isEmpty else { return nil }

        let places = hunks.map { hunk -> String in
            let start = max(hunk.newStart, 1)
            let end = hunk.newCount > 0 ? start + hunk.newCount - 1 : start
            return end > start ? "\(start)–\(end)" : "\(start)"
        }

        // Больше трёх мест в строку не влезает и читаться перестаёт —
        // тогда честнее назвать первые два и сказать, сколько осталось.
        guard places.count > 3 else { return listed(places) }
        let rest = places.count - 2
        return listed(Array(places.prefix(2)))
            + " и ещё \(rest) " + HumanFormat.plural(rest, "место", "места", "мест")
    }

    /// «12–18» · «12–18 и 40–44» · «12–18, 40–44 и 70».
    private static func listed(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " и " + last
    }

    /// Сколько строк в тексте. Считаем так же, как `FileDiff.oldLineCount`,
    /// иначе «было» и «станет» мерились бы разными линейками.
    private static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        for character in text where character == "\n" { count += 1 }
        if text.hasSuffix("\n") { count -= 1 }
        return max(0, count)
    }

    private func countersLine(for diff: FileDiff) -> some View {
        HStack(spacing: 6) {
            if diff.isNewFile {
                badge(text: "новый файл", color: Theme.bubbleUser)
            }
            badge(text: "+\(diff.addedCount)", color: Theme.added)
            badge(text: "−\(diff.removedCount)", color: Theme.removed)
            Spacer(minLength: 0)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold().monospacedDigit())
            .padding(.horizontal, Theme.Metrics.badgePaddingHorizontal)
            .padding(.vertical, Theme.Metrics.badgePaddingVertical)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    /// Имя файла без папок. Разбор пути живёт в одном месте — `PathDisplay`.
    private func fileName(of path: String) -> String {
        PathDisplay.fileName(of: path)
    }

    /// Папка, в которой лежит файл. `nil` — файл в корне проекта: там показываем
    /// не путь, а фразу обычным языком, и набирается она иначе (см. `pathLine`).
    private func directory(of path: String) -> String? {
        PathDisplay.directory(of: path)
    }

    private var subtitle: String {
        // Возврат объясняется своими словами: «файл будет перезаписан целиком» —
        // правда, но человеку в этот момент важно совсем другое.
        switch intent {
        case .undoRestore: return UndoTexts.restoreSubtitle
        case .undoDelete:  return UndoTexts.deleteSubtitle
        case .change:      break
        }
        switch action.invocation.kind {
        case .some(.writeFile):
            return "Файл будет перезаписан целиком. До вашего согласия на диске ничего не меняется."
        case .some(.readFile):
            return "Агент хочет прочитать файл."
        case .some(.listFiles):
            return "Агент хочет посмотреть список файлов."
        case .some(.webSearch):
            // Сюда карточка подтверждения не попадает: поиск выполняется сразу,
            // как список файлов и чтение. Ветка нужна для полноты разбора.
            return "Агент хочет поискать в интернете."
        case .some(.finish):
            return "Агент считает задачу выполненной."
        case .none:
            return "Непонятное действие: \(action.invocation.rawName)"
        }
    }

    // MARK: - Тело предпросмотра

    @ViewBuilder
    private var previewBody: some View {
        switch action.preview {
        // ⚠️ `text` — имя переменной специально НЕ `body`: так называется свойство самой
        // вьюхи, и затенение сбивает вывод типов на ровном месте при следующей правке.
        case .text(let title, let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)

                // Своей прокрутки у предпросмотра нет: он лежит внутри ленты чата,
                // и вложенный вертикальный скролл забирал бы жест себе — палец над
                // предпросмотром переставал прокручивать ленту.
                VStack(alignment: .leading, spacing: 8) {
                    Text(text.isEmpty ? "(пусто)" : text)
                        .font(Theme.Fonts.code)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(Self.previewLineLimit)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if lineCount(of: text) > Self.previewLineLimit {
                        Button {
                            isFullTextShown = true
                        } label: {
                            Text("Показать целиком")
                                .font(Theme.Fonts.caption.bold())
                                // Площадь касания по норме Apple: надпись мелкая,
                                // а промахиваться по ней нельзя — без неё не увидеть,
                                // что именно применяется.
                                .frame(minHeight: Theme.Metrics.minimumTapTarget,
                                       alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.bubbleUser)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.diffBlockBackground,
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.diffCorner, style: .continuous))
            }
            .sheet(isPresented: $isFullTextShown) {
                FullTextSheet(title: title, text: text)
            }

        case .diff(let diff):
            // Имя файла и счётчики уже показаны крупно в шапке — здесь только сам дифф,
            // и ровно столько строк, чтобы кнопки решения оставались достижимы (см.
            // `cardDiffLines`). Что не поместилось — за кнопкой «Показать весь дифф».
            DiffPreviewView(diff: diff,
                            visibleLineLimit: Self.cardDiffLines,
                            showsFileHeader: false)
        }
    }

    /// Сколько строк в тексте — по этому решаем, нужна ли кнопка «Показать целиком».
    private func lineCount(of text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: - Кнопки

    @ViewBuilder
    private var footer: some View {
        if isApplying {
            HStack(spacing: 10) {
                ProgressView()
                Text(intent.isUndo ? "Возвращаю…" : "Применяю…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    // ⚠️ minHeight, а не height. С жёсткой высотой надпись при крупном
                    // шрифте переносилась на вторую строку и обрезалась по вертикали —
                    // ровно в тот момент, когда человеку важнее всего понимать,
                    // что происходит с его файлом.
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // ⚠️ Та же высота, что и у пары кнопок, — поэтому подмена «кнопки →
            // применяю» не двигает ни карточку, ни ленту под ней.
            .frame(minHeight: Self.actionButtonHeight)
            .transition(.opacity)
        } else {
            // ⚠️ Две главные надписи продукта не сжимаются и не обрезаются.
            // Раньше у «Отклонить» стояли жёсткие 140 точек ширины и сжатие до 80 % —
            // при крупном шрифте человек видел «Откло…» и «Приме…», причём разным
            // кеглем. Теперь: не помещаются в строку — встают друг под друга,
            // главное действие сверху.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    rejectButton
                    approveButton
                }
                VStack(spacing: 10) {
                    approveButton
                    rejectButton
                }
            }
            .controlSize(.large)
            .transition(.opacity)
        }
    }

    /// Высота обеих кнопок решения — одна на всех, чтобы они читались парой.
    private static let actionButtonHeight: CGFloat = 54

    /// Главная кнопка называет РЕЗУЛЬТАТ, а не действие вообще: «Применить» —
    /// про правку, «Вернуть» — про возврат, «Удалить файл» — про то, что файл
    /// исчезнет. Одно слово «Применить» на все три случая было бы уклончивым
    /// ровно там, где человек решает судьбу своего файла.
    private var approveTitle: String {
        switch intent {
        case .change:      return "Применить"
        case .undoRestore: return "Вернуть"
        case .undoDelete:  return "Удалить файл"
        }
    }

    private var approveIcon: String {
        switch intent {
        case .change:      return "checkmark"
        case .undoRestore: return "arrow.uturn.backward"
        case .undoDelete:  return "trash"
        }
    }

    /// «Отклонить» — второстепенное действие, поэтому обводка, а не заливка.
    /// У возврата второстепенное — «Отмена»: отклонять человеку тут нечего,
    /// он отказывается от собственного решения, а не от предложения модели.
    private var rejectButton: some View {
        Button(action: onReject) {
            Label(intent.isUndo ? "Отмена" : "Отклонить", systemImage: "xmark")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: Self.actionButtonHeight)
        }
        .buttonStyle(.bordered)
        .tint(Theme.textSecondary)
    }

    private var approveButton: some View {
        Button(action: onApprove) {
            Label(approveTitle, systemImage: approveIcon)
                .font(.headline)
                // ⚠️ Без этих двух строк подпись переносится как «Приме-нить»:
                // на снимке с симулятора именно так и вышло. Слово короткое,
                // лучше слегка ужать шрифт, чем рвать его дефисом пополам.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: Self.actionButtonHeight)
        }
        .buttonStyle(.borderedProminent)
        // Синий — цвет главного действия во всём приложении (так же выглядят
        // свои пузыри и кнопка отправки).
        // ⚠️ Раньше здесь была зелёная заливка: белая подпись на ней читается
        // с контрастом около 2:1 при норме 4,5:1 — и это самая важная надпись
        // продукта. Зелёный остался там, где он значит «получилось»:
        // добавленные строки в диффе и статус «готово».
        .tint(Theme.Colors.accent)
    }
}

// MARK: - Дифф

/// Показ FileDiff: заголовок с файлом и счётчиками, дальше цветные строки.
/// Длинные куски без изменений сворачиваются, чтобы правка читалась целиком.
struct DiffPreviewView: View {

    let diff: FileDiff
    /// Сколько строк показывать сразу. `nil` — показать дифф целиком
    /// (так он выглядит на отдельной странице, у которой есть своя прокрутка).
    ///
    /// ⚠️ Своего `ScrollView` у диффа НЕТ и быть не должно: он лежит внутри ленты чата,
    /// а вложенная прокрутка той же оси забирает жест целиком — пока палец над диффом,
    /// лента не прокручивается вообще, и человек упирается в карточку.
    var visibleLineLimit: Int?
    /// Шапка с именем файла и счётчиками. В карточке подтверждения она своя, крупная.
    var showsFileHeader: Bool = true

    /// Развёрнутые вручную куски без изменений.
    @State private var expandedRuns: Set<String> = []
    /// Дифф открыт целиком отдельной страницей.
    @State private var isFullDiffShown = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ширина ОДНОГО знака в моноширинном шрифте строки диффа (`Theme.Fonts.diffLine`,
    /// это `.caption`) при обычном размере системного шрифта. Растёт вместе с ним.
    ///
    /// ⚠️ Ширина колонки номеров считается отсюда и от самого длинного номера
    /// в конкретном диффе. Раньше стояли жёсткие 30 точек: в файле длиннее тысячи
    /// строк номер туда не влезал, а при крупном шрифте не влезал и трёхзначный.
    @ScaledMetric(relativeTo: .caption) private var gutterDigitWidth: CGFloat = 9

    /// Со скольких подряд идущих неизменённых строк кусок сворачивается.
    private let collapseThreshold = 6

    /// Ширина колонки номеров: по самому длинному номеру этого диффа, но не уже двух знаков.
    private var gutterWidth: CGFloat {
        CGFloat(max(maxLineNumberDigits, 2)) * gutterDigitWidth
    }

    private var maxLineNumberDigits: Int {
        let largest = diff.hunks.reduce(1) { partial, hunk in
            max(partial,
                hunk.oldStart + hunk.oldCount,
                hunk.newStart + hunk.newCount)
        }
        return String(max(largest, 1)).count
    }

    /// Инициализатор задан явно: у типа есть приватные хранимые свойства,
    /// и полагаться на автоматический почленный конструктор здесь не стоит.
    init(diff: FileDiff, visibleLineLimit: Int? = 28, showsFileHeader: Bool = true) {
        self.diff = diff
        self.visibleLineLimit = visibleLineLimit
        self.showsFileHeader = showsFileHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsFileHeader {
                fileHeader
            }

            if diff.hunks.isEmpty {
                // ⚠️ «Построчных изменений нет» и «файл не изменится» — РАЗНЫЕ вещи.
                // Дифф считается по приведённым к одному виду строкам, а на диск уходит
                // сырой текст модели: файл с виндовыми переводами строк даёт пустой дифф,
                // но переписывается целиком. Об этом говорим прямо.
                if diff.hasInvisibleChangesOnly {
                    note("Строки не меняются, но текст на диске отличается: другие переводы строк или завершающий перенос. Файл будет переписан целиком.",
                         color: Theme.Colors.warning)
                } else {
                    note(diff.isNewFile
                         ? "Новый файл пока пустой."
                         : "Содержимое файла не меняется — записывать нечего.",
                         color: Theme.textSecondary)
                }
            } else {
                diffBlock
            }

            if diff.isTruncated {
                // Раньше здесь было просто «показана только часть» — из этого не следовало
                // главное: непоказанное всё равно применится. Теперь говорим прямо.
                note("Показана только часть изменений — правка слишком большая. Остальные изменения тоже будут применены, хотя здесь их не видно.",
                     color: Theme.Colors.warning)
            }

            if !diff.createdDirectories.isEmpty {
                note("Вместе с файлом появятся папки: \(diff.createdDirectories.joined(separator: ", "))",
                     color: Theme.textSecondary)
            }
        }
        .sheet(isPresented: $isFullDiffShown) {
            FullDiffSheet(diff: diff)
        }
    }

    // MARK: Блок с самим диффом

    /// Длинные строки переносим, а не прячем в горизонтальную прокрутку:
    /// на телефоне так читается лучше и не спорит с прокруткой ленты.
    private var diffBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleRows) { row in
                rowView(row)
                    // Раскрыли свёрнутый кусок — строки проявляются на месте.
                    // Только прозрачность: любой сдвиг здесь читался бы как
                    // «дифф уехал», а человек в этот момент сверяет строки.
                    .transition(.opacity)
            }

            if isTrimmed {
                moreButton
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.diffBlockBackground,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.diffCorner, style: .continuous))
        // ⚠️ Обрезка по той же форме обязательна. Подложка строки и цветная полоска
        // по левому краю идут во всю ширину блока — у скруглённых углов они вылезали
        // за подложку тонкой заусеницей. Заметно это ровно на первой и последней
        // строке диффа, то есть всегда.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.diffCorner, style: .continuous))
        // ⚠️ Потолок роста именно у блока диффа, а не у всей карточки.
        // Дальше accessibility1 на строку кода остаётся 8–9 знаков ширины, и каждая
        // строка файла разваливается на пять переносов — дифф перестаёт читаться как
        // дифф ровно у того, кто и включает крупный шрифт, чтобы прочитать код.
        // Весь дифф целиком при этом доступен отдельной страницей — там своя ширина.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// Показан не весь дифф — остальное открывается отдельной страницей.
    private var isTrimmed: Bool { visibleRows.count < allRows.count }

    private var moreButton: some View {
        Button {
            isFullDiffShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2.bold())
                Text("Показать весь дифф — ещё \(allRows.count - visibleRows.count) строк")
                Spacer(minLength: 0)
            }
            .font(Theme.Fonts.caption.bold())
            .foregroundStyle(Theme.bubbleUser)
            .padding(.horizontal, Theme.Metrics.toolRowPaddingHorizontal)
            .padding(.vertical, Theme.Metrics.diffNotePaddingVertical)
            .frame(maxWidth: .infinity,
                   minHeight: Theme.Metrics.minimumTapTarget,
                   alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Одна строка блока: заголовок куска, свёрнутый контекст или строка диффа.
    @ViewBuilder
    private func rowView(_ row: DiffRow) -> some View {
        switch row {
        case .hunkHeader(let hunk):   hunkHeader(hunk)
        case .collapsed(let run):     collapsedRow(run)
        case .line(let line):         lineRow(line)
        }
    }

    /// Что показываем: либо всё, либо первые `visibleLineLimit` строк.
    private var visibleRows: [DiffRow] {
        guard let limit = visibleLineLimit, allRows.count > limit else { return allRows }
        return Array(allRows.prefix(limit))
    }

    /// Дифф, разложенный в плоский список строк, — так его можно честно подрезать
    /// по числу строк, а не по высоте в точках.
    private var allRows: [DiffRow] {
        var rows: [DiffRow] = []
        for hunk in diff.hunks {
            rows.append(.hunkHeader(hunk))
            for run in runs(in: hunk) {
                if run.isCollapsible && !expandedRuns.contains(run.id) {
                    rows.append(.collapsed(run))
                } else {
                    rows.append(contentsOf: run.lines.map { DiffRow.line($0) })
                }
            }
        }
        return rows
    }

    /// Одна строка плоского списка.
    private enum DiffRow: Identifiable {
        case hunkHeader(DiffHunk)
        case collapsed(DiffRun)
        case line(DiffLine)

        var id: String {
            switch self {
            case .hunkHeader(let hunk): return "h\(hunk.id)"
            case .collapsed(let run):   return "c\(run.id)"
            case .line(let line):       return "l\(line.id)"
            }
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Шапка (для ленты чата)

    private var fileHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: diff.isNewFile ? "doc.badge.plus" : "doc.text")
                    .foregroundStyle(Theme.textSecondary)
                // Путь — моноширинным и с обрезкой С ГОЛОВЫ: в глубокой вложенности
                // важен хвост «…/Header/index.tsx», а не первые буквы.
                // Невидимые места переноса — путь переносится по папкам,
                // а не рвётся посреди имени (см. PathDisplay).
                Text(PathDisplay.wrappable(diff.relativePath))
                    .font(Theme.Fonts.code.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    // Вслух — чистый путь, без служебных знаков переноса.
                    .accessibilityLabel(diff.relativePath)
            }
            HStack(spacing: 6) {
                if diff.isNewFile {
                    smallBadge("новый файл", Theme.Colors.accent)
                }
                smallBadge("+\(diff.addedCount)", Theme.added)
                smallBadge("−\(diff.removedCount)", Theme.removed)
                Spacer(minLength: 0)
            }
        }
    }

    private func smallBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.bold().monospacedDigit())
            .padding(.horizontal, Theme.Metrics.badgePaddingHorizontal)
            .padding(.vertical, Theme.Metrics.badgePaddingVertical)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Куски и строки

    /// Заголовок куска: какие строки старого файла на какие строки нового заменяются.
    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        Text("строки \(hunk.oldStart)–\(hunk.oldStart + max(hunk.oldCount - 1, 0)) → \(hunk.newStart)–\(hunk.newStart + max(hunk.newCount - 1, 0))")
            // Роль, а не размер в точках: иначе заголовок куска не растёт
            // при увеличенном системном шрифте.
            .font(Theme.Fonts.diffLine.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Metrics.diffNotePaddingHorizontal)
            .padding(.vertical, Theme.Metrics.diffRowPaddingVertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hairline.opacity(0.7))
    }

    /// Кусок диффа: либо подряд идущие изменённые строки, либо подряд идущий контекст.
    private struct DiffRun: Identifiable {
        let id: String
        let lines: [DiffLine]
        let isCollapsible: Bool
    }

    /// Режем куски на «изменения» и «контекст», длинный контекст помечаем сворачиваемым.
    private func runs(in hunk: DiffHunk) -> [DiffRun] {
        var result: [DiffRun] = []
        var buffer: [DiffLine] = []
        var bufferIsContext = true

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(DiffRun(id: "\(hunk.id)-\(result.count)",
                                  lines: buffer,
                                  isCollapsible: bufferIsContext && buffer.count > collapseThreshold))
            buffer = []
        }

        for line in hunk.lines {
            let isContext = (line.kind == .context)
            if isContext != bufferIsContext {
                flush()
                bufferIsContext = isContext
            }
            buffer.append(line)
        }
        flush()
        return result
    }

    private func collapsedRow(_ run: DiffRun) -> some View {
        Button {
            expand(run)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
                Text("ещё \(run.lines.count) строк без изменений")
                    .font(Theme.Fonts.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Metrics.toolRowPaddingHorizontal)
            .padding(.vertical, Theme.Metrics.diffNotePaddingVertical)
            // Площадь касания по норме Apple: раскрыть кусок пальцем на ходу
            // раньше почти не получалось — вместо раскрытия лента прокручивалась.
            .frame(maxWidth: .infinity,
                   minHeight: Theme.Metrics.minimumTapTarget,
                   alignment: .leading)
            .background(Theme.hairline.opacity(0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Показать \(run.lines.count) строк без изменений")
    }

    /// Раскрыть свёрнутый кусок. При включённом «Уменьшении движения» — без анимации.
    private func expand(_ run: DiffRun) {
        if reduceMotion {
            _ = expandedRuns.insert(run.id)
        } else {
            withAnimation(Theme.Motion.expand) {
                _ = expandedRuns.insert(run.id)
            }
        }
    }

    private func lineRow(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(numberText(line.oldNumber))
                .frame(width: gutterWidth, alignment: .trailing)
                // ⚠️ Смысловая роль, а не белый с прозрачностью 32 %: тот давал
                // контраст около 2,8:1 при норме 4,5:1 — номера строк читались хуже
                // самого кода, и было не понять, к какой строке файла относится правка.
                .foregroundStyle(Theme.textSecondary)
            Text(numberText(line.newNumber))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .foregroundStyle(Theme.textSecondary)
            Text(marker(line.kind) + line.text)
                .foregroundStyle(textColor(line.kind))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.Fonts.diffLine)
        .padding(.vertical, Theme.Metrics.diffRowPaddingVertical)
        .padding(.horizontal, Theme.Metrics.diffRowPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Подсвечиваем ФОН всей строки, а не только текст: на телефоне так видно сразу.
        .background(background(line.kind))
        // ⚠️ Плюс яркая полоска по левому краю строки.
        // Подложки диффа намеренно приглушены, чтобы код на них читался, — но из-за
        // этого на ходу, одним взглядом, тёмно-зелёная строка от тёмно-красной
        // почти не отличается. Полоска в три точки отличается всегда: это и есть
        // ответ на «что добавилось, а что исчезло» без чтения знаков «+» и «−».
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(edgeColor(line.kind))
                .frame(width: 3)
        }
        // ⚠️ Строка диффа читается ОДНИМ элементом и говорит, добавлена она или
        // удалена. Раньше это были три отдельных Text: VoiceOver произносил
        // «14», «14», «TODO написать описание» — ни слова о том, что строка
        // УДАЛЯЕТСЯ. Человек подтверждал правку вслепую. Знак «−» (U+2212) в озвучку
        // не отдаём — синтезатор его проглатывает.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: line))
    }

    private func accessibilityLabel(for line: DiffLine) -> String {
        let number = line.newNumber ?? line.oldNumber
        let place = number.map { "Строка \($0)" } ?? "Строка"
        let content = line.text.trimmingCharacters(in: .whitespaces).isEmpty
            ? "пустая строка"
            : line.text
        switch line.kind {
        case .added:   return "\(place), добавлена: \(content)"
        case .removed: return "\(place), удалена: \(content)"
        case .context: return "\(place), без изменений: \(content)"
        }
    }

    private func numberText(_ value: Int?) -> String {
        guard let value else { return " " }
        return String(value)
    }

    private func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .added:   return "+ "
        case .removed: return "− "
        case .context: return "  "
        }
    }

    // Цвета строк диффа задаёт Theme — свои литералы тут заводить нельзя.
    private func textColor(_ kind: DiffLineKind) -> Color {
        Theme.Colors.diffText(for: kind)
    }

    private func background(_ kind: DiffLineKind) -> Color {
        Theme.Colors.diffRowBackground(for: kind)
    }

    /// Цвет полоски по левому краю строки. У неизменённой строки её нет.
    private func edgeColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added:   return Theme.added
        case .removed: return Theme.removed
        case .context: return .clear
        }
    }
}

// MARK: - Отдельные страницы для длинного предпросмотра

/// Весь дифф целиком — отдельной страницей со своей прокруткой.
///
/// Существует ради одного правила: внутри ленты чата вложенной вертикальной прокрутки
/// быть не должно. Длинный дифф не режем по высоте — открываем на всю страницу,
/// где прокрутка одна и она главная.
struct FullDiffSheet: View {

    let diff: FileDiff

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            // visibleLineLimit: nil — здесь дифф показывается целиком.
            DiffPreviewView(diff: diff, visibleLineLimit: nil)
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        // Шапка через safeAreaInset, а не поверх контента: иначе текст проезжает
        // прямо под кнопкой закрытия — тот же дефект, что был в чате.
        .safeAreaInset(edge: .top, spacing: 0) { SheetTopBar { dismiss() } }
        .preferredColorScheme(.dark)
    }
}

/// Длинный текстовый предпросмотр (список файлов, кусок файла) — отдельной страницей.
struct FullTextSheet: View {

    let title: String
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(text.isEmpty ? "(пусто)" : text)
                    .font(Theme.Fonts.code)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .safeAreaInset(edge: .top, spacing: 0) { SheetTopBar { dismiss() } }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Шапка страницы-шита

/// Один жест закрытия на все отдельные страницы: крестик справа сверху, по тому же
/// полю экрана, что и заголовок под ним.
///
/// ⚠️ Раньше эти страницы закрывались стрелкой `chevron.down` СЛЕВА, а «О программе» —
/// крестиком справа: три страницы, три разных способа. Плюс кнопка висела над обычной
/// прокруткой без подложки, и текст проезжал прямо под ней.
///
/// Тип намеренно виден только внутри этого файла: одноимённая шапка может появиться
/// и на других экранах, а два одинаковых имени в одном модуле — это провал сборки.
private struct SheetTopBar: View {

    let onClose: () -> Void

    /// Такое же мягкое растворение, как у верхней строки чата, — одно число на всех.
    private var fadeHeight: CGFloat { Theme.Metrics.topFadeHeight }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark",
                              accessibilityTitle: "Закрыть",
                              action: onClose)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
        .padding(.bottom, fadeHeight)
        .background(alignment: .top) { scrim }
        .accessibilitySortPriority(1)
    }

    /// Подложка — ТОЛЬКО для iOS 17–18.
    /// ⚠️ На iOS 26 своего фона позади стеклянной кнопки быть не должно: стеклу нечего
    /// сэмплить, кроме этого прямоугольника, и оно становится плоской тёмной таблеткой.
    /// Растворение края там делает система (`adaptiveScrollEdge` у самой страницы).
    @ViewBuilder
    private var scrim: some View {
        if !GlassAvailability.isLiquidGlassAvailable {
            VStack(spacing: 0) {
                Theme.background
                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: fadeHeight)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}

/// Имя из архитектурной карты.
typealias DiffView = DiffPreviewView
