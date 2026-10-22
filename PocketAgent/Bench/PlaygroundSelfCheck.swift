//
//  PlaygroundSelfCheck.swift
//  PocketAgent / Bench
//
//  Проверка САМОЙ ПЛОЩАДКИ на живом телефоне — без единого нажатия человека.
//
//  ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ (10.09.2026). Замер проверял, что ПИШЕТ помощник, и ни разу —
//  что человек УВИДИТ, открыв площадку. Из-за этого владелец дважды находил руками
//  то, чего замер не ловил: круг «почини bootstrap» и голый сайт без стилей. А разбор
//  надзирателей нашёл в площадке два места, где она вставала намертво, — и опять
//  никакой замер этого не показывал.
//
//  ⚠️ ЧТО ИМЕННО ПРОВЕРЯЕТСЯ. Тот же движок, что у человека: `PlaygroundFinder` ищет
//  страницы, `PlaygroundDoctor` открывает их невидимо и выносит вердикт, `mayNavigate`
//  решает про переходы. Своей копии логики здесь нет НИ ОДНОЙ — иначе проверка
//  однажды разойдётся с приложением и будет успокаивать вместо того, чтобы ловить.
//
//  ⚠️ ЧЕГО ЭТО НЕ ЗАМЕНЯЕТ. Нажатий пальцем и вида экрана. Здесь проверяется
//  устройство площадки, а не её внешность.
//

#if DEBUG

import Foundation
import WebKit

@MainActor
enum PlaygroundSelfCheck {

    /// Одна проверка: что ожидали и что вышло.
    struct Result {
        let id: String
        let title: String
        let passed: Bool
        let detail: String
    }

    /// Прогнать все проверки. Модель для этого не нужна — секунды, а не минуты.
    static func run() async -> [Result] {
        var out: [Result] = []
        let root: URL
        do { root = try seed() } catch {
            return [Result(id: "playground-seed", title: "Разложить пробные страницы",
                           passed: false, detail: "не вышло: \(error)")]
        }

        // 1. Обход находит страницы и НЕ берёт ссылку.
        let scan = PlaygroundFinder.scan(rawRoot: root)
        let names = Set(scan.items.map(\.name))
        let wanted: Set<String> = ["ok.html", "cdn.html", "broken.html", "missing.html"]
        let foundPages = wanted.isSubset(of: names)
        out.append(Result(id: "playground-scan",
                          title: "Обход находит страницы в папке",
                          passed: foundPages,
                          detail: "нашёл: \(names.sorted().joined(separator: ", "))"))
        // ⚠️⚠️ «ССЫЛКИ НЕТ» — ЭТО ДОКАЗАТЕЛЬСТВО, ТОЛЬКО ЕСЛИ ОСТАЛЬНОЕ НАШЛОСЬ.
        //
        // Что ломалось: проверка устроена как отрицание, а отрицание всегда верно
        // для пустоты. Сломайся обход целиком и верни пустой список — эта строка
        // всё равно сказала бы «ссылки нет ✅». То есть самая слепая поломка из
        // возможных выглядела бы зелёной именно там, где мы сторожим границу папки.
        // Поэтому требуем ДВА факта разом: страницы найдены И ссылки среди них нет.
        let linkLeaked = names.contains("ссылка-наружу.html")
        out.append(Result(id: "playground-scan-skips-link",
                          title: "Обход не берёт символическую ссылку",
                          passed: foundPages && !linkLeaked,
                          detail: linkLeaked ? "ссылка попала в список"
                                : foundPages ? "страницы найдены, ссылки среди них нет"
                                : "обход не нашёл и обычных страниц — судить о ссылке не по чему"))

        // 2. Вердикты невидимой проверки — по одной странице за раз.
        let doctor = PlaygroundDoctor()
        for (file, expectation) in Self.expectations {
            let issues = await doctor.check(fileURL: root.appendingPathComponent(file), rootURL: root)
            let kinds = Set(issues.map(\.kind))
            // ⚠️⚠️ ПРОВЕРКА ОБЯЗАНА ДОКАЗАТЬ, ЧТО ОНА ВООБЩЕ СМОТРЕЛА НА СТРАНИЦУ.
            //
            // Что ломалось 10.09.2026. Ожидание для хорошей страницы — «никаких
            // жалоб», и оно выполняется САМО СОБОЙ, когда движок не отработал:
            // жалоб нет ни у целой страницы, ни у непроверенной. Проверка трижды
            // отвечала «жалоб нет ✅» про страницы, которые в тот момент даже не
            // начинали грузиться (отменённое ожидание срабатывало мгновенно) —
            // и по слову «жалоб нет» отличить одно от другого было нельзя.
            //
            // Теперь рядом с ожиданием стоит требование к самой проверке: вьюха
            // была в окне и страница ДОГРУЗИЛАСЬ. Не доказала — провал, каким бы
            // удобным ни выглядел вердикт.
            // ⚠️ Жалоба — это тоже доказательство работы: страница могла не
            // догрузиться именно потому, что с ней беда, и объявлять такую проверку
            // несостоявшейся значило бы прятать настоящую находку.
            let didWork = doctor.lastAttachedToWindow && (doctor.lastDidLoad || !issues.isEmpty)
            let passed = didWork && expectation.holds(kinds)
            // ⚠️ ГОВОРИМ НЕ ТОЛЬКО «ЧТО», НО И «ПОЧЕМУ». 10.09.2026 проверка на телефоне
            // трижды ответила «жалоб нет» про заведомо сломанные страницы, и по одному
            // этому слову понять было нечего: страница цела? движок её не выполнял?
            // не дождались? Теперь рядом стоят факты, по которым это различимо.
            let facts = "в окне: \(doctor.lastAttachedToWindow ? "да" : "НЕТ")"
                + " · загрузилась: \(doctor.lastDidLoad ? "да" : "НЕТ")"
                + " · ждали \(String(format: "%.1f", doctor.lastElapsed)) с"
                + (didWork ? "" : " · ПРОВЕРКА НЕ СОСТОЯЛАСЬ, вердикту верить нельзя")
            out.append(Result(id: "playground-\(file)",
                              title: expectation.title,
                              passed: passed,
                              detail: (kinds.isEmpty ? "жалоб нет"
                                                     : kinds.map(\.rawValue).sorted().joined(separator: ", "))
                                      + " · " + facts))
        }
        doctor.stop()

        // 3. Граница папки — чистая проверка решения о переходе, без движка.
        out.append(border(id: "playground-border-absolute",
                          title: "Абсолютный путь наружу отклонён",
                          url: URL(fileURLWithPath: "/etc/passwd"), root: root))
        out.append(border(id: "playground-border-dotdot",
                          title: "Путь через ../ отклонён",
                          url: root.appendingPathComponent("../чужое.html"), root: root))
        out.append(border(id: "playground-border-symlink",
                          title: "Ссылка изнутри папки наружу отклонена",
                          url: root.appendingPathComponent("ссылка-наружу.html"), root: root))
        out.append(border(id: "playground-border-network",
                          title: "Выход в интернет отклонён",
                          url: URL(string: "https://example.com/x")!, root: root, expectNetwork: true))
        // 3б. ГРАНИЦА ПО НАШЕЙ СОБСТВЕННОЙ СХЕМЕ. Страницы теперь открываются как
        // `pa-play://page/…`, и все прежние проверки границы проверяли ДРУГУЮ дорогу —
        // ту, которой человек больше не ходит. Проверка, отставшая от кода, успокаивает.
        out.append(schemeBorder(id: "playground-scheme-dotdot",
                                title: "Свой адрес с ../ наружу отклонён",
                                url: playURL("../чужое.html"), root: root, expectAllow: false))
        out.append(schemeBorder(id: "playground-scheme-symlink",
                                title: "Свой адрес на ссылку-обманку отклонён",
                                url: playURL("ссылка-наружу.html"), root: root, expectAllow: false))
        out.append(schemeBorder(id: "playground-scheme-host",
                                title: "Свой адрес с чужим хостом отклонён",
                                url: URL(string: "pa-play://чужой-хост/ok.html")
                                    ?? URL(string: "pa-play://other/ok.html"),
                                root: root, expectAllow: false))
        out.append(schemeBorder(id: "playground-scheme-protected",
                                title: "Служебный файл (.git) по своей схеме отклонён",
                                url: playURL(".git/config"), root: root, expectAllow: false))
        // ⚠️ ГРАНИЦА САМОЙ ПОЛКИ. Полка лежит внутри приложения, но адрес к ней пишет
        // страница, сочинённая моделью: `pa-play://lib/../../…` — ровно та попытка,
        // ради которой проверка и заводится. Своей папке доверия не больше, чем чужой.
        out.append(schemeBorder(id: "playground-shelf-dotdot",
                                title: "Уход с полки через ../ отклонён",
                                url: URL(string: "pa-play://lib/%2E%2E/%2E%2E/тайна.txt"),
                                root: root, expectAllow: false))
        out.append(schemeBorder(id: "playground-shelf-inside",
                                title: "Файл с полки по своему адресу открывается",
                                url: URL(string: "pa-play://lib/three/three.min.js"),
                                root: root, expectAllow: true))
        out.append(schemeBorder(id: "playground-scheme-inside",
                                title: "Своя страница по своей схеме открывается",
                                url: playURL("ok.html"), root: root, expectAllow: true))

        // 4. ⚠️⚠️ ДОКАЗАТЕЛЬСТВО, ЧТО СЕТЬ ПО-ПРЕЖНЕМУ ЗАКРЫТА, А ПЛОЩАДКА — НЕТ.
        //
        // Правки этого дня добавили движку собственную схему. Ошибись мы в образцах
        // блокировки на один символ — и получилось бы одно из двух, оба тихие:
        // либо схема попала бы под запрет (площадка не открывает НИЧЕГО, а выглядит
        // это как «страница пустая»), либо запрет перестал бы ловить сетевые адреса
        // (и содержимое папки уехало бы наружу молча). Проверяем оба факта разом,
        // теми же самыми образцами, которые уходят в движок.
        out.append(networkRules())

        // ⚠️⚠️ ОБРАЗЕЦ «РАЗРЕШИТЬ» — БЕЗ НЕГО ТРИ ЗАПРЕТА НИЧЕГО НЕ ЗНАЧАТ.
        //
        // Что ломалось: все проверки границы ждали ОТКАЗА. Сломайся решение о
        // переходе так, что оно отказывает всегда, — и три из четырёх строк
        // остались бы зелёными, а площадка перестала бы открывать вообще что
        // угодно, включая работу помощника. Проверка, которая не умеет отличить
        // «правильно запрещает» от «запрещает всё», доказывает только своё
        // существование. Поэтому рядом стоит обратный образец.
        out.append(allowed(id: "playground-border-inside",
                           title: "Своя страница внутри папки открывается",
                           url: root.appendingPathComponent("ok.html"), root: root))

        return out
    }

    // MARK: - Ожидания по каждой странице

    private struct Expectation {
        let title: String
        /// Виды жалоб, которые ОБЯЗАНЫ быть.
        let required: Set<PlaygroundIssue.Kind>
        /// Виды жалоб, которых быть НЕ должно.
        let forbidden: Set<PlaygroundIssue.Kind>

        func holds(_ kinds: Set<PlaygroundIssue.Kind>) -> Bool {
            required.isSubset(of: kinds) && kinds.isDisjoint(with: forbidden)
        }
    }

    private static let expectations: [(String, Expectation)] = [
        ("ok.html", Expectation(
            title: "Хорошая страница проходит без жалоб",
            required: [],
            // ⚠️ Именно этого мы и добиваемся: рабочую страницу нельзя отправлять
            // помощнику «чинить» — на этом владелец поймал круг 10.09.2026.
            forbidden: [.script, .missingResource, .failedToOpen, .externalResource])),
        ("cdn.html", Expectation(
            title: "Ссылка на чужой сайт — это «перепиши со своими стилями», а не поломка",
            required: [.externalResource],
            forbidden: [.script])),
        ("broken.html", Expectation(
            title: "Ошибка в скрипте страницы замечена",
            required: [.script],
            forbidden: [])),
        ("missing.html", Expectation(
            title: "Не найденный соседний файл замечен",
            required: [.missingResource],
            forbidden: [])),
        // ⚠️⚠️ ТРИ ПРОВЕРКИ НИЖЕ — ЭТО И ЕСТЬ ПРАВКА «ПЛОЩАДКА С ПОДДЕРЖКОЙ ВСЕГО».
        // Каждая из них НА `file://` ПАДАЛА: у файлового адреса нет происхождения,
        // и браузер запрещает ровно то, из чего состоят сайты, игры и трёхмерные сцены.
        // Каждая требует ПОЛОЖИТЕЛЬНОГО признака (страница сама сообщает «получилось»),
        // а не «жалоб нет»: молчание бывает и у непроверенной страницы — на этом
        // площадка уже обожглась 10.09.2026.
        ("модули.html", Expectation(
            title: "Модуль и чтение соседнего файла работают",
            required: [.consoleNote],
            forbidden: [.script, .missingResource, .failedToOpen])),
        ("рабочий.html", Expectation(
            title: "Рабочий поток (Worker) создаётся и отвечает",
            required: [.consoleNote],
            forbidden: [.script, .missingResource, .failedToOpen])),
        ("холст.html", Expectation(
            title: "Картинка ложится на холст и холст остаётся читаемым (текстуры 3D)",
            required: [.consoleNote],
            forbidden: [.script, .missingResource, .failedToOpen])),
        ("полка-ссылка.html", Expectation(
            title: "Библиотека с полки подменяет ссылку в интернет (обычная сборка)",
            required: [.consoleNote],
            forbidden: [.script, .missingResource, .failedToOpen, .externalResource])),
        ("полка-модуль.html", Expectation(
            title: "Библиотека с полки берётся по голому имени в модуле",
            required: [.consoleNote],
            forbidden: [.script, .missingResource, .failedToOpen, .externalResource]))
    ]

    /// Адрес площадки из пути внутри папки — БЕЗ канонизации.
    ///
    /// ⚠️ Почему не зовём `PlaygroundSchemeHandler.pageURL`: тот снимает символические
    /// ссылки, и адрес на ссылку-обманку через него просто не собрался бы — проверить
    /// границу было бы нечем.
    /// ⚠️ И почему «..» кодируем: разбор адресов в системе сам схлопывает точки,
    /// и написанный «..» до нас бы не доехал. Закодированный доезжает — а это ровно
    /// та форма, которой и пробуют обойти проверку.
    private static func playURL(_ relative: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encoded = relative
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { part -> String in
                if part == ".." { return "%2E%2E" }
                return String(part).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            }
            .joined(separator: "/")
        return URL(string: "\(PlaygroundSchemeHandler.scheme)://\(PlaygroundSchemeHandler.host)/" + encoded)
    }

    /// Проверка границы для адреса собственной схемы.
    private static func schemeBorder(id: String, title: String, url: URL?,
                                     root: URL, expectAllow: Bool) -> Result {
        guard let url else {
            return Result(id: id, title: title, passed: false, detail: "адрес не собрался — проверять нечего")
        }
        let verdict = PlaygroundWebKit.mayNavigate(to: url, insideRoot: root)
        let allowed: Bool
        switch verdict {
        case .allow: allowed = true
        case .cancelQuietly, .blockedNetwork, .outsideFolder: allowed = false
        }
        return Result(id: id, title: title, passed: allowed == expectAllow, detail: "\(verdict)")
    }

    /// Образцы блокировки сети: ловят ли они сеть и НЕ ловят ли нашу схему.
    private static func networkRules() -> Result {
        let network = ["https://example.com/x", "http://example.com/x",
                       "wss://example.com/s", "ftp://example.com/f"]
        let ours = ["\(PlaygroundSchemeHandler.scheme)://\(PlaygroundSchemeHandler.host)/игра/index.html",
                    "\(PlaygroundSchemeHandler.scheme)://\(PlaygroundSchemeHandler.host)/сцена.glb"]
        let expressions = PlaygroundWebKit.blockedURLPatterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        guard expressions.count == PlaygroundWebKit.blockedURLPatterns.count else {
            return Result(id: "playground-network-rules", title: "Правила сети: сеть закрыта, своя схема открыта",
                          passed: false, detail: "образцы не разобрались — правила в движок не встанут")
        }
        func matches(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            return expressions.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
        }
        let missedNetwork = network.filter { !matches($0) }
        let caughtOurs = ours.filter { matches($0) }
        let passed = missedNetwork.isEmpty && caughtOurs.isEmpty
        let detail = passed
            ? "сетевых адресов под запретом: \(network.count) · своя схема под запрет не попала"
            : "не поймали сеть: \(missedNetwork.joined(separator: ", "))"
                + " · зря поймали своё: \(caughtOurs.joined(separator: ", "))"
        return Result(id: "playground-network-rules",
                      title: "Правила сети: сеть закрыта, своя схема открыта",
                      passed: passed, detail: detail)
    }

    /// Обратный образец: то, что открывать МОЖНО, обязано открываться.
    private static func allowed(id: String, title: String, url: URL, root: URL) -> Result {
        let verdict = PlaygroundWebKit.mayNavigate(to: url, insideRoot: root)
        if case .allow = verdict {
            return Result(id: id, title: title, passed: true, detail: "\(verdict)")
        }
        return Result(id: id, title: title, passed: false,
                      detail: "\(verdict) — площадка не открывает даже свою страницу")
    }

    /// Сколько проверок этот набор обязан вернуть.
    ///
    /// ⚠️ Число нужно снаружи: замер сверяет его с тем, сколько проверок пришло
    /// на самом деле. Иначе набор, оборвавшийся на середине, даёт короткий
    /// зелёный список, который выглядит как удачный прогон.
    /// Считается: 2 (обход) + по одной на каждую страницу + 4 (граница по файлам)
    /// + 5 (граница по своей схеме) + 1 (правила сети) + 1 (образец «разрешить»).
    static var expectedCount: Int { 2 + expectations.count + 4 + 5 + 2 + 1 + 1 }

    private static func border(id: String, title: String, url: URL, root: URL,
                               expectNetwork: Bool = false) -> Result {
        let verdict = PlaygroundWebKit.mayNavigate(to: url, insideRoot: root)
        let ok: Bool
        switch verdict {
        case .outsideFolder:  ok = !expectNetwork
        case .blockedNetwork: ok = expectNetwork
        case .allow, .cancelQuietly: ok = false
        }
        return Result(id: id, title: title, passed: ok, detail: "\(verdict)")
    }

    // MARK: - Пробные страницы

    /// ⚠️ Все страницы — САМОДОСТАТОЧНЫЕ, кроме той, что нарочно ломается. Иначе
    /// проверка сама зависела бы от сети, которой в приложении нет.
    private static func seed() throws -> URL {
        // ⚠️⚠️ ВРЕМЕННАЯ ПАПКА, А НЕ «Bench» РЯДОМ С ОТЧЁТАМИ — И ЭТО НЕ ВКУСОВЩИНА.
        // Проверка кладёт СИМВОЛИЧЕСКУЮ ССЫЛКУ НАРУЖУ (ловушку для границы папки).
        // Пока она лежала внутри «Bench», выгрузка отчётов с телефона спотыкалась
        // об неё: «Failed to open …/ссылка-наружу.html, POSIX error 62» — и самый
        // свежий отчёт не приезжал вовсе. Полночи 11.09.2026 ушло на «отчёт битый»
        // и «числа брать неоткуда» ровно из-за этого мусора.
        let base = FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("Площадка", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let pages: [String: String] = [
            "ok.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Ок</title>
            <style>body{background:#111;color:#eee;font-family:system-ui}</style></head>
            <body><h1>Работает</h1><script>document.title="ок"</script></body></html>
            """,
            // ⚠️ АДРЕС НАРОЧНО ТАКОЙ, КОТОРОГО НА ПОЛКЕ НЕТ И НЕ БУДЕТ. Раньше здесь
            // стоял bootstrap — а он с 11.09.2026 лежит у нас на полке, и правильным
            // поведением стало БЕЗ жалобы (мы подменяем адрес своим файлом). Проверка
            // покраснела бы на ровном месте, хотя всё работает.
            "cdn.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Через интернет</title>
            <link rel="stylesheet" href="https://чужой-сайт.example/оформление/наше.css">
            </head><body><h1>Голая</h1></body></html>
            """,
            // ⚠️ ПОЛКА: ссылка в интернет на ЗНАКОМУЮ библиотеку обязана подмениться
            // нашим файлом ДО того, как браузер пойдёт в сеть. Не подменилась —
            // страница молчит, и это красное.
            "полка-ссылка.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Полка</title>
            <script src="https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js"></script>
            </head><body><h1>Полка</h1><script>
            if (typeof THREE !== 'undefined' && THREE.Scene) {
              console.error('ПОЛКА-ОБЫЧНАЯ:да');
            }
            </script></body></html>
            """,
            // ⚠️ ПОЛКА: голое имя в модуле (`import … from 'three'`) работает только
            // если мы вставили карту соответствий. Не вставили — браузер объявит имя
            // неразрешимым, записи не будет.
            "полка-модуль.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Полка-модуль</title></head>
            <body><h1>Полка</h1><script type="module">
            import * as THREE from 'three';
            if (THREE && THREE.Scene) { console.error('ПОЛКА-МОДУЛЬ:да'); }
            </script></body></html>
            """,
            "broken.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Сломана</title></head>
            <body><h1>Ошибка</h1><script>нетТакойФункции();</script></body></html>
            """,
            "missing.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Нет соседа</title></head>
            <body><h1>Нет файла</h1><script src="нет-такого-файла.js"></script></body></html>
            """,
            // Модуль + чтение соседнего файла. На file:// не работает ни то, ни другое.
            "модули.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Модули</title></head>
            <body><h1>Модуль</h1><script type="module" src="./module.js"></script></body></html>
            """,
            "module.js": """
            const ответ = await fetch('./data.json');
            const данные = await ответ.json();
            console.error('МОДУЛЬ-РАБОТАЕТ:' + данные.ok);
            """,
            "data.json": """
            {"ok":"да"}
            """,
            // Рабочий поток. На file:// его создание бросает ошибку сразу.
            "рабочий.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Поток</title></head>
            <body><h1>Поток</h1><script>
            function беда(текст) {
              try {
                window.webkit.messageHandlers.pocketAgentIssue.postMessage(
                  { kind: 'script', text: текст, line: 0 });
              } catch (e) {}
            }
            try {
              var w = new Worker('./worker.js');
              w.onmessage = function (e) { console.error('РАБОЧИЙ-ПОТОК:' + e.data); };
              w.onerror = function (e) { беда('рабочий поток упал: ' + (e && e.message)); };
              w.postMessage('пинг');
            } catch (e) { беда('рабочий поток не создался: ' + e); }
            </script></body></html>
            """,
            "worker.js": """
            onmessage = function (e) { postMessage('готов'); };
            """,
            // Текстура на холсте. На file:// холст «портится» и getImageData бросает
            // ошибку — из-за этого и умирали трёхмерные сцены с картинкой.
            "холст.html": """
            <!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Холст</title></head>
            <body><h1>Холст</h1><script>
            function беда(текст) {
              try {
                window.webkit.messageHandlers.pocketAgentIssue.postMessage(
                  { kind: 'script', text: текст, line: 0 });
              } catch (e) {}
            }
            var img = new Image();
            img.onload = function () {
              try {
                var c = document.createElement('canvas');
                c.width = 1; c.height = 1;
                var g = c.getContext('2d');
                g.drawImage(img, 0, 0);
                g.getImageData(0, 0, 1, 1);
                console.error('ХОЛСТ-ЧИСТ');
              } catch (e) { беда('холст испорчен картинкой: ' + e); }
            };
            img.onerror = function () { беда('картинка не загрузилась'); };
            img.src = './dot.png';
            </script></body></html>
            """
        ]
        for (name, text) in pages {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // Точка 1×1 в PNG. Нужна настоящая картинка, а не SVG: только с растровой
        // текстурой видно, «портится» холст или нет.
        if let dot = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==") {
            try dot.write(to: root.appendingPathComponent("dot.png"))
        }
        // Ссылка изнутри папки наружу — ровно та дыра, которую закрыли 10.09.2026.
        try? FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("ссылка-наружу.html"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        return root
    }
}

#endif
