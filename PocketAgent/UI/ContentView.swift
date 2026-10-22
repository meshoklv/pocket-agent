//
//  ContentView.swift
//  PocketAgent
//
//  Корневой экран: нижние вкладки и то, что показано в выбранной.
//  Ничего не знает ни про LiteRT-LM, ни про FileManager — только AppViewModel.
//
//  Оформление:
//  • чёрный фон на весь экран, тёмная тема;
//  • системной панели навигации НЕТ НИ НА ОДНОМ экране (docs/UI-CONTRACT.md, §1
//    «Решения по волне доведение до идеала»): её роль везде играют круглые
//    стеклянные кнопки (GlassCircleButton), которые каждый экран кладёт себе сам
//    через `.safeAreaInset(edge: .top)`;
//  • заголовок у экрана ровно один — крупный, в контенте.
//
//  ⚠️ ВКЛАДКИ ТЕПЕРЬ РОДНЫЕ (см. PocketAgent/UI/MainTabBar.swift).
//  Раньше корневой экран подкладывал самодельную стеклянную панель через
//  `.safeAreaInset(edge: .bottom)`. Теперь разделы держит системный `TabView`:
//  место под панель он резервирует сам, а собственные панели экранов (поле ввода
//  в чате, «Скачать» на моделях, «Добавить папку» на папках) по-прежнему ставятся
//  через `.safeAreaInset(edge: .bottom)` ВНУТРИ своего раздела и ложатся ровно над
//  вкладками. Отмерять место числом нельзя как раньше, так и теперь — на этом уже
//  дважды теряли последнюю карточку.
//
//  ⚠️ ДВЕ ПЛАВАЮЩИЕ ПАНЕЛИ ДРУГ НАД ДРУГОМ — НЕ ПРОСТО ТАК.
//  На вкладке «Чат» внизу уже стоит поле ввода. Пока человек печатает, вкладок нет:
//  над клавиатурой две капсулы съедали бы половину экрана, а выйти из чата в этот
//  момент и не нужно. Скрытием занимается сама панель (`MainTabBar.isHidden`).
//
//  ⚠️ NavigationStack ЗДЕСЬ БЫЛ И УБРАН НАМЕРЕННО, НЕ ВОЗВРАЩАТЬ.
//  Экраны не «пушатся» — их переключает вкладка. NavigationStack при этом всё равно
//  ставил системный жест «смахни от края — назад», и он таскал весь текст вбок,
//  хотя возвращаться было некуда. Это и был баг «текст ездит от свайпа»
//  (docs/UI-CONTRACT.md, §1). Родной `TabView` этот жест НЕ ставит: он переключает
//  разделы нажатием, горизонтального жеста у нижней панели нет вовсе — так что
//  возврат к системным вкладкам того бага не воскрешает.
//
//  ⚠️ АНИМАЦИИ МЕЖДУ РАЗДЕЛАМИ БОЛЬШЕ НЕТ, И ЭТО НЕ НЕДОДЕЛКА.
//  Раньше смена вкладки рисовалась своим переходом (проявление + подъезд на 14 точек,
//  треть секунды). Это ровно то, что делает интерфейс медленным: телефон не успевает
//  за пальцем, а показать за эту треть секунды нечего — оба экрана уже готовы.
//  Система переключает вкладки мгновенно, и это её осознанное решение. Внутри вкладки
//  «Чат» смена состояния (нет модели → нет папки → готовлю → чат) остаётся плавной,
//  но это короткое растворение на 0,2 секунды, а не переезд.
//
//  Зависимости из PocketAgent/UI/Design/ (контракт docs/UI-CONTRACT.md):
//  GlassCircleButton, Theme.background / textPrimary / textSecondary / Motion.gentle.
//

import SwiftUI

struct ContentView: View {

    @ObservedObject var app: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Нужен ровно для одного: открыть папку проекта в «Файлах».
    @Environment(\.openURL) private var openURL
    @State private var isAboutShown = false
    @State private var isMenuShown = false
    /// Экран «Работа по ключу»: поставщик, ключ, модель, предел трат.
    @State private var isRemoteAccessShown = false
    /// На этой странице тронули то, из-за чего движок надо поднять заново.
    @State private var remoteSettingsChanged = false
    /// Подтверждение на «Стереть историю разговоров».
    @State private var isEraseHistoryShown = false

    init(app: AppViewModel) {
        self.app = app
    }

    var body: some View {
        ZStack {
            // Фон всего приложения. Родной `TabView` своего фона не рисует, поэтому
            // чёрный кладём под него один раз здесь, а не в каждом разделе.
            Theme.background
                .ignoresSafeArea()

            // Разделы держит РОДНАЯ панель вкладок iOS (см. MainTabBar).
            MainTabBar(selection: app.tab,
                       select: { app.selectTab($0) },
                       // Прогресс идёт с любой вкладки: сессия загрузки в AppViewModel
                       // общая на всё приложение, а не только на вкладку «Модели».
                       downloadProgress: app.downloadProgress,
                       isHidden: isTabBarHidden) { tab in
                screen(for: tab)
            }
            // ⚠️ Окно висит ЗДЕСЬ, а не на корневом экране: там уже описаны меню
            // и окно ошибки, а два таких окна на одной ветке спорят между собой —
            // открывается то, что описано последним (docs/UI-CONTRACT.md).
            .confirmationDialog("Стереть историю разговоров?",
                                isPresented: $isEraseHistoryShown,
                                titleVisibility: .visible) {
                Button("Стереть", role: .destructive) { app.eraseConversationHistory() }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Записи последних задач лежат только на этом телефоне и пропадут насовсем. Разговор, который сейчас на экране, останется — сотрутся записи о нём и о прошлых задачах.")
            }
            // ⚠️ Эта страница висит на ПАНЕЛИ ВКЛАДОК, а не на корневом экране, по той же
            // причине, что и окно выше: на корне уже описана страница «О программе»,
            // а две страницы на одной ветке спорят между собой — открывается описанная
            // последней (docs/UI-CONTRACT.md).
            .sheet(isPresented: $isRemoteAccessShown, onDismiss: {
                // ⚠️ Движок поднимаем заново ОДИН РАЗ, при закрытии страницы, а не на
                // каждое касание. Смена движка откладывает текущую задачу в «Задачи»
                // и закрывает разговор; делай мы это на каждую букву ключа — человек
                // терял бы работу, пока заполняет поля.
                //
                // ⚠️ Зовём тот же путь, что и смена размера памяти разговора: он отпускает
                // прежний движок и поднимает нужный. Второго такого пути заводить нельзя —
                // они разойдутся.
                guard remoteSettingsChanged else { return }
                remoteSettingsChanged = false
                app.reloadModelForContextSize()
            }) {
                RemoteAccessView(onNeedsReload: { remoteSettingsChanged = true })
            }
        }
        .preferredColorScheme(.dark)
        .task { app.start() }
        .onChange(of: scenePhase) { _, newPhase in
            app.handleScenePhase(newPhase)
        }
        .sheet(isPresented: $isAboutShown) {
            // Что рассказать про модель, экран получает готовыми строками —
            // сам он про каталог моделей и движок ничего не знает.
            AboutView(model: app.modelInfo,
                      storage: app.modelStorageBinding,
                      acceleration: app.accelerationBinding,
                      // Выключатель поиска сам по себе живёт в настройках приложения,
                      // а отсюда страница получает право пересобрать помощника:
                      // набор действий фиксируется на весь разговор.
                      webSearch: app.webSearchBinding,
                      // ⚠️ И право поднять модель заново. Размер памяти разговора движок
                      // берёт в момент своего создания, поэтому смена размера посреди
                      // работы — это не новая сессия, а новая загрузка модели.
                      // Без этого человек передвинул бы выбор и ничего бы не заметил.
                      contextSize: app.contextSizeBinding)
        }
        .confirmationDialog("Pocket Agent",
                            isPresented: $isMenuShown,
                            titleVisibility: .visible) {
            menuButtons
        }
        .alert("Что-то пошло не так",
               isPresented: Binding(get: { app.errorText != nil },
                                    set: { if !$0 { app.errorText = nil } })) {
            Button("Понятно", role: .cancel) { app.errorText = nil }
        } message: {
            Text(app.errorText ?? "")
        }
    }

    // MARK: - Разделы

    /// Что показать в разделе. Никаких своих переходов между разделами тут нет:
    /// вкладки переключает система, и делает это мгновенно.
    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .chat:     chatTab
        case .tasks:    TasksView(app: app)
        case .playground: PlaygroundView(app: app)
        case .models:   ModelSetupView(app: app)
        case .projects: FolderPickerView(app: app)
        }
    }

    /// Вкладка «Чат» показывает работу, а когда работать нечем — прямо говорит, чего
    /// не хватает, и ведёт туда одним нажатием. Тупика тут быть не должно.
    private var chatTab: some View {
        chatRoute
            // Единственная анимация смены экранов в приложении — и она короткая.
            // При включённом «Уменьшении движения» экраны меняются мгновенно.
            .animation(reduceMotion ? nil : Theme.Motion.gentle, value: app.route)
    }

    @ViewBuilder
    private var chatRoute: some View {
        switch app.route {
        case .chat:
            // Меню открывает корневой экран — диалог со списком пунктов живёт здесь.
            ChatView(app: app, onMenu: { isMenuShown = true })
                .transition(screenTransition)
        case .buildingAgent:
            preparingView
                .transition(screenTransition)
        case .modelSetup:
            // ⚠️ Два РАЗНЫХ случая, которые раньше выглядели одинаково.
            // «Модели нет» — надо что-то делать. «Модель уже поднимается» — надо просто
            // подождать. Показывать второму «Сначала нужна модель» значит отправить
            // человека ставить то, что и так ставится.
            // ⚠️ Обёртка обязательна: переход нельзя навесить на «если — иначе»,
            // это не один экран, а два разных, и компилятор такое не принимает.
            Group {
                if app.isModelUnderway {
                    waitingForModelView
                } else if RemoteAccessSettings.isEnabled {
                    // ⚠️ ЧЕЛОВЕК ВЫБРАЛ РАБОТУ ПО КЛЮЧУ — ЗНАЧИТ И ЗВАТЬ ЕГО НАДО ТУДА.
                    // Раньше здесь стояло «Сначала нужна модель», и человек, у которого
                    // кончился предел трат, оказывался заперт: чат пропал, а поднять
                    // предел или выключить режим было негде. Теперь причина названа,
                    // а кнопка открывает ровно ту страницу, где всё это чинится.
                    missingView(icon: "key",
                                title: "Работа по ключу не идёт",
                                detail: remoteProblemText,
                                actionTitle: "Открыть «Работа по ключу»") {
                        isRemoteAccessShown = true
                    }
                } else {
                    missingView(icon: "brain.head.profile",
                                title: "Сначала нужна модель",
                                detail: "Помощник думает прямо в телефоне — для этого ему нужен файл модели.",
                                actionTitle: "Открыть «Модели»") {
                        app.selectTab(.models)
                    }
                }
            }
            .transition(screenTransition)
        case .folderPicker:
            missingView(icon: "folder",
                        title: "Сначала нужна папка",
                        detail: "Помощник работает в одной папке и видит только её.",
                        actionTitle: "Открыть «Папки»") {
                app.selectTab(.projects)
            }
            .transition(screenTransition)
        }
    }

    /// Почему работа по ключу не идёт — одной фразой, из первой же настоящей причины.
    /// Выключить режим и вернуться к своей модели человек может там же, куда ведёт кнопка.
    private var remoteProblemText: String {
        if let missing = RemoteAccessSettings.missingPartText { return missing }
        if RemoteSpend.isOverLimit {
            return RemoteSpend.statusText + ". Поднимите предел, начните счёт заново "
                + "или выключите работу по ключу."
        }
        return "Проверьте ключ, модель и адрес поставщика."
    }

    /// Модель уже в пути. Человеку остаётся ждать — но ждать он должен, понимая,
    /// что именно происходит, и имея дверь наружу.
    ///
    /// ⚠️ Подпись берём у самой модели (`modelPresence.title`): «Скачиваю модель… 46 %»,
    /// «Проверяю файл модели…», «Загружаю модель…». Своих слов про это не выдумываем —
    /// иначе на экране два разных рассказа об одном и том же.
    private var waitingForModelView: some View {
        waitingView(title: app.modelPresence.title,
                    detail: app.modelPresence.detail ?? "Как только модель будет готова, откроется рабочий экран.",
                    actionTitle: "Открыть «Модели»") {
            app.selectTab(.models)
        }
    }

    /// Смена состояния внутри вкладки «Чат» — короткое растворение, и только оно.
    ///
    /// ⚠️ ПОДЪЕЗД СНИЗУ УБРАН НАМЕРЕННО. Раньше новый экран проявлялся И подъезжал
    /// на 14 точек за треть секунды. Выглядело это вязко по двум причинам: во-первых,
    /// долго — палец давно закончил движение, а экран всё едет; во-вторых, оба экрана
    /// в этот момент лежат друг на друге и каждый со своими вставками безопасной зоны,
    /// поэтому подъезд превращался в дёрганье панелей. Растворение таких побочных
    /// эффектов не даёт вовсе и на глаз читается как «сразу».
    private var screenTransition: AnyTransition { .opacity }

    // MARK: - Нижние вкладки

    /// Пока человек печатает задачу, вкладок не видно: над клавиатурой они спорили бы
    /// с полем ввода за самое дорогое место экрана. Убрал клавиатуру — вернулись.
    private var isTabBarHidden: Bool {
        app.tab == .chat && app.isComposing
    }

    // MARK: - Экран «работать пока нечем»

    /// Честная страница вместо тупика: чего не хватает и куда нажать.
    private func missingView(icon: String,
                             title: String,
                             detail: String,
                             actionTitle: String,
                             perform: @escaping () -> Void) -> some View {
        centeredScreen(title: title,
                       detail: detail,
                       actionTitle: actionTitle,
                       perform: perform,
                       mark: {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(Theme.textSecondary)
        })
    }

    /// То же самое, но делать ничего не надо — идёт работа, и её видно.
    /// Кнопка всё равно есть: ждать вслепую человек не обязан, а подробности лежат
    /// в отдельном разделе.
    private func waitingView(title: String,
                             detail: String,
                             actionTitle: String,
                             perform: @escaping () -> Void) -> some View {
        centeredScreen(title: title,
                       detail: detail,
                       actionTitle: actionTitle,
                       perform: perform,
                       mark: {
            ProgressView()
                .controlSize(.large)
        })
    }

    /// Общая раскладка страниц «работать пока нечем» и «идёт работа»: знак, заголовок,
    /// одна поясняющая строка и ровно одна кнопка выхода.
    ///
    /// ⚠️ Прокрутка обязательна, хотя содержимого мало: при крупном системном шрифте
    /// (или боком) кнопка уезжала за нижний край, и страница превращалась в ловушку
    /// ровно там, где из неё больше всего надо выйти.
    private func centeredScreen<Mark: View>(title: String,
                                            detail: String,
                                            actionTitle: String,
                                            perform: @escaping () -> Void,
                                            @ViewBuilder mark: () -> Mark) -> some View {
        // Знак вычисляем ЗДЕСЬ, а не внутри GeometryReader: замыкание-строитель
        // не убегающее, звать его из другого замыкания нельзя.
        let markView = mark()
        return GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Theme.Metrics.cardPadding) {
                    markView
                    Text(title)
                        .font(Theme.Fonts.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(actionTitle, action: perform)
                        .font(.subheadline.bold())
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(Theme.Colors.accent)
                        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
                }
                .padding(Theme.Metrics.screenPadding)
                .frame(maxWidth: .infinity)
                // Пока содержимое ниже экрана — оно стоит по центру. Как только
                // переросло — превращается в обычный прокручиваемый список.
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
            .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        }
    }

    /// ⚠️ У этого экрана ОБЯЗАН быть выход.
    /// Он показывается, пока сессии агента нет, и сам себя не повторяет. Если собрать
    /// сессию не удалось (например, после перезапуска телефона потерян доступ к папке),
    /// без этой кнопки человек оставался на спиннере навсегда — приложение было для него
    /// мертво до переустановки. Сама ошибка теперь тоже возвращает к выбору папки,
    /// а кнопка — вторая линия обороны.
    ///
    /// ⚠️ Прокрутка здесь обязательна, хотя содержимого мало. Раньше это был
    /// единственный экран без неё: при крупном системном шрифте (или боком)
    /// кнопка выхода уезжала за нижний край и нажать её было нельзя — экран
    /// становился ловушкой ровно там, где из него больше всего надо выйти.
    private var preparingView: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Theme.Metrics.cardPadding) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Готовлю агента")
                        .font(Theme.Fonts.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Открываю папку проекта и объясняю модели правила работы.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Выбрать папку заново") {
                        app.requestFolderChange()
                    }
                    .font(.subheadline.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Theme.textSecondary)
                    .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
                }
                .padding(Theme.Metrics.screenPadding)
                .frame(maxWidth: .infinity)
                // Пока содержимое ниже экрана — оно стоит по центру, как раньше.
                // Как только переросло — превращается в обычный прокручиваемый список.
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
            // Своя круглая кнопка меню — вместо системной панели, как на всех остальных
            // экранах. Через вставку безопасной зоны, а не оверлеем: только так под неё
            // резервируется место по фактической высоте и текст не проезжает по часам.
            .safeAreaInset(edge: .top, spacing: 0) { preparingTopLayer }
            .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        }
    }

    /// Круглая кнопка меню экрана «Готовлю агента».
    ///
    /// Подложка только для iOS 17–18: там системного растворения края нет.
    /// ⚠️ На iOS 26 своего фона позади плавающего слоя быть НЕ ДОЛЖНО — стеклу нечего
    /// будет сэмплить, и капсула станет плоской тёмной таблеткой (docs/LIQUID-GLASS.md).
    @ViewBuilder
    private var preparingTopLayer: some View {
        if GlassAvailability.isLiquidGlassAvailable {
            preparingMenuButton
        } else {
            VStack(spacing: 0) {
                preparingMenuButton
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

    private var preparingMenuButton: some View {
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

    // MARK: - Меню

    @ViewBuilder
    private var menuButtons: some View {
        if app.route == .chat {
            Button("Новая задача") { app.reset() }
        }
        // Забрать файлы, которые сделал агент, — и положить свои.
        // Через системные «Файлы»: там человек уже умеет всё — копировать,
        // переслать, сохранить в облако.
        if app.projectFolderURL != nil {
            Button("Открыть папку в «Файлах»") { openFolderInFiles() }
        }
        // ⚠️ «Сменить папку» из меню убрана намеренно: теперь это отдельная вкладка,
        // и второй путь к тому же самому только сбивает с толку.
        // «О программе» доступно всегда: текст лицензии Apache 2.0
        // обязан быть доступен человеку, а не только на рабочем экране.
        Button("О программе") { isAboutShown = true }
        // Второй путь для модели: не телефон, а поставщик по ключу человека.
        // ⚠️ Пункт есть ВСЕГДА, а не только когда режим включён: включают его как раз
        // отсюда, и спрятанный за условием вход означал бы, что войти некуда.
        Button("Работа по ключу") { isRemoteAccessShown = true }
        // Приложение записывает последние разговоры на телефон — значит человек обязан
        // иметь возможность их стереть, и не в дебрях настроек, а там же, где всё остальное.
        Button("Стереть историю разговоров", role: .destructive) { isEraseHistoryShown = true }
        Button("Отмена", role: .cancel) { }
    }

    /// Открыть папку проекта в системном приложении «Файлы».
    ///
    /// ⚠️ Другого способа нет: своего файлового менеджера у приложения не будет,
    /// а забрать несколько файлов сразу или переложить свои человеку надо уметь.
    /// Адрес папки отдаём «Файлам» их собственным способом обращения; сработало это
    /// или нет — видно по ответу системы, и молчать в случае отказа мы не будем.
    private func openFolderInFiles() {
        guard let folder = app.projectFolderURL,
              var parts = URLComponents(url: folder, resolvingAgainstBaseURL: false) else {
            app.errorText = "Не получилось открыть папку в «Файлах»."
            return
        }
        parts.scheme = "shareddocuments"
        guard let url = parts.url else {
            app.errorText = "Не получилось открыть папку в «Файлах»."
            return
        }
        openURL(url) { accepted in
            guard !accepted else { return }
            app.errorText = "Не получилось открыть папку в «Файлах». "
                + "Откройте «Файлы» сами — папка называется «\(folder.lastPathComponent)»."
        }
    }
}

/// Имя из архитектурной карты: корневой экран-маршрутизатор.
/// Точка входа использует ContentView напрямую, псевдоним оставлен для читаемости карты.
typealias RootView = ContentView
