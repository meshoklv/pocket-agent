//
//  RemoteProviders.swift
//  PocketAgent / Runtime
//
//  Всё, что нужно знать про работу ПО ЧУЖОМУ КЛЮЧУ, кроме самого разговора с моделью:
//    • RemoteProvider        — справочник поставщиков (кто, по какому адресу, как ключ);
//    • RemoteKeyStore        — ключ человека в защищённом хранилище системы (Keychain);
//    • RemoteAccessSettings  — выбор человека: включено, поставщик, модель, адрес, цены;
//    • RemoteSpend           — сколько потрачено и предел трат (по умолчанию один доллар);
//    • RemoteModelDirectory  — список моделей, СПРОШЕННЫЙ У ПОСТАВЩИКА, а не зашитый.
//
//  ⚠️⚠️ ГЛАВНОЕ ПРО ЭТОТ ФАЙЛ. Всё приложение обещает человеку, что его файлы и задачи
//  никуда не уходят. Работа по ключу это обещание НАРУШАЕТ — и потому она:
//    • выключена по умолчанию (`UserDefaults.bool` на незаданном ключе — это `false`,
//      то есть у всех, кто ничего не трогал, её просто нет);
//    • включается ТОЛЬКО руками человека и только после экрана, где прямым текстом
//      написано, что именно и кому уходит (`PocketAgent/UI/RemoteAccessView.swift`);
//    • ничего не меняет в работе без интернета: местная модель остаётся главной,
//      выключил переключатель — приложение снова целиком в телефоне.
//  Та же планка, что у выключателя поиска в интернете (`WebSearchTool.swift`), — оттуда
//  и списано устройство: одно решение человека, один ключ в настройках, никаких
//  оговорок задним числом.
//
//  ⚠️ КЛЮЧ ЧЕЛОВЕКА НЕ ЛЕЖИТ В НАСТРОЙКАХ ПРИЛОЖЕНИЯ НИ ОДНОЙ БУКВОЙ. Только Keychain.
//  Причина не «так принято»: журнал диагностики у нас с 10.08.2026 пишет ВСЁ подряд
//  (текст задач, ответы модели, куски файлов) и уходит в буфер обмена одной кнопкой,
//  а его шапка вдобавок перечисляет настройки приложения (`EngineDiagnostics.rememberedLines`).
//  Лежи ключ в настройках — он уехал бы в буфер обмена вместе с журналом.
//  Поэтому: ключ только в Keychain, и ни один ключ настроек в этом файле не начинается
//  с «pocketagent.runtime.» — именно эту приставку печатает шапка журнала.
//

import Foundation
import Security

// MARK: - Как поставщик принимает ключ

/// Способ передать ключ. Всегда ЗАГОЛОВОК запроса и никогда не адрес.
///
/// ⚠️ Ключа в адресе (`?api_key=…`) здесь нет намеренно, хотя некоторые поставщики так
/// умеют. Адрес запроса попадает и в системный журнал телефона, и в текст почти любой
/// сетевой ошибки — то есть ключ утёк бы туда, куда мы его специально не пускаем.
public enum RemoteAuthStyle: String, Sendable, Equatable, Codable {
    /// `Authorization: Bearer КЛЮЧ` — так делают почти все.
    case bearer
    /// `x-api-key: КЛЮЧ` — так просит часть поставщиков.
    case apiKeyHeader

    func header(for key: String) -> (name: String, value: String) {
        switch self {
        case .bearer:       return ("Authorization", "Bearer \(key)")
        case .apiKeyHeader: return ("x-api-key", key)
        }
    }
}

// MARK: - Справочник поставщиков

/// Один поставщик: имя для человека, адрес и то, как он принимает ключ.
///
/// ⚠️ Адрес у КАЖДОГО поставщика человек может поправить руками. Это не лишняя
/// настройка, а честность: адреса чужих служб меняются без нашего ведома, и приложение,
/// у которого адрес зашит намертво, в этот день просто перестаёт работать без объяснений.
public struct RemoteProvider: Sendable, Equatable, Identifiable {

    public let id: String
    /// Имя для человека: «OpenRouter».
    public let displayName: String
    /// Адрес до `/chat/completions`, без косой черты на конце.
    public let baseURL: String
    /// Как передать ключ.
    public let auth: RemoteAuthStyle
    /// Добавочные заголовки, если поставщик их просит.
    public let extraHeaders: [String: String]
    /// Отдаёт ли поставщик СТОИМОСТЬ запроса деньгами. false — считаем сами по токенам
    /// и честно помечаем, что это прикидка.
    public let reportsCost: Bool
    /// Где человек берёт ключ — одной строкой, чтобы не искать.
    public let keyHint: String

    public init(id: String,
                displayName: String,
                baseURL: String,
                auth: RemoteAuthStyle = .bearer,
                extraHeaders: [String: String] = [:],
                reportsCost: Bool = false,
                keyHint: String) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.auth = auth
        self.extraHeaders = extraHeaders
        self.reportsCost = reportsCost
        self.keyHint = keyHint
    }
}

/// Кого приложение знает. Список короткий намеренно: «свой адрес» закрывает всех
/// остальных, а длинный список поставщиков — это обещание поддержки, которого мы
/// не давали.
///
/// ⚠️ АДРЕСА ЗАПИСАНЫ ПО РАЗВЕДКЕ И ЖИВЫМИ ЗАПРОСАМИ ИЗ ПРИЛОЖЕНИЯ НЕ ПРОВЕРЯЛИСЬ.
/// Подробности по каждому поставщику собирает `design notes`. Поэтому адрес и
/// правится руками, и виден человеку на экране: ошибись мы здесь — он поправит сам,
/// а не останется с молчащим приложением.
public enum RemoteProviderDirectory {

    public static let openRouter = RemoteProvider(
        id: "openrouter",
        displayName: "OpenRouter",
        baseURL: "https://openrouter.ai/api/v1",
        auth: .bearer,
        // Поставщик просит назвать приложение — по этим двум заголовкам он показывает
        // человеку в его же личном кабинете, кто именно потратил его деньги.
        extraHeaders: [
            "HTTP-Referer": "https://github.com/YOUR_GITHUB_USER/pocket-agent",
            "X-Title": "Pocket Agent"
        ],
        // Единственный из четырёх, кто присылает стоимость запроса деньгами.
        reportsCost: true,
        keyHint: "Ключ берётся в личном кабинете OpenRouter, раздел Keys."
    )

    public static let zai = RemoteProvider(
        id: "zai",
        displayName: "Z.AI",
        baseURL: "https://api.z.ai/api/paas/v4",
        auth: .bearer,
        keyHint: "Ключ берётся в личном кабинете Z.AI."
    )

    public static let opencodeZen = RemoteProvider(
        id: "opencode-zen",
        displayName: "OpenCode Zen",
        baseURL: "https://opencode.ai/zen/v1",
        auth: .bearer,
        keyHint: "Ключ берётся в личном кабинете OpenCode."
    )

    /// «Свой адрес» — для всех остальных. Ничего не подставляем: адрес человек вводит сам.
    public static let custom = RemoteProvider(
        id: "custom",
        displayName: "Свой адрес",
        baseURL: "",
        auth: .bearer,
        keyHint: "Адрес до /chat/completions и ключ — от вашего поставщика."
    )

    public static let all: [RemoteProvider] = [openRouter, zai, opencodeZen, custom]

    public static func provider(withID id: String) -> RemoteProvider? {
        all.first { $0.id == id }
    }
}

// MARK: - Ключ человека в защищённом хранилище

/// Ключ доступа лежит ТОЛЬКО здесь — в Keychain, отдельно на каждого поставщика.
///
/// ⚠️ ПОЧЕМУ ОТДЕЛЬНО НА КАЖДОГО. Человек пробует одного поставщика, переключается на
/// другого и возвращается обратно. Храни мы один ключ на всех — возврат означал бы
/// «введите ключ заново», причём молча: приложение показывало бы «ключ есть», а он
/// был бы чужой.
///
/// ⚠️ `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` выбран осознанно: ключ не уезжает
/// в резервную копию iCloud и не переносится на новый телефон. Это деньги человека —
/// пусть лучше он введёт ключ заново, чем ключ окажется там, где он его не клал.
public enum RemoteKeyStore {

    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "pocket-agent") + ".remote-key"
    }

    private static func query(for providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
    }

    /// Положить ключ. Пустая строка — то же самое, что «убрать».
    @discardableResult
    public static func save(_ key: String, for providerID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(for: providerID) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Перезапись = удалить и положить заново. Обновление на месте (`SecItemUpdate`)
        // требует, чтобы запись уже была, — а это лишняя развилка на ровном месте.
        SecItemDelete(query(for: providerID) as CFDictionary)

        var attributes = query(for: providerID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Достать ключ. nil — ключа нет.
    ///
    /// ⚠️ Возвращённую строку НЕЛЬЗЯ класть ни в журнал, ни в текст ошибки, ни в адрес
    /// запроса. Единственное её законное место — заголовок запроса (`RemoteRuntime`).
    public static func key(for providerID: String) -> String? {
        var request = query(for: providerID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    public static func remove(for providerID: String) -> Bool {
        let status = SecItemDelete(query(for: providerID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Ключ на месте? Спрашивается экраном — самого ключа он при этом не видит.
    public static func hasKey(for providerID: String) -> Bool {
        key(for: providerID) != nil
    }

    /// Последние знаки ключа — чтобы человек узнал, ЧТО у него лежит, не показывая ключ.
    /// ⚠️ Четыре знака: по ним ключ не восстановить, а «тот или не тот» видно.
    public static func tail(for providerID: String) -> String? {
        guard let key = key(for: providerID), key.count > 4 else { return nil }
        return "…" + String(key.suffix(4))
    }
}

// MARK: - Выбор человека

/// Настройки работы по ключу. Ключа доступа здесь НЕТ и быть не может — см. шапку файла.
public enum RemoteAccessSettings {

    // ⚠️ Приставка «pocketagent.remote.» выбрана НЕ ради красоты: шапка журнала
    // (`EngineDiagnostics.rememberedLines`) печатает все настройки с приставкой
    // «pocketagent.runtime.», и попади наши ключи туда — они уехали бы в буфер обмена
    // вместе с журналом. Здесь ничего секретного нет, но правило одно на весь файл.
    public static let enabledKey  = "pocketagent.remote.enabled"
    public static let providerKey = "pocketagent.remote.provider"
    public static let modelKey    = "pocketagent.remote.model"

    /// Адрес, поправленный руками, — СВОЙ У КАЖДОГО ПОСТАВЩИКА.
    ///
    /// ⚠️ РАНЬШЕ АДРЕС БЫЛ ОДИН НА ВСЕХ, И ЭТО БЫЛО ОПАСНО. Человек пробовал «Свой адрес»,
    /// вписывал туда чужую службу, возвращался на OpenRouter — и запрос с ключом OpenRouter
    /// уходил по вписанному чужому адресу, потому что поле никто не чистил. То есть ключ
    /// человека уезжал не тому, кому он его давал. Теперь адрес хранится отдельно на каждого
    /// поставщика: вернулся к OpenRouter — вернулся и его собственный адрес.
    public static func baseURLKey(for providerID: String) -> String {
        "pocketagent.remote.baseURL." + providerID
    }
    /// Цена, введённая человеком руками, — на случай, когда поставщик её не сообщает.
    public static let promptPriceKey = "pocketagent.remote.pricePrompt"
    public static let answerPriceKey = "pocketagent.remote.priceAnswer"

    private static var defaults: UserDefaults { .standard }

    /// Работать по ключу. ВЫКЛЮЧЕНО ПО УМОЛЧАНИЮ — это обещание продукта, а не настройка
    /// осторожности (см. шапку файла).
    public static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Выбранный поставщик. По умолчанию — первый из справочника.
    public static var providerID: String {
        get { defaults.string(forKey: providerKey) ?? RemoteProviderDirectory.openRouter.id }
        set { defaults.set(newValue, forKey: providerKey) }
    }

    public static var provider: RemoteProvider {
        RemoteProviderDirectory.provider(withID: providerID) ?? RemoteProviderDirectory.openRouter
    }

    /// Имя модели у поставщика («openai/gpt-4o-mini» и подобное). Пусто — не выбрана.
    public static var modelID: String {
        get { defaults.string(forKey: modelKey) ?? "" }
        set { defaults.set(newValue, forKey: modelKey) }
    }

    /// Адрес, если человек поправил его руками, — у ВЫБРАННОГО поставщика.
    /// Пусто — берём адрес самого поставщика.
    public static var customBaseURL: String {
        get { customBaseURL(for: providerID) }
        set { setCustomBaseURL(newValue, for: providerID) }
    }

    public static func customBaseURL(for providerID: String) -> String {
        defaults.string(forKey: baseURLKey(for: providerID)) ?? ""
    }

    public static func setCustomBaseURL(_ text: String, for providerID: String) {
        defaults.set(text.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: baseURLKey(for: providerID))
    }

    /// Адрес, по которому пойдёт запрос. Косая черта на конце срезается: иначе
    /// получается «…/v1//chat/completions», и часть служб отвечает отказом.
    public static var effectiveBaseURL: String {
        let chosen = customBaseURL.isEmpty ? provider.baseURL : customBaseURL
        var text = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Цена за миллион слов-кусочков, введённая человеком. 0 — не вводил.
    /// Нужна там, где поставщик цену не сообщает: без цены предел трат в долларах
    /// посчитать НЕ ИЗ ЧЕГО, и приложение об этом честно говорит, а не делает вид.
    public static var manualPromptPricePerMillion: Double {
        get { defaults.double(forKey: promptPriceKey) }
        set { defaults.set(newValue, forKey: promptPriceKey) }
    }

    public static var manualAnswerPricePerMillion: Double {
        get { defaults.double(forKey: answerPriceKey) }
        set { defaults.set(newValue, forKey: answerPriceKey) }
    }

    /// Есть ли из чего считать деньги: поставщик присылает счёт ИЛИ человек назвал цену.
    ///
    /// ⚠️ ЭТО НЕ МЕЛОЧЬ, А ЧЕСТНОСТЬ ПРО ПРЕДЕЛ ТРАТ. Счёт деньгами присылает только
    /// OpenRouter; у трёх остальных поставщиков без введённой руками цены потраченное
    /// не растёт вообще — то есть предел «мало ли сожжётся всё» не наступит никогда.
    /// Экран обязан сказать об этом прямо, а не обещать защиту, которой нет.
    public static var canCountMoney: Bool {
        provider.reportsCost
            || manualPromptPricePerMillion > 0
            || manualAnswerPricePerMillion > 0
    }

    /// Ключ выбранного поставщика на месте.
    public static var hasKey: Bool { RemoteKeyStore.hasKey(for: providerID) }

    /// Всё нужное на месте: включено, есть ключ, выбрана модель, известен адрес.
    public static var isReady: Bool {
        isEnabled && hasKey && !modelID.isEmpty && !effectiveBaseURL.isEmpty
    }

    /// Чего не хватает — одной русской фразой. nil — всё на месте.
    public static var missingPartText: String? {
        if !isEnabled { return "Работа по ключу выключена." }
        if effectiveBaseURL.isEmpty { return "Не задан адрес поставщика." }
        if !hasKey { return "Не введён ключ доступа." }
        if modelID.isEmpty { return "Не выбрана модель." }
        return nil
    }
}

// MARK: - Деньги

/// Сколько потрачено и где предел.
///
/// ⚠️ ПРЕДЕЛ ПО УМОЛЧАНИЮ — ОДИН ДОЛЛАР. Прямое требование владельца, дословно:
/// «мало ли там сожжётся всё». Поднять предел человек может сам на экране настройки;
/// опустить — тоже. Но по умолчанию приложение НЕ ДАЁТ потратить больше доллара,
/// даже если ключ человека позволяет тысячу.
///
/// ⚠️ СЧИТАЕМ В МИЛЛИОННЫХ ДОЛЛАРА (микродолларах) ЦЕЛЫМИ ЧИСЛАМИ, А НЕ В ДРОБНЫХ
/// ДОЛЛАРАХ. Один запрос к дешёвой модели стоит около 0,00002 доллара; складывая такие
/// дроби сотнями, дробное число копит собственную ошибку — и предел срабатывал бы
/// то раньше, то позже. Целое число миллионных не врёт никогда.
public enum RemoteSpend {

    public static let limitKey        = "pocketagent.remote.limitMicros"
    public static let spentKey        = "pocketagent.remote.spentMicros"
    public static let estimateKey     = "pocketagent.remote.spentHasEstimate"
    public static let uncountedKey    = "pocketagent.remote.uncountedTurns"
    public static let startedKey      = "pocketagent.remote.countingSince"

    /// Один доллар в миллионных.
    public static let oneDollar = 1_000_000

    private static var defaults: UserDefaults { .standard }

    /// Предел трат в миллионных доллара. Не задан — один доллар.
    public static var limitMicros: Int {
        get {
            let saved = defaults.integer(forKey: limitKey)
            return saved > 0 ? saved : oneDollar
        }
        set { defaults.set(max(0, newValue), forKey: limitKey) }
    }

    /// Потрачено в миллионных доллара.
    public static var spentMicros: Int {
        get { defaults.integer(forKey: spentKey) }
        set { defaults.set(max(0, newValue), forKey: spentKey) }
    }

    /// Хотя бы одна из сложенных сумм — наша прикидка по токенам, а не счёт поставщика.
    /// От этого зависит ОДНО СЛОВО на экране — «потрачено» или «потрачено примерно», —
    /// и это слово важнее многих: человек должен знать, чему верить.
    public static var hasEstimates: Bool {
        get { defaults.bool(forKey: estimateKey) }
        set { defaults.set(newValue, forKey: estimateKey) }
    }

    /// Ходы, которые в деньги перевести не удалось: поставщик не прислал счёта, а цены
    /// не назвал никто — ни он, ни человек. Молчать об этом нельзя: предел трат на такие
    /// ходы не действует.
    ///
    /// ⚠️ СЧИТАЕМ ХОДЫ, А НЕ СЛОВА-КУСОЧКИ, И ЭТО ВАЖНО. Слова-кусочки известны только
    /// когда поставщик прислал отчёт; когда отчёта нет вовсе (а так отвечает часть служб),
    /// не росло ВООБЩЕ НИЧЕГО — ни деньги, ни пометка. Человек видел «Потрачено 0,00 $»
    /// после десятка платных ходов и был уверен, что предел его бережёт. Ход же виден
    /// всегда, и «ходов мимо счёта: 12» человек понимает без объяснений.
    public static var uncountedTurns: Int {
        get { defaults.integer(forKey: uncountedKey) }
        set { defaults.set(max(0, newValue), forKey: uncountedKey) }
    }

    /// С какого дня считаем. Нужно только для честной подписи на экране.
    public static var countingSince: Date? {
        get { defaults.object(forKey: startedKey) as? Date }
        set { defaults.set(newValue, forKey: startedKey) }
    }

    public static var remainingMicros: Int { max(0, limitMicros - spentMicros) }

    /// Предел достигнут — дальше не работаем.
    public static var isOverLimit: Bool { spentMicros >= limitMicros }

    /// Записать трату.
    /// - Parameter isEstimate: это наша прикидка по токенам, а не счёт поставщика.
    public static func add(micros: Int, isEstimate: Bool) {
        guard micros > 0 else { return }
        if countingSince == nil { countingSince = Date() }
        spentMicros += micros
        if isEstimate { hasEstimates = true }
    }

    /// Записать ход, который в деньги не перевели.
    public static func noteUncountedTurn() {
        if countingSince == nil { countingSince = Date() }
        uncountedTurns += 1
    }

    /// Начать счёт заново — по нажатию человека, и только по нему.
    public static func reset() {
        spentMicros = 0
        hasEstimates = false
        uncountedTurns = 0
        countingSince = Date()
    }

    // MARK: Слова для человека

    /// «0,42 $» — деньги человеческим языком.
    ///
    /// ⚠️ Считаем сами, без системного форматировщика: он берёт разделитель дробной
    /// части из настроек ТЕЛЕФОНА, и на англоязычном устройстве вышло бы «0.42» —
    /// ровно та беда, ради которой в проекте заведён `HumanFormat`.
    public static func money(_ micros: Int) -> String {
        let dollars = Double(micros) / 1_000_000
        let text: String
        if dollars > 0, dollars < 0.01 {
            // Меньше цента. Округлив до сотых, мы написали бы «0,00 $» — то есть
            // «бесплатно», а это неправда.
            text = String(format: "%.4f", dollars)
        } else {
            text = String(format: "%.2f", dollars)
        }
        return text.replacingOccurrences(of: ".", with: ",") + " $"
    }

    /// Строка для экрана: «Потрачено примерно 0,04 $ из 1,00 $».
    public static var statusText: String {
        let prefix = hasEstimates ? "Потрачено примерно" : "Потрачено"
        return "\(prefix) \(money(spentMicros)) из \(money(limitMicros))"
    }
}

// MARK: - Список моделей у поставщика

/// Одна модель поставщика: имя и цена, если он её сообщил.
public struct RemoteModelOption: Sendable, Equatable, Identifiable, Hashable {
    /// Имя, которое уходит в запрос («openai/gpt-4o-mini»).
    public let id: String
    /// Имя для человека. Часто совпадает с `id` — тогда показываем его.
    public let displayName: String
    /// Цена за миллион слов-кусочков запроса. nil — поставщик не сообщил.
    public let promptPricePerMillion: Double?
    /// Цена за миллион слов-кусочков ответа. nil — поставщик не сообщил.
    public let answerPricePerMillion: Double?

    public init(id: String,
                displayName: String,
                promptPricePerMillion: Double?,
                answerPricePerMillion: Double?) {
        self.id = id
        self.displayName = displayName
        self.promptPricePerMillion = promptPricePerMillion
        self.answerPricePerMillion = answerPricePerMillion
    }

    /// Цена одной строкой: «0,15 $ / 0,60 $ за миллион». nil — цены нет.
    public var priceText: String? {
        guard let promptPricePerMillion, let answerPricePerMillion else { return nil }
        func money(_ value: Double) -> String {
            String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
        }
        return "\(money(promptPricePerMillion)) $ / \(money(answerPricePerMillion)) $ за миллион"
    }
}

/// Список моделей спрашивается У ПОСТАВЩИКА, а не зашивается в приложение.
///
/// ⚠️ ПОЧЕМУ ИМЕННО ТАК. Зашитый список устаревает в тот же месяц: модели у поставщиков
/// появляются и исчезают еженедельно. Человек, выбравший из нашего списка исчезнувшую
/// модель, получил бы отказ поставщика и ни одного объяснения. Спрошенный список
/// врать не может — он и есть правда на сегодня.
public enum RemoteModelDirectory {

    /// Своя короткая сессия: без кэша и без печенья, как у поиска моделей.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// Спросить список моделей.
    ///
    /// - Throws: `PocketAgentError.remoteKeyRejected`, если ключ не принят, —
    ///   это единственный ответ, который человеку нужно разобрать немедленно.
    public static func models(provider: RemoteProvider,
                              baseURL: String,
                              key: String) async throws -> [RemoteModelOption] {

        guard let url = URL(string: baseURL + "/models") else {
            throw PocketAgentError.remoteBadAddress(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let auth = provider.auth.header(for: key)
        request.setValue(auth.value, forHTTPHeaderField: auth.name)
        for (name, value) in provider.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        if code == 401 || code == 403 {
            throw PocketAgentError.remoteKeyRejected
        }
        guard (200..<300).contains(code) else {
            throw PocketAgentError.remoteModelsUnavailable
        }

        return parse(data)
    }

    /// Разбор ответа. Форма общая для всех: `{"data": [{"id": …, "pricing": {…}}]}`.
    ///
    /// ⚠️ Разбираем ВРУЧНУЮ, а не готовым разбором по типам, и это осознанно: у разных
    /// поставщиков в одном и том же поле лежит то строка, то число, то его нет вовсе.
    /// Строгий разбор уронил бы весь список из-за одной чужой модели с непривычным полем.
    static func parse(_ data: Data) -> [RemoteModelOption] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let rows = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []

        var out: [RemoteModelOption] = []
        for row in rows {
            guard let id = row["id"] as? String ?? row["name"] as? String, !id.isEmpty else { continue }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let pricing = row["pricing"] as? [String: Any]
            out.append(RemoteModelOption(
                id: id,
                displayName: name,
                // ⚠️ Цена у поставщиков указана ЗА ОДНО слово-кусочек и строкой
                // («0.00000015»). Переводим в цену за миллион — только так число
                // читается человеком.
                promptPricePerMillion: perMillion(pricing?["prompt"]),
                answerPricePerMillion: perMillion(pricing?["completion"])
            ))
        }
        // По имени: список в сотни строк без порядка искать невозможно.
        return out.sorted { $0.id < $1.id }
    }

    /// Цена за миллион из цены за штуку. Приходит то строкой, то числом.
    private static func perMillion(_ raw: Any?) -> Double? {
        let value: Double?
        if let text = raw as? String { value = Double(text) }
        else if let number = raw as? NSNumber { value = number.doubleValue }
        else { value = nil }
        guard let value, value >= 0 else { return nil }
        return value * 1_000_000
    }
}
