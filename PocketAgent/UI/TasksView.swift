//
//  TasksView.swift
//  PocketAgent
//
//  Раздел «Задачи» — нижняя вкладка. Список того, что человек уже просил сделать
//  за этот запуск: текущая задача сверху, закрытые под ней.
//
//  ⚠️ ЧЕСТНАЯ ГРАНИЦА. Постоянной истории у приложения ПОКА НЕТ: переписка переживает
//  уход в фон, но список задач живёт только до закрытия приложения. Мы не притворяемся,
//  что храним его дольше, — это написано прямо на экране, последней строкой. Лучше
//  честно мало, чем сломано много: настоящее хранилище истории — отдельная большая
//  работа (docs/PRODUCT-PLAN.md, §3), и делать её наспех ради красивого списка нельзя.
//
//  ⚠️ Прошлая задача открывается НА ЧТЕНИЕ, продолжить её нельзя, и это решение,
//  а не недоделка: показанные тогда «до/после» строились по старому состоянию файлов,
//  применять их сегодня нельзя. Вместо продолжения — «Повторить задачу»: та же фраза
//  встаёт в поле ввода, разговор начинается заново.
//
//  Стекло — только на плавающем слое: нижние вкладки кладёт корневой экран, своей
//  панели у этого экрана нет вовсе. Карточки списка — обычные, без стекла.
//

import SwiftUI

struct TasksView: View {

    @ObservedObject var app: AppViewModel

    /// Открытая на чтение прошлая задача. nil — страница закрыта.
    @State private var openedTask: AppViewModel.SessionTask?

    var body: some View {
        // ⚠️ Своего фона во весь экран нет намеренно: его рисует корневой экран.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                header

                if let title = app.currentTaskTitle {
                    currentTaskCard(title)
                }

                if !app.finishedTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeading("Уже сделанное")
                        VStack(spacing: 10) {
                            ForEach(app.finishedTasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                }

                if isEmpty {
                    emptyState
                }

                newTaskButton
                // ⚠️ Оговорка про «до закрытия приложения» — про СПИСОК. Пустому списку
                // терять нечего, и на пустом экране это просто лишний абзац
                // (ROADMAP.md, §2: экран говорит только то, что нужно сейчас).
                if !isEmpty {
                    footnote
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { topLayer }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .preferredColorScheme(.dark)
        .sheet(item: $openedTask) { task in
            TaskTranscriptSheet(task: task) {
                openedTask = nil
                app.repeatTask(task)
            }
        }
    }

    // MARK: - Верхний слой

    /// Круглых кнопок у этого экрана нет — только растворение верхнего края, и только
    /// на iOS 17–18. ⚠️ На iOS 26 своего фона наверху быть не должно: край растворяет
    /// система (`adaptiveScrollEdge`), а лишний прямоугольник спорил бы со стеклом
    /// (docs/LIQUID-GLASS.md).
    @ViewBuilder
    private var topLayer: some View {
        if !GlassAvailability.isLiquidGlassAvailable {
            LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                           startPoint: .top,
                           endPoint: .bottom)
                .frame(height: Theme.Metrics.topFadeHeight)
                // Сплошная часть уходит ПОД часы и значки сети: их зона в безопасную
                // зону не входит, а закрывать её надо.
                .background {
                    Theme.background
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(false)
        }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Задачи")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.textPrimary)

            // Пока список пуст, эту же мысль говорит карточка «Задач пока нет» —
            // два одинаковых объяснения подряд читаются как ошибка вёрстки.
            if !isEmpty {
                Text("Что вы просили сделать за этот запуск.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        // Заголовок стоит под круглыми кнопками остальных экранов — здесь их нет,
        // поэтому воздух сверху добавляем сами.
        .padding(.top, Theme.Metrics.sectionSpacing)
    }

    // MARK: - Текущая задача

    private func currentTaskCard(_ title: String) -> some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .foregroundStyle(Theme.Colors.accent)
                Text("Сейчас в работе")
                    .font(Theme.Fonts.barLabel)
                    .foregroundStyle(Theme.Colors.accent)
            }

            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let folderName = app.folder?.displayName {
                Text("папка «\(folderName)»")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Button {
                app.selectTab(.chat)
            } label: {
                Label("Вернуться к ней", systemImage: "arrow.right.circle.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.textOnAccent)
            .background(Theme.Colors.accent, in: Capsule())
        }
    }

    // MARK: - Закрытые задачи

    private func taskRow(_ task: AppViewModel.SessionTask) -> some View {
        Button {
            openedTask = task
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Первая фраза человека дословно: своя формулировка узнаётся сразу,
                // а название от модели пришлось бы ещё и сверять с памятью.
                Text(task.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(subtitle(for: task))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Metrics.cardPadding)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
        .contextMenu {
            Button("Повторить задачу") { app.repeatTask(task) }
            Button("Убрать из списка", role: .destructive) { app.forgetTask(task) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Открыть на чтение")
    }

    /// «в 14:32 · папка «Сайт» · закончена»
    private func subtitle(for task: AppViewModel.SessionTask) -> String {
        var parts = [Self.timeFormatter.string(from: task.startedAt)]
        if let folderName = task.folderName {
            parts.append("папка «\(folderName)»")
        }
        parts.append(task.outcome)
        return parts.joined(separator: " · ")
    }

    /// Формат один на весь экран: создавать его на каждую строку списка дорого.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Пусто

    /// Списка нет вовсе: ни идущей задачи, ни закрытых.
    private var isEmpty: Bool {
        app.currentTaskTitle == nil && app.finishedTasks.isEmpty
    }

    /// ⚠️ ПУСТОЙ ЭКРАН БЕЗ ВЫХОДА — ТУПИК, И ЭТО САМАЯ ЧАСТАЯ ЖАЛОБА.
    /// Поэтому здесь всегда три вещи: что тут будет, чего сейчас не хватает и ОДНА
    /// кнопка, которая это решает. Кнопка ведёт туда, где лежит ближайший шаг:
    /// нет модели — в «Модели», нет папки — в «Папки», всё на месте — в чат.
    private var emptyState: some View {
        card {
            Text("Задач пока нет")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            Text(emptyDetail)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                app.selectTab(emptyStep.tab)
            } label: {
                Label(emptyStep.title, systemImage: emptyStep.icon)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.textOnAccent)
            .background(Theme.Colors.accent, in: Capsule())
        }
    }

    /// Одна строка «что здесь будет» — и честно о том, чего пока не хватает.
    private var emptyDetail: String {
        if !app.isModelReady && !app.isModelUnderway {
            return "Здесь будет всё, что вы просили сделать. Помощнику пока не с чем работать — нужен файл модели."
        }
        if app.folder == nil {
            return "Здесь будет всё, что вы просили сделать. Осталось выбрать папку, в которой работать."
        }
        return "Напишите помощнику, что сделать в папке, — задача появится здесь."
    }

    /// Ближайший шаг: куда вести и как назвать кнопку.
    private var emptyStep: (tab: AppViewModel.Tab, title: String, icon: String) {
        if !app.isModelReady && !app.isModelUnderway {
            return (.models, "Открыть «Модели»", "brain.head.profile")
        }
        if app.folder == nil {
            return (.projects, "Открыть «Папки»", "folder")
        }
        return (.chat, "Поставить задачу", "square.and.pencil")
    }

    // MARK: - Новая задача

    /// Кнопка живёт в контенте, а не на стекле: нижний плавающий слой занят вкладками.
    @ViewBuilder
    private var newTaskButton: some View {
        if app.currentTaskTitle != nil {
            Button {
                app.reset()
                app.selectTab(.chat)
            } label: {
                Label("Начать новую задачу", systemImage: "square.and.pencil")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .background(Theme.surface, in: Capsule())
            // Пока идёт ход, начинать заново нельзя: человек не увидит, чем кончилась
            // запись файла. Погашенная кнопка честнее живой, которая молча ничего не делает.
            .disabled(app.snapshot.isBusy)
            .opacity(app.snapshot.isBusy ? 0.5 : 1)
        }
    }

    private var footnote: some View {
        Text("Список живёт до закрытия приложения: постоянной истории задач пока нет — после перезапуска он будет пустым.")
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Metrics.cardPadding)
    }

    // MARK: - Мелочи

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(Theme.Fonts.sectionTitle)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Metrics.cardPadding)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: - Прошлая задача на чтение

/// Страница прошлой задачи. Только чтение: кнопок «Применить» и «Отклонить» здесь нет
/// и быть не может — правка строилась по тому состоянию файлов, которого уже нет.
struct TaskTranscriptSheet: View {

    let task: AppViewModel.SessionTask
    let onRepeat: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(Theme.Fonts.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(task.outcome)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                ForEach(task.messages) { message in
                    // Кнопки «Поделиться» здесь нет намеренно: файл мог с тех пор
                    // измениться или исчезнуть, а обещать его — обман.
                    ChatMessageRow(message: message)
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        // ⚠️ Обе вставки безопасной зоны — прямо на ScrollView и ПЕРВЫМИ, до эффекта
        // края: только тогда место под крестик и под панель резервируется по их
        // фактической высоте (docs/UI-CONTRACT.md).
        .safeAreaInset(edge: .top, spacing: 0) { TaskTranscriptTopBar { dismiss() } }
        .safeAreaInset(edge: .bottom, spacing: 0) { repeatBar }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .preferredColorScheme(.dark)
    }

    /// Единственное действие страницы. Продолжить старую задачу нельзя — только повторить.
    private var repeatBar: some View {
        FloatingGlassBar {
            Button(action: onRepeat) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3)
                    Text("Повторить задачу")
                        .font(Theme.Fonts.sectionTitle)
                }
                // Надпись лежит НА СТЕКЛЕ — смысловая роль, а не белый с прозрачностью.
                .foregroundStyle(Theme.Colors.glassTextPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.Metrics.minimumTapTarget)
                .padding(.vertical, Theme.Metrics.floatingBarContentPaddingVertical)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Крестик справа сверху — тот же жест закрытия, что и у остальных страниц-шитов.
/// ⚠️ Тип виден только внутри этого файла: одноимённые шапки уже есть в других файлах,
/// а два одинаковых имени, видимых всему модулю, — это провал сборки.
private struct TaskTranscriptTopBar: View {

    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark",
                              accessibilityTitle: "Закрыть",
                              action: onClose)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
        .padding(.bottom, Theme.Metrics.topFadeHeight)
        .background(alignment: .top) { scrim }
        .accessibilitySortPriority(1)
    }

    /// Подложка — ТОЛЬКО для iOS 17–18.
    /// ⚠️ На iOS 26 своего фона позади стеклянной кнопки быть не должно: стеклу нечего
    /// сэмплить, кроме этого прямоугольника, и оно становится плоской тёмной таблеткой.
    @ViewBuilder
    private var scrim: some View {
        if !GlassAvailability.isLiquidGlassAvailable {
            VStack(spacing: 0) {
                Theme.background
                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: Theme.Metrics.topFadeHeight)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}
