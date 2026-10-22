//
//  AboutView.swift
//  PocketAgent
//
//  «О программе». Это не украшение: Apache 2.0 §4 требует передать получателям
//  копию лицензии и сохранить указание авторства. Поэтому здесь есть и текст
//  лицензии из бандла, и явное упоминание Gemma 4 от Google.
//
//  Плюс главный по смыслу блок — «как это работает и чего помощник НЕ может»:
//  человеку важно понимать границы до того, как он отдаст приложению свои файлы.
//
//  Дизайн: тёмная тема, карточки обычные, стекло — только на круглой кнопке закрытия.
//
//  ⚠️ Кнопка закрытия живёт во ВСТАВКЕ безопасной зоны, а не в оверлее: только так
//  под ней резервируется место по фактической высоте, и текст не проезжает под
//  кнопкой при прокрутке. Под кнопкой — сплошная подложка и растворение, иначе
//  строки проходят прямо по часам (тот же брак, что был на рабочем экране).
//

import SwiftUI

/// Всё, что странице «О программе» нужно знать про ускорение.
///
/// Отдельная маленькая структура, а не ссылка на `AppViewModel`, — по образцу
/// `ModelStorageBinding`: страница не знает ни движка, ни каталога моделей.
struct AccelerationBinding {
    /// На чём модель считает прямо сейчас: «GPU», «CPU» или «—».
    let backendName: String
    /// Ускорение отключено после неудачных попыток.
    let isDisabled: Bool
    /// Спросить движок заново (страница зовёт при появлении).
    let refresh: () -> Void
    /// Разрешить попытку с ускорением ещё раз.
    let enableAgain: () -> Void
}

/// Всё, что странице «О программе» нужно знать про поиск в интернете.
///
/// ⚠️ Самого положения выключателя здесь НЕТ, и это не забывчивость: оно лежит
/// в настройках приложения, и страница читает его тем же ключом, что и сам поиск
/// (`@AppStorage(WebSearchSettings.defaultsKey)`). Через эту структуру передаётся
/// только то, чего экран сделать не может, — пересобрать помощника под новый
/// набор действий.
struct WebSearchBinding {
    /// Человек передвинул выключатель. `true` — помощник уже соответствует новому
    /// положению; `false` — разговор идёт, поиск появится только с новой задачи.
    let apply: () -> Bool
    /// Начать новую задачу: прежняя уходит в «Задачи», помощник собирается заново.
    let startNewTask: () -> Void
}

/// Всё, что странице «О программе» нужно знать про размер памяти разговора.
///
/// ⚠️ Самого числа здесь НЕТ — по той же причине, что и у поиска: оно лежит в настройках
/// приложения, и страница читает его тем же ключом, что и движок
/// (`@AppStorage(ContextSizeSettings.defaultsKey)`). Через эту структуру передаётся
/// только то, чего экран сделать не может: узнать, с каким размером движок РАБОТАЕТ
/// прямо сейчас, и поднять модель заново.
struct ContextSizeBinding {
    /// Спросить движок, с каким размером он поднят (страница зовёт при появлении).
    ///
    /// ⚠️ Число сюда не возвращается: странице оно не нужно, а вот приложению нужно —
    /// по нему оно решает, надо ли вообще поднимать модель заново. Спрашивать движок
    /// в момент открытия страницы дешевле и честнее, чем помнить своё старое значение.
    let refresh: () -> Void
    /// Живой движок работает НЕ с тем размером, который выбран. Спрашивается при
    /// открытии страницы: человек мог выбрать размер, не поднять модель и вернуться
    /// сюда позже — и тогда страница обязана напомнить, а не делать вид, что всё
    /// применилось.
    let isStale: () -> Bool
    /// Человек выбрал новый размер. `true` — движок уже соответствует выбору (или его
    /// ещё нет, и он поднимется с новым числом); `false` — задача идёт, и чтобы
    /// применить, модель надо поднять заново.
    let apply: () -> Bool
    /// Поднять модель заново с выбранным размером. Прежняя задача уходит в «Задачи».
    let reloadModel: () -> Void
}

struct AboutView: View {

    /// Что рассказываем про модель — ГОТОВЫЕ строки из Contracts.
    /// ⚠️ Экран намеренно не знает ни каталога моделей, ни типов Runtime:
    /// раньше он читал поля `ModelDescriptor`, и переименование поля каталога
    /// уронило бы сборку сразу двух экранов — причём в облаке, где никто не смотрит.
    let model: ModelInfo

    /// Модель на телефоне: сколько занимает и как удалить.
    /// nil — блока про место просто нет (демонстрационный режим, превью, ничего не установлено).
    var storage: ModelStorageBinding? = nil

    /// На чём модель считает и можно ли вернуть ускорение.
    /// nil — движок про это не рассказывает, тогда блока на странице нет.
    ///
    /// ⚠️ Блок обязан быть. После двух оборванных запусков движок ставит ПОСТОЯННЫЙ запрет
    /// на ускорение, и снять его умеет только кнопка отсюда (либо смена версии системы).
    /// Пока кнопки не было, человек молча оставался на вдвое более медленном счёте
    /// и не понимал почему.
    var acceleration: AccelerationBinding? = nil

    /// Поиск в интернете: это ЕДИНСТВЕННОЕ место во всём приложении, где его
    /// включают и выключают. nil — страница открыта без приложения (превью, снимки):
    /// сам выключатель всё равно виден и сохраняется, просто пересобирать помощника
    /// некому — значит, и кнопки «Начать новую задачу» нет.
    ///
    /// ⚠️ Раньше по nil прятался ВЕСЬ блок — и дыру нашли снимком экрана: на кадре
    /// «О программе» из демонстрации выключателя поиска не было вовсе, то есть
    /// проверить главную новую настройку можно было только руками на телефоне.
    /// Прятать надо не выбор, а действие, которого без приложения не существует.
    var webSearch: WebSearchBinding? = nil

    /// Размер памяти разговора: движок читает выбор отсюда же.
    /// nil — страница открыта без приложения (превью, снимки): выбор всё равно виден
    /// и сохраняется, просто применится при следующей загрузке модели.
    var contextSize: ContextSizeBinding? = nil

    @Environment(\.dismiss) private var dismiss

    /// Положение выключателя «Искать в интернете». Лежит в настройках приложения —
    /// тот же самый ключ читает и сам поиск, своей копии решения здесь нет.
    @AppStorage(WebSearchSettings.defaultsKey) private var isWebSearchOn = false
    /// Выключатель тронули посреди разговора: помощник узнает об этом с новой задачи.
    @State private var needsNewTaskForWebSearch = false

    /// Сколько памяти разговора выбрал человек. Тот же ключ читает движок.
    @AppStorage(ContextSizeSettings.defaultsKey) private var contextTokens
        = AgentLimits.contextTokenBudget
    /// С каким числом НЕ получилось. 0 — жаловаться не на что.
    ///
    /// ⚠️ Читается из настроек, а не из состояния экрана, и это принципиально: неудача
    /// могла закрыть приложение целиком, и человек вернётся уже в новый запуск.
    @AppStorage(ContextSizeSettings.retreatKey) private var contextRetreatedFrom = 0
    /// Размер тронули посреди задачи: чтобы применить, модель надо поднять заново.
    @State private var needsReloadForContext = false

    /// Колонка под иконку. Растёт вместе с системным шрифтом.
    @ScaledMetric(relativeTo: .body) private var iconGutter: CGFloat
        = Theme.Metrics.iconGutterWidth
    /// Кружок с номером шага — тоже растёт: цифра внутри набрана ролью.
    @ScaledMetric(relativeTo: .footnote) private var stepBadgeSize: CGFloat
        = Theme.Metrics.stepBadgeSize
    /// Колонка подписи в строке «Название — значение».
    @ScaledMetric(relativeTo: .footnote) private var labelColumnWidth: CGFloat
        = Theme.Metrics.labelColumnWidth
    @State private var licenseText: String?
    @State private var isLicenseShown = false

    var body: some View {
        // Это шит: собственный фон здесь свой и единственный, системной панели нет.
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                header
                howItWorks
                limits
                webSearchBlock
                contextSizeBlock
                modelBlock
                accelerationBlock
                conversationsBlock
                if let storage {
                    ModelStorageCard(model: model, storage: storage)
                }
                licenseBlock
                versionBlock
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            closeLayer(title: "Закрыть") { dismiss() }
        }
        // Как на остальных экранах: край растворяет система, а не своя подложка.
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .preferredColorScheme(.dark)
        .onAppear {
            acceleration?.refresh()
            contextSize?.refresh()
            // Выбор мог остаться неприменённым с прошлого захода: страница закрывается,
            // а @State забывается. Спрашиваем факт, а не помним своё старое решение.
            needsReloadForContext = contextSize?.isStale() ?? false
        }
        .sheet(isPresented: $isLicenseShown) { licenseSheet }
    }

    // MARK: - Круглая стеклянная кнопка закрытия (единственное стекло на экране)

    /// Один и тот же жест закрытия на ВСЕХ страницах приложения: крестик справа сверху.
    ///
    /// ⚠️ Раньше лицензия закрывалась стрелкой вниз слева, а «О программе» — крестиком
    /// справа: два разных способа закрыть две соседние страницы. Теперь способ один,
    /// а понять, что именно закрываешь, помогает сам заголовок страницы под кнопкой.
    @ViewBuilder
    private func closeLayer(title: String, action: @escaping () -> Void) -> some View {
        if GlassAvailability.isLiquidGlassAvailable {
            closeButtonRow(title: title, action: action)
        } else {
            VStack(spacing: 0) {
                closeButtonRow(title: title, action: action)
                    // Гибкий цвет с ignoresSafeArea сам дотягивается до верхней кромки
                    // экрана и закрывает часы. Фиксированную высоту сюда ставить нельзя —
                    // она не растёт.
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

    /// ⚠️ Подложка под этой кнопкой живёт ТОЛЬКО на iOS 17–18 (см. closeLayer).
    /// На iOS 26 непрозрачный фон позади стекла запрещён: стеклу нечего сэмплить.
    private func closeButtonRow(title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark", accessibilityTitle: title, action: action)
        }
        // Тот же отступ, что и у заголовка под кнопкой: раньше крестик стоял
        // на 4 точки ближе к краю, и эта асимметрия была видна на снимке.
        .padding(.horizontal, Theme.Metrics.screenPadding)
        // ⚠️ Верхний отступ нужен именно здесь, а не на экранах подготовки:
        // страница открывается шитом, и безопасной зоны с часами у неё нет —
        // без него крестик упирался бы в скруглённый верхний край страницы.
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pocket Agent")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.textPrimary)

            // ⚠️ Формулировка подобрана под ширину: длинное слово «изменение» стояло
            // на кромке и переносилось со знаком — единственный перенос во всём
            // приложении, он читался как случайность.
            Text("""
            Помощник-программист, который работает прямо на телефоне: читает и правит файлы \
            в папке, которую вы выбрали. Что он хочет поправить, вы видите заранее — \
            и правка применяется только по вашей команде.
            """)
            .font(.callout)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Как это работает

    private var howItWorks: some View {
        card(title: "Как это работает") {
            VStack(alignment: .leading, spacing: 12) {
                step(number: "1", text: "Вы описываете задачу обычными словами.")
                step(number: "2", text: "Помощник предлагает ОДНО действие: посмотреть список файлов, прочитать файл или изменить файл.")
                step(number: "3", text: "Вы видите, что именно он собирается сделать. Для изменения файла — что было и что станет, строка за строкой.")
                step(number: "4", text: "Вы жмёте «Применить» или «Отклонить». Дальше он делает следующий шаг — и снова спрашивает.")
            }
        }
    }

    // MARK: - Границы

    private var limits: some View {
        card(title: "Чего помощник не может") {
            VStack(alignment: .leading, spacing: 12) {
                limitRow(icon: "lock.shield",
                         text: "Выйти за выбранную папку. Файлы вне неё он не прочитает и не изменит — проверка стоит перед каждым действием.")
                // ⚠️ Раньше здесь стояло «отправить файлы ИЛИ ЗАДАЧИ» — после появления
                // поиска это стало неправдой: со включённым поиском слова запроса уходят
                // наружу. Про файлы обещание осталось прежним и полным, а про запрос
                // всё сказано в блоке ниже, рядом с самим выключателем.
                limitRow(icon: "wifi.slash",
                         text: "Отправить ваши файлы в интернет. Модель работает на самом телефоне.")
                limitRow(icon: "terminal",
                         text: "Запустить что-нибудь на телефоне. Он умеет только смотреть, читать и менять файлы.")
                // ⚠️ «Изменить файл без подтверждения» и «одно действие за раз» здесь
                // намеренно не повторяются — это уже сказано шагами 2-4 в блоке
                // «Как это работает» выше. Оставлена только цифра, которой там нет:
                // сколько шагов подряд помощник может сделать без ответа.
                limitRow(icon: "figure.walk",
                         text: "Работать больше \(AgentLimits.maxSteps) шагов на одну задачу: упрётся — остановится и спросит вас.")
            }
        }
    }

    // MARK: - Поиск в интернете

    /// Единственный выключатель во всём приложении — и он выключен, пока человек
    /// сам его не тронет.
    ///
    /// ⚠️ Подпись под ним обязана остаться такой подробной, хотя объяснений на экранах
    /// мы и сокращаем. Всё приложение обещает, что наружу не уходит ничего; поиск это
    /// обещание меняет, и человек должен понимать РОВНО ЧТО меняется — до того как
    /// включит, а не после.
    ///
    /// ⚠️ Строка «задача уже идёт» и кнопка рядом — не украшение. Набор действий
    /// помощника фиксируется на весь разговор, и посреди задачи включение подействовать
    /// не может. Промолчать здесь значит вернуть человека ровно туда, где он уже был:
    /// «включил, а поиска нет».
    ///
    /// ⚠️ БЛОК ЕСТЬ ВСЕГДА — так же, как у размера памяти разговора ниже. Положение
    /// выключателя живёт в настройках, и сохранить его страница умеет сама, без
    /// приложения. Приложение нужно только чтобы пересобрать помощника — поэтому по nil
    /// исчезает лишь кнопка «Начать новую задачу», а не сам выбор.
    @ViewBuilder
    private var webSearchBlock: some View {
        card(title: "Поиск в интернете") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Искать в интернете", isOn: $isWebSearchOn)
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.Colors.accent)
                    .onChange(of: isWebSearchOn) { _, _ in
                        // Приложения рядом нет (превью, снимок экрана) — положение просто
                        // сохранилось, пересобирать некого и жаловаться не на что.
                        needsNewTaskForWebSearch = !(webSearch?.apply() ?? true)
                    }

                Text("Выключено — ни задачи, ни файлы не выходят за телефон. Включите — наружу уходят только слова запроса, и каждый запрос вы увидите в переписке. Файлы и содержимое папки не отправляются никогда.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if needsNewTaskForWebSearch, let webSearch {
                    Text("Задача уже идёт — помощник узнает про это со следующей. Прежняя останется в «Задачах».")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Начать новую задачу") {
                        webSearch.startNewTask()
                        needsNewTaskForWebSearch = false
                        // Страница закрывается сразу: новая задача начинается в чате,
                        // и оставлять человека здесь — заставлять его закрывать окно
                        // руками ради того, что уже произошло.
                        dismiss()
                    }
                    .font(.footnote.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: - Память разговора

    /// Сколько помощник помнит из разговора. Выбирает ЧЕЛОВЕК, вплоть до 32 000.
    ///
    /// ⚠️ ПРЕДУПРЕЖДЕНИЕ, А НЕ ЗАПРЕТ (ROADMAP, раздел 6). Большие значения здесь
    /// не спрятаны, не помечены «не трогать» и ничем не ограничены: мы честно говорим,
    /// чем человек рискует, и пропускаем. Заранее знать, поедет ли 32 000 на конкретном
    /// телефоне, нельзя ни нам, ни ему — это выясняется живым запуском.
    ///
    /// ⚠️ ВЫБОР ПРИВЯЗАН К СОБСТВЕННОМУ Binding, А НЕ К `.onChange`, И ЭТО НЕ КРАСОТА.
    /// То же число переписывает движок, когда отступает после неудачи, — и `.onChange`
    /// не отличил бы его запись от касания человека: приложение сочло бы отступление
    /// новым выбором, стёрло бы строку «не получилось» (то есть скрыло бы от человека,
    /// что произошло) и полезло бы поднимать модель заново. Сеттер Binding зовётся
    /// ТОЛЬКО когда человек тронул сам выбор.
    @ViewBuilder
    private var contextSizeBlock: some View {
        card(title: "Память разговора") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Размер памяти разговора", selection: contextChoice) {
                    ForEach(ContextSizeSettings.options, id: \.self) { tokens in
                        Text(ContextSizeSettings.text(tokens)).tag(tokens)
                    }
                }
                .pickerStyle(.segmented)

                Text("Больше — дольше помощник помнит, о чём вы говорили, и реже теряет начало задачи. Но и памяти телефона нужно больше: на большом размере модель может замолчать или приложение закроется. Надёжно работает \(ContextSizeSettings.text(AgentLimits.contextTokenBudget)).")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Приложение уже пробовало это число и не смогло. Молчать об этом нельзя:
                // человек увидел бы, что выбор сам собой уменьшился, и решил бы,
                // что настройка не работает.
                if contextRetreatedFrom > AgentLimits.contextTokenBudget {
                    Text("\(ContextSizeSettings.text(contextRetreatedFrom)) не получилось — вернул \(ContextSizeSettings.text(AgentLimits.contextTokenBudget)). Подробности — в журнале запуска модели.")
                        .font(.footnote.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // ⚠️ Фраза одна на два случая — «задача идёт прямо сейчас» и «выбор
                // остался с прошлого захода» — и потому не говорит «задача уже идёт»:
                // это было бы неправдой во втором случае.
                //
                // ⚠️ ПЕРВАЯ ФРАЗА ГОВОРИТ ПРО «СЕЙЧАС», И ЭТО ИСПРАВЛЕНИЕ ЖИВОЙ ЖАЛОБЫ
                // 09.08.2026 («хочу 32 000, а получаю 4 096»). Раньше здесь стояло только
                // «новый применится, когда модель поднимется заново» — то есть страница
                // говорила про будущее и молчала про настоящее, а в выборе сверху
                // по-прежнему значились 32 000. Человек читал это как «всё в порядке,
                // просто позже» и считал, что настройка сломана. Показывать выбранное
                // число как действующее, когда движку ушло другое, нельзя.
                if needsReloadForContext, let contextSize {
                    Text("Сейчас помощник работает не с этим размером — он задаётся при загрузке модели. Задача, если она идёт, останется в «Задачах».")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Загрузить модель заново") {
                        contextSize.reloadModel()
                        needsReloadForContext = false
                        // Дальше человеку смотреть не на что: модель поднимается
                        // на главном экране, и держать его здесь незачем.
                        dismiss()
                    }
                    .font(.footnote.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())

                    // ⚠️ ВТОРОЙ ВЫХОД, И БЕЗ НЕГО КНОПКА ВЫШЕ ИНОГДА ВРЁТ. Если модель
                    // на этом размере однажды промолчала, приложение подобрало для неё
                    // свою настройку — а среди них есть такая, где размер берёт сама
                    // модель, и выбор человека не действует. Перезагрузка тогда ничего
                    // не меняет: подобранное помнится за парой «модель + размер».
                    // Смена числа — другая пара, и подбор начинается заново.
                    Text("Не помогло — выберите другое число и вернитесь к этому.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Выбор размера: читаем из настроек, пишем туда же — и только по касанию человека.
    private var contextChoice: Binding<Int> {
        Binding(get: { contextTokens },
                set: { chosen in
                    contextTokens = chosen
                    // Человек решил сам — прошлая жалоба относится уже не к тому,
                    // что он видит перед собой.
                    ContextSizeSettings.forgetRetreat()
                    needsReloadForContext = !(contextSize?.apply() ?? true)
                })
    }

    // MARK: - Модель

    private var modelBlock: some View {
        card(title: "Модель") {
            VStack(alignment: .leading, spacing: 8) {
                labeled("Название", model.displayName)
                labeled("Автор", "Google")
                labeled("Лицензия", model.license)
                labeled("Размер", model.sizeText)
                labeled("Файл", model.fileName)
                labeled("Версия", model.versionText)

                // Честно про требования: модель целиком лежит в памяти телефона,
                // и на телефонах со скромной памятью она может не подняться.
                Text("Модель целиком лежит в памяти телефона, пока помощник работает. Не хватит памяти — приложение скажет прямо, а не упадёт молча.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)

                if let page = model.pageURL {
                    Link("Страница модели", destination: page)
                        .font(.footnote)
                        .frame(minHeight: Theme.Metrics.minimumTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: - Скорость работы

    /// На чём считает модель и как вернуть ускорение.
    ///
    /// ⚠️ Кнопка здесь — единственный способ снять запрет на ускорение. Движок ставит
    /// его сам после двух подряд оборванных запусков (телефон убил приложение прямо
    /// во время «Готовим движок») и больше не снимает — кроме случая, когда обновится
    /// система или сборка. Без кнопки человек навсегда оставался на счёте вдвое медленнее
    /// и не имел ни одного способа узнать об этом.
    @ViewBuilder
    private var accelerationBlock: some View {
        if let acceleration {
            card(title: "Скорость работы") {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("Считает на", acceleration.backendName)

                    if acceleration.isDisabled {
                        Text("Ускорение выключено — приложение пару раз закрылось при подготовке модели, и оно отключилось само. Сейчас считает процессор, это примерно вдвое медленнее.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Попробовать ускорение заново") {
                            acceleration.enableAgain()
                        }
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: Theme.Metrics.minimumTapTarget)
                        .contentShape(Rectangle())

                        Text("Подействует при следующей загрузке модели.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Что приложение записывает на телефон

    /// Честно и без уловок: что именно оседает на диске, куда оно НЕ уходит
    /// и как это стереть.
    ///
    /// ⚠️ Про начало прочитанных файлов сказано прямо, и убирать это нельзя. Записи
    /// повторяют ленту разговора, а в ленте видны первые строки каждого файла, который
    /// помощник читал. Умолчать об этом — соврать человеку о его же данных.
    private var conversationsBlock: some View {
        card(title: "Разговоры хранятся на телефоне") {
            Text("""
            Последние 10 задач остаются на телефоне: ваша задача, ответы помощника \
            и начало файлов, которые он читал (сами файлы и правки целиком не хранятся — \
            только строка вида «README.md · +4 −1»). Никуда, кроме телефона, они не уходят. \
            Стереть — в меню «…» → «Стереть историю разговоров».
            """)
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Лицензия

    private var licenseBlock: some View {
        card(title: "Лицензия") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(model.displayName) распространяется по лицензии Apache 2.0. На использование модели также действует Prohibited Use Policy компании Google.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)

                Button("Показать текст лицензии") {
                    loadLicenseIfNeeded()
                    isLicenseShown = true
                }
                .font(.footnote.bold())
                // Площадь касания по рекомендации Apple: надпись мелкая, но человек
                // с тремором или на ходу обязан попадать по ней с первого раза.
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: Theme.Metrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
        }
    }

    private var licenseSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Apache License 2.0")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)

                Text(licenseText ?? "Текст лицензии не найден в приложении.")
                    // ⚠️ Роль, а не размер в точках: это юридически обязательный текст,
                    // и человек со слабым зрением обязан иметь возможность его прочитать.
                    // Размер 11 «Динамический шрифт» не увеличивает вообще.
                    .font(Theme.Fonts.code)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            closeLayer(title: "Закрыть текст лицензии") { isLicenseShown = false }
        }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .preferredColorScheme(.dark)
    }

    // MARK: - Версия сборки

    private var versionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Версия приложения \(versionText)")
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        // Строки вне карточки выравниваются по ВНУТРЕННЕМУ краю карточки,
        // а не по случайному числу — иначе левый край экрана идёт ступеньками.
        .padding(.horizontal, Theme.Metrics.cardPadding)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (сборка \(build))"
    }

    // MARK: - Мелочи

    private func step(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.footnote.bold().monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                // Кружок растёт вместе с цифрой: шрифт задан ролью, и в жёстких
                // 24 точках при крупном системном шрифте цифра вылезала за круг.
                .frame(width: stepBadgeSize, height: stepBadgeSize)
                .background(Theme.surfaceHigh, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Для VoiceOver это одна мысль, а не «два» и отдельно текст шага.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Шаг \(number). \(text)")
    }

    private func limitRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                // Колонка растёт вместе со шрифтом и не обрезает иконку.
                .frame(minWidth: iconGutter, alignment: .leading)
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    /// Обычная карточка контента — без стекла.
    private func card<Content: View>(title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            content()
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Единственное описание поверхности карточки — Theme.cardSurface().
        .cardSurface()
    }

    /// Строка «подпись — значение».
    ///
    /// ⚠️ Не помещается в строку — разъезжается в два этажа, а не обрезается.
    /// Раньше подпись была заперта в жёсткие 84 точки: при крупном системном шрифте
    /// «Лицензия» туда не влезала и обрывалась — а это блок, где по Apache 2.0 §4
    /// обязано читаться авторство модели.
    private func labeled(_ name: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: labelColumnWidth, alignment: .leading)
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // «Название: Gemma 4 E2B» одним элементом, а не двумя свайпами.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(value)")
    }

    /// Текст лицензии лежит в бандле — читаем один раз и только по нажатию.
    private func loadLicenseIfNeeded() {
        guard licenseText == nil else { return }
        guard let url = Bundle.main.url(forResource: "LICENSE-Apache-2.0", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        licenseText = text
    }
}
