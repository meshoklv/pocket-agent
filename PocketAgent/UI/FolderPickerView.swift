//
//  FolderPickerView.swift
//  PocketAgent
//
//  Раздел «Папки» — нижняя вкладка. Здесь человек выбирает, в какой папке работает
//  помощник, и переключается между теми, где уже работал.
//
//  ⚠️ Раньше это был экран-развилка: он показывался, пока папки нет, и пропадал
//  насовсем, как только она появилась. Сменить папку можно было только «выбрать
//  заново», а список прежних папок не хранился вообще. Теперь раздел доступен всегда,
//  а папки, в которых уже работали, лежат списком.
//
//  allowedContentTypes: [.folder] — выбираем именно ПАПКУ, а не файл.
//  Дизайн: тёмная тема, карточки обычные, стекло — только на нижней плавающей панели
//  и на круглой кнопке меню сверху.
//
//  ⚠️ Системной панели навигации на экране НЕТ:
//  её роль играют круглые плавающие кнопки, а заголовок у экрана ровно один —
//  крупный, в контенте.
//
//  ⚠️ Нижние вкладки этот экран себе НЕ рисует — их кладёт корневой экран. Своя
//  панель «Добавить папку» ложится ровно над ними, потому что обе стоят через
//  safeAreaInset и место считает система, а не выдуманное число.
//

import SwiftUI
import UniformTypeIdentifiers

struct FolderPickerView: View {

    @ObservedObject var app: AppViewModel

    @State private var isPickerShown = false
    /// Человек закрыл системное окно, ничего не выбрав. Это не ошибка — просто мягкая подсказка.
    @State private var didCancelPick = false
    @State private var isMenuShown = false
    @State private var isAboutShown = false
    /// Подтверждение перед тем, как забыть папку: действие необратимое.
    @State private var isForgetConfirmShown = false
    /// Что человек собрался сделать с папками, если разговор при этом закроется.
    @State private var pendingIntent: FolderIntent?
    /// Открыта страница правки заметки о проекте.
    @State private var isNoteEditorShown = false
    /// Что сейчас лежит в заметке этой папки. Перечитывается с диска при смене папки
    /// и после каждой записи.
    @State private var note: ProjectNoteState = .missing

    /// Колонка под иконку в строках «иконка + текст». Растёт вместе с системным шрифтом.
    @ScaledMetric(relativeTo: .title3) private var iconGutter: CGFloat
        = Theme.Metrics.iconGutterWidth

    /// Действие, которое закроет текущий разговор, — сначала спрашиваем.
    private enum FolderIntent: Equatable {
        case add
        case open(AppViewModel.RecentProject)
    }

    var body: some View {
        // ⚠️ Своего фона во весь экран нет намеренно: его рисует корневой экран.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                header
                // Правила показываем только при первом знакомстве: когда папка уже
                // выбрана, человек их прочитал и они превращаются в шум.
                if app.folder == nil {
                    emptyState
                    rules
                }
                if let folder = app.folder {
                    currentFolderCard(folder)
                    projectNoteCard
                }
                otherProjects
                if app.folder != nil {
                    forgetCurrentButton
                }
                if didCancelPick {
                    cancelHint
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
        }
        .scrollIndicators(.hidden)
        // ⚠️ ПОРЯДОК МОДИФИКАТОРОВ ВАЖЕН. Вставки безопасной зоны — ПЕРВЫМИ, прямо
        // на ScrollView: только тогда место под панель резервируется по фактической
        // высоте панели. Растворение контента лежит в той же вставке, поэтому карточки
        // больше не разрезаются панелью пополам.
        .safeAreaInset(edge: .top, spacing: 0) { topLayer }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomLayer }
        // Оба края, а не только нижний: на iOS 26 верх экрана держится именно системным
        // растворением — своей подложки позади плавающего слоя там нет и быть не должно.
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .preferredColorScheme(.dark)
        .confirmationDialog("Pocket Agent",
                            isPresented: $isMenuShown,
                            titleVisibility: .visible) {
            Button("О программе") { isAboutShown = true }
            Button("Отмена", role: .cancel) { }
        }
        .confirmationDialog("Забыть эту папку?",
                            isPresented: $isForgetConfirmShown,
                            titleVisibility: .visible) {
            Button("Забыть", role: .destructive) { app.forgetFolder() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Файлы останутся на месте — приложение просто перестанет их видеть, пока вы не выберете папку снова.")
        }
        // ⚠️ Именно `alert`, а не третий лист действий: два листа на одной ветке спорят
        // между собой — открывается тот, что описан последним.
        .alert("Перейти в другую папку?",
               isPresented: switchDialogBinding,
               presenting: pendingIntent) { intent in
            Button("Перейти") { perform(intent) }
            Button("Остаться", role: .cancel) { pendingIntent = nil }
        } message: { _ in
            Text(switchWarningText)
        }
        .sheet(isPresented: $isAboutShown) {
            AboutView(model: app.modelInfo, acceleration: app.accelerationBinding)
        }
        // Заметку перечитываем при появлении экрана и при КАЖДОЙ смене папки:
        // это файл конкретной папки, и от чужой папки он остался бы враньём на экране.
        .task(id: app.folder?.url.path) { await reloadNote() }
        .fileImporter(
            isPresented: $isPickerShown,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: { (result: Result<[URL], any Error>) in
                switch result {
                case .success(let urls):
                    guard let folder = urls.first else { return }
                    didCancelPick = false
                    app.adoptFolder(folder)
                case .failure(let error):
                    app.folderPickFailed(error)
                }
            },
            onCancellation: {
                // Просто закрыл окно выбора. Никаких «ошибок» и красного — только тихая подсказка,
                // и то лишь если папки ещё нет.
                didCancelPick = (app.folder == nil)
            }
        )
    }

    // MARK: - Переход, который закроет разговор

    /// Что человек хотел сделать, спросить или сделать сразу.
    ///
    /// ⚠️ Молча закрывать начатый разговор нельзя: смена папки стирает переписку —
    /// это ровно то, ради чего человек и держит приложение открытым.
    private func request(_ intent: FolderIntent) {
        guard app.hasLiveConversation else {
            perform(intent)
            return
        }
        pendingIntent = intent
    }

    private func perform(_ intent: FolderIntent) {
        pendingIntent = nil
        switch intent {
        case .add:
            didCancelPick = false
            isPickerShown = true
        case .open(let project):
            app.openRecentProject(project)
        }
    }

    private var switchDialogBinding: Binding<Bool> {
        Binding(get: { pendingIntent != nil },
                set: { isShown in if !isShown { pendingIntent = nil } })
    }

    private var switchWarningText: String {
        let place = app.folder.map { " в папке «\($0.displayName)»" } ?? ""
        if app.snapshot.isBusy {
            return "Задача\(place) ещё идёт — она остановится, а разговор закроется. "
                + "Файлы останутся как есть, задача попадёт в «Задачи»."
        }
        return "Разговор\(place) закроется, и задача начнётся заново. "
            + "Файлы останутся как есть, задача попадёт в «Задачи»."
    }

    // MARK: - Верхний плавающий слой

    /// Круглая кнопка меню и — ТОЛЬКО на iOS 17–18 — подложка под ней.
    ///
    /// ⚠️ На старой системе без подложки лента проезжает по часам, значкам сети и по самой
    /// кнопке: системного растворения края там нет. На iOS 26 своего фона позади стекла
    /// быть НЕ ДОЛЖНО — стеклу нечего сэмплить, кроме собственного
    /// чёрного прямоугольника, и капсула вырождается в плоскую тёмную таблетку.
    @ViewBuilder
    private var topLayer: some View {
        if GlassAvailability.isLiquidGlassAvailable {
            menuButtonRow
        } else {
            VStack(spacing: 0) {
                menuButtonRow
                    // Гибкий цвет с ignoresSafeArea сам дотягивается до кромки экрана
                    // и закрывает часы. Фиксированную высоту сюда ставить нельзя — она не растёт.
                    .background {
                        Theme.background
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                    }

                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: Theme.Metrics.topFadeHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    private var menuButtonRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "ellipsis",
                              accessibilityTitle: "Меню") {
                isMenuShown = true
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
    }

    // MARK: - Нижний плавающий слой

    /// Панель, а на iOS 17–18 — ещё и растворение контента над ней, одним куском
    /// в одной вставке. Градиент гасит контент к верхней кромке панели, под панелью фон
    /// сплошной: иначе в зазорах по бокам капсулы виден проезжающий текст.
    /// ⚠️ На iOS 26 сплошной фон остаётся только под самой панелью: нижние вкладки
    /// кладёт корневой экран НИЖЕ этой вставки, и закрашивать место под ними нельзя.
    @ViewBuilder
    private var bottomLayer: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background],
                           startPoint: .top,
                           endPoint: .bottom)
                .frame(height: Theme.Metrics.bottomFadeHeight)
                .allowsHitTesting(false)

            actionBar
                // ⚠️ Сплошной фон позади панели: панель — плавающая капсула с отступами,
                // между ней и краями остаётся полоса, и в ней лента видна насквозь.
                // ⚠️ `ignoresSafeArea` отсюда УБРАН: ниже стоит панель вкладок, и фон,
                // дотянутый до кромки экрана, закрасил бы место под ней.
                .background {
                    Theme.background
                        .allowsHitTesting(false)
                }
        }
    }

    // MARK: - Шапка

    private var header: some View {
        // Раньше здесь же висело «Помощник работает в одной папке и видит только её» —
        // ровно то, что и так видно по карточке выбранной папки под заголовком.
        Text("Папки")
            .font(Theme.Fonts.screenTitle)
            .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - Пусто

    /// ⚠️ ПУСТОЙ ЭКРАН БЕЗ ВЫХОДА — ТУПИК. Раньше человек без папки видел заголовок
    /// и три правила, а единственная кнопка лежала внизу на стеклянной панели, где
    /// её ещё надо было заметить. Теперь на месте, куда падает взгляд, написано,
    /// чего не хватает, и стоит кнопка, которая это решает.
    private var emptyState: some View {
        card {
            Text("Папка ещё не выбрана")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            Text("Здесь будут папки, в которых работает помощник. Подойдёт любая из «Файлов».")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                request(.add)
            } label: {
                Label("Выбрать папку", systemImage: "folder.badge.plus")
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

    // MARK: - Правила, ради которых человек и соглашается

    // Развёрнутые пояснения под каждым правилом убраны: то же самое (папка одна,
    // запись только с подтверждением) уже сказано в AboutView и в пустом экране
    // чата — здесь достаточно заголовков, чтобы напомнить, а не объяснять заново.
    private var rules: some View {
        card {
            ruleRow(icon: "lock.shield", title: "Только эта папка")
            divider
            ruleRow(icon: "hand.raised", title: "Ничего не пишется без вас")
            divider
            ruleRow(icon: "folder", title: "Подойдёт любая папка из «Файлов»")
        }
    }

    // MARK: - Текущая папка

    private func currentFolderCard(_ folder: ProjectFolder) -> some View {
        card {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.apply)
                Text(folder.displayName)
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("сейчас здесь")
                    .font(Theme.Fonts.barLabel)
                    .foregroundStyle(Theme.apply)
            }

            // ⚠️ Путь — моноширинным и обрезкой С ГОЛОВЫ: человеку важен ХВОСТ пути
            // (где именно лежит папка), а не «/private/var/mobile/Library/…» в начале.
            Text(folder.url.path)
                .font(Theme.Fonts.code)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Путь к папке")
                .accessibilityValue(folder.url.path)

            Button {
                app.keepCurrentFolder()
            } label: {
                Label("Перейти к работе", systemImage: "arrow.right.circle.fill")
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

    // MARK: - Заметка о проекте

    /// Карточка про `AGENTS.md` — файл, который помощник читает перед каждой задачей.
    ///
    /// ⚠️ ЗАЧЕМ ОНА ЗДЕСЬ. Чтение заметки в приложении было давно, а человеку про неё
    /// не говорили нигде — то есть завести её мог только тот, кто читал наш код. Приём
    /// существовал и не существовал одновременно. Место выбрано не случайно: заметка
    /// принадлежит ПАПКЕ, и живёт она там же, где человек эту папку выбирает.
    ///
    /// ⚠️ Приложение заметку НЕ пишет само. Кнопка открывает страницу правки, а оттуда
    /// текст уходит на диск только через карточку подтверждения — как любая правка файла.
    @ViewBuilder
    private var projectNoteCard: some View {
        card {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.textSecondary)
                Text("Заметка о проекте")
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(ProjectNote.fileName)
                    .font(Theme.Fonts.code)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            Text("Помощник читает её перед каждой задачей: что за проект и чего не трогать.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            switch note {
            case .missing:
                EmptyView()
            case .text(let text):
                notePreview(text)
            case .unreadable(let reason):
                Text("Заметка есть, но открыть её здесь нельзя: \(reason).")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isNoteEditable {
                Button {
                    isNoteEditorShown = true
                } label: {
                    Label(noteButtonTitle, systemImage: "square.and.pencil")
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
        // ⚠️ Страница правки повешена НА КАРТОЧКУ, а не на экран целиком: на экране уже
        // висит лист «О программе», а два `sheet` на одной и той же ветке спорят между
        // собой — открывается тот, что описан последним (та же грабля, что с двумя
        // листами действий в design notes).
        .sheet(isPresented: $isNoteEditorShown) {
            if let root = app.projectFolderURL {
                ProjectNoteSheet(root: root,
                                 initialText: noteText,
                                 onSaved: { Task { await reloadNote() } })
            }
        }
    }

    /// Первые строки заметки — чтобы было видно, что там уже написано.
    /// Пустые строки пропускаем: у заготовки они через одну, и предпросмотр из трёх
    /// пустот выглядел бы как пустой файл.
    private func notePreview(_ text: String) -> some View {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)

        return Text(lines.isEmpty ? "(заметка пустая)" : lines.joined(separator: "\n"))
            .font(Theme.Fonts.code)
            .foregroundStyle(Theme.Colors.textTertiary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noteButtonTitle: String {
        if case .text = note { return "Поправить заметку" }
        return "Создать заметку"
    }

    /// Заметку, которую мы не смогли прочитать, править нельзя: содержимого человеку
    /// не показали, и «Применить» затёрло бы его вслепую.
    private var isNoteEditable: Bool {
        if case .unreadable = note { return false }
        return true
    }

    /// Текст, с которым откроется страница правки. Пусто — там подставится заготовка.
    private var noteText: String {
        if case .text(let text) = note { return text }
        return ""
    }

    /// Перечитать заметку с диска.
    /// ⚠️ Чтение — вне главного потока: папка может лежать в iCloud и отвечать медленно.
    /// Сама функция при этом главного потока не покидает — она меняет состояние экрана.
    @MainActor
    private func reloadNote() async {
        guard let root = app.projectFolderURL else {
            note = .missing
            return
        }
        note = await Task.detached(priority: .userInitiated) {
            ProjectNote.read(root: root)
        }.value
    }

    // MARK: - Папки, в которых уже работали

    /// Список прежних папок. Появляется только когда есть куда переключаться —
    /// пустой заголовок «Другие папки» без единой строки выглядит как поломка.
    @ViewBuilder
    private var otherProjects: some View {
        let others = app.recentProjects.filter { $0.path != app.folder?.url.path }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Где работали раньше")

                VStack(spacing: 10) {
                    ForEach(others) { project in
                        projectRow(project)
                    }
                }
            }
        }
    }

    private func projectRow(_ project: AppViewModel.RecentProject) -> some View {
        Button {
            request(.open(project))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.title3)
                    .frame(minWidth: iconGutter, alignment: .leading)
                    .foregroundStyle(Theme.textSecondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.displayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
        // Убрать строку из списка. Файлы это не трогает — так и написано в подписи.
        .contextMenu {
            Button("Убрать из списка", role: .destructive) {
                app.forgetRecentProject(path: project.path)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Перейти в эту папку")
    }

    private var forgetCurrentButton: some View {
        Button(role: .destructive) {
            isForgetConfirmShown = true
        } label: {
            Text("Забыть эту папку")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Область касания по норме Apple: раньше строка была высотой
                // примерно 30 точек, и по ней промахивались.
                .frame(minHeight: Theme.Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.removed)
        .padding(.horizontal, Theme.Metrics.cardPadding)
    }

    private var cancelHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.textSecondary)
            Text("Выбор закрыт — ничего не потерялось. Папку можно выбрать в любой момент.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        // Строки вне карточки выравниваются по ВНУТРЕННЕМУ краю карточки.
        .padding(.horizontal, Theme.Metrics.cardPadding)
    }

    // MARK: - Плавающая панель снизу (единственное стекло внизу экрана)

    private var actionBar: some View {
        FloatingGlassBar {
            barButton(title: "Добавить папку", systemImage: "folder.badge.plus") {
                request(.add)
            }
        }
    }

    /// Панель целиком и есть кнопка. Своего стекла у кнопки нет — стекло уже на панели.
    private func barButton(title: String,
                           systemImage: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
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

    // MARK: - Мелочи

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(Theme.Fonts.sectionTitle)
            .foregroundStyle(Theme.textPrimary)
            // По внутреннему краю карточки — та же колонка, что и у остального текста.
            .padding(.horizontal, Theme.Metrics.cardPadding)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Theme.Metrics.hairlineWidth)
    }

    private func ruleRow(icon: String, title: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                // Колонка растёт вместе со шрифтом: иконка набрана ролью, и в жёсткие
                // 26 точек при крупном системном шрифте она не помещалась.
                .frame(minWidth: iconGutter, alignment: .leading)
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(Theme.textPrimary)
        }
    }

    /// Обычная карточка контента — без стекла.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Единственное описание поверхности карточки — Theme.cardSurface().
        .cardSurface()
    }
}
