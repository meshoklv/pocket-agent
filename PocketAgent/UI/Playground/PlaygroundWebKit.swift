//
//  PlaygroundWebKit.swift
//  PocketAgent
//
//  Общая начинка площадки: чем страница показывается, как у неё ловятся ошибки
//  и как приложение проверяет её ДО того, как показать человеку.
//
//  ⚠️ ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Одна и та же настройка нужна двум разным местам:
//  видимому просмотрщику и невидимой проверке («не показывать, пока не работает»,
//  ROADMAP §18.4В). Держать две копии настройки безопасности — прямой путь к тому,
//  что однажды их разведёт и невидимая проверка полезет в сеть.
//

import Foundation
import WebKit

// MARK: - Что пошло не так

/// Одна поломка на странице — человеческими словами.
struct PlaygroundIssue: Identifiable, Hashable, Sendable {

    enum Kind: String, Sendable {
        /// Ошибка в скрипте страницы.
        case script
        /// Не загрузилось что-то из соседних файлов (картинка, стиль, скрипт).
        case missingResource
        /// Страница попыталась выйти в сеть — мы не пустили.
        case blockedNetwork
        /// Страница вообще не открылась.
        case failedToOpen
        /// Страница тянет стили или скрипты из интернета, а его тут нет.
        ///
        /// ⚠️ ЭТО НЕ ПОЛОМКА И НЕ ПОВОД ДЕРЖАТЬ СТРАНИЦУ ЗАКРЫТОЙ. Знакомые адреса
        /// (Bootstrap, Tailwind, three.js и ещё два десятка) теперь лежат на полке
        /// внутри приложения и подменяются молча — сюда попадает только то, чего у нас
        /// нет. Такая страница открывается и работает, просто выглядит голой: показываем
        /// её сразу, а почему она голая — говорит спокойная строка на самой сцене.
        /// Отдавать это помощнику как отдельную задачу мы уже пробовали 10.09.2026:
        /// он открывал файл, видел, что всё верно, и отвечал «ошибок нет» — круг.
        case externalResource
        /// Страница сама что-то написала в свой журнал.
        ///
        /// ⚠️ ЭТО НЕ ПОЛОМКА, И ЭТО ВАЖНО. Рабочая игра вправе писать в журнал
        /// предупреждения. Считать их поломкой значит НЕ ПОКАЗАТЬ исправную игру —
        /// то есть сторож «не показывать, пока не работает» сработает против себя.
        case consoleNote
    }

    let id = UUID()
    let kind: Kind
    /// Короткая строка для человека.
    let text: String
    /// Строка в файле, если движок её назвал.
    let line: Int?

    /// Считается ли это НАСТОЯЩЕЙ поломкой, которую надо чинить.
    ///
    /// ⚠️ Попытка выйти в сеть — НЕ поломка страницы, а наша защита. Человеку
    /// её показываем (он должен знать, что страница ломилась наружу), но чинить
    /// помощнику не отдаём и показ из-за неё не задерживаем: сеть в этом продукте
    /// запрещена намеренно, и «починить» её нельзя.
    var isBreakage: Bool {
        switch kind {
        case .script, .missingResource, .failedToOpen: return true
        case .blockedNetwork, .consoleNote, .externalResource: return false
        }
    }

    /// Как это выглядит ЧЕЛОВЕКУ.
    ///
    /// ⚠️ ОТДЕЛЬНО ОТ СТРОКИ ДЛЯ ПОМОЩНИКА, И ЭТО НЕ ДУБЛЬ. Браузер сообщает
    /// «Uncaught ReferenceError: ctx is not defined» — помощнику это и нужно,
    /// он по этой строке чинит. Человеку такое показывать нельзя: всё, что он
    /// видит в этом приложении, — по-русски и человеческими словами.
    var lineForHuman: String {
        switch kind {
        case .script:          return "в коде страницы ошибка — сама она не запустится"
        case .missingResource: return "рядом со страницей не нашёлся нужный файл"
        case .failedToOpen:    return "страница не открылась"
        // ⚠️ ТЕКСТ ПЕРЕПИСАН ПОСЛЕ ПОЯВЛЕНИЯ ПОЛКИ (11.09.2026). Знакомые библиотеки
        // теперь подставляются с полки внутри приложения и человеку про это не говорят
        // вовсе — правильно, ему это знать незачем. Значит сюда доходит ровно один
        // случай: библиотеки на полке НЕТ. Прежние слова «тянет оформление… выглядит
        // голой» описывали только стили: если страница просила скрипт, она не «голая»,
        // а не работает вообще, и человек читал неправду про то, что видит.
        case .externalResource: return "страница просит из интернета готовую библиотеку, которой у нас нет"
        case .consoleNote:     return "страница что-то сообщила в свой журнал"
        case .blockedNetwork:  return text   // этот текст мы пишем сами, он уже человеческий
        }
    }

    /// Как это выглядит в задаче для помощника.
    ///
    /// ⚠️ У внешних ссылок текст СВОЙ и он говорит, что ДЕЛАТЬ. Просто «не загрузился
    /// bootstrap.css» помощник чинить не умеет — файл-то верный. А «впиши стили сам»
    /// он выполняет.
    var lineForAgent: String {
        if kind == .externalResource {
            return "страница ссылается на \(text) — этого адреса тут не будет, "
                 + "перепиши так, чтобы стили и скрипты были прямо внутри файла"
        }
        if let line { return "строка \(line): \(text)" }
        return text
    }

    /// Стоит ли УПОМИНАТЬ это в задаче помощнику — но НЕ «надо ли ради этого чинить».
    ///
    /// ⚠️⚠️ РАЗНИЦА С `isBreakage` ВАЖНА, И ПУТАТЬ ИХ НЕЛЬЗЯ. Решение «чинить или
    /// показывать» принимается ТОЛЬКО по `isBreakage` (см. `PlaygroundView.decide`).
    /// Пока это решалось здесь, косметика уводила человека в чат: он нажимал
    /// «посмотреть страницу», а его дважды прогоняли через кнопку «Применить», и
    /// страницу он видел лишь после того, как попытки кончались. Внешняя ссылка
    /// остаётся в списке потому, что помощник всё равно переписывает файл целиком
    /// из-за настоящей поломки — сказать заодно и про оформление дешевле, чем
    /// звать его второй раз.
    var isWorthFixing: Bool {
        switch kind {
        case .script, .missingResource, .failedToOpen, .externalResource: return true
        case .blockedNetwork, .consoleNote: return false
        }
    }
}

// MARK: - Настройка движка

enum PlaygroundWebKit {

    /// Имя канала, по которому страница сообщает нам о своих бедах.
    static let issueChannel = "pocketAgentIssue"

    /// Скрипт-наблюдатель. Ставится ДО кода страницы, иначе пропустит ранние ошибки.
    ///
    /// ⚠️ ЛОВИМ ЧЕТЫРЬМЯ СПОСОБАМИ, И КАЖДЫЙ НУЖЕН:
    ///  • `window.onerror` — обычная ошибка в скрипте;
    ///  • `unhandledrejection` — упавшее обещание, самая частая беда в играх;
    ///  • `console.error` — модель нередко сама пишет туда «не нашёл холст»;
    ///  • слушатель `error` в фазе перехвата — не загрузившиеся картинки, стили
    ///    и скрипты; обычным всплытием их не поймать, они не всплывают.
    static let watcherScript = """
    (function () {
      // ⚠️ WebRTC контентными правилами НЕ режется вообще — это отдельный канал,
      // по которому данные уходят DNS-запросами к чужому серверу. Заглушка тут
      // не абсолютна (страница может достать нетронутый объект из пустого фрейма),
      // но убирает самый простой путь. Настоящая защита — отсутствие интернета
      // у самого приложения; здесь мы закрываем то, что можем закрыть.
      try {
        delete window.RTCPeerConnection;
        delete window.webkitRTCPeerConnection;
        Object.defineProperty(window, 'RTCPeerConnection', { get: function () { return undefined; } });
      } catch (e) {}
      var sent = 0;
      function post(kind, text, line) {
        if (sent > 20) { return; }        // не заваливаем приложение потоком одинакового
        sent += 1;
        try {
          window.webkit.messageHandlers.\(issueChannel).postMessage({
            kind: kind, text: String(text || '').slice(0, 400), line: line || 0
          });
        } catch (e) {}
      }
      window.addEventListener('error', function (e) {
        if (e && e.target && e.target !== window && e.target.tagName) {
          var src = e.target.src || e.target.href || '';
          post('missingResource', e.target.tagName.toLowerCase() + ': ' + src, 0);
          return;
        }
        post('script', (e && e.message) || 'ошибка в скрипте', (e && e.lineno) || 0);
      }, true);
      window.addEventListener('unhandledrejection', function (e) {
        var r = e && e.reason;
        post('script', (r && (r.message || r)) || 'обещание отклонено', 0);
      });
      var realError = console.error;
      console.error = function () {
        post('consoleNote', Array.prototype.join.call(arguments, ' '), 0);
        try { realError.apply(console, arguments); } catch (e) {}
      };
    })();
    """

    /// Подставляемая строчка про масштаб — если автор страницы её не написал.
    ///
    /// ⚠️ ЗАЧЕМ. Страница без этой строчки открывается на телефоне так, будто это
    /// экран ноутбука: всё крошечное, кнопки не нажать, игра занимает угол. Модель
    /// на 2–4 млрд параметров про эту строчку забывает через раз, а человек видит
    /// «приложение показало какую-то мелочь» и винит площадку.
    ///
    /// ⚠️ И ПОЧЕМУ ТОЛЬКО ЕСЛИ АВТОР МОЛЧИТ. Своя строчка про масштаб — законный
    /// приём: игра вправе запретить растягивание пальцами или задать свою ширину.
    /// Перебить её значило бы сломать рабочую страницу ради нерабочей.
    /// Ставится в КОНЦЕ разбора: в начале головы страницы ещё нет, и авторская
    /// строчка не успела бы попасться нам на глаза — мы бы решили, что её нет.
    static let viewportScript = """
    (function () {
      try {
        if (document.querySelector('meta[name="viewport"]')) { return; }
        var m = document.createElement('meta');
        m.setAttribute('name', 'viewport');
        m.setAttribute('content', 'width=device-width, initial-scale=1, viewport-fit=cover');
        (document.head || document.documentElement).appendChild(m);
      } catch (e) {}
    })();
    """

    /// Собрать настройку движка: скрипты включены, сеть выключена, следов не остаётся.
    ///
    /// ⚠️ Правила блокировки сети ставятся отдельно и асинхронно (`installBlocking`) —
    /// собрать их синхронно WebKit не даёт.
    ///
    /// - Parameter rootURL: папка проекта. Из неё и только из неё обработчик схемы
    ///   отдаёт файлы странице.
    static func makeConfiguration(handler: WKScriptMessageHandler,
                                  rootURL: URL) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Скрипты нужны: без них не работает ни одна игра, а ради игр площадка и есть.
        // Безопасность держится не на их запрете, а на том, что позвонить некуда.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // ⚠️ ПАМЯТЬ СТРАНИЦЫ — ПОСТОЯННАЯ, И ЭТО ПЕРЕМЕНА РЕШЕНИЯ (11.09.2026).
        // Раньше стояло «ни кук, ни кэша, ни памяти между запусками» — и звучало
        // это правильно, но означало, что игра НЕ МОЖЕТ ЗАПОМНИТЬ РЕКОРД: закрыл
        // площадку — счёт обнулился. Владелец просил площадку «полноценную»,
        // а полноценной игры без сохранения не бывает.
        // Наружу это ничего не открывает: память живёт в песочнице приложения на
        // телефоне, сеть по-прежнему перекрыта, и уйти этим данным некуда.
        configuration.websiteDataStore = .default()
        // ⚠️ ЧУЖОЙ ПРОЕКТ НЕ ДОЛЖЕН ВИДЕТЬ ПАМЯТЬ ПРЕДЫДУЩЕГО. У всех страниц
        // площадки одно происхождение (`pa-play://page`), значит память у них общая.
        // Поэтому при СМЕНЕ ПАПКИ проекта прежние следы стираем — иначе игра из
        // одной папки прочитала бы рекорд игры из другой.
        forgetPreviousProjectIfNeeded(newRoot: rootURL, in: configuration.websiteDataStore)
        configuration.allowsInlineMediaPlayback = true
        // ⚠️ ЗВУК БЕЗ ПРЕДВАРИТЕЛЬНОГО НАЖАТИЯ. По умолчанию WebKit молчит, пока человек
        // сам не ткнёт в проигрыватель, — а в игре звук запускает код, а не палец, и игра
        // выходит немой. Безопасно это потому, что взяться звуку неоткуда, кроме файлов
        // этой же папки: сеть перекрыта, чужие источники в движок не попадают.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // ⚠️ ПОЛНОЭКРАННЫЙ РЕЖИМ ЭЛЕМЕНТА. Без него игра не может развернуть свой холст
        // на весь экран, а трёхмерная сцена остаётся в окошке. Наружу это ничего не
        // открывает: разворачивается элемент НАШЕЙ же страницы внутри нашего же окна.
        configuration.preferences.isElementFullscreenEnabled = true

        // ⚠️⚠️ СОБСТВЕННАЯ СХЕМА ВМЕСТО `file://` — РАДИ ПРОИСХОЖДЕНИЯ СТРАНИЦЫ.
        // Подробности, почему без него не работают модули, `fetch`, рабочие потоки и
        // текстуры трёхмерной сцены, — в шапке `PlaygroundSchemeHandler`.
        // Ставится ЗДЕСЬ, в общей настройке, а не у показа: невидимая проверка обязана
        // ходить ровно тем же путём, что и человек, иначе она проверяет не то приложение.
        configuration.setURLSchemeHandler(PlaygroundSchemeHandler(root: rootURL),
                                          forURLScheme: PlaygroundSchemeHandler.scheme)

        let controller = WKUserContentController()
        controller.add(handler, name: issueChannel)
        controller.addUserScript(WKUserScript(source: watcherScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: viewportScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        configuration.userContentController = controller
        return configuration
    }

    /// Забыть память страниц, если человек перешёл на ДРУГУЮ папку проекта.
    ///
    /// ⚠️ Ключ — путь папки, а не её имя: две разные папки «сайт» не должны
    /// считаться одной. Стирание идёт своим чередом (движок иначе не умеет), и это
    /// не гонка: страница ещё не загружена, читать ей пока нечего.
    private static let lastRootKey = "playground.lastProjectRoot"

    static func forgetPreviousProjectIfNeeded(newRoot: URL, in store: WKWebsiteDataStore) {
        let now = newRoot.standardizedFileURL.path
        let was = UserDefaults.standard.string(forKey: lastRootKey)
        guard was != now else { return }
        UserDefaults.standard.set(now, forKey: lastRootKey)
        // Первый запуск (прошлой папки не было) — стирать нечего, но и вреда нет:
        // память чужих проектов на этом происхождении всё равно не нужна.
        let kinds = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: kinds, modifiedSince: Date(timeIntervalSince1970: 0)) { }
    }

    /// Достать обработчик схемы из уже собранной настройки — чтобы сказать ему новую папку.
    static func schemeHandler(of webView: WKWebView) -> PlaygroundSchemeHandler? {
        webView.configuration
            .urlSchemeHandler(forURLScheme: PlaygroundSchemeHandler.scheme) as? PlaygroundSchemeHandler
    }

    /// Открыть страницу площадки. ОДИН путь для видимого показа и невидимой проверки.
    ///
    /// - Returns: удалось ли вообще начать загрузку. `false` — файл лежит вне папки
    ///   проекта, и это надо сказать вслух, а не проглотить.
    @discardableResult
    static func loadPage(_ fileURL: URL, root: URL, in webView: WKWebView) -> Bool {
        schemeHandler(of: webView)?.updateRoot(root)
        guard let pageURL = PlaygroundSchemeHandler.pageURL(forFile: fileURL, root: root) else {
            return false
        }
        webView.load(URLRequest(url: pageURL))
        return true
    }

    /// Правила, рубящие сеть внутри самого движка.
    ///
    /// ⚠️ ПОЧЕМУ СПИСКОМ СХЕМ, А НЕ «ЗАБЛОКИРОВАТЬ ВСЁ». Фильтр правил WebKit —
    /// урезанный набор образцов, отрицания в нём нет. Правило «блокируй всё» убило бы
    /// и нашу собственную схему, то есть саму страницу. Перечисляем сетевые схемы:
    /// того, чего в локальной странице быть не должно вовсе.
    /// ⚠️ ОБРАЗЦЫ ВЫНЕСЕНЫ ОТДЕЛЬНО НАРОЧНО. По ним же проверка площадки доказывает
    /// два факта разом: сетевые адреса под запрет ПОПАДАЮТ, а наша собственная схема
    /// `pa-play://` — НЕТ. Иначе правка, добавившая схему, могла бы тихо зарубить
    /// саму площадку (страница не открылась бы вовсе) или, наоборот, приоткрыть сеть.
    static let blockedURLPatterns = ["^https?://", "^wss?://", "^ftps?://"]

    private static var blockingRules: String {
        let rules = blockedURLPatterns
            .map { "{\"trigger\":{\"url-filter\":\"\($0)\"},\"action\":{\"type\":\"block\"}}" }
            .joined(separator: ",")
        return "[\(rules)]"
    }

    /// Поставить правила и сказать, ВСТАЛИ ли они.
    ///
    /// ⚠️⚠️ ЗАКРЫТО ПО УМОЛЧАНИЮ, И ЭТО ИСПРАВЛЕНИЕ НАСТОЯЩЕЙ ДЫРЫ (10.09.2026).
    /// Прежняя редакция при несобравшихся правилах показывала страницу всё равно,
    /// а в комментарии стояло «остаются ещё два слоя защиты». Это была НЕПРАВДА:
    ///  • решение о переходе (`decidePolicyFor`) вызывается только на НАВИГАЦИИ
    ///    фреймов — картинки, скрипты, `fetch`, маяки через него не проходят вовсе;
    ///  • обработчик схемы отдаёт только файлы папки и к сети не относится никак.
    /// То есть для подресурсов — а именно ими и утекают данные — слой РОВНО ОДИН,
    /// вот этот. Не встал он — защиты нет совсем, и `fetch('https://…')` уходит
    /// молча, даже без жалобы: жаловаться некому. Поэтому не встал — не показываем.
    static func installBlocking(on webView: WKWebView, then: @escaping (Bool) -> Void) {
        // ⚠️⚠️ ОТВЕТ ВОЗВРАЩАЕМ НА ГЛАВНЫЙ ПОТОК, И ЭТО НЕ ФОРМАЛЬНОСТЬ.
        // `compileContentRuleList` зовёт своё замыкание с ЧУЖОГО потока. А внутри
        // ответа мы трогаем и вьюху, и состояние проверки — то есть читаем с одного
        // потока то, что записано на другом. 10.09.2026 это стоило нам слепой
        // невидимой проверки: она видела вьюху как «ещё не созданную», немедленно
        // заканчивалась с пустым разбором и отвечала «жалоб нет» про заведомо
        // сломанную страницу — а значит самопочинка не срабатывала НИКОГДА.
        // Поймано замером: «в окне: да · загрузилась: НЕТ · ждали 0.0 с».
        let answer: (Bool) -> Void = { ok in
            if Thread.isMainThread { then(ok) } else { DispatchQueue.main.async { then(ok) } }
        }
        guard let store = WKContentRuleListStore.default() else { answer(false); return }
        store.compileContentRuleList(forIdentifier: "pocket-agent-playground-no-network",
                                     encodedContentRuleList: blockingRules) { list, _ in
            guard let list else { answer(false); return }
            // Правила добавляем тоже на главном потоке — настройка вьюхи не для чужих.
            DispatchQueue.main.async {
                webView.configuration.userContentController.add(list)
                then(true)
            }
        }
    }

    /// Можно ли пускать движок по этому адресу. ОДНА политика на видимый показ
    /// и на невидимую проверку.
    ///
    /// ⚠️ ЗАЧЕМ ОБЩАЯ. Раньше у невидимой проверки была своя, ослабленная: она
    /// пускала ЛЮБОЙ `file://`, не проверяя папку, и молчала об этом. Проверка,
    /// защищённая слабее показа, бессмысленна — она проверяет не то приложение,
    /// которое потом увидит человек. Ровно от этого расхождения и заведён общий файл.
    static func mayNavigate(to url: URL, insideRoot rootURL: URL) -> NavigationVerdict {
        // Движок открывает пустую страницу сам при старте — это не переход наружу.
        if url.absoluteString == "about:blank" { return .allow }
        // ⚠️ `javascript:` и `data:` в ссылке — не выход в интернет, и пугать ими
        // человека нельзя. Но и пускать незачем: страница и так исполняет свои скрипты.
        // ⚠️ `blob:` — это данные, которые страница сделала САМА и держит у себя в памяти.
        // Наружу по нему уйти нельзя, но и переход по нему нам не нужен. Отменяем МОЛЧА,
        // а не жалобой «ломится в интернет»: ложная жалоба уходит помощнику как задача,
        // и он идёт «чинить интернет» — ровно тот круг, с которым боролись 10.09.2026.
        if let scheme = url.scheme?.lowercased(),
           scheme == "javascript" || scheme == "data" || scheme == "blob" {
            return .cancelQuietly
        }
        // ⚠️⚠️ СВОЯ СХЕМА — ЭТО НЕ СЕТЬ, НО И НЕ «ПУСКАТЬ ВСЁ». Страницы площадки теперь
        // открываются как `pa-play://page/…` (ради происхождения — см. шапку
        // `PlaygroundSchemeHandler`). Не разбери мы эту схему здесь — площадка объявила
        // бы САМУ СЕБЯ попыткой выйти в интернет и не открыла бы ни одной страницы.
        // Границу папки при этом проверяем тем же разбором, что и выдача файлов:
        // двух разных ответов на вопрос «внутри ли это папки» быть не должно.
        if url.scheme?.lowercased() == PlaygroundSchemeHandler.scheme {
            switch PlaygroundSchemeHandler.resolve(url, root: rootURL) {
            case .ok: return .allow
            // «Файла нет» — обычное дело для страницы (опечатка в ссылке), и решает это
            // сам обработчик честным 404. Переход разрешаем, чтобы человек увидел
            // понятную страницу отказа, а не молчание.
            case .notFound: return .allow
            case .forbidden: return .outsideFolder
            }
        }
        guard url.isFileURL else { return .blockedNetwork(url.host ?? url.scheme ?? "неизвестный адрес") }
        // ⚠️ У file-адреса бывает ХОСТ: `file://evil.com/…/внутри-корня.html` прошёл бы
        // проверку пути насквозь. Чужой хост у локального файла — всегда подделка.
        guard url.host == nil || url.host?.isEmpty == true || url.host == "localhost" else {
            return .outsideFolder
        }
        // ⚠️ СРАВНИВАЕМ ПО КОМПОНЕНТАМ ПУТИ, А НЕ ЧЕРЕЗ hasPrefix. Это уже выстрадано
        // в SafePath: `hasPrefix` считает `/proj-evil` частью `/proj`. Своя проверка
        // здесь однажды разойдётся с той — поэтому зовём ту же самую.
        guard SafePath.isInside(url, root: rootURL) else { return .outsideFolder }
        // ⚠️⚠️ И ОТДЕЛЬНО — ССЫЛКА. Проверка выше сравнивает НАПИСАННЫЙ путь: ссылка
        // `внутри-папки.html -> /etc/passwd` проходит её насквозь, потому что лежит
        // она действительно внутри. Обход папки ссылки не показывает вовсе
        // (PlaygroundFinder), но страница вправе позвать любой адрес сама.
        // Разбор надзирателя 10.09.2026: единственная дыра границы, что осталась.
        guard !SafePath.isSymbolicLink(url) else { return .outsideFolder }
        return .allow
    }

    /// Что делать с переходом.
    enum NavigationVerdict {
        case allow
        /// Отменить и промолчать: человеку про это знать незачем.
        case cancelQuietly
        /// Страница ломится в интернет — отменить и сказать.
        case blockedNetwork(String)
        /// Страница ломится за пределы папки проекта — отменить и сказать.
        case outsideFolder
    }

    /// Сколько жалоб принимаем от одной страницы. Ограничение стоит ЗДЕСЬ, а не
    /// в скрипте: скрипт живёт внутри страницы, и обойти его она может в одну строку.
    static let maxIssuesPerRun = 20
    /// Длиннее этого текст ошибки не берём. Страница вольна прислать мегабайт.
    static let maxIssueTextLength = 200

    /// Разобрать сообщение от страницы.
    ///
    /// ⚠️⚠️ ТЕЛО СООБЩЕНИЯ ПИШЕТ ЧУЖОЙ КОД — ВЕРИТЬ ЕМУ НЕЛЬЗЯ НИ В ЧЁМ.
    /// Страница обращается к каналу напрямую, минуя наш скрипт-наблюдатель, и может
    /// прислать что угодно и сколько угодно. Поэтому длина режется здесь, счёт ведём
    /// снаружи, а вид `blockedNetwork` со страницы НЕ принимаем вовсе: его имеем
    /// право ставить только мы сами, увидев настоящую попытку выхода в сеть.
    static func issue(from body: Any) -> PlaygroundIssue? {
        guard let dict = body as? [String: Any],
              let rawKind = dict["kind"] as? String,
              let kind = PlaygroundIssue.Kind(rawValue: rawKind),
              kind != .blockedNetwork,
              let rawText = dict["text"] as? String,
              !rawText.isEmpty else { return nil }
        // ⚠️⚠️ ПЕРЕНОСЫ СТРОК ВЫРЕЗАЕМ, И ЭТО НЕ КРАСОТА, А ЗАЩИТА. Этот текст пишет
        // САМА СТРАНИЦА, и он потом ложится в задачу помощнику. Многострочная жалоба
        // умеет выглядеть в задаче как новый абзац с новым распоряжением — то есть
        // страница получает голос там, где его быть не должно. Одна строка такой
        // возможности не даёт, а читаемость от этого не страдает.
        let flattened = rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return nil }
        let text = String(flattened.prefix(maxIssueTextLength))
        let line = (dict["line"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        // ⚠️ Заблокированный нами внешний адрес приходит как «не нашёлся ресурс» —
        // это НЕ поломка страницы и чинить помощнику её нельзя (он побежит чинить
        // интернет). Распознаём по адресу и переводим в свой вид.
        if kind == .missingResource, Self.looksLikeNetworkAddress(text) {
            return PlaygroundIssue(kind: .externalResource, text: text, line: nil)
        }
        return PlaygroundIssue(kind: kind, text: text, line: line)
    }

    /// Похоже ли на сетевой адрес. Нужен, чтобы отличить «нет соседнего файла»
    /// от «мы сами не пустили в интернет».
    static func looksLikeNetworkAddress(_ text: String) -> Bool {
        let lower = text.lowercased()
        for marker in ["http://", "https://", "//cdn", "ws://", "wss://", "load failed", "failed to fetch"]
        where lower.contains(marker) { return true }
        return false
    }
}

// MARK: - Тихая проверка страницы до показа

/// Открывает страницу НЕВИДИМО, собирает её беды и гасит себя.
///
/// ⚠️ ЗАЧЕМ (правка владельца 10.09.2026, дословно): «ваще не показывать плейграунд
/// до того момента пока там не будет ошибок то есть агент сам все починит еще до того
/// как будет показывать пользователю это же гениально». Здесь — первая половина:
/// узнать про беды раньше человека. Вторая половина (отдать их помощнику) живёт
/// на экране, потому что применяет правку по-прежнему человек — ядро продукта
/// «один шаг, одно подтверждение» самопочинка не отменяет.
///
/// ⚠️ ПОЧЕМУ ВЬЮХА ВСЁ-ТАКИ ДОБАВЛЯЕТСЯ В ОКНО, А НЕ ВИСИТ В ВОЗДУХЕ. WKWebView,
/// не попавший в иерархию окна, iOS имеет право не отрисовывать — а без отрисовки
/// не запускаются ни таймеры страницы, ни рисование на холсте, и половина ошибок
/// игры просто не случится. Поэтому кладём его размером 1×1 и полностью прозрачным.
@MainActor
final class PlaygroundDoctor: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

    /// Сколько ждём, пока страница проявит себя. Меньше — не успевают сработать
    /// таймеры и рисование; больше — человек ждёт впустую.
    static let watchSeconds: TimeInterval = 2.2

    private var webView: WKWebView?
    private var rootURL: URL?
    private var issues: [PlaygroundIssue] = []
    private var finish: (([PlaygroundIssue]) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    /// ⚠️ ФАКТЫ О ПОСЛЕДНЕЙ ПРОВЕРКЕ — чтобы замер мог сказать, ПОЧЕМУ жалоб нет.
    /// 10.09.2026 проверка на телефоне отчиталась «жалоб нет» про заведомо сломанную
    /// страницу, и понять причину по одному этому слову было нельзя.
    private(set) var lastAttachedToWindow = false
    private(set) var lastElapsed: TimeInterval = 0
    private(set) var lastDidLoad = false
    private var startedAt = Date()

    /// Проверить страницу и вернуть, что с ней не так.
    func check(fileURL: URL, rootURL: URL) async -> [PlaygroundIssue] {
        await withCheckedContinuation { continuation in
            start(fileURL: fileURL, rootURL: rootURL) { found in
                continuation.resume(returning: found)
            }
        }
    }

    private func start(fileURL: URL, rootURL: URL, finish: @escaping ([PlaygroundIssue]) -> Void) {
        stop()
        self.finish = finish
        self.issues = []
        self.rootURL = rootURL

        let configuration = PlaygroundWebKit.makeConfiguration(handler: self, rootURL: rootURL)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                                configuration: configuration)
        webView.navigationDelegate = self
        // ⚠️ И РАСПОРЯДИТЕЛЬ ОКОН ТОЖЕ. Без него попытка страницы открыть окно наружу
        // проходит для проверки незаметно: окно всё равно не создастся, но в разбор
        // эта попытка не попадёт, и невидимая проверка окажется слепее видимого показа.
        // А расходиться им нельзя — ради этого весь файл и заведён.
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.isHidden = false
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        lastAttachedToWindow = Self.attachToWindow(webView)
        lastDidLoad = false
        startedAt = Date()
        self.webView = webView

        // ⚠️ СТРАХОВОЧНЫЙ СРОК ЗАВОДИМ СРАЗУ, А НЕ ВНУТРИ ОТВЕТА О ПРАВИЛАХ.
        // Прежде единственный срок жил в замыкании: не позвали замыкание — обещание
        // не разрешалось НИКОГДА, и площадка вставала насмерть до перезапуска
        // приложения. Цена мала, вероятность мала, последствие — намертво.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.watchSeconds + 6) * 1_000_000_000))
            // ⚠️⚠️ ОТМЕНЁННОЕ ОЖИДАНИЕ НЕ МОЛЧИТ, А СРАБАТЫВАЕТ НЕМЕДЛЕННО.
            // `Task.sleep` у отменённой задачи не спит, а бросает ошибку; `try?` её
            // проглатывает — и следующая строка выполняется В ТУ ЖЕ МИЛЛИСЕКУНДУ.
            // Именно это делало невидимую проверку слепой: ниже мы сами отменяем
            // этот срок, как только встали правила, — и он тут же «истекал»,
            // объявляя страницу проверенной ДО того, как она начала грузиться.
            // Замер показал это словами: «загрузилась: НЕТ · ждали 0.0 с».
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.report() }
        }

        PlaygroundWebKit.installBlocking(on: webView) { [weak self] didInstall in
            guard let self else { return }
            guard let webView = self.webView else { self.report(); return }
            guard didInstall else {
                // Защита не встала — не показываем вовсе. См. installBlocking.
                self.issues.append(PlaygroundIssue(
                    kind: .failedToOpen,
                    text: "не смог включить защиту от выхода в интернет — показывать страницу нельзя",
                    line: nil))
                self.report()
                return
            }
            // ⚠️ Открываем ТОЙ ЖЕ дорогой, что и видимый показ, — своей схемой. Разойдись
            // они, и проверка снова проверяла бы не то приложение, которое увидит человек:
            // на `file://` половина игр не работает вовсе, и «поломки», найденные тут,
            // были бы выдуманы нами самими.
            guard PlaygroundWebKit.loadPage(fileURL, root: rootURL, in: webView) else {
                // Файл вне папки проекта — открывать нельзя, и молчать об этом нельзя тоже.
                self.issues.append(PlaygroundIssue(
                    kind: .failedToOpen,
                    text: "файл лежит за пределами папки проекта — открыть его нельзя",
                    line: nil))
                self.report()
                return
            }
            self.timeoutTask?.cancel()
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.watchSeconds * 1_000_000_000))
                // Та же оговорка, что и у страховочного срока выше: отменённое
                // ожидание обязано промолчать, а не отчитаться немедленно.
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.report() }
            }
        }
    }

    /// Положить проверяющую вьюху в окно так, чтобы её никто не увидел.
    /// - Returns: удалось ли положить вьюху в окно. ⚠️ Это НЕ мелочь: вьюха вне
    ///   окна не рисуется и не выполняет таймеры, а значит страница молчит и проверка
    ///   честно возвращает «жалоб нет» — про сломанную страницу. Возвращаем факт,
    ///   чтобы замер отличал «страница цела» от «мы её даже не запустили».
    @discardableResult
    private static func attachToWindow(_ webView: WKWebView) -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            // ⚠️ Запасной вариант: любая сцена с окном. Во время замера приложение
            // может не считаться «деятельным», и строгий поиск не находил ничего.
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        else { return false }
        window.addSubview(webView)
        window.sendSubviewToBack(webView)
        return true
    }

    /// Страница попросила открыть новое окно — новых окон нет ни у показа, ни здесь.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, !url.isFileURL {
            MainActor.assumeIsolated {
                guard issues.count < PlaygroundWebKit.maxIssuesPerRun else { return }
                issues.append(PlaygroundIssue(
                    kind: .blockedNetwork,
                    text: "страница попыталась открыть окно наружу: \(url.host ?? url.scheme ?? "неизвестный адрес")",
                    line: nil))
            }
        }
        return nil
    }

    /// Страница дошла до конца загрузки — значит движок её действительно выполнял.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { lastDidLoad = true }
    }

    private func report() { stop() }

    /// Погасить проверку — И ОБЯЗАТЕЛЬНО ОТПУСТИТЬ ТОГО, КТО ЕЁ ЖДЁТ.
    ///
    /// ⚠️⚠️ ЗДЕСЬ БЫЛА ДЫРА, КОТОРАЯ ВЕШАЛА ПЛОЩАДКУ НАСМЕРТЬ. Прежняя `stop()`
    /// гасила таймер и вьюху, но обещание, выданное `check(fileURL:rootURL:)`,
    /// не разрешала. Достаточно было нажать карточку и в те же две секунды уйти
    /// в чат (`onDisappear` зовёт `stop()`) — и экран навсегда оставался с одной
    /// «проверяю…» карточкой, а остальные были притушены и не нажимались.
    /// Правило простое: у ожидания ровно один выход, и он здесь.
    func stop() {
        timeoutTask?.cancel(); timeoutTask = nil
        lastElapsed = Date().timeIntervalSince(startedAt)
        let found = issues
        let done = finish
        finish = nil
        webView?.stopLoading()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: PlaygroundWebKit.issueChannel)
        webView?.removeFromSuperview()
        webView = nil
        done?(found)
    }

    // MARK: Сообщения страницы

    /// ⚠️ БЕЗ ПРЫЖКА ЧЕРЕЗ ОЧЕРЕДЬ. WebKit зовёт это на главном потоке, а прежний
    /// `Task { @MainActor … }` ставил добавление В КОНЕЦ очереди — и жалоба, пришедшая
    /// за миг до срока, ложилась ПОСЛЕ отчёта и пропадала. Терялись именно поздние
    /// ошибки, то есть ровно те, ради которых и ждут две секунды.
    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard issues.count < PlaygroundWebKit.maxIssuesPerRun else { return }
            guard let issue = PlaygroundWebKit.issue(from: message.body) else { return }
            issues.append(issue)
        }
    }

    // MARK: Переходы

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            guard let url = navigationAction.request.url, let rootURL else {
                decisionHandler(.cancel); return
            }
            switch PlaygroundWebKit.mayNavigate(to: url, insideRoot: rootURL) {
            case .allow:
                decisionHandler(.allow)
            case .cancelQuietly:
                decisionHandler(.cancel)
            case .blockedNetwork(let where_):
                issues.append(PlaygroundIssue(kind: .blockedNetwork,
                                              text: "страница попыталась выйти в интернет: \(where_)",
                                              line: nil))
                decisionHandler(.cancel)
            case .outsideFolder:
                issues.append(PlaygroundIssue(kind: .blockedNetwork,
                                              text: "страница попыталась открыть файл за пределами папки",
                                              line: nil))
                decisionHandler(.cancel)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        let text = error.localizedDescription
        MainActor.assumeIsolated {
            issues.append(PlaygroundIssue(kind: .failedToOpen, text: text, line: nil))
            report()
        }
    }
}
