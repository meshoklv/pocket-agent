//
//  RemoteAccessView.swift
//  PocketAgent
//
//  Экран «Работа по ключу»: выбрать поставщика, ввести ключ, выбрать модель, поставить
//  предел трат.
//
//  ⚠️ ПО ТЕКСТАМ ЭКРАН УЖЕ ПРИЧЁСАН (10.08.2026), НЕ РАЗДУВАТЬ ОБРАТНО. Из него убраны
//  повторы: рассказ «модель в телефоне работает без интернета» (он же был в блоке
//  «Что уходит наружу»), пересказ этого блока в окне подтверждения, подпись «Ключа нет»
//  под пустым полем «Вставьте ключ» и подпись «пусто — берётся обычный адрес» под полем,
//  где этот адрес и так виден серым. Правило простое: экран говорит то, что нужно СЕЙЧАС.
//  Всё про ДЕНЬГИ и про то, ЧТО УХОДИТ НАРУЖУ, осталось — резать это нельзя.
//
//  ПОРЯДОК БЛОКОВ СВЕРХУ ВНИЗ = ПОРЯДОК ДЕЙСТВИЙ ЧЕЛОВЕКА (разбор устройства 10.08.2026):
//   1. заголовок;
//   2. «Что уходит наружу» — прочитать, прежде чем что-то трогать;
//   3. «Поставщик» — у кого будем считать;
//   4. «Ключ доступа» — без него поставщик не ответит и список моделей не отдаст;
//   5. «Модель» — кнопка «Спросить список» работает только с сохранённым ключом;
//   6. «Предел трат» — сколько денег человек согласен потратить;
//   7. «Режим» — и только теперь выключатель.
//
//  ⚠️⚠️ ВЫКЛЮЧАТЕЛЬ СТОИТ ПОСЛЕДНИМ, А НЕ ВТОРЫМ БЛОКОМ, И ЭТО ГЛАВНАЯ ПРАВКА ЭКРАНА.
//  Раньше он шёл сразу под «Что уходит наружу» — то есть человеку предлагали включить
//  режим ДО того, как он выбрал поставщика, вставил ключ и выбрал модель. Включение
//  честно отвечало строкой «не хватает ключа и модели», но эта строка показывала
//  на блоки, которых человек ещё не видел: она смотрела ВНИЗ, под экран. Теперь
//  включение — последний шаг, и всё, чего не хватает, лежит ВЫШЕ него: подсказка
//  указывает туда, откуда человек только что пришёл.
//
//  ⚠️ «ЧТО УХОДИТ НАРУЖУ» ОСТАЁТСЯ ПЕРВЫМ БЛОКОМ, И ЕГО НЕЛЬЗЯ УБИРАТЬ ВНИЗ.
//  Всё приложение обещает человеку, что его файлы и задачи не покидают телефон. Работа
//  по ключу это обещание отменяет — и человек обязан узнать об этом ДО того, как включит
//  переключатель, а не мелким шрифтом потом. Цена ошибки здесь выше, чем у поиска
//  в интернете (уходят ФАЙЛЫ, а не слова запроса), поэтому к прямой фразе добавлено
//  ещё и подтверждение при включении.
//
//  ⚠️ САМОГО КЛЮЧА ЭКРАН НЕ ВИДИТ И НЕ ХРАНИТ. Он кладёт введённое в защищённое хранилище
//  системы (`RemoteKeyStore`) и тут же забывает черновик. Обратно он получает только
//  четыре последних знака — чтобы человек узнал, тот ли ключ лежит.
//

import SwiftUI

struct RemoteAccessView: View {

    /// Настройки изменились так, что движок надо поднять заново (сменился поставщик,
    /// ключ или модель). nil — экран открыт без приложения (превью): менять нечего.
    var onNeedsReload: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    // Все настройки читаются ТЕМИ ЖЕ ключами, что и движок: своей копии решения
    // у экрана нет — ровно как у выключателя поиска.
    @AppStorage(RemoteAccessSettings.enabledKey) private var isOn = false
    @AppStorage(RemoteAccessSettings.providerKey) private var providerID
        = RemoteProviderDirectory.openRouter.id
    @AppStorage(RemoteAccessSettings.modelKey) private var modelID = ""
    @AppStorage(RemoteSpend.limitKey) private var limitMicros = RemoteSpend.oneDollar

    /// Адрес — СВОЙ У КАЖДОГО ПОСТАВЩИКА, поэтому он не может лежать в @AppStorage
    /// с одним именем ключа: имя зависит от того, кто сейчас выбран.
    /// (Почему адреса разведены по поставщикам — см. `RemoteAccessSettings.baseURLKey`.)
    @State private var customBaseURL = ""

    /// Черновик ключа. Живёт ровно до нажатия «Сохранить» и стирается сразу после.
    @State private var keyDraft = ""
    /// Четыре последних знака сохранённого ключа. nil — ключа нет.
    @State private var keyTail: String?

    /// Черновики цен — СТРОКАМИ, а не числами.
    ///
    /// ⚠️ ЭТО НЕ ПРИДИРКА К УСТРОЙСТВУ, А ЕДИНСТВЕННЫЙ СПОСОБ ВВЕСТИ ЦЕНУ. Раньше поле
    /// показывало число, прочитанное обратно: набрал «0» — поле тут же стирало ноль
    /// (ноль показывался пустым), набрал запятую — она пропадала, потому что «0,» числом
    /// не является. То есть «0,15» не набиралось в принципе — а цены моделей все меньше
    /// доллара. Теперь пока человек печатает, на экране живёт его строка, а число из неё
    /// вынимается молча.
    @State private var promptPriceDraft = ""
    @State private var answerPriceDraft = ""

    @State private var models: [RemoteModelOption] = []
    @State private var modelFilter = ""
    @State private var isLoadingModels = false
    @State private var modelsProblem: String?

    /// Подтверждение включения: человек должен согласиться явно.
    @State private var isTurnOnAsked = false

    /// Что показать про потраченное. Пересчитывается при появлении экрана и после
    /// сброса — само по себе оно меняется в движке, а не здесь.
    @State private var spentText = RemoteSpend.statusText
    /// Сколько ходов прошло мимо счёта. Ноль — все посчитаны.
    @State private var uncountedTurns = RemoteSpend.uncountedTurns

    private var provider: RemoteProvider {
        RemoteProviderDirectory.provider(withID: providerID) ?? RemoteProviderDirectory.openRouter
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                header
                honestyBlock
                providerBlock
                keyBlock
                modelBlock
                spendBlock
                // Последним — см. разбор порядка в шапке файла.
                switchBlock
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { closeLayer }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .preferredColorScheme(.dark)
        .onAppear {
            keyTail = RemoteKeyStore.tail(for: providerID)
            customBaseURL = RemoteAccessSettings.customBaseURL(for: providerID)
            spentText = RemoteSpend.statusText
            uncountedTurns = RemoteSpend.uncountedTurns
            promptPriceDraft = Self.priceDraft(RemoteAccessSettings.manualPromptPricePerMillion)
            answerPriceDraft = Self.priceDraft(RemoteAccessSettings.manualAnswerPricePerMillion)
        }
        .confirmationDialog("Работать по ключу?",
                            isPresented: $isTurnOnAsked,
                            titleVisibility: .visible) {
            Button("Включить") {
                isOn = true
                onNeedsReload?()
            }
            Button("Отмена", role: .cancel) { isOn = false }
        } message: {
            // ⚠️ Коротко и по делу: подробности человек только что прочитал в блоке
            // «Что уходит наружу» прямо над выключателем. Пересказывать их вторым
            // разом в окне — то самое «одно и то же в двух местах». Здесь важно
            // ровно одно новое слово: КОМУ именно уйдут файлы.
            Text("Задача и куски ваших файлов будут уходить поставщику «\(provider.displayName)».")
        }
    }

    // MARK: - Круглая стеклянная кнопка закрытия (единственное стекло на экране)

    /// Тот же слой закрытия, что у «О программе» и у поиска моделей.
    ///
    /// ⚠️ ПОДЛОЖКА И РАСТВОРЕНИЕ ЖИВУТ ТОЛЬКО НА iOS 17–18, И БЕЗ НИХ ЭКРАН БЫЛ БРАКОМ.
    /// Здесь стояла голая кнопка без слоя — единственная такая страница в приложении.
    /// На iOS 17–18 системного растворения края нет, и текст при прокрутке проезжал
    /// прямо по крестику и по часам. На iOS 26 наоборот: непрозрачный фон позади стекла
    /// запрещён (docs/LIQUID-GLASS.md) — стеклу нечего сэмплить, и кнопка вырождается
    /// в плоскую тёмную таблетку. Место под кнопку в обоих случаях резервирует вставка
    /// безопасной зоны, а не подложка.
    @ViewBuilder
    private var closeLayer: some View {
        if GlassAvailability.isLiquidGlassAvailable {
            closeButtonRow
        } else {
            VStack(spacing: 0) {
                closeButtonRow
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

    private var closeButtonRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark", accessibilityTitle: "Закрыть") { dismiss() }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Работа по ключу")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.textPrimary)
            // ⚠️ Текст — короткий (приёмщик интерфейса): про «модель в телефоне остаётся
            // главной и работает без интернета» здесь не пишем, ровно это же сказано
            // в блоке «Что уходит наружу» строкой «Выключено — не уходит ничего».
            // Дважды на одном экране — мусор.
            // ⚠️ Роль `.callout`, а не `.footnote` (приёмщик устройства): подпись под крупным
            // заголовком набрана так на всех страницах приложения. Была мельче — и страница
            // на глаз выглядела чужой.
            Text("Думает не телефон, а модель поставщика — по вашему ключу и за ваши деньги.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Честность (первый блок, и это не случайность)

    private var honestyBlock: some View {
        card(title: "Что уходит наружу") {
            VStack(alignment: .leading, spacing: 8) {
                line("Задача, которую вы написали.")
                line("Куски файлов, которые помощник прочитал в вашей папке.")
                line("То, что помощник собирается записать, — до того, как вы нажмёте «Применить».")
                // ⚠️ Обе половины фразы обязательные — «кому уходит» и «что будет,
                // если выключить», ровно как у выключателя поиска в интернете.
                // А вот двумя абзацами это было лишним: смысла в них на одну строку.
                Text("Уходит выбранному поставщику — что он с этим делает, решает он, а не мы. Выключено — не уходит ничего.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.footnote).foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Выключатель (последний блок экрана)

    /// Последний шаг: всё настроено — включаем.
    ///
    /// ⚠️ ПОДСКАЗКА «ЧЕГО НЕ ХВАТАЕТ» РАБОТАЕТ ТОЛЬКО ОТСЮДА, СНИЗУ. Пока выключатель
    /// стоял вторым блоком, она называла недостающее (ключ, модель) раньше, чем человек
    /// вообще увидел эти карточки, — то есть отправляла его искать вслепую вниз по экрану.
    /// Теперь всё названное лежит ВЫШЕ: подсказка указывает назад, туда, где человек
    /// только что был, и найти нужную карточку — одно движение вверх.
    private var switchBlock: some View {
        card(title: "Режим") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Работать по ключу", isOn: Binding(
                    get: { isOn },
                    set: { wanted in
                        // ⚠️ Включение идёт ЧЕРЕЗ ВОПРОС, выключение — сразу.
                        // Отказаться от сети человек вправе в одно касание; согласиться —
                        // только осознанно.
                        if wanted {
                            isOn = false
                            isTurnOnAsked = true
                        } else {
                            isOn = false
                            onNeedsReload?()
                        }
                    }
                ))
                .font(.footnote.bold())
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.Colors.accent)

                if isOn, let missing = RemoteAccessSettings.missingPartText {
                    // Сама фраза («Не введён ключ доступа.») под включённым выключателем
                    // всё говорит: добавка «пока этого нет, ничего не заработает» была
                    // объяснением очевидного.
                    Text(missing)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Поставщик

    private var providerBlock: some View {
        card(title: "Поставщик") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Поставщик", selection: Binding(
                    get: { providerID },
                    set: { newValue in
                        providerID = newValue
                        // Ключ у каждого поставщика свой, список моделей — тоже.
                        keyDraft = ""
                        keyTail = RemoteKeyStore.tail(for: newValue)
                        // ⚠️ И АДРЕС ТОЖЕ СВОЙ. Пока адрес был один на всех, человек мог
                        // попробовать «Свой адрес», вернуться на OpenRouter — и запрос
                        // с ключом OpenRouter уходил по чужому вписанному адресу.
                        customBaseURL = RemoteAccessSettings.customBaseURL(for: newValue)
                        models = []
                        modelsProblem = nil
                        onNeedsReload?()
                    }
                )) {
                    ForEach(RemoteProviderDirectory.all) { item in
                        Text(item.displayName).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.Colors.accent)

                Text(provider.keyHint)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // ⚠️ Адрес правится руками у ЛЮБОГО поставщика. Адреса чужих служб
                // меняются без нашего ведома, и приложение с намертво зашитым адресом
                // в этот день просто перестаёт работать без объяснений.
                // ⚠️ Правку адреса ОБЯЗАТЕЛЬНО отдаём наружу (`onNeedsReload`): движок
                // берёт адрес в момент своей подготовки. Без этой строки человек правил
                // адрес, закрывал страницу — и запросы до перезапуска приложения
                // продолжали уходить по старому адресу, молча.
                TextField(provider.baseURL.isEmpty ? "https://…/v1" : provider.baseURL,
                          // ⚠️ Не голая привязка: правку адреса надо и СОХРАНИТЬ для этого
                          // поставщика, и отдать наружу — движок берёт адрес в момент
                          // подготовки. Без этого человек правил адрес, закрывал страницу,
                          // и запросы до перезапуска приложения молча уходили по старому.
                          text: Binding(
                            get: { customBaseURL },
                            set: { newValue in
                                customBaseURL = newValue
                                RemoteAccessSettings.setCustomBaseURL(newValue, for: providerID)
                                onNeedsReload?()
                            }
                          ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .fieldSurface()

                // ⚠️ Строка показывается ТОЛЬКО когда адрес вписан руками. Пока поле
                // пустое, обычный адрес поставщика и так виден в самом поле серым —
                // писать под ним «пусто — берётся обычный адрес» значит подписывать
                // подпись. А вот свой адрес человек обязан увидеть целиком: он его
                // и вводит затем, чтобы проверить, куда уйдёт запрос.
                if !customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Запрос уйдёт на «\(RemoteAccessSettings.effectiveBaseURL)/chat/completions».")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Ключ

    private var keyBlock: some View {
        card(title: "Ключ доступа") {
            VStack(alignment: .leading, spacing: 10) {
                // ⚠️ Строки «Ключа нет» здесь больше нет: пустое поле с подписью
                // «Вставьте ключ» прямо под ней говорит ровно то же самое. Осталось
                // то, чего по полю не увидеть, — какой именно ключ уже лежит.
                if let keyTail {
                    Text("Ключ сохранён: \(keyTail)")
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                }

                SecureField("Вставьте ключ", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldSurface()

                // ⚠️ ДВА ДЕЙСТВИЯ СТОЯТ СТОЛБИКОМ, А НЕ В ОДНУ СТРОКУ. Рядом они были
                // двумя мелкими надписями через 16 точек: на ходу и одной рукой человек
                // вместо «Сохранить» попадал в «Убрать» — то есть стирал ключ вместо того,
                // чтобы его записать. Во всех остальных карточках приложения действия
                // тоже идут столбиком, каждое во всю ширину.
                // ⚠️ Надпись короткая («Сохранить», а не «Сохранить ключ»): карточка
                // называется «Ключ доступа», второй раз слово «ключ» тут лишнее.
                actionButton("Сохранить",
                             isEnabled: !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    RemoteKeyStore.save(keyDraft, for: providerID)
                    // Черновик стираем СРАЗУ: чем меньше живёт копия ключа
                    // в памяти экрана, тем лучше.
                    keyDraft = ""
                    keyTail = RemoteKeyStore.tail(for: providerID)
                    onNeedsReload?()
                }

                if keyTail != nil {
                    destructiveButton("Убрать") {
                        RemoteKeyStore.remove(for: providerID)
                        keyTail = nil
                        onNeedsReload?()
                    }
                }

                Text("Ключ лежит в защищённом хранилище телефона и в журнал не попадает.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Модель

    private var modelBlock: some View {
        card(title: "Модель") {
            VStack(alignment: .leading, spacing: 10) {
                Text(modelID.isEmpty ? "Модель не выбрана." : modelID)
                    .font(.footnote)
                    .foregroundStyle(modelID.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // Вид кнопки — общий для карточек (приёмщик устройства), надпись —
                // короткая (приёмщик интерфейса): «у поставщика» и так ясно из карточки.
                actionButton(isLoadingModels ? "Спрашиваю…" : "Спросить список",
                             isEnabled: !isLoadingModels && keyTail != nil) {
                    loadModels()
                }

                if keyTail == nil {
                    // Почему без ключа список не придёт — человеку и так понятно;
                    // ему нужно знать, что сделать.
                    Text("Сначала сохраните ключ.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let modelsProblem {
                    Text(modelsProblem)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !models.isEmpty {
                    TextField("Отбор по имени", text: $modelFilter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fieldSurface()

                    // ⚠️ Показываем не весь список, а первые двадцать подходящих:
                    // у крупных поставщиков моделей больше трёхсот, и рисовать их
                    // все в прокрутке — это заметная задержка на ровном месте.
                    //
                    // ⚠️ СТРОКИ РАЗДЕЛЕНЫ ВОЛОСЯНОЙ ЧЕРТОЙ И ЛЕЖАТ НА СВОЕЙ ПОДЛОЖКЕ,
                    // как в списке «Модели на телефоне». Раньше двухэтажные строки
                    // (имя + цена) шли встык, без единой линии, и список читался как
                    // сплошная простыня текста: где кончается одна модель и начинается
                    // следующая, приходилось угадывать по цвету.
                    let shown = Array(filteredModels.prefix(20))
                    VStack(spacing: 0) {
                        ForEach(shown) { option in
                            modelRow(option)
                            if option.id != shown.last?.id { rowDivider }
                        }
                    }
                    .background(Theme.Colors.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: Theme.Metrics.controlCorner,
                                                     style: .continuous))

                    if filteredModels.count > 20 {
                        Text("Первые 20 из \(filteredModels.count) — уточните отбор.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                // Имя модели можно вписать руками: список получить удаётся не у всех.
                // ⚠️ И вписанное руками имя тоже просит поднять движок заново — иначе
                // до перезапуска приложения запрос уходил бы на прежнюю модель.
                TextField("Или впишите имя модели", text: Binding(
                    get: { modelID },
                    set: {
                        modelID = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        onNeedsReload?()
                    }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldSurface()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filteredModels: [RemoteModelOption] {
        let needle = modelFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return models }
        return models.filter { $0.id.lowercased().contains(needle) }
    }

    private func modelRow(_ option: RemoteModelOption) -> some View {
        let isPicked = modelID == option.id
        // ⚠️ Набор признаков собираем отдельной переменной, а не тернаром прямо
        // в модификаторе: тернар из «.isSelected» и пустого литерала разные версии
        // компилятора выводят по-разному — этой граблёй уже обожглись на экране моделей.
        var traits = AccessibilityTraits()
        if isPicked { traits.insert(.isSelected) }

        return Button {
            modelID = option.id
            // ⚠️ Цену запоминаем ВМЕСТЕ с выбором модели. Без неё предел трат у тех
            // поставщиков, кто не присылает счёт, считать было бы не из чего —
            // и человеку пришлось бы вводить цену руками.
            if let prompt = option.promptPricePerMillion, let answer = option.answerPricePerMillion {
                RemoteAccessSettings.manualPromptPricePerMillion = prompt
                RemoteAccessSettings.manualAnswerPricePerMillion = answer
                // Поля цены показывают черновик — значит его и надо обновить,
                // иначе человек увидит в них старое число.
                promptPriceDraft = Self.priceDraft(prompt)
                answerPriceDraft = Self.priceDraft(answer)
            }
            onNeedsReload?()
        } label: {
            // Строка списка — как в «Моделях на телефоне» (приёмщик устройства):
            // галочка у выбранной, а не только цвет имени.
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.id)
                        .font(.footnote)
                        .foregroundStyle(isPicked ? Theme.Colors.accent : Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let price = option.priceText {
                        Text(price)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        // Про деньги молчать нельзя, но и разворачивать в предложение
                        // на каждой строке незачем — их тут двадцать.
                        Text("цена неизвестна")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // ⚠️ Галочка справа, как в любом системном списке выбора. Раньше выбранную
                // строку выдавал только цвет имени — на списке из двадцати строк одним
                // взглядом это не ловится, а прокручивать весь список ради вопроса
                // «а что у меня сейчас выбрано» человек не должен.
                Image(systemName: "checkmark")
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.Colors.accent)
                    .opacity(isPicked ? 1 : 0)
            }
            .padding(.horizontal, Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(traits)
    }

    /// Волосяная черта между строками списка — та же, что в «Моделях на телефоне».
    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Theme.Metrics.hairlineWidth)
            .padding(.leading, Theme.Metrics.cardPadding)
    }

    private func loadModels() {
        guard let key = RemoteKeyStore.key(for: providerID) else {
            modelsProblem = "Ключа нет — спрашивать нечем."
            return
        }
        isLoadingModels = true
        modelsProblem = nil
        let provider = self.provider
        let address = RemoteAccessSettings.effectiveBaseURL

        Task {
            do {
                let found = try await RemoteModelDirectory.models(provider: provider,
                                                                  baseURL: address,
                                                                  key: key)
                await MainActor.run {
                    models = found
                    isLoadingModels = false
                    modelsProblem = found.isEmpty
                        ? "Поставщик ответил, но списка моделей в ответе нет. Впишите имя модели руками."
                        : nil
                }
            } catch {
                await MainActor.run {
                    models = []
                    isLoadingModels = false
                    modelsProblem = SystemErrorText.russian(for: error)
                }
            }
        }
    }

    // MARK: - Деньги

    private var spendBlock: some View {
        card(title: "Предел трат") {
            VStack(alignment: .leading, spacing: 10) {
                Text(spentText)
                    .font(.footnote)
                    .foregroundStyle(Theme.textPrimary)

                Picker("Предел", selection: Binding(
                    get: { limitMicros },
                    set: {
                        limitMicros = $0
                        // ⚠️ Поднятый предел обязан подействовать СРАЗУ. Движок,
                        // остановленный пределом, сам не оживает — его надо поднять
                        // заново, иначе человек поднял предел и ничего не изменилось.
                        onNeedsReload?()
                    }
                )) {
                    ForEach(Self.limitChoices, id: \.self) { value in
                        Text(RemoteSpend.money(value)).tag(value)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.Colors.accent)

                // ⚠️ ПРЕДЕЛ ОБЕЩАЕМ ТОЛЬКО ТАМ, ГДЕ ЕГО ЕСТЬ ИЗ ЧЕГО СЧИТАТЬ. Счёт
                // деньгами присылает один OpenRouter; у остальных без вписанной цены
                // потраченное не растёт вовсе — и обещание «помощник остановится»
                // было бы прямой неправдой про деньги человека.
                if RemoteAccessSettings.canCountMoney {
                    Text("Дойдёт до предела — помощник остановится.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Предел не сработает: «\(provider.displayName)» стоимость не сообщает — впишите цену модели ниже.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if RemoteSpend.hasEstimates {
                    Text("Часть суммы — наша прикидка, а не счёт поставщика.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if uncountedTurns > 0 {
                    Text("Ходов мимо счёта: \(uncountedTurns). Предел на них не подействовал.")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                priceFields

                actionButton("Начать счёт заново") {
                    RemoteSpend.reset()
                    spentText = RemoteSpend.statusText
                    uncountedTurns = 0
                    // Счёт обнулён — значит предел больше не достигнут, и движок,
                    // остановленный им, должен подняться заново.
                    onNeedsReload?()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Цена модели руками — нужна там, где поставщик её не сообщает.
    private var priceFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Цена за миллион слов-кусочков, в долларах")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                priceField(title: "запрос",
                           draft: $promptPriceDraft) { RemoteAccessSettings.manualPromptPricePerMillion = $0 }
                priceField(title: "ответ",
                           draft: $answerPriceDraft) { RemoteAccessSettings.manualAnswerPricePerMillion = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Поле цены. На экране живёт ЧЕРНОВИК-СТРОКА, число из него вынимается молча.
    ///
    /// ⚠️ ПОЧЕМУ НЕ ЧИСЛО НАПРЯМУЮ. Поле, читающее число обратно, стирало ноль (ноль
    /// показывался пустым) и запятую («0,» — не число), и цену «0,15» набрать было
    /// нельзя вообще, а дешевле доллара стоят все модели. Черновик человек видит таким,
    /// каким печатает; «0,15» превращается в 0,15 сразу, а «0,» просто ждёт продолжения.
    private func priceField(title: String,
                            draft: Binding<String>,
                            apply: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            TextField("0", text: Binding(
                get: { draft.wrappedValue },
                set: { typed in
                    draft.wrappedValue = typed
                    apply(Double(typed.replacingOccurrences(of: ",", with: ".")) ?? 0)
                }
            ))
            .textFieldStyle(.plain)
            .font(.footnote)
            .foregroundStyle(Theme.textPrimary)
            .keyboardType(.decimalPad)
            // ⚠️ Та же подложка и та же высота, что у всех остальных полей экрана.
            // Раньше эти два поля были на четыре точки уже и с другим скруглением —
            // на глаз читалось как «эти два не такие, как все».
            .fieldSurface()
        }
    }

    /// Число → черновик. Хвостовые нули срезаем: «0,1500» человек не пишет.
    /// Разделитель — запятая, как во всём приложении (см. `RemoteSpend.money`).
    private static func priceDraft(_ value: Double) -> String {
        guard value > 0 else { return "" }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",")
    }

    /// Сколько можно поставить. Первое значение — доллар, оно же по умолчанию.
    private static let limitChoices = [1, 2, 5, 10, 25, 100].map { $0 * RemoteSpend.oneDollar }

    // MARK: - Карточка

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
        .cardSurface()
    }

    // MARK: - Кнопки внутри карточки

    /// Обычное действие карточки: подпись во всю ширину, площадь касания по норме Apple.
    ///
    /// ⚠️ ВИД ОДИН НА ВСЕ ТРИ КНОПКИ ЭКРАНА («Сохранить ключ», «Спросить список
    /// у поставщика», «Начать счёт заново») И СОВПАДАЕТ С «О ПРОГРАММЕ» («Начать новую
    /// задачу», «Загрузить модель заново», «Попробовать ускорение заново»). Раньше каждая
    /// из трёх была набрана по-своему: одна с площадью касания, другая без, третья
    /// в строке рядом с чужой кнопкой. Это те самые «три разных изобретения» одного
    /// и того же органа управления.
    private func actionButton(_ title: String,
                              isEnabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.footnote.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .contentShape(Rectangle())
            .disabled(!isEnabled)
    }

    /// Разрушающее действие: тот же вид, но красное и обычной насыщенности —
    /// как «Отменить загрузку и стереть скачанное» на экране моделей.
    private func destructiveButton(_ title: String,
                                   action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: Theme.Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.removed)
    }
}

// MARK: - Поле ввода

private extension View {

    /// Единый вид поля ввода на этом экране: подложка, скругление и высота.
    ///
    /// ⚠️ ЧЕТЫРЕ ПОЛЯ БЫЛИ НАБРАНЫ ТРЕМЯ РАЗНЫМИ СПОСОБАМИ (отступ 10 со скруглением 10,
    /// отступ 8 со скруглением 8) и ни у одного не было минимальной высоты касания:
    /// при мелком шрифте поле получалось около 37 точек при норме Apple в 44, и попасть
    /// в него пальцем на ходу было тем ещё делом. Скругление берётся из общего словаря
    /// (`Theme.Metrics.controlCorner`) — тем же скруглением набрана строка поиска
    /// на странице поиска моделей.
    func fieldSurface() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.footnote)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .background(Theme.Colors.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlCorner,
                                             style: .continuous))
    }
}
