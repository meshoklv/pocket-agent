//
//  ModelSearchView.swift
//  PocketAgent
//
//  Поиск моделей прямо в приложении — и честная пометка «пойдёт или нет».
//
//  ⚠️ ЗАЧЕМ ЭКРАН ПОЯВИЛСЯ (ROADMAP, раздел 7). Раньше выбор человека был заперт
//  в нашем списке из десятка файлов: всё остальное приходилось искать в браузере,
//  качать другим приложением и приносить файлом. Теперь модель ищется здесь же.
//
//  ⚠️ ГЛАВНОЕ НА ЭКРАНЕ — НЕ ПОИСК, А ПОМЕТКА. Зелёная стоит только там, где
//  приложение действительно запустит файл и памяти телефона хватает. Везде, где
//  мы не уверены, стоит серая или жёлтая с объяснением: жёлтая с объяснением лучше
//  зелёной с враньём.
//
//  ⚠️ КАК СЮДА ПОПАСТЬ — ПРОВЕРЕНО ПО КОДУ 09.08.2026, НЕ ИСКАТЬ ЗАНОВО.
//  Два пути, оба с вкладки «Модели» (`ModelSetupView`):
//    • строка «Найти модель в интернете» под списком «Какую модель поставить»;
//    • меню «…» → «Найти модель в интернете».
//  Саму страницу открывает ModelSetupView — там же, где он открывает «О программе»
//  и «Где взять файл». Искать в ModelSetupView.swift: `ModelSearchView(`.
//
//  ⚠️ И ОТДЕЛЬНО ПРО ПОИСК ПО КОДУ, потому что на этом дважды ошиблись. Проводка
//  страницы живёт в `extension AgentAssembly` (файл Agent/HubSearchAssembly.swift):
//  поиск по имени файла не находит НИЧЕГО, хотя код вызывается. Искать надо
//  `searchHub` и `startHubDownload`.
//
//  ⚠️ ЖИВОЙ СПИСОК ЖИВЁТ ТОЛЬКО ЗДЕСЬ, И ЭТО РЕШЕНИЕ ВЛАДЕЛЬЦА (10.08.2026).
//  Один день у него был второй вход — блок «Свежее из интернета» прямо на вкладке
//  «Модели» (`LiveModelsSection`). Владелец его забраковал: «вкладка свежее
//  из интернета — колхоз, убери это или спрячь в раздел». Блок убран, а сам тип
//  удалён вместе с ним — мёртвая вьюха с описанием «я стою на вкладке» в этом файле
//  уже дважды приводила к тому, что живой экран считали мёртвым и переподключали.
//  То, ради чего блок делался, никуда не делось и лежит на ЭТОЙ странице: свежий
//  список приходит сразу при открытии, печатать ничего не надо, а порядок
//  («В тренде», «Нравятся», «Качают», «Новые») выбирается в меню у строки поиска.
//
//  ⚠️ ПОРЯДОК ЖИВЁТ РОВНО В ОДНОМ МЕСТЕ — В МЕНЮ (`UI/HubListMenu.swift`).
//  Один день на экране было ДВА «Порядка»: свой переключатель страницы (он менял
//  вопрос к справочнику) и «Порядок» в меню отбора (он раскладывал уже пришедшее).
//  Человек выбирал в меню «Лёгкие сверху», а на экране горело «Порядок: Популярные» —
//  список стоял не в том порядке, что написано, и понять, кто победил, было нельзя.
//  Переключатель со страницы убран, оба пункта разведены внутри одного меню.
//  ⛔ Не возвращать сюда отдельный переключатель порядка ни в каком виде.
//
//  Экран НИЧЕГО не знает ни про Hugging Face, ни про каталог, ни про хранилище:
//  готовые строки приходят замыканиями от композиционного корня — тем же приёмом,
//  что и список моделей на экране подготовки.
//
//  Дизайн: страница-шит, тёмная тема, карточки обычные, стекло — только на круглой
//  кнопке закрытия (docs/LIQUID-GLASS.md).
//

import SwiftUI

// MARK: - Словарь экрана

/// Цвет пометки годности. Ровно четыре — больше человек не различает с одного взгляда.
enum HubFitBadge: String, Sendable, Equatable {
    /// Зелёная: должна пойти на этом телефоне.
    case ready
    /// Жёлтая: может не хватить памяти.
    case tight
    /// Серая: пока не запустим (чужой вид файла либо память измерить не удалось).
    case notYet
    /// Красная: на iPhone не работает вовсе.
    case impossible
}

/// Один файл модели: то, что человек в итоге качает.
struct HubFileOption: Sendable, Equatable, Identifiable {

    /// Опознаватель модели — он же опознаватель загрузки.
    let id: String
    let fileName: String
    /// Точный размер. Нужен ровно для порядка «лёгкие сверху»: сравнивать «3,8 ГБ»
    /// с «980 МБ» как строки нельзя, а разбирать напечатанное обратно в число —
    /// значит однажды промахнуться на запятой в чужой раскладке.
    let byteSize: Int64
    /// Размер человеческим языком: «3,8 ГБ».
    let sizeText: String
    /// Вид файла — по нему работает отбор «Формат».
    ///
    /// ⚠️ ПРИХОДИТ ГОТОВЫМ, А НЕ РАЗБИРАЕТСЯ ЗДЕСЬ ПО ИМЕНИ. Модель для движка Apple —
    /// это ПАПКА, у неё расширения нет вовсе, и разбор по имени ответил бы «другой вид»
    /// на модель, которую приложение как раз запускает.
    let format: ModelFileFormat
    let badge: HubFitBadge
    /// Два-три слова на пометке: «Должна пойти».
    let badgeTitle: String
    /// Одна фраза «почему так».
    let fitDetail: String
    /// Строка про память с числами. nil — сказать нечего.
    let memoryNote: String?
    /// «Набор из 3 файлов» — когда веса разложены по частям. nil — обычный один файл.
    let partsNote: String?
    /// Можно ли скачать это прямо здесь.
    let canDownload: Bool
    /// Почему нельзя. nil — можно.
    ///
    /// ⚠️ Здесь только то, от чего нажатие всё равно ничего не даст: закрытый
    /// репозиторий и нехватка места. «Нам кажется, что вам это не нужно» — не отсюда,
    /// это `warningText` рядом с живой кнопкой.
    let blockReason: String?
    /// На что человек идёт, если всё-таки нажмёт. nil — предупреждать не о чем.
    let warningText: String?

    init(id: String,
         fileName: String,
         byteSize: Int64 = 0,
         sizeText: String,
         format: ModelFileFormat = .other,
         badge: HubFitBadge,
         badgeTitle: String,
         fitDetail: String,
         memoryNote: String?,
         partsNote: String?,
         canDownload: Bool,
         blockReason: String?,
         warningText: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.byteSize = byteSize
        self.sizeText = sizeText
        self.format = format
        self.badge = badge
        self.badgeTitle = badgeTitle
        self.fitDetail = fitDetail
        self.memoryNote = memoryNote
        self.partsNote = partsNote
        self.canDownload = canDownload
        self.blockReason = blockReason
        self.warningText = warningText
    }

    // ⚠️ ЗДЕСЬ БЫЛА `markedNotRunnable()` — она помечала КАЖДЫЙ файл модели
    // с приговором крестом и подписью «Не запустится». У находки с пятью сжатиями
    // человек читал эти два слова шесть раз подряд и не мог нажать ни на одно
    // из них. Теперь у такой находки списка файлов нет вовсе (`HubRepoRow.canOpen`),
    // и помечать нечего.
}

/// Запустится ли найденная модель на этом телефоне — ответ по её устройству,
/// а не по размеру.
///
/// ⚠️ ЗАЧЕМ ОТДЕЛЬНО ОТ ПОМЕТКИ ПАМЯТИ. Пометка `HubFitBadge` отвечает на вопрос
/// «хватит ли памяти», и она у модели-пустышки бывает зелёной: весит мало, влезет
/// легко — и не запустится никогда. Владелец на такой и обжёгся (ROADMAP, 12.8).
enum HubRunCheck: Sendable, Equatable {

    /// Спрашиваем прямо сейчас.
    case checking
    /// Устройство знакомое — движок такую модель поднимает.
    case willRun
    /// Не поднимет никогда. Внутри — причина человеческими словами.
    case wontRun(HubRunRefusal)
}

/// Приговор в двух длинах — короткой и полной.
///
/// ⚠️ ДВЕ ДЛИНЫ, А НЕ ОДНА, И ЭТО НЕ УКРАШАТЕЛЬСТВО. Полный приговор — три предложения
/// (около 230 знаков): на телефоне это четыре-пять строк, и раньше он печатался прямо
/// в СВЁРНУТОЙ строке списка. Раскрыл пять находок — список превратился в простыню
/// из красных абзацев. Теперь в свёрнутой строке одна фраза «чем эта модель плоха»,
/// а полное объяснение с советом человек видит, когда строку раскроет, — то есть
/// ровно тогда, когда оно ему и нужно.
struct HubRunRefusal: Sendable, Equatable {

    /// Одна фраза для свёрнутой строки.
    let short: String
    /// Полное объяснение с советом — для раскрытой строки и для отказа под кнопкой.
    let full: String
}

/// Общая проверка «запустится ли»: тянем описание модели (килобайты) и спрашиваем
/// движок Apple, знакомо ли ему такое устройство.
///
/// ⚠️ ОТДЕЛЬНЫМ ИМЕНЕМ, А НЕ ПОЛЕМ ЭКРАНА, потому что это значение по умолчанию
/// для его подстановки: значения по умолчанию считаются на месте вызова, а вызов
/// живёт вне главного потока.
enum HubRunCheckDefault {

    static let ask: @Sendable (String) async -> HubRunCheck = { repoID in
        switch await MLXArchitectures.verdict(forRepo: repoID, revision: nil) {
        case .runnable:
            return .willRun
        case .notRunnable(let type):
            return .wontRun(HubRunRefusal(short: MLXArchitectures.shortText(forModelType: type),
                                          full: MLXArchitectures.humanText(forModelType: type)))
        case .unknown:
            // Не проверили — молчим. Пугать человека собственной неудачей нельзя.
            return .willRun
        }
    }
}

/// Чем закончилось нажатие «Скачать».
///
/// ⚠️⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ. Раньше нажатие ничего не возвращало: экран поиска закрывался
/// сразу, ВСЕГДА, — начáлась загрузка или нет. Владелец нажал «Скачать» на модели без
/// цензуры и не увидел ни загрузки, ни отказа: «нажимаю на скачать нейронку без цензуры —
/// нету ничего — не качается». Отказ, о котором человек не узнал, — это худший исход
/// в этом приложении, хуже самой поломки.
///
/// Теперь ответ обязателен: либо загрузка пошла (и экран закрывается, чтобы человек увидел
/// полосу), либо названа причина — и экран ОСТАЁТСЯ, а причина встаёт под той самой кнопкой,
/// которую он нажал.
enum HubDownloadStart: Sendable, Equatable {

    /// Загрузка началась — можно закрывать поиск.
    case started
    /// Загрузка не началась. Внутри — причина человеческими словами и что делать.
    case refused(String)
}

/// Одна найденная модель. Внутри неё — файлы: у одной и той же модели их бывает
/// несколько, сжатых по-разному, и выбирает человек, а не мы за него.
struct HubRepoOption: Sendable, Equatable, Identifiable {

    let id: String
    /// Имя модели без имени выложившего.
    let name: String
    /// «Выложил prism-ml».
    let authorText: String
    /// «2,7 млн скачиваний · 3 файла».
    let statsText: String
    /// Лучшее, что есть среди файлов этой модели.
    let badge: HubFitBadge
    let badgeTitle: String
    /// Отдельная честная оговорка про всю модель (закрытый репозиторий и т.п.).
    let noteText: String?
    let files: [HubFileOption]
    let pageURL: URL?
    /// Это модель для картинок, а не для разговора. nil — обычная находка.
    ///
    /// ⚠️ ТАКУЮ НАХОДКУ НЕЛЬЗЯ ПОСТАВИТЬ КАК ЧАТ-МОДЕЛЬ (ROADMAP §23). Рисующая часть
    /// говорить не умеет вовсе, а файл .gguf с виду такой же, как у модели для чата:
    /// без пометки человек скачал бы гигабайты и получил «модель не запускается».
    let imageKind: ImageModelRegistry.Recognition?

    init(id: String,
         name: String,
         authorText: String,
         statsText: String,
         badge: HubFitBadge,
         badgeTitle: String,
         noteText: String?,
         files: [HubFileOption],
         pageURL: URL?,
         imageKind: ImageModelRegistry.Recognition? = nil) {
        self.imageKind = imageKind
        self.id = id
        self.name = name
        self.authorText = authorText
        self.statsText = statsText
        self.badge = badge
        self.badgeTitle = badgeTitle
        self.noteText = noteText
        self.files = files
        self.pageURL = pageURL
    }
}

/// О чём спрашиваем справочник: слова человека плюс быстрые отборы.
///
/// ⚠️ ОДНИМ ЗНАЧЕНИЕМ, А НЕ ДВУМЯ ОТДЕЛЬНЫМИ. Слова и отбор «Дистилляты» — это один
/// вопрос, и уехать они обязаны вместе. Разложи их по разным местам — и однажды
/// придёт список, собранный по старым словам с новым отбором.
struct HubQuery: Sendable, Equatable {

    /// Что человек напечатал. Пустое — не ошибка: «покажи всё подряд».
    let text: String
    /// Выбранный раздел.
    let section: HubSectionOption

    init(text: String, section: HubSectionOption = .all) {
        self.text = text
        self.section = section
    }
}

/// Разделы моделей — отбор не по виду файла, а по сути. Прямая просьба владельца:
/// «сделай разные разделы у моделей: фронтир, экспериментальные, без цензуры».
///
/// ⚠️ ЧЕСТНОСТЬ ОТБОРА — ГЛАВНОЕ ЗДЕСЬ. Ни силы модели, ни наличия цензуры в справочнике
/// не записано: там есть имя модели и имя того, кто её выложил. Значит, разделы собраны
/// по приметам, и в подписи под каждым это сказано прямо. Молча выдавать догадку
/// за измерение нельзя — на этом в проекте уже обжигались.
enum HubSectionOption: String, Sendable, Equatable, CaseIterable, Identifiable {

    case all
    case frontier
    case experimental
    case uncensored
    case distills

    var id: String { rawValue }

    /// Подпись на кнопке. Коротко — их пять в одну прокручиваемую строку.
    var title: String {
        switch self {
        case .all:          return "Все"
        case .frontier:     return "Фронтир"
        case .experimental: return "Эксперименты"
        case .uncensored:   return "Без цензуры"
        case .distills:     return "Дистилляты"
        }
    }

    /// Строка под кнопками: что это за раздел и по какой примете он собран.
    ///
    /// ⚠️ У «Все» подписи НЕТ, и пустая строка здесь намеренная. «Весь справочник
    /// подряд» под кнопкой «Все» — это подпись к слову, которое само себя объясняет,
    /// а раздел этот стоит по умолчанию: строка висела бы под каждым открытием экрана.
    /// Остальные подписи ужаты до сути: что это за модели и по какой примете отобраны.
    /// Именно примета — главное, её выкидывать нельзя: силы модели мы не измеряем
    /// и выдавать догадку за измерение не имеем права.
    var note: String {
        switch self {
        case .all:
            return ""
        case .frontier:
            return "Новые семейства от команд движка: Gemma 4, Qwen3.5, LFM2.5. "
                + "Отбор по тому, кто выложил, — силу модели мы не измеряем."
        case .experimental:
            return "Сборки обычных людей. Никто их не проверял: бывает удачно, бывает мусор."
        case .uncensored:
            // ⚠️ Про послушание сказано НЕ ради строгости. Отказ и послушание — одно
            // и то же умение, и снимают их вместе. Приложение держится на том, что модель
            // ЗОВЁТ действие, а не пересказывает его словами; человек, не знающий этого,
            // скачает три гигабайта и получит модель, которая не берётся за файлы.
            return "Отбор по словам в названии (uncensored, abliterated). Чужая работа, "
                + "никем не проверенная. Вместе с запретами у таких моделей слабеет "
                + "послушание: они чаще отвечают словами вместо того, чтобы взяться за файл."
        case .distills:
            return "Маленькие модели, обученные повторять ответы больших. "
                + "⚠️ Дистиллятов Claude не бывает: сборки с такими словами в названии — "
                + "это Qwen, дообученный чужими людьми."
        }
    }

    /// Что написать, когда в этом разделе не нашлось ничего.
    ///
    /// ⚠️ ОТДЕЛЬНАЯ СТРОКА НА КАЖДЫЙ РАЗДЕЛ, И ЭТО НЕ ПРИДИРКА. Пустой раздел без
    /// объяснения человек читает как поломку приложения. Он должен понимать: искали,
    /// дошли до конца списка, таких моделей в этом виде файлов действительно нет.
    var emptyText: String {
        switch self {
        case .all:
            return "В этом виде файлов ничего не нашлось."
        case .frontier:
            return "В этом виде файлов основной канал пока ничего не выложил."
        case .experimental:
            return "В этом виде файлов чужих сборок пока нет."
        case .uncensored:
            return "В этом виде файлов моделей со снятыми ограничениями пока нет. "
                + "Поищите в GGUF — там их много, но запустить их приложение сегодня не умеет."
        case .distills:
            return "В этом виде файлов дистиллятов пока нет. "
                + "Поищите в GGUF — там их тысячи, но запустить их приложение сегодня не умеет."
        }
    }
}

/// Одна страница находок и способ дотянуть следующую.
///
/// ⚠️ ЗАЧЕМ СТРАНИЦЫ. Раньше экран показывал первый десяток и молчал о том, что за ним
/// есть ещё сотни. Человек видел обрубок и считал, что это весь справочник, — на это
/// и пожаловался владелец. Теперь список либо продолжается («Показать ещё»), либо
/// прямо говорит, что кончился.
///
/// ⚠️ Продолжение — ЗАМЫКАНИЕ, а не метка страницы. Экран не знает ни про адреса, ни про
/// метки чужого сервера: он спрашивает «дальше есть?» и зовёт, если есть.
struct HubSearchPage: Sendable {

    let repos: [HubRepoOption]
    /// Чем дотянуть следующую страницу. nil — дальше ничего нет, это весь список.
    let more: (@Sendable () async throws -> HubSearchPage)?

    /// Что уже известно про «запустится ли» — по опознавателю модели.
    ///
    /// ⚠️⚠️ ПРИЕЗЖАЕТ ВМЕСТЕ СО СПИСКОМ, И РАДИ ЭТОГО ВСЁ ЗАТЕВАЛОСЬ (ROADMAP, 12.8).
    /// Справочник отдаёт устройство модели прямо в списке находок, поэтому пометка
    /// «Не запустится» стоит у ВСЕХ находок сразу — человек видит её, пока листает,
    /// а не после того, как раскроет каждую по очереди. Пусто для какой-то модели —
    /// значит справочник промолчал, и её проверит запасной путь (`checkRun`).
    ///
    /// ⚠️ Отдельным словарём, а не полем внутри `HubRepoOption`, потому что отбор
    /// пересобирает находки (`ModelListFilter.replacing(files:)`) — и приговор,
    /// лежащий внутри находки, при первом же отборе потерялся бы.
    let runChecks: [String: HubRunCheck]

    init(repos: [HubRepoOption],
         more: (@Sendable () async throws -> HubSearchPage)? = nil,
         runChecks: [String: HubRunCheck] = [:]) {
        self.repos = repos
        self.more = more
        self.runChecks = runChecks
    }
}

/// Что ищем. Приложение сегодня запускает только первый вид — и говорит об этом прямо.
enum HubSearchScope: String, Sendable, Equatable, CaseIterable, Identifiable {
    case thisApp
    case gguf
    case mlx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisApp: return "Наши"
        case .gguf:    return "GGUF"
        case .mlx:     return "MLX"
        }
    }

    /// Одна строка под переключателем — чтобы не приходилось гадать, что это за слова.
    var note: String {
        switch self {
        case .thisApp:
            return "Файлы, которые приложение запускает сегодня."
        case .gguf:
            // ⚠️ Раньше здесь было «приложение их пока не запускает» — с тех пор
            // подключился отдельный движок (llama.cpp), и файл приезжает той же
            // кнопкой «Скачать». Обещать скорость и лёгкость не будем: движок другой,
            // и мерили мы на нём не всё.
            return "Самый ходовой вид файлов. Приложение их запускает — через отдельный движок."
        case .mlx:
            // ⚠️ Раньше здесь было «приложение пока их не запускает» — с тех пор движок
            // Apple подключён, и модель приезжает папкой той же кнопкой «Скачать».
            return "Модели Apple. Приложение их запускает; на телефон приезжают папкой из нескольких файлов."
        }
    }
}

/// В каком порядке показывать список. Ровно то, что просил владелец:
/// «условно по популярности, по тренду, по скачиваниям и так далее».
///
/// ⚠️ Экран знает только эти четыре слова. Чем они называются на чужом сервере —
/// его дело не касается: перевод живёт в Agent/HubSearchAssembly.swift.
enum HubSortOption: String, Sendable, Equatable, CaseIterable, Identifiable {

    /// Что обсуждают прямо сейчас.
    case trending
    /// Что людям понравилось за всё время.
    case likes
    /// Что чаще всего качают.
    case downloads
    /// Что выложили или поправили последним.
    case fresh

    var id: String { rawValue }

    /// Подпись на переключателе. Коротко — их четыре штуки в одну строку экрана.
    var title: String {
        switch self {
        case .trending:  return "В тренде"
        case .likes:     return "Нравятся"
        case .downloads: return "Качают"
        case .fresh:     return "Новые"
        }
    }
}

// MARK: - Состояние экрана

@MainActor
final class ModelSearchViewModel: ObservableObject {

    /// Что человек напечатал.
    @Published var query: String = ""
    /// Что ищем.
    @Published var scope: HubSearchScope = .thisApp
    /// В каком порядке показываем.
    ///
    /// ⚠️ По умолчанию «В тренде», а не «Качают». Число скачиваний за всё время —
    /// это память о прошлом: наверху там годами стоят одни и те же две модели,
    /// и список выглядит застывшим. Владелец просил СВЕЖИЙ список.
    @Published var sort: HubSortOption = .trending
    /// Выбранный раздел — быстрый отбор одним нажатием.
    @Published var section: HubSectionOption = .all

    @Published private(set) var repos: [HubRepoOption] = []
    @Published private(set) var isSearching = false
    /// Ошибка человеческим языком. nil — всё в порядке.
    @Published private(set) var errorText: String?
    /// Хотя бы один поиск уже закончился. До этого «ничего не нашли» писать нельзя.
    @Published private(set) var didSearchOnce = false
    /// Идёт дозагрузка следующей страницы — прежний список при этом остаётся на месте.
    @Published private(set) var isLoadingMore = false
    /// Список кончился. Тогда внизу вместо кнопки стоит честное «это всё».
    @Published private(set) var isListComplete = false

    /// Чем дотянуть следующую страницу. nil — тянуть нечего.
    private var nextPage: (@Sendable () async throws -> HubSearchPage)?
    private var moreTask: Task<Void, Never>?

    /// Можно ли долистать дальше.
    var canLoadMore: Bool { nextPage != nil }

    /// Сколько ждём, пока человек допечатает.
    ///
    /// ⚠️ Ждать обязательно: у справочника есть предел числа запросов, а поиск на каждую
    /// букву — это десяток обращений на одно слово. Полсекунды человек не замечает,
    /// а запросов становится втрое меньше.
    private static let typingPause: UInt64 = 700_000_000

    /// Файл, на котором загрузка не началась. nil — отказывать не в чем.
    ///
    /// ⚠️ Помним ИМЕННО ФАЙЛ, а не просто текст: причина обязана встать под той кнопкой,
    /// которую человек нажал. Отказ, показанный где-то наверху списка из двадцати строк,
    /// человек с телефоном в руке просто не увидит — а это то же молчание, только длиннее.
    @Published private(set) var refusedFileID: String?
    /// Почему загрузка не началась. Человеческими словами и с тем, что делать.
    @Published private(set) var refusalText: String?

    /// Что уже известно про то, запустится ли модель. Ключ — опознаватель модели
    /// (он же адрес репозитория). Пусто — ещё не спрашивали.
    @Published private(set) var runChecks: [String: HubRunCheck] = [:]

    private let searchAction: @Sendable (HubQuery, HubSearchScope, HubSortOption) async throws -> HubSearchPage
    /// ⚠️ Помечено главным потоком намеренно: за этим замыканием стоит смена рабочей
    /// модели и начало загрузки — и то, и другое трогает состояние экранов.
    ///
    /// ⚠️ И оно ОБЯЗАНО отвечать, началась загрузка или нет. Замыкание без ответа —
    /// это и есть та дыра, через которую нажатие уходило в никуда.
    private let downloadAction: @MainActor (HubFileOption) -> HubDownloadStart
    /// Чем спросить, запустится ли модель. Отвечает по её описанию — файлу весом
    /// в килобайты, а не по гигабайтам весов.
    ///
    /// ⚠️ У НЕГО ЕСТЬ ЗНАЧЕНИЕ ПО УМОЛЧАНИЮ, И ЭТО НЕ ЛЕНЬ. Экран по-прежнему ничего
    /// не знает ни про справочник, ни про движок — но и композиционный корень
    /// (`Agent/HubSearchAssembly.swift`) переписывать ради одной проверки не нужно:
    /// подстановку он может задать позже, а до тех пор работает общая.
    private let runCheckAction: @Sendable (String) async -> HubRunCheck
    private var searchTask: Task<Void, Never>?

    /// Кого ещё надо спросить и сколько вопросов сейчас в полёте.
    private var runCheckQueue: [String] = []
    private var runChecksInFlight = 0

    /// Сколько проверок держим одновременно.
    ///
    /// ⚠️ Предел нужен потому, что спрашиваем мы теперь про ВСЕ строки списка сразу,
    /// а не про одну раскрытую. Двадцать одновременных обращений к чужому серверу —
    /// верный способ получить в ответ «слишком часто»; три идут почти так же быстро
    /// и никого не злят. Обычно очередь и вовсе пустая: устройство модели приезжает
    /// вместе со списком, и спрашивать не о чем.
    private static let parallelRunChecks = 3

    init(search: @escaping @Sendable (HubQuery, HubSearchScope, HubSortOption) async throws -> HubSearchPage,
         download: @escaping @MainActor (HubFileOption) -> HubDownloadStart,
         runCheck: @escaping @Sendable (String) async -> HubRunCheck = HubRunCheckDefault.ask) {
        self.searchAction = search
        self.downloadAction = download
        self.runCheckAction = runCheck
    }

    /// Строка появилась в списке — узнаём, запустится ли эта модель.
    ///
    /// ⚠️⚠️ РАНЬШЕ СПРАШИВАЛИ ТОЛЬКО ПРО РАСКРЫТУЮ, И ЭТО ОБЕСЦЕНИВАЛО ВСЮ ЗАТЕЮ.
    /// Пометка «Не запустится» заводилась ровно затем, чтобы человек НЕ ТРАТИЛ время
    /// (ROADMAP, 12.8), — а узнать правду он мог, только раскрыв каждую находку
    /// по очереди. Двадцать строк выглядели одинаково годными.
    ///
    /// ⚠️ И это ЗАПАСНОЙ путь, а не основной. Устройство модели приезжает вместе
    /// со списком (`HubSearchPage.runChecks`), и обычно спрашивать уже нечего.
    /// Сюда попадают только те, про кого справочник промолчал.
    ///
    /// ⚠️ Спрашиваем по очереди, не больше `parallelRunChecks` разом: список
    /// не «ленивый», строки создаются все сразу, и без очереди двадцать обращений
    /// ушли бы к чужому серверу одним залпом.
    ///
    /// ⚠️ И только для моделей Apple: у остальных видов файлов устройство модели
    /// в описании не лежит, спрашивать нечего.
    func checkRun(for repo: HubRepoOption) {
        guard scope == .mlx else { return }
        guard runChecks[repo.id] == nil, !runCheckQueue.contains(repo.id) else { return }
        runCheckQueue.append(repo.id)
        pumpRunChecks()
    }

    /// Запустить столько проверок, сколько разрешено держать одновременно.
    private func pumpRunChecks() {
        while runChecksInFlight < Self.parallelRunChecks, !runCheckQueue.isEmpty {
            let id = runCheckQueue.removeFirst()
            // Пока строка стояла в очереди, ответ мог приехать вместе со списком.
            guard runChecks[id] == nil else { continue }

            runChecks[id] = .checking
            runChecksInFlight += 1
            let ask = runCheckAction
            Task { [weak self] in
                let answer = await ask(id)
                guard let self else { return }
                self.runChecks[id] = answer
                self.runChecksInFlight -= 1
                self.pumpRunChecks()
            }
        }
    }

    /// Приговоры, приехавшие вместе со списком, — задаром и сразу для всех находок.
    private func adopt(_ checks: [String: HubRunCheck]) {
        for (id, check) in checks {
            runChecks[id] = check
        }
    }

    /// Человек печатает — ждём, пока допечатает.
    func queryChanged() {
        schedule(afterPause: true)
    }

    /// Человек нажал «Найти», сменил вид файлов или экран только открылся —
    /// ждать нечего, ищем сразу.
    func searchNow() {
        schedule(afterPause: false)
    }

    /// Человек нажал «Скачать». Возвращает `true`, если загрузка правда началась —
    /// только тогда экран поиска имеет право закрыться.
    ///
    /// ⚠️ Закрывать экран безусловно, как было раньше, нельзя: при отказе человек
    /// оказывался на другой вкладке, где ничего не происходит, и никакого объяснения
    /// там уже не было.
    @discardableResult
    func download(_ file: HubFileOption) -> Bool {
        // ⚠️ Последняя застава на экране: человек мог нажать «Скачать» в ту же секунду,
        // когда пришёл ответ «не запустится», — кнопка ещё не успела смениться.
        if let reason = runRefusal(for: file) {
            refusedFileID = file.id
            refusalText = reason
            return false
        }
        switch downloadAction(file) {
        case .started:
            refusedFileID = nil
            refusalText = nil
            return true
        case .refused(let reason):
            refusedFileID = file.id
            refusalText = reason
            return false
        }
    }

    /// Почему этот файл качать бессмысленно. nil — качать можно.
    private func runRefusal(for file: HubFileOption) -> String? {
        guard let repo = repos.first(where: { repo in repo.files.contains { $0.id == file.id } }),
              case .wontRun(let reason) = runChecks[repo.id] ?? .checking else { return nil }
        // Под кнопкой — полное объяснение: человек уже нажал, коротко отделаться нечестно.
        return reason.full
    }

    /// Долистать до следующей страницы.
    ///
    /// ⚠️ Прежний список при этом НЕ пропадает и не гаснет: человек дочитал до низа,
    /// и подменять прочитанное значком ожидания — значит потерять его место в списке.
    func loadMore() {
        guard let nextPage, !isLoadingMore, !isSearching else { return }
        isLoadingMore = true
        moreTask?.cancel()
        moreTask = Task { [weak self] in
            let outcome: Result<HubSearchPage, Error>
            do {
                outcome = .success(try await nextPage())
            } catch {
                outcome = .failure(error)
            }
            if Task.isCancelled { return }
            self?.appendPage(outcome)
        }
    }

    private func appendPage(_ outcome: Result<HubSearchPage, Error>) {
        isLoadingMore = false
        switch outcome {
        case .success(let page):
            // Одна и та же модель может прийти дважды, если справочник за время
            // листания переставил список. Показывать её второй раз незачем.
            let known = Set(repos.map(\.id))
            repos += page.repos.filter { !known.contains($0.id) }
            adopt(page.runChecks)
            nextPage = page.more
            isListComplete = page.more == nil
        case .failure(let error):
            // Что уже показано — остаётся: обрыв на пятой странице не повод стирать
            // четыре прочитанные. Кнопка «Показать ещё» останется на месте.
            errorText = (error as? LocalizedError)?.errorDescription
                ?? "Дальше список не загрузился. Попробуйте ещё раз."
        }
    }

    private func schedule(afterPause: Bool) {
        searchTask?.cancel()
        moreTask?.cancel()
        let request = HubQuery(text: query, section: section)
        let scope = self.scope
        let sort = self.sort
        errorText = nil
        // Список сейчас сменится — отказ, написанный под кнопкой прежней строки,
        // относиться будет уже не к ней.
        refusedFileID = nil
        refusalText = nil
        // Список сменится — очередь на проверку относится уже не к тем строкам.
        // Сами ответы (`runChecks`) остаются: они про модель, а не про этот поиск.
        runCheckQueue.removeAll()
        // Новый поиск — новое начало списка: продолжение от прошлого запроса
        // дотянуло бы сюда чужие строки.
        nextPage = nil
        isLoadingMore = false
        isListComplete = false

        searchTask = Task { [weak self] in
            // ⚠️ «Ищу…» показываем ПОСЛЕ паузы, а не сразу: иначе значок ожидания
            // мигал бы на каждой букве, хотя никакого запроса ещё не было.
            if afterPause {
                try? await Task.sleep(nanoseconds: Self.typingPause)
                if Task.isCancelled { return }
            }
            self?.isSearching = true
            await self?.run(request: request, scope: scope, sort: sort)
        }
    }

    private func run(request: HubQuery, scope: HubSearchScope, sort: HubSortOption) async {
        // Ошибку и список раскладываем ПОСЛЕ ожидания: пока ответ не пришёл, на экране
        // должен оставаться прежний список, а не пустота.
        let outcome: Result<HubSearchPage, Error>
        do {
            outcome = .success(try await searchAction(request, scope, sort))
        } catch {
            outcome = .failure(error)
        }
        // Пришёл ответ на устаревший запрос (человек уже печатает другое) — выбрасываем.
        if Task.isCancelled { return }

        isSearching = false
        didSearchOnce = true
        switch outcome {
        case .success(let page):
            repos = page.repos
            adopt(page.runChecks)
            nextPage = page.more
            isListComplete = page.more == nil
            errorText = nil
        case .failure(let error):
            repos = []
            nextPage = nil
            isListComplete = false
            errorText = (error as? LocalizedError)?.errorDescription
                ?? "Поиск не получился. Попробуйте ещё раз."
        }
    }
}

// MARK: - Экран

struct ModelSearchView: View {

    /// Смена модели закроет начатый разговор — тогда спрашиваем ДО загрузки.
    let willRestartConversation: Bool

    @StateObject private var model: ModelSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool
    /// Какая модель раскрыта до списка файлов. nil — все свёрнуты.
    @State private var openedID: String?
    /// Файл ждёт подтверждения смены модели. nil — спрашивать не о чем.
    @State private var pendingFile: HubFileOption?
    /// Порядок и отбор находок. Живёт между запусками (`ModelListFilterStorage`).
    ///
    /// ⚠️ ОТБОР ЗДЕСЬ ДЕЛАЕТСЯ НА УЖЕ ПРИШЕДШЕМ СПИСКЕ, а не превращается в запрос
    /// к справочнику. Справочник не умеет отвечать «только то, что влезет в этот
    /// телефон»: про телефон он ничего не знает, а вес и вид файла мы всё равно
    /// перемеряем сами. Значит и врать про «искали по всему справочнику» нельзя —
    /// поэтому под списком честно написано, сколько уже показано.
    @State private var filter = ModelListFilter.load(.hubList)

    /// Колонка под иконку. Растёт вместе с системным шрифтом.
    @ScaledMetric(relativeTo: .body) private var iconGutter: CGFloat
        = Theme.Metrics.iconGutterWidth

    /// Открыть «Картинки» с узнанным семейством (ROADMAP §23). Поиск при этом
    /// закрывается сам — «Картинки» открывает тот, кто открыл поиск.
    let openImages: ((String) -> Void)?

    init(willRestartConversation: Bool,
         search: @escaping @Sendable (HubQuery, HubSearchScope, HubSortOption) async throws -> HubSearchPage,
         download: @escaping @MainActor (HubFileOption) -> HubDownloadStart,
         openImages: ((String) -> Void)? = nil) {
        self.willRestartConversation = willRestartConversation
        self.openImages = openImages
        // ⚠️ Именно StateObject, а не создание на каждом кадре: иначе список найденного
        // и напечатанное слово стирались бы при любой перерисовке экрана.
        _model = StateObject(wrappedValue: ModelSearchViewModel(search: search, download: download))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                header

                // ⚠️ ОРГАНЫ ОТБОРА — ОДНА ГРУППА, А НЕ НЕСКОЛЬКО РАВНОПРАВНЫХ БЛОКОВ.
                // Раньше строка поиска, «Что ищем», разделы и порядок стояли через
                // тот же промежуток, что и целые разделы страницы (22 точки), — и на
                // телефоне человек прокручивал больше половины экрана прежде, чем
                // увидеть хоть одну найденную модель. А ищет он не отбор, а находки.
                // Внутри группы промежуток обычный, между группой и находками —
                // прежний большой: так сразу видно, что это «чем отбираем» и «что нашли».
                VStack(alignment: .leading, spacing: Theme.Metrics.contentSpacing) {
                    searchRow
                    scopePicker
                    sectionPicker
                    // Строки нет вовсе, пока отбор ничего не спрятал.
                    ModelListFilterNotice(filter: $filter,
                                          shown: shownRepos.count,
                                          total: model.repos.count,
                                          horizontalInset: 0)
                }

                if wantsImages { imagesCard }

                resultsBlock
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { closeLayer }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .preferredColorScheme(.dark)
        // Открыли экран — сразу показываем самые скачиваемые, не заставляя ничего печатать.
        .task {
            if !model.didSearchOnce { model.searchNow() }
        }
        // Выбранный порядок и отбор человек находит на месте и завтра, и через неделю.
        .onChange(of: filter) { _, newValue in
            newValue.save(.hubList)
        }
        // ⚠️ Этот пункт меню — ЕДИНСТВЕННЫЙ, который меняет ВОПРОС к справочнику,
        // а не раскладку уже пришедшего. Поэтому он и только он перезапрашивает список.
        .onChange(of: model.sort) { _, _ in
            openedID = nil
            model.searchNow()
        }
        .alert("Сменить модель?",
               isPresented: pendingBinding,
               presenting: pendingFile) { file in
            Button("Сменить") { start(file) }
            Button("Отмена", role: .cancel) { pendingFile = nil }
        } message: { _ in
            // ⚠️ Дословно та же фраза стоит на вкладке «Модели»: это один и тот же
            // вопрос, и звучать он обязан одинаково. Из неё убрано объяснение
            // «помощник думает той моделью, которая загружена» — человеку в этот
            // момент нужны последствия, а не устройство.
            Text("Разговор начнётся заново, задача попадёт в «Задачи». Файлы останутся как есть.")
        }
    }

    // MARK: Загрузка

    private var pendingBinding: Binding<Bool> {
        Binding(get: { pendingFile != nil },
                set: { isShown in if !isShown { pendingFile = nil } })
    }

    private func requestDownload(_ file: HubFileOption) {
        if willRestartConversation {
            pendingFile = file
        } else {
            start(file)
        }
    }

    /// Загрузку ведёт экран моделей — там уже есть и полоса, и пауза, и место на диске.
    /// Поэтому поиск закрывается: человек должен видеть, что пошло скачивание.
    ///
    /// ⚠️ НО ТОЛЬКО ЕСЛИ ЗАГРУЗКА ПРАВДА НАЧАЛАСЬ. Раньше экран закрывался всегда, и при
    /// отказе человек оказывался на вкладке «Модели», где не происходило ничего и не было
    /// написано ничего. Теперь при отказе поиск остаётся открытым, а причина встаёт прямо
    /// под нажатой кнопкой.
    private func start(_ file: HubFileOption) {
        pendingFile = nil
        if model.download(file) {
            dismiss()
        }
    }

    // MARK: Модели для картинок

    /// Человек ищет модель для картинок — наши готовые наборы стоят первыми.
    ///
    /// ⚠️ ЗАЧЕМ ОТДЕЛЬНАЯ КАРТОЧКА, если находки и так помечены «для картинок».
    /// В справочнике их видно только в выдаче GGUF, а наш набор — это три-четыре
    /// файла из РАЗНЫХ репозиториев (рисующая часть, понимание текста, проявка).
    /// Одна находка его целиком не покажет никогда.
    private var wantsImages: Bool {
        guard openImages != nil else { return false }
        let q = ImageModelRegistry.squash(model.query)
        guard !q.isEmpty else { return false }
        if case .family? = ImageModelRegistry.recognize(repoID: model.query) { return true }
        return ["картин", "рисова", "image", "flux", "diffusion", "sdxl"].contains { q.contains($0) }
    }

    private var imagesCard: some View {
        card {
            Text("Модели для картинок")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            ForEach(ImageModelRegistry.all) { family in
                Button {
                    openImagesAndClose(family.id)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(family.displayName)
                                .font(.subheadline.bold())
                                .foregroundStyle(Theme.textPrimary)
                            Text(family.tagline)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Вход в «Картинки» для строк находок — только если его дали снаружи.
    private var rowOpenImages: ((String) -> Void)? {
        guard openImages != nil else { return nil }
        return { familyID in openImagesAndClose(familyID) }
    }

    private func openImagesAndClose(_ familyID: String) {
        openImages?(familyID)
        dismiss()
    }

    // MARK: Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Поиск моделей")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.textPrimary)
            Text("Ищем в открытом справочнике моделей. Наружу уходит только то, что вы напечатали.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Строка поиска

    /// Строка поиска и кнопка порядка с отбором — В ОДНУ СТРОКУ, а не двумя.
    ///
    /// ⚠️ ПОЧЕМУ КНОПКА ЗДЕСЬ, А НЕ ОТДЕЛЬНЫМ РЯДОМ. На экране уже три органа
    /// управления подряд (строка, «Что ищем», разделы); четвёртый ряд отодвинул бы
    /// сами находки ещё ниже, а человек пришёл сюда именно за ними. Так кнопка
    /// не занимает ни одной новой строки.
    ///
    /// ⚠️ И она СНАРУЖИ поля, а не внутри его капсулы: внутри она отъела бы у строки
    /// ввода сорок с лишним точек ширины (там уже стоит крестик «стереть»), а по смыслу
    /// относится не к напечатанному слову, а к списку находок под ним.
    private var searchRow: some View {
        HStack(spacing: 10) {
            searchField

            HubListMenuButton(sort: $model.sort,
                              filter: $filter,
                              formats: ModelListFilter.formats(in: model.repos),
                              sources: ModelListFilter.sourceOptions(in: model.repos))
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)

            TextField("Например, gemma", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.search)
                .focused($isFieldFocused)
                .foregroundStyle(Theme.textPrimary)
                .onSubmit { model.searchNow() }

            if !model.query.isEmpty {
                // Новый поиск запускать здесь не надо: пустая строка сама придёт
                // в `onChange` ниже, и там уже всё решено.
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .frame(minWidth: Theme.Metrics.minimumTapTarget,
                               minHeight: Theme.Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Стереть напечатанное")
            }
        }
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, 6)
        .frame(minHeight: Theme.Metrics.minimumTapTarget)
        .cardSurface(cornerRadius: Theme.Metrics.controlCorner)
        // ⚠️ Поиск НЕ дёргается на каждую букву: сначала ждём, пока человек допечатает.
        .onChange(of: model.query) { _, _ in
            model.queryChanged()
        }
    }

    // MARK: Что ищем

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Что ищем", selection: $model.scope) {
                ForEach(HubSearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: model.scope) { _, _ in
                openedID = nil
                model.searchNow()
            }

            Text(model.scope.note)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Разделы

    /// «Все · Фронтир · Эксперименты · Без цензуры · Дистилляты» — прямая просьба
    /// владельца про разделы по сути модели, а не по виду файла.
    ///
    /// ⚠️ ПРОКРУЧИВАЕМАЯ ПОЛОСА, А НЕ ЕЩЁ ОДИН СПЛОШНОЙ ПЕРЕКЛЮЧАТЕЛЬ. Пять подписей
    /// в одну ширину телефона не влезают: «Эксперименты» и «Без цензуры» превратились бы
    /// в «Эксп…» и «Без ц…». Полоса с прокруткой сохраняет слова целиком.
    ///
    /// ⚠️ И это ОТДЕЛЬНАЯ строка от переключателя выше, а не его продолжение: там человек
    /// выбирает ВИД ФАЙЛА, а разделы есть в каждом виде. Смешать их в одну строку —
    /// значит заставить выбирать между «GGUF» и «без цензуры», хотя это не выбор.
    private var sectionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(HubSectionOption.allCases) { option in
                        sectionChip(option)
                    }
                }
            }
            .scrollIndicators(.hidden)

            // Пустая подпись («Все») не оставляет после себя ни строки, ни отступа.
            if !model.section.note.isEmpty {
                Text(model.section.note)
                    .font(.caption)
                    .foregroundStyle(model.section == .uncensored || model.section == .distills
                                     ? Theme.Colors.warning
                                     : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionChip(_ option: HubSectionOption) -> some View {
        let isPicked = model.section == option
        // ⚠️ Набор признаков собираем отдельной переменной, а не тернаром прямо
        // в модификаторе: тернар из «.isSelected» и пустого литерала разные версии
        // компилятора выводят по-разному (той же граблёй уже обожглись на экране
        // моделей), а собрать проект под рукой нечем.
        var traits = AccessibilityTraits()
        if isPicked { traits.insert(.isSelected) }

        return Button {
            guard !isPicked else { return }
            model.section = option
            openedID = nil
            model.searchNow()
        } label: {
            Text(option.title)
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .frame(minHeight: Theme.Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPicked ? Theme.Colors.textOnAccent : Theme.textSecondary)
        .background {
            if isPicked {
                Capsule().fill(Theme.Colors.accent)
            } else {
                Capsule().fill(Theme.hairline)
            }
        }
        .accessibilityAddTraits(traits)
    }

    // MARK: Найденное

    /// Находки в том порядке и в том составе, в каком человек попросил их показать.
    /// Отбор не по умолчанию — про спрятанное скажет строка над списком.
    private var shownRepos: [HubRepoOption] {
        filter.apply(to: model.repos)
    }

    @ViewBuilder
    private var resultsBlock: some View {
        if let errorText = model.errorText {
            card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title3)
                        .frame(minWidth: iconGutter, alignment: .leading)
                        .foregroundStyle(Theme.Colors.warning)
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    model.searchNow()
                } label: {
                    Text("Попробовать снова")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.textOnAccent)
                .background(Theme.Colors.accent, in: Capsule())
            }
        } else if model.isSearching && model.repos.isEmpty {
            card {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Ищу…")
                        .font(Theme.Fonts.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        } else if model.repos.isEmpty {
            if model.didSearchOnce {
                // ⚠️ ПУСТОЙ РАЗДЕЛ ОБЯЗАН ОБЪЯСНИТЬСЯ. Молчаливая пустота читается как
                // поломка приложения: человек нажал «Без цензуры», увидел ничего и не
                // понял, то ли не нашлось, то ли не работает. Поэтому каждый раздел
                // говорит своими словами, чего именно в этом виде файлов нет и где
                // такое бывает.
                card {
                    Text("Ничего не нашли")
                        .font(Theme.Fonts.sectionTitle)
                        .foregroundStyle(Theme.textPrimary)
                    Text(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? model.section.emptyText
                         : "По этому слову ничего нет. Попробуйте другое — например, "
                            + "имя семейства моделей: gemma, qwen, phi.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            // ⚠️ Строки находок рисует ОБЩИЙ вид (`HubResultsList`), а не этот экран:
            // ровно те же строки стоят живым списком на вкладке «Модели». Две копии
            // одной разметки разъехались бы уже на первой правке — и человек увидел бы
            // на двух экранах разные сведения про одну и ту же модель.
            HubResultsList(repos: shownRepos,
                           openedID: $openedID,
                           isDimmed: model.isSearching,
                           refusedFileID: model.refusedFileID,
                           refusalText: model.refusalText,
                           runChecks: model.runChecks,
                           onAppear: { model.checkRun(for: $0) },
                           onDownload: requestDownload,
                           onOpenImages: rowOpenImages)
            listFooter
        }
    }

    // MARK: Низ списка — сколько показано и есть ли ещё

    /// ⚠️ РАДИ ЭТОГО ВСЁ И ДЕЛАЛОСЬ. Раньше список молча обрывался на десятой строке,
    /// и понять, это весь справочник или только начало, было нельзя. Теперь внизу
    /// всегда написано, сколько уже показано, и либо стоит кнопка «дальше», либо прямо
    /// сказано, что список кончился.
    ///
    /// ⚠️ И мы НЕ пишем «показаны первые 20 из 245», хотя такая строка была бы красивее.
    /// Справочник общего числа не сообщает вовсе (проверено живым запросом 10.08.2026:
    /// в ответе есть только адрес следующей страницы). Второе число пришлось бы
    /// выдумать, а выдуманные цифры в этом приложении запрещены.
    ///
    /// ⚠️ И ПОЧЕМУ СЛЕДУЮЩАЯ СТРАНИЦА НЕ ПРИХОДИТ САМА, ПРИ ПРОКРУТКЕ. Список строк
    /// здесь обычный, а не «ленивый»: все строки создаются сразу, ещё до того, как
    /// человек до них домотал. Значит, зацепка «этот кусок показался на экране» тут
    /// срабатывает не при прокрутке, а мгновенно, — и вместо подгрузки по требованию
    /// получилась бы тихая двойная загрузка при каждом открытии экрана.
    /// Нажатие явное, оплачено человеком, и на мобильном интернете это правильно.
    @ViewBuilder
    private var listFooter: some View {
        VStack(spacing: 10) {
            // ⚠️ Когда отбор спрятал ВСЁ, счётчика тут нет вовсе: «Показано 0 моделей»
            // ничего не объясняет и выглядит поломкой. Что произошло и как это отменить,
            // говорит строка над списком, а кнопка «Показать ещё» остаётся на месте —
            // подходящее вполне может найтись на следующей странице.
            if !shownCountText.isEmpty {
                Text(shownCountText)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            if model.isLoadingMore {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Загружаю ещё…")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(minHeight: Theme.Metrics.minimumTapTarget)
            } else if model.canLoadMore {
                Button {
                    model.loadMore()
                } label: {
                    Text("Показать ещё")
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
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var shownCountText: String {
        // Считаем то, что человек ВИДИТ, а не то, что пришло от справочника: сколько
        // из пришедшего спрятал отбор, сказано отдельной строкой над самим списком.
        let count = shownRepos.count
        guard count > 0 else { return "" }
        let word = HumanFormat.plural(count, "модель", "модели", "моделей")
        // ⚠️ «Есть ещё» отсюда убрано: прямо под этой строкой стоит кнопка
        // «Показать ещё» — она и есть ответ. Осталось то, чего кнопка не говорит:
        // сколько уже показано и кончился ли список.
        return model.isListComplete
            ? "Это весь список: \(count) \(word)."
            : "Показано \(count) \(word)."
    }

    // MARK: Мелочи

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: Круглая стеклянная кнопка закрытия (единственное стекло на экране)

    /// ⚠️ Подложка живёт ТОЛЬКО на iOS 17–18: там системного растворения края нет.
    /// На iOS 26 непрозрачный фон позади стекла запрещён — стеклу нечего сэмплить
    /// (docs/LIQUID-GLASS.md). Место под кнопку резервирует вставка безопасной зоны.
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
            GlassCircleButton(systemImage: "xmark", accessibilityTitle: "Закрыть") {
                dismiss()
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
    }
}

// MARK: - Вход в поиск с экрана моделей

/// Строка «Найти модель в интернете» на экране подготовки моделей.
///
/// ⚠️ ЭТО ТОЛЬКО ВНЕШНИЙ ВИД СТРОКИ — ни состояния, ни страницы поиска здесь больше нет.
/// Раньше вид держал страницу сам (`@State` + `.sheet` прямо тут), и получалось, что
/// `ModelSearchView` создаётся в том же файле, где и объявлен. Со стороны это выглядело
/// как «экран никем не открывается»: обычный поиск по имени экрана находил только его
/// собственный файл, и по этому признаку страницу дважды признали мёртвой.
/// Теперь страницу открывает `ModelSetupView` — там же, где живут остальные её страницы
/// и вопросы. Спорить за то, чей шит покажется, они не могут: этот висит на заголовке,
/// отдельной веткой (см. `ModelSetupView.header`).
struct ModelSearchButton: View {

    /// Что делать по нажатию. Открывает страницу поиска тот, кто эту строку поставил.
    let action: () -> Void

    /// Колонка под иконку — общая с остальными строками экрана.
    @ScaledMetric(relativeTo: .title3) private var iconGutter: CGFloat
        = Theme.Metrics.iconGutterWidth

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .frame(minWidth: iconGutter, alignment: .leading)
                    .foregroundStyle(Theme.Colors.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Найти модель в интернете")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // ⚠️ ПОДПИСЬ ОБЯЗАНА НАЗЫВАТЬ СПИСОК, А НЕ ТОЛЬКО ПОИСК. Один день
                    // готовый список висел вторым блоком прямо на вкладке, и строка
                    // отвечала лишь за то, чего в нём нет, — за поиск по слову. Блок
                    // владелец забраковал, и теперь это ЕДИНСТВЕННАЯ дверь к свежему
                    // списку с сортировкой. Обещать за ней один «поиск по слову» значит
                    // спрятать то, ради чего всё и делалось: человек не станет открывать
                    // поиск, если ему нечего печатать.
                    Text("Свежий список из справочника — с сортировкой и поиском по слову.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
    }
}

// MARK: - Общие строки находок

/// Значок годности: зелёная галочка, жёлтый восклицательный, серый вопрос, красный крест.
///
/// ⚠️ Отдельным видом, а не парой функций, ровно затем, чтобы колонка под значок
/// росла вместе с системным шрифтом (`ScaledMetric`) — в функции этого не сделать.
struct HubFitIcon: View {

    let badge: HubFitBadge

    @ScaledMetric(relativeTo: .body) private var gutter: CGFloat
        = Theme.Metrics.iconGutterWidth

    var body: some View {
        Image(systemName: HubFitStyle.symbol(for: badge))
            .font(.title3)
            .frame(minWidth: gutter, alignment: .leading)
            .foregroundStyle(HubFitStyle.color(for: badge))
            .accessibilityHidden(true)
    }
}

/// Один набор значков и цветов пометки на всё приложение.
enum HubFitStyle {

    static func symbol(for badge: HubFitBadge) -> String {
        switch badge {
        case .ready:      return "checkmark.circle.fill"
        case .tight:      return "exclamationmark.circle.fill"
        case .notYet:     return "questionmark.circle"
        case .impossible: return "xmark.circle.fill"
        }
    }

    static func color(for badge: HubFitBadge) -> Color {
        switch badge {
        case .ready:      return Theme.apply
        case .tight:      return Theme.Colors.warning
        case .notYet:     return Theme.Colors.textTertiary
        case .impossible: return Theme.removed
        }
    }
}

/// Строка-оговорка со значком: закрытый репозиторий, причина погашенной кнопки.
struct HubNoteRow: View {

    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Список находок: карточка на модель, внутри раскрывается список её файлов.
///
/// ⚠️ ОДНА РАЗМЕТКА НА ДВА ЭКРАНА. Ровно эти строки человек видит и на странице
/// поиска, и живым списком на вкладке «Модели». Копия разъехалась бы с оригиналом
/// на первой же правке, и на двух экранах про одну модель было бы написано разное.
struct HubResultsList: View {

    let repos: [HubRepoOption]
    /// Какая модель раскрыта до списка файлов. nil — все свёрнуты.
    @Binding var openedID: String?
    /// Идёт новый запрос: прежний список остаётся на месте, но гаснет.
    let isDimmed: Bool
    /// На каком файле загрузка не началась. nil — отказывать не в чем.
    let refusedFileID: String?
    /// Почему не началась.
    let refusalText: String?
    /// Что известно про «запустится ли эта модель». Ключ — опознаватель модели.
    /// Пусто — не спрашивали; строка тогда выглядит как раньше.
    var runChecks: [String: HubRunCheck] = [:]
    /// Строка появилась в списке — самое время узнать, запустится ли эта модель.
    ///
    /// ⚠️ ПО ПОЯВЛЕНИЮ, А НЕ ПО РАСКРЫТИЮ, и это не мелочь. Пометка «Не запустится»
    /// заводилась ровно затем, чтобы человек не тратил время впустую; спрашивая
    /// только про раскрытую строку, мы показывали ему двадцать одинаково годных
    /// на вид находок и открывали правду лишь тому, кто раскроет каждую.
    var onAppear: (HubRepoOption) -> Void = { _ in }
    let onDownload: (HubFileOption) -> Void
    /// Открыть «Картинки» с этим семейством. nil — входа туда отсюда нет.
    var onOpenImages: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            ForEach(repos) { repo in
                HubRepoRow(repo: repo,
                           isOpen: openedID == repo.id,
                           refusedFileID: refusedFileID,
                           refusalText: refusalText,
                           runCheck: runChecks[repo.id],
                           onToggle: {
                               openedID = openedID == repo.id ? nil : repo.id
                           },
                           onDownload: onDownload,
                           onOpenImages: onOpenImages)
                    .onAppear { onAppear(repo) }
            }
        }
        .opacity(isDimmed ? 0.5 : 1)
    }
}

/// Одна найденная модель.
struct HubRepoRow: View {

    let repo: HubRepoOption
    let isOpen: Bool
    /// На каком файле загрузка не началась. nil — отказывать не в чем.
    let refusedFileID: String?
    /// Почему не началась.
    let refusalText: String?
    /// Запустится ли эта модель вообще. nil — не спрашивали.
    var runCheck: HubRunCheck? = nil
    let onToggle: () -> Void
    let onDownload: (HubFileOption) -> Void
    var onOpenImages: ((String) -> Void)? = nil

    /// «Qwen-Image 2.1, Z-Image-Turbo, FLUX.2 klein 4B и FLUX.3 klein» — из реестра,
    /// чтобы новый набор не забывали дописать в подсказку руками.
    static var ownImageModelsList: String {
        let names = ImageModelRegistry.all.map(\.displayName)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " и " + names.last!
    }

    /// Семейство картинок, которое ставится у нас. nil — не картинки или не наше.
    private var imageFamily: ImageModelFamily? {
        if case .family(let id)? = repo.imageKind { return ImageModelRegistry.family(id: id) }
        return nil
    }

    /// Приговор: качать эту модель бессмысленно. nil — качать можно.
    private var refusal: HubRunRefusal? {
        if case .wontRun(let reason) = runCheck { return reason }
        return nil
    }

    /// Пометка строки. Приговор по устройству модели старше любой прикидки памяти:
    /// «должна пойти» на модели, которая не запустится никогда, — это враньё.
    private var shownBadge: HubFitBadge {
        if repo.imageKind == .unsupportedImage { return .impossible }
        if repo.imageKind != nil { return .ready }
        return refusal == nil ? repo.badge : .impossible
    }
    private var shownBadgeTitle: String {
        if repo.imageKind == .unsupportedImage { return "Для картинок · не умеем" }
        if repo.imageKind != nil { return "Для картинок" }
        return refusal == nil ? repo.badgeTitle : "Не запустится"
    }

    /// Раскрывается ли строка вообще.
    ///
    /// ⚠️ У МОДЕЛИ С ПРИГОВОРОМ СПИСКА ФАЙЛОВ НЕТ, И ЭТО ГЛАВНОЕ ЗДЕСЬ. Раньше он
    /// раскрывался, и у находки с пятью сжатиями человек читал «Не запустится» шесть
    /// раз подряд: один раз в шапке и по разу под каждым файлом, — причём ни у одного
    /// файла не было ни кнопки, ни объяснения. Список мёртвых имён, в котором нечего
    /// нажать. Всё, что человеку тут нужно, сказано одной строкой: крест, «Не запустится»
    /// и причина.
    ///
    /// ⚠️ У МОДЕЛИ КАРТИНОК СПИСКА ФАЙЛОВ ТОЖЕ НЕТ (ROADMAP §23): каждый её файл —
    /// это кнопка «поставить как модель для разговора», а говорить она не умеет.
    /// Вместо списка — один вход в «Картинки», где набор докачивается целиком.
    private var canOpen: Bool { refusal == nil && repo.imageKind == nil }

    /// Шапка находки: имя, кто выложил, числа и пометка.
    private var headline: some View {
        HStack(alignment: .top, spacing: 12) {
            HubFitIcon(badge: shownBadge)
            VStack(alignment: .leading, spacing: 4) {
                Text(repo.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !repo.authorText.isEmpty {
                    Text(repo.authorText)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                Text(repo.statsText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(shownBadgeTitle)
                    .font(Theme.Fonts.barLabel)
                    .foregroundStyle(HubFitStyle.color(for: shownBadge))
            }
            // Стрелка — обещание, что внутри что-то есть. У модели с приговором
            // внутри ничего нет, и стрелки быть не должно.
            if canOpen {
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if canOpen {
                Button(action: onToggle) {
                    headline
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(isOpen ? "Свернуть файлы" : "Показать файлы")
            } else {
                headline
                    .accessibilityElement(children: .combine)
            }

            // Закрытый репозиторий виден ЗАРАНЕЕ, ещё свёрнутой строкой: узнать про
            // согласие с лицензией после нажатия «Скачать» — это потраченное впустую
            // ожидание (ROADMAP, раздел 7).
            if let note = repo.noteText {
                HubNoteRow(icon: "lock", color: Theme.Colors.warning, text: note)
            }

            // Приговор по устройству модели — виден СРАЗУ, ещё до всякого нажатия
            // (ROADMAP, 12.8). Одна фраза, а не три: полное объяснение с советом
            // человек читает на странице модели, а в списке ему нужно только понять,
            // что эту качать незачем.
            if let family = imageFamily {
                imagesEntry(family)
            } else if repo.imageKind == .unsupportedImage {
                HubNoteRow(icon: "xmark.octagon", color: Theme.removed,
                           text: "Эту модель для картинок движок не умеет. В «Картинках» есть "
                               + Self.ownImageModelsList + ".")
            } else if let refusal {
                HubNoteRow(icon: "xmark.octagon", color: Theme.removed, text: refusal.short)
            } else if isOpen, runCheck == .checking {
                // ⚠️ ТОЛЬКО У РАСКРЫТОЙ СТРОКИ, И ЭТО ВАЖНО ТЕПЕРЬ, КОГДА СПРАШИВАЕМ
                // ПРО ВЕСЬ СПИСОК СРАЗУ. Покажи мы «Проверяю…» у каждой из двадцати
                // находок — получилась бы страница мигающих серых строк. У раскрытой
                // она нужна: молчание там читается как «всё хорошо, качайте», а мы
                // ровно в этот момент выясняем, не зря ли человек потратит время.
                HubNoteRow(icon: "clock",
                           color: Theme.Colors.textTertiary,
                           text: "Проверяю, запустится ли она.")
            }

            if isOpen, canOpen {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: Theme.Metrics.hairlineWidth)
                ForEach(repo.files) { file in
                    HubFileRow(file: file,
                               refusalText: file.id == refusedFileID ? refusalText : nil,
                               onDownload: onDownload)
                }
            }
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

extension HubRepoRow {

    /// Вход в «Картинки» с узнанным семейством: там набор докачивается целиком
    /// (рисующая часть, понимание текста, проявка) и сам настраивается.
    @ViewBuilder
    fileprivate func imagesEntry(_ family: ImageModelFamily) -> some View {
        if let onOpenImages {
            Button {
                onOpenImages(family.id)
            } label: {
                Text(ImageModelCatalog.isInstalled(family)
                     ? "Рисовать в «Картинках»"
                     : "Поставить \(family.displayName) в «Картинках»")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.textOnAccent)
            .background(Theme.Colors.accent, in: Capsule())
        } else {
            HubNoteRow(icon: "photo", color: Theme.textSecondary,
                       text: "Модель для картинок — ставится в разделе «Картинки».")
        }
    }
}

/// Один файл внутри модели — то, что человек в итоге качает.
struct HubFileRow: View {

    let file: HubFileOption
    /// Загрузка этого файла не началась, и вот почему. nil — либо не нажимали,
    /// либо всё пошло как надо.
    let refusalText: String?
    let onDownload: (HubFileOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                HubFitIcon(badge: file.badge)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName)
                        .font(Theme.Fonts.code)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(sizeLine)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    // Пустое пояснение бывает у файлов модели, которая не запустится:
                    // причина написана один раз, на самой модели, и повторять её
                    // под каждым файлом незачем.
                    Text(file.fitDetail.isEmpty ? file.badgeTitle : "\(file.badgeTitle). \(file.fitDetail)")
                        .font(.caption)
                        .foregroundStyle(HubFitStyle.color(for: file.badge))
                        .fixedSize(horizontal: false, vertical: true)
                    // ⚠️ Здесь же видно, замер это или расчёт: у моделей не из семейства
                    // Gemma в конце строки стоит оговорка «расчёт». Живьём мы мерили
                    // только Gemma, и подавать чужую модель как проверенную нельзя
                    // (см. ModelFitRule).
                    if let memoryNote = file.memoryNote {
                        Text(memoryNote)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // ⚠️ ПРЕДУПРЕЖДЕНИЕ СТОИТ НАД ЖИВОЙ КНОПКОЙ, А НЕ ВМЕСТО НЕЁ. Раньше на этом
            // месте была погашенная кнопка с отговоркой вроде «у файла нет контрольной
            // суммы, поэтому качать не станем». Владелец ответил на неё дословно:
            // «И что? А если я хочу скачать?» — и был прав. Наше дело назвать риск,
            // а нажимать или нет, решает он.
            if let warning = file.warningText {
                HubNoteRow(icon: "exclamationmark.triangle",
                           color: Theme.Colors.warning,
                           text: warning)
            }

            if file.canDownload {
                Button {
                    onDownload(file)
                } label: {
                    Text("Скачать · \(file.sizeText)")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.textOnAccent)
                .background(Theme.Colors.accent, in: Capsule())
            } else if let reason = file.blockReason {
                // Причина называется прямо вместо погашенной кнопки: кнопка без объяснения
                // читается как поломка приложения, а не как «этот файл отсюда не взять».
                HubNoteRow(icon: "info.circle", color: Theme.Colors.textTertiary, text: reason)
            }

            // ⚠️ ОТВЕТ НА НАЖАТИЕ. Нажал — и загрузка не пошла: причина встаёт здесь же,
            // под кнопкой, а экран поиска остаётся открытым. Именно этой строки не хватало,
            // когда владелец нажал «Скачать» и не увидел ни-че-го.
            if let refusalText {
                HubNoteRow(icon: "exclamationmark.circle.fill",
                           color: Theme.removed,
                           text: refusalText)
            }
        }
        .padding(.vertical, 6)
    }

    private var sizeLine: String {
        guard let partsNote = file.partsNote, !partsNote.isEmpty else { return file.sizeText }
        return "\(file.sizeText) · \(partsNote)"
    }
}
