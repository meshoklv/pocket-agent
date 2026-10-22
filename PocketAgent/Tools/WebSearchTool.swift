//
//  WebSearchTool.swift
//  PocketAgent / Tools
//
//  Пятое действие — поиск в интернете. Всё, что с ним связано, живёт в одном файле:
//    • WebSearchSettings  — переключатель человека (выключено по умолчанию);
//    • WebSearchHit       — одна находка;
//    • источники          — Википедия и Stack Overflow;
//    • WebSearchService   — спрашивает источники разом и мешает находки;
//    • WebSearchTool      — сам инструмент для модели.
//
//  ⚠️ ГЛАВНОЕ, ЧЕГО ЗДЕСЬ НЕТ И НЕ ДОЛЖНО ПОЯВИТЬСЯ.
//  1. Наружу уходят ТОЛЬКО слова запроса. Ни файлов человека, ни его задачи,
//     ни имени папки, ни чего-либо о телефоне — здесь просто неоткуда взять
//     ничего, кроме строки `query`.
//  2. В папку человека поиск не пишет НИЧЕГО. Захочет сохранить найденное —
//     это обычная запись файла: карточка, дифф, кнопка «Применить».
//  3. Целые страницы в модель не отдаются НИКОГДА. Только заголовок, две строки
//     выжимки и короткий адрес — пределы в AgentLimits.webSearch*.
//  4. Пока человек не включил поиск, инструмента нет ни в реестре, ни в схеме
//     для модели. Проверка стоит ДВАЖДЫ: при сборке реестра и здесь, перед самым
//     запросом, — переключатель могли выключить посреди задачи.
//
//  ⚠️ ПОЧЕМУ ИМЕННО ЭТИ ДВА ИСТОЧНИКА (проверено живыми запросами 09.08.2026).
//  Настоящего поисковика с открытым доступом «без ключа и без учётной записи»
//  не существует: Google, Bing, Яндекс, Brave и Mojeek требуют ключ, а свободный
//  SearXNG требует собственного сервера — то есть ровно того, от чего продукт уходит.
//  Из того, что работает без ключа, разрешает встраивание и отвечает из России:
//    • Википедия (ru и en, официальный открытый API, CC BY-SA) — общие сведения;
//    • Stack Overflow (Stack Exchange API, без ключа, CC BY-SA) — вопросы по коду,
//      то есть ровно то, за чем к кодинг-агенту и приходят.
//  Оба отдают короткие выжимки, а не страницы, — то, что нам и нужно.
//

import Foundation

// MARK: - Переключатель человека

/// «Искать в интернете» — единственное место, где хранится решение человека.
///
/// ⚠️ ВЫКЛЮЧЕНО ПО УМОЛЧАНИЮ, И ЭТО НЕ НАСТРОЙКА ОСТОРОЖНОСТИ, А ОБЕЩАНИЕ ПРОДУКТА.
/// Приложение говорит человеку, что его задачи и файлы никуда не уходят. Поиск это
/// обещание меняет, поэтому включить его может только человек и только сам:
/// `UserDefaults.bool(forKey:)` на незаданном ключе отдаёт `false` — то есть у всех,
/// кто ничего не трогал, поиска нет.
///
/// Интерфейсу для переключателя ничего заводить не нужно: тот же ключ читается
/// из SwiftUI как `@AppStorage(WebSearchSettings.defaultsKey)`.
public enum WebSearchSettings {

    /// Ключ в настройках приложения. Одна строка на весь проект.
    public static let defaultsKey = "webSearchEnabled"

    /// Человек разрешил выходить в интернет.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

// MARK: - Одна находка

/// Что нашлось: заголовок, выжимка и адрес.
public struct WebSearchHit: Sendable, Equatable {
    /// Название страницы.
    public let title: String
    /// Две строки о том, что там написано.
    public let snippet: String
    /// Полный адрес — его показываем ЧЕЛОВЕКУ, чтобы он мог открыть и проверить.
    public let link: String
    /// Короткий адрес того же места — он уходит МОДЕЛИ.
    ///
    /// ⚠️ Два адреса вместо одного заведены ради памяти разговора. Читаемая ссылка
    /// на статью с русским названием — это 150 знаков, то есть дороже самой выжимки;
    /// четыре таких съедают четверть ответа. Короткая форма («ru.wikipedia.org/?curid=…»)
    /// ведёт ровно туда же, стоит впятеро дешевле и всегда состоит из латиницы.
    public let modelLink: String
    /// Откуда находка — это видит человек: «Википедия», «Stack Overflow».
    public let source: String

    public init(title: String, snippet: String, link: String, modelLink: String, source: String) {
        self.title = title
        self.snippet = snippet
        self.link = link
        self.modelLink = modelLink
        self.source = source
    }
}

// MARK: - Источник

/// Один источник поиска. Их несколько, и каждый обязан уметь ровно одно:
/// по словам запроса вернуть короткие находки или честно упасть.
public protocol WebSearchProviding: Sendable {
    /// Название для человека.
    var sourceName: String { get }
    /// Найти. Бросать можно что угодно: служба ловит и превращает в русскую фразу.
    func search(query: String, limit: Int) async throws -> [WebSearchHit]
}

// MARK: - Разбор текста, который прислал интернет

/// Чужой текст всегда приходит с разметкой и мусором. Здесь он превращается
/// в простые строки, которые не стыдно показать человеку и отдать модели.
enum WebSearchText {

    /// Убирает теги и подстановки вроде `&quot;`, схлопывает пробелы.
    ///
    /// ⚠️ Свой разбор, а не `NSAttributedString(html:)`: тот тянет за собой WebKit,
    /// работает только на главном потоке и на телефоне стоит десятки миллисекунд
    /// на каждую строчку. Нам нужно снять `<span class="searchmatch">` и `&hellip;` —
    /// для этого хватает пятнадцати строк.
    static func plain(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var insideTag = false
        for character in raw {
            if character == "<" {
                insideTag = true
                continue
            }
            if character == ">" {
                insideTag = false
                continue
            }
            if !insideTag {
                out.append(character)
            }
        }
        return squeeze(decodeEntities(out))
    }

    /// Подстановки HTML в обычные знаки.
    ///
    /// ⚠️ `&amp;` меняется ПОСЛЕДНИМ, и это не придирка: поменяй его первым —
    /// и записанный текстом «&amp;lt;» превратится в настоящую скобку «<».
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        // ⚠️ Записи с нулём впереди (`&#039;`) — не выдумка «на всякий случай»:
        // именно так апостроф приходит от Википедии, проверено живым ответом 09.08.2026.
        // Без них человек читал бы «Landhelgisstríðin, lit. &#039;The Coastal Wars&#039;».
        let pairs: [(String, String)] = [
            ("&quot;", "\""), ("&#34;", "\""), ("&#034;", "\""),
            ("&#39;", "'"), ("&#039;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
            ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&nbsp;", " "), ("&laquo;", "«"), ("&raquo;", "»"),
            ("&amp;", "&")
        ]
        for (entity, symbol) in pairs {
            out = out.replacingOccurrences(of: entity, with: symbol)
        }
        return out
    }

    /// Любые пробелы и переводы строк — в один обычный пробел.
    /// Выжимка обязана быть одной строкой: перевод строки внутри неё ломает
    /// нумерованный список, которым ответ уходит модели.
    static func squeeze(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// Обрезает до `limit` знаков, по возможности по границе слова.
    static func clip(_ text: String, to limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        let head = text.prefix(limit)
        // Обрывать слово посередине некрасиво, но обрывать в самом начале строки —
        // хуже: останется огрызок в два знака. Поэтому границу слова ищем только
        // во второй половине куска.
        if let space = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[head.startIndex..<space]) + "…"
        }
        return String(head) + "…"
    }
}

// MARK: - Сеть

/// Одно соединение с интернетом на весь поиск и все правила похода наружу.
enum WebSearchHTTP {

    /// Как приложение представляется источникам.
    ///
    /// ⚠️ Этого требуют правила Викимедиа: клиент обязан назвать себя и оставить
    /// способ связи, иначе его блокируют без предупреждения. Заодно это честно:
    /// на той стороне видно, что пришло наше приложение, а не подделка под браузер
    /// (за браузерную подпись у бота там же обещают считать поведение вредоносным).
    /// Ничего о человеке и его телефоне в подписи нет и быть не должно.
    static let userAgent =
        "PocketAgent/1.0 (https://github.com/YOUR_GITHUB_USER/pocket-agent) offline-coding-agent"

    /// Знаки, которые обязаны быть закодированы в значении параметра запроса.
    ///
    /// ⚠️ `.urlQueryAllowed` пропускает «&», «=», «+» и «#» — то есть запрос
    /// «C++ & Swift» разъехался бы на несколько параметров. Убираем их отдельно.
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()

    /// Соединение без следов: ни кук, ни кэша на диске.
    ///
    /// ⚠️ `.ephemeral` выбран намеренно. Обычная сессия сложила бы куки источников
    /// в контейнер приложения, и «ничего не сохраняется» перестало бы быть правдой.
    /// Мобильная сеть разрешена — так же, как у загрузки модели: запрещать человеку
    /// его же интернет мы не будем.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(AgentLimits.webSearchTimeoutSeconds)
        config.timeoutIntervalForResource = TimeInterval(AgentLimits.webSearchTimeoutSeconds)
        config.allowsCellularAccess = true
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json"
        ]
        return URLSession(configuration: config)
    }()

    /// Собрать адрес из готовой строки. nil — значит адрес не сложился.
    static func url(_ text: String) -> URL? {
        URL(string: text)
    }

    /// Запросить и вернуть тело ответа. Всё, что не «двести», — это отказ источника.
    static func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw WebSearchFailure.rejected(status: http.statusCode)
        }
        return data
    }

    /// Запрос в поиск, приведённый к виду параметра адреса. nil — кодировать нечего.
    static func encoded(query: String) -> String? {
        let trimmed = String(query.prefix(AgentLimits.webSearchQueryChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
    }
}

/// Почему поиск не получился. Тексты сразу русские: их читает и человек, и модель.
enum WebSearchFailure: Error {
    /// Источник ответил отказом (слишком часто спрашиваем, запрос не понят).
    case rejected(status: Int)
    /// Запрос пуст или из него нечего собрать.
    case emptyQuery
    /// Ответ источника не разобрался.
    case unreadableAnswer
}

// MARK: - Википедия

/// Общие сведения: определения, названия, кто это и что это.
///
/// Условия использования: открытый API Викимедиа, без ключа и без учётной записи,
/// содержимое под CC BY-SA. Требование одно — назвать себя в подписи клиента,
/// это делает WebSearchHTTP.userAgent. Живой запрос 09.08.2026: отвечает и из России.
public struct WikipediaSearchProvider: WebSearchProviding {

    public let sourceName = "Википедия"

    public init() {}

    public func search(query: String, limit: Int) async throws -> [WebSearchHit] {
        guard let encoded = WebSearchHTTP.encoded(query: query) else {
            throw WebSearchFailure.emptyQuery
        }
        let language = Self.language(for: query)
        guard let url = WebSearchHTTP.url(
            "https://\(language).wikipedia.org/w/rest.php/v1/search/page?q=\(encoded)&limit=\(limit)"
        ) else {
            throw WebSearchFailure.emptyQuery
        }

        let data = try await WebSearchHTTP.data(from: url)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw WebSearchFailure.unreadableAnswer
        }

        return answer.pages.prefix(limit).map { page -> WebSearchHit in
            // Выжимка — это найденный кусок статьи; если его нет, берём короткое
            // пояснение вида «язык программирования, созданный компанией Apple».
            let excerpt = WebSearchText.plain(page.excerpt ?? "")
            let snippet = excerpt.isEmpty ? WebSearchText.plain(page.description ?? "") : excerpt

            // Читаемый адрес — человеку. Пробелов в ключе не бывает, но подстраховаться
            // дешевле, чем однажды показать ссылку с дыркой посередине.
            let readableKey = page.key.replacingOccurrences(of: " ", with: "_")
            return WebSearchHit(
                title: WebSearchText.plain(page.title),
                snippet: snippet,
                link: "https://\(language).wikipedia.org/wiki/\(readableKey)",
                // Короткий адрес по номеру статьи — модели. Ведёт туда же.
                modelLink: "\(language).wikipedia.org/?curid=\(page.id)",
                source: sourceName
            )
        }
    }

    /// В какой Википедии искать.
    ///
    /// ⚠️ Решаем по буквам запроса, а не по языку телефона: человек с русским
    /// телефоном пишет «swift codable» — и русская Википедия про это молчит,
    /// а английская отвечает. И наоборот: «борщ» в английской не найдётся.
    static func language(for query: String) -> String {
        for scalar in query.unicodeScalars where (0x0400...0x04FF).contains(scalar.value) {
            return "ru"
        }
        return "en"
    }

    /// Ответ Викимедиа. Разбираем только то, что показываем.
    private struct Answer: Decodable {
        let pages: [Page]

        struct Page: Decodable {
            let id: Int
            let key: String
            let title: String
            /// Кусок статьи с подсветкой найденных слов — бывает пустым.
            let excerpt: String?
            /// Короткое пояснение к названию — тоже бывает пустым.
            let description: String?
        }
    }
}

// MARK: - Stack Overflow

/// Вопросы по коду: ошибки, «как сделать», чужие грабли.
///
/// Условия использования: Stack Exchange API работает без ключа (квота считается
/// по адресу устройства, порядка трёхсот запросов в сутки — на карманного агента
/// с запасом), содержимое под CC BY-SA, ссылка на исходный вопрос обязательна —
/// поэтому адрес идёт в каждой находке и человеку, и модели.
/// Живой запрос 09.08.2026: отвечает и из России.
public struct StackOverflowSearchProvider: WebSearchProviding {

    public let sourceName = "Stack Overflow"

    public init() {}

    public func search(query: String, limit: Int) async throws -> [WebSearchHit] {
        guard let encoded = WebSearchHTTP.encoded(query: query) else {
            throw WebSearchFailure.emptyQuery
        }
        // /search/excerpts — единственная их выдача, где сразу приходит выжимка.
        // ⚠️ Вместе с ней приходит и полный текст вопроса: убрать его можно только
        // «фильтром» с нечитаемым опознавателем, который у них меняется. Лишние
        // килобайты остаются в телефоне и никуда дальше не идут — в модель уходит
        // только выжимка, обрезанная по нашему пределу.
        guard let url = WebSearchHTTP.url(
            "https://api.stackexchange.com/2.3/search/excerpts"
                + "?order=desc&sort=relevance&site=stackoverflow&pagesize=\(limit)&q=\(encoded)"
        ) else {
            throw WebSearchFailure.emptyQuery
        }

        let data = try await WebSearchHTTP.data(from: url)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw WebSearchFailure.unreadableAnswer
        }

        return answer.items.prefix(limit).map { item -> WebSearchHit in
            var snippet = WebSearchText.plain(item.excerpt ?? "")
            // Отвечен вопрос или нет — единственная пометка, которая стоит своих
            // трёх слов: она отличает готовый ответ от такого же вопроса без ответа.
            if item.isAnswered == true {
                snippet = snippet.isEmpty ? "есть ответ" : snippet + " (есть ответ)"
            }
            let link = "https://stackoverflow.com/q/\(item.questionID)"
            return WebSearchHit(
                title: WebSearchText.plain(item.title),
                snippet: snippet,
                link: link,
                // Здесь короткий и читаемый адрес — это одно и то же: у них
                // и так номер вопроса вместо названия.
                modelLink: "stackoverflow.com/q/\(item.questionID)",
                source: sourceName
            )
        }
    }

    private struct Answer: Decodable {
        let items: [Item]

        struct Item: Decodable {
            let title: String
            let excerpt: String?
            let questionID: Int
            let isAnswered: Bool?

            enum CodingKeys: String, CodingKey {
                case title
                case excerpt
                case questionID = "question_id"
                case isAnswered = "is_answered"
            }
        }
    }
}

// MARK: - Служба поиска

/// Чем кончился поиск: находки и — если не вышло совсем — русская причина.
public struct WebSearchOutcome: Sendable, Equatable {
    public let hits: [WebSearchHit]
    /// Ни один источник не ответил. nil — спрашивать было у кого.
    public let failure: String?

    public init(hits: [WebSearchHit], failure: String? = nil) {
        self.hits = hits
        self.failure = failure
    }
}

/// Спрашивает все источники разом и мешает находки.
public struct WebSearchService: Sendable {

    private let providers: [any WebSearchProviding]

    /// ⚠️ ПОРЯДОК ИСТОЧНИКОВ ЗДЕСЬ — ЭТО ПОРЯДОК НАХОДОК У МОДЕЛИ, И ОН ВЫБРАН ПО ЖИВОЙ
    /// ПРОВЕРКЕ, А НЕ ПО ВКУСУ. Запрос «swift codable» 09.08.2026: Stack Overflow отдал
    /// три вопроса точно по делу, а Википедия — футбольный клуб «Свифт», Кейп-Код-канал
    /// и «Тресковые войны». У нас кодинг-агент, и первыми модель обязана видеть ответы
    /// про код: до конца списка маленькая модель часто и не дочитывает.
    public init(providers: [any WebSearchProviding] = [StackOverflowSearchProvider(),
                                                       WikipediaSearchProvider()]) {
        self.providers = providers
    }

    /// Найти. Не бросает никогда: неудача — это тоже ответ, и он короткий.
    public func search(query: String) async -> WebSearchOutcome {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return WebSearchOutcome(hits: [], failure: "Пустой запрос — скажи, что искать.")
        }
        guard !providers.isEmpty else {
            return WebSearchOutcome(hits: [], failure: "Искать негде.")
        }

        let perSource = AgentLimits.webSearchResultsPerSource
        // Место под ответ каждого источника заводим заранее: так порядок находок
        // не зависит от того, кто ответил быстрее, и одинаковый запрос даёт
        // одинаковый ответ. Иначе разбор одной и той же поломки был бы невозможен.
        var collected = [[WebSearchHit]](repeating: [], count: providers.count)
        var failures = 0

        await withTaskGroup(of: (Int, [WebSearchHit], Bool).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    // ⚠️ Сама ошибка из задачи НЕ выносится: её тип не обязан быть
                    // безопасным для передачи между задачами, и Swift на этом ругается.
                    // Наружу отдаём признак «не ответил» — больше про неудачу и не нужно.
                    //
                    // ⚠️ И этот признак — НЕ «список пуст». Пустой список бывает
                    // законным ответом («такого в Википедии нет»), и путать его
                    // с обрывом связи нельзя: человеку это два разных совета —
                    // «спроси иначе» и «включи интернет».
                    do {
                        let hits = try await provider.search(query: text, limit: perSource)
                        return (index, hits, false)
                    } catch {
                        return (index, [], true)
                    }
                }
            }
            for await (index, hits, didFail) in group {
                if didFail { failures += 1 }
                collected[index] = hits
            }
        }

        let merged = Self.merge(collected, limit: AgentLimits.webSearchMaxResults)

        if merged.isEmpty {
            // Разница честная и важная: «интернет молчит» и «в интернете этого нет» —
            // это два разных совета человеку.
            let reason = failures == providers.count
                ? "Не удалось спросить интернет — похоже, нет связи."
                : "Ничего не нашлось."
            return WebSearchOutcome(hits: [], failure: reason)
        }
        return WebSearchOutcome(hits: merged, failure: nil)
    }

    /// Мешает находки по кругу: первая от каждого источника, потом вторая и так далее.
    ///
    /// ⚠️ По кругу, а не подряд, — чтобы один разговорчивый источник не занял собой
    /// весь ответ. При пределе в четыре находки «подряд» означало бы, что до второго
    /// источника очередь не доходит вообще.
    static func merge(_ lists: [[WebSearchHit]], limit: Int) -> [WebSearchHit] {
        var out: [WebSearchHit] = []
        var round = 0
        let deepest = lists.map(\.count).max() ?? 0

        while out.count < limit && round < deepest {
            for list in lists where round < list.count {
                out.append(list[round])
                if out.count >= limit { break }
            }
            round += 1
        }
        return out
    }
}

// MARK: - Сам инструмент

/// Пятое действие модели: спросить интернет.
///
/// ⚠️ В реестр попадает ТОЛЬКО когда человек включил поиск (см. AgentAssembly).
/// Здесь стоит вторая такая же проверка — на случай, если переключатель выключили
/// посреди задачи: сессия агента живёт до конца разговора, и без этой проверки
/// один запрос всё-таки успел бы уйти после выключения.
public struct WebSearchTool: AgentTool {

    public let kind: ToolKind = .webSearch

    /// Текст берётся из ToolTexts — тот же самый уходит в схему для модели.
    public let details = ToolTexts.webSearch

    public let parameters: [ToolParameterSpec] = [
        // Одно поле, и это принципиально: чем меньше полей у действия, тем реже
        // маленькая модель забывает их заполнить.
        ToolParameterSpec(name: "query",
                          details: ToolTexts.webSearchQuery,
                          type: .string,
                          isRequired: true)
    ]

    private let service: WebSearchService

    public init(service: WebSearchService = WebSearchService()) {
        self.service = service
    }

    // MARK: Предпросмотр

    /// Показывает, что именно уйдёт наружу. В сеть здесь не ходим: предпросмотр
    /// обязан быть мгновенным и бесплатным.
    public func preview(_ invocation: ToolInvocation) async throws -> ActionPreview {
        .text(title: "Искать в интернете", body: invocation.query)
    }

    // MARK: Поиск

    public func execute(_ invocation: ToolInvocation) async throws -> ToolResult {
        let query = invocation.query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return ToolResult.failure(invocation,
                                      error: .missingArgument(tool: kind.rawValue, argument: "query"))
        }
        guard WebSearchSettings.isEnabled else {
            return ToolResult.failure(invocation, error: .webSearchDisabled)
        }

        // ⚠️ ПОСЛЕДНЯЯ ПРОВЕРКА ПЕРЕД ВЫХОДОМ НАРУЖУ: в запросе не должно быть ключа
        // или пароля. Модель на 2 млрд параметров вполне способна взять непонятную
        // строку из файла и «поискать, что это такое». Читать файлы с секретами агенту
        // и так не дают, но текст мог попасть к нему из задачи самого человека —
        // а отправленный в поиск ключ считается утёкшим навсегда.
        // Список примет — тот же, что у чтения файлов: два списка разошлись бы.
        do {
            try SecurityScopedWorkspace.ensureNoSecrets(in: query, relativePath: "запрос")
        } catch {
            // ⚠️ Здесь НЕ .webSearchFailed: это не беда со связью, а кривой ход модели,
            // и счётчик неудачных ходов обязан его посчитать. Иначе агент будет
            // долбиться в поиск с тем же ключом до конца отведённых шагов.
            return ToolResult.failure(
                invocation,
                reason: "В запросе похоже лежит ключ или пароль — наружу такое не уходит. "
                    + "Спроси словами, без ключей."
            )
        }

        let outcome = await service.search(query: query)

        guard !outcome.hits.isEmpty else {
            let reason = outcome.failure ?? "Ничего не нашлось."
            // ⚠️ Ошибка сети возвращается модели КОРОТКОЙ ФРАЗОЙ, а не падением задачи:
            // человек в метро не должен терять работу из-за того, что агент решил
            // что-то уточнить. Тип ошибки несём с собой, чтобы цикл агента мог отличить
            // «нет связи» от кривого хода модели (ToolResult.isNetworkProblem).
            return ToolResult.failure(invocation,
                                      reason: reason + " Работай с тем, что есть в файлах.",
                                      error: .webSearchFailed(reason))
        }

        return ToolResult.success(for: invocation,
                                  payload: .lines(Self.modelLines(for: outcome.hits)),
                                  userSummary: Self.humanText(query: query, hits: outcome.hits))
    }

    // MARK: Что видит модель

    /// Находки короткими строками: «1. Заголовок — выжимка · адрес».
    ///
    /// ⚠️ Здесь и стоит главный предохранитель по размеру. Ответ собирается
    /// по одной находке и обрывается ЦЕЛОЙ находкой, как только упирается
    /// в AgentLimits.webSearchAnswerChars. Обрезать находку на полуслове нельзя:
    /// модель дочитает половину заголовка и перескажет её человеку как факт.
    static func modelLines(for hits: [WebSearchHit]) -> [String] {
        var lines: [String] = []
        var used = 0

        for (index, hit) in hits.prefix(AgentLimits.webSearchMaxResults).enumerated() {
            let title = WebSearchText.clip(hit.title, to: AgentLimits.webSearchTitleChars)
            let snippet = WebSearchText.clip(hit.snippet, to: AgentLimits.webSearchSnippetChars)

            var line = "\(index + 1). \(title)"
            if !snippet.isEmpty {
                line += " — \(snippet)"
            }
            line += " · \(hit.modelLink)"

            if !lines.isEmpty && used + line.count > AgentLimits.webSearchAnswerChars {
                break
            }
            used += line.count
            lines.append(line)
        }
        return lines
    }

    // MARK: Что видит человек

    /// Строка для ленты: что искали и что нашли, со ссылками целиком.
    ///
    /// ⚠️ Ссылки человеку даём ПОЛНЫЕ и настоящие. Он вправе открыть их и проверить,
    /// откуда агент это взял: находка из интернета — не то же самое, что строка
    /// из его собственного файла, и доверия ей меньше.
    static func humanText(query: String, hits: [WebSearchHit]) -> String {
        var text = "Искал в интернете: «\(query)»"
        for hit in hits {
            text += "\n• \(WebSearchText.clip(hit.title, to: AgentLimits.webSearchTitleChars))"
                + " · \(hit.source)\n  \(hit.link)"
        }
        return text
    }
}
