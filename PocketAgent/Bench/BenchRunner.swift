//
//  BenchRunner.swift
//  PocketAgent / Bench
//
//  Прогон набора задач на ЖИВОЙ модели ЖИВОГО телефона, без единого нажатия.
//
//  ⚠️ ЗАМЕР ИДЁТ ТОЙ ЖЕ ДОРОГОЙ, ЧТО И ЧЕЛОВЕК, И ЭТО ГЛАВНОЕ ТРЕБОВАНИЕ К НЕМУ.
//  Здесь нет ни своей сборки помощника, ни своего разбора ответов, ни своего пути
//  к файлам: поднимается тот же движок (`runtime.prepare`), собирается та же сессия
//  (`AgentAssembly.makeSession`), задача уходит тем же `submit`, а карточка правки
//  подтверждается тем же `approve`, что и пальцем по экрану. Замер, который ходит
//  в обход продукта, меряет сам себя — и однажды покажет зелёное на сломанном
//  приложении.
//
//  ⚠️ «ПРИМЕНИТЬ» ЖМЁТ ЗАМЕР — И ЭТО НЕ ДЫРА В ЯДРЕ ПРОДУКТА. Правило «без нажатия
//  человека на диск ничего не попадает» остаётся нетронутым: запись по-прежнему
//  возможна ТОЛЬКО через approve(), просто в замере на эту кнопку жмёт код, и жмёт он
//  её в своей папке-песочнице (Library/Application Support/Bench), а не в файлах
//  человека. Ни одна из этих строк не собирается в сборку для магазина.
//

#if DEBUG

import Foundation
import UIKit
import os

/// Отказ замера сделать то, чего ему делать нельзя.
///
/// ⛔ Пока причина ровно одна: в режиме настоящей папки владельца замер не пишет
/// на диск ничего и никогда. Отдельный тип нужен, чтобы такой отказ было видно
/// в отчёте текстом, а не как безымянную ошибку файловой системы.
enum BenchRefusal: LocalizedError {
    case ownerFolderIsReadOnly

    var errorDescription: String? {
        switch self {
        case .ownerFolderIsReadOnly:
            return "в настоящей папке владельца замер работает ТОЛЬКО на чтение — "
                + "раскладка файлов запрещена"
        }
    }
}

@MainActor
final class BenchRunner: ObservableObject {

    /// Что показать на экране, пока идёт прогон, — чтобы с телефона было видно, что
    /// он не завис. Читать отчёт всё равно будем файлом.
    @Published private(set) var line = "Готовлюсь…"
    @Published private(set) var log: [String] = []
    @Published private(set) var isDone = false
    /// Замер НЕ состоялся: считать было нечего или отчёт не лёг на диск.
    ///
    /// ⚠️ Отдельно от `isDone`, потому что экран раньше писал «Замер закончен»
    /// на любой конец, включая отказ. Слово «закончен» человек читает как
    /// «получилось», и отличить провал от успеха с телефона было нельзя.
    @Published private(set) var failed = false
    @Published private(set) var reportPath = ""

    /// Сколько ждём одну задачу, прежде чем признать её зависшей.
    /// Ход маленькой модели на телефоне — единицы секунд; шесть минут на задачу
    /// с запасом покрывают даже подъём по лесенке настроек.
    ///
    /// ⚠️ СТОРОЖ НЕ ВСЕСИЛЕН, И ЭТО ПРОВЕРЕНО БОЛЬЮ (07.09.2026). Прогон на модели
    /// LFM2.5-2.6B завис НАСМЕРТЬ: полтора часа без единого движения, хотя сторож
    /// обязан был снять задачу через шесть минут. Причина в том, что сторож зовёт
    /// `session.cancel()`, а тот просит движок прервать ход — если сам движок застрял
    /// внутри генерации и наружу не выходит, просить некого. Прогон пришлось убивать
    /// снаружи (`devicectl device process terminate`).
    ///
    /// Что из этого следует для следующего: (1) на незнакомой модели не оставлять
    /// замер без присмотра дольше получаса; (2) отчёт пишется только В КОНЦЕ, поэтому
    /// зависший прогон не оставляет вообще никаких чисел — стоит научить замер
    /// дописывать отчёт после КАЖДОЙ задачи, тогда зависание будет стоить одну задачу,
    /// а не весь прогон.
    /// ⚠️ 10 МИНУТ, А НЕ 6 — РЕШЕНИЕ ВЛАДЕЛЦА 11.09.2026 («подними до 10 минут»).
    /// Повод: в полном наборе задача «игра одним файлом» провалилась дважды из трёх
    /// только по таймеру — модель успевала сделать 13–15 шагов, и ответ обрывался
    /// на 360 секундах посреди работы. Это мерило скорости модели, а не поломки,
    /// и резать её собственным сторожем нечестно.
    private let scenarioTimeout: TimeInterval = 600

    /// Сколько раз подряд можно нажать «Применить» в одной задаче.
    /// Больше — это уже не работа, а круг, и его надо прервать.
    private let maxApprovals = 8

    /// Настройки владельца, которые замер трогает на время прогона и возвращает назад.
    private var toolsWereEnabled = true
    private var webSearchWasEnabled = false

    /// Модель, которая была выбрана у владельца до замера.
    ///
    /// ⚠️ ЕЁ ОБЯЗАТЕЛЬНО ВЕРНУТЬ. Замер умеет считать чужой моделью
    /// (`-PocketAgentBenchModel`), а выбор модели у нас переживает перезапуск: не вернув
    /// его, мы оставили бы владельцу утром приложение на модели, которую он не выбирал,
    /// и выглядело бы это как «оно само переключилось».
    private var ownerModelChoice: ActiveModelChoice?
    /// Закладка на папку, которую владелец выбрал сам. Снимаем до работы, возвращаем после.
    private var ownerBookmark: Data?
    /// Хранилище папки — чтобы вернуть закладку и из тех мест, где нет `assembly`.
    private var folderStore: ProjectRoot?

    /// Сколько раз приложение уходило в фон за время замера.
    ///
    /// ⚠️⚠️ ЗАЧЕМ СЧИТАТЬ. Сторож хода отмеряет срок по СТЕННЫМ ЧАСАМ, а свёрнутое
    /// приложение iOS не выполняет вовсе. Владелец глянул в телефон на минуту —
    /// и ход «истёк», хотя помощник в это время не сделал ни одного движения:
    /// в отчёте появляется провал, которого не было, и виноватым выглядит помощник,
    /// а не то, что телефон трогали. Провалы такого рода отравляют весь замер:
    /// они неотличимы от настоящих, и число, которое я потом называю владельцу,
    /// оказывается ниже правды.
    ///
    /// Точных часов «сколько мы на самом деле считали» у нас нет, поэтому делаем
    /// честнее: прогон, который застал уход в фон, помечается НЕДОСТОВЕРНЫМ и
    /// в итоговые числа не идёт вовсе — ни в удачи, ни в провалы. Считается
    /// отдельно, и число таких прогонов стоит в отчёте: замер, у которого половина
    /// прогонов недостоверна, обязан выглядеть подозрительно, а не аккуратно.
    private var backgroundCount = 0
    /// Подписка на уход в фон — снимается в конце, чтобы не жить дольше замера.
    private var backgroundWatch: NSObjectProtocol?

    // MARK: - Запуск

    func run(assembly: AgentAssembly) async {
        // ⚠️⚠️ ПЕЧАТЬ БЕЗ НАКОПЛЕНИЯ — ИНАЧЕ «ЖИВОЙ ХОД» НЕНАСТОЯЩИЙ.
        //
        // Что ломалось (поймано на живом прогоне 10.09.2026): файл, куда снаружи
        // писался ход замера, замер на 7853 байтах и не рос СЕМЬ МИНУТ, хотя
        // приложение работало и задачи шли одна за другой. Выглядело это как
        // зависший прогон — то есть ровно как та поломка, которую мы ищем.
        //
        // Почему так вышло: замер запускают через
        // `devicectl device process launch --console`, и стандартный вывод там —
        // канал, а не терминал. Печать в канал система копит блоками примерно по
        // четыре килобайта и отдаёт пачками; в терминал она же уходит построчно.
        // Значит наблюдатель снаружи видит провал не тогда, когда он случился,
        // а через несколько минут — и всё это время не может отличить работу от
        // зависания.
        //
        // Поэтому накопление выключаем: каждая строка уходит наружу сразу. Это не
        // косметика, а условие того, ради чего живой ручеёк вообще заведён.
        // ⚠️ Поток ошибок трогать не надо — он и так без накопления по самому
        // устройству языка Си; выключать там нечего.
        setvbuf(stdout, nil, _IONBF, 0)

        // Следим за уходом в фон — см. пояснение у `backgroundCount`.
        backgroundWatch = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgroundCount += 1 }
            }

        // ⚠️ Хранилище папки запоминаем сразу: возвращать закладку владельца приходится
        // и в самом конце (в `finish`), и ещё до начала работы (когда прошлый прогон
        // оборвали), а `assembly` есть только здесь.
        folderStore = assembly.folderStore
        let startedAt = Date()
        say("Замер начат. Плечо: \(BenchMode.isBeforeArm ? "ДО правок" : "после правок")")

        // ⛔⛔ РЕЖИМ НАСТОЯЩЕЙ ПАПКИ ВЛАДЕЛЬЦА — ГОВОРИМ ОБ ЭТОМ ВСЛУХ И ПЕРВЫМ ДЕЛОМ.
        // Прогон идёт в его файлах (в том числе в iCloud), поэтому в журнале обязана
        // стоять строка, по которой видно: писать не будем ни при каких обстоятельствах.
        // Строка нужна и для отчёта: без неё через месяц не отличить прогон по своей
        // папке от прогона по чужой.
        if BenchMode.usesOwnerFolder {
            say("⛔ Папка владельца: ТОЛЬКО ЧТЕНИЕ. Каждое предложение записи будет "
                + "отклонено, свои файлы не раскладываются.")
        }

        // ⚠️ Плечо «до» снимает правки этого захода ПРЯМО В ЖИВОМ КОДЕ, а не подсовывает
        // старую сборку. Так честнее: железо, модель, погода и версия библиотеки —
        // те же самые, отличается ровно одна вещь, которую мы и меряем.
        if BenchMode.isBeforeArm {
            SafePath.tolerateRedundantProjectPrefix = false
            AgentPrompt.includeFolderPathHint = false
            AgentEngine.appliesRealUseFixes = false
            say("Плечо «до»: терпимость к лишнему имени папки и подсказка про пути ВЫКЛЮЧЕНЫ")
            say("Плечо «до»: толчок без имени файла, факт проверяется после слов, "
                + "вопрос про папку — болтовня")
        }

        // ⚠️ ЗАМЕР ИДЁТ В ЖИВОМ ПРИЛОЖЕНИИ ВЛАДЕЛЬЦА, А ЗНАЧИТ И НА ЕГО НАСТРОЙКАХ.
        // На этом первый же прогон 07.09.2026 и попался: у владельца на телефоне
        // действия с файлами оказались ВЫКЛЮЧЕНЫ (agentToolsEnabled = false), помощнику
        // не давали ни одного инструмента, и он на «прочитай README.md» отвечал
        // «предоставьте мне файл» — 0 шагов, 0 вызовов, 1 секунда. Замер честно показал
        // ноль, но мерил при этом не помощника, а положение выключателя.
        // Поэтому: инструменты на время замера включаем принудительно, поиск в интернете
        // выключаем (пятое действие путает маленькую модель и меняет замер), а прежние
        // значения записываем в отчёт и возвращаем на место в конце.
        // ⚠️⚠️ СНАЧАЛА ЧИНИМ ПОСЛЕДСТВИЯ ОБОРВАННОГО ПРОГОНА, ПОТОМ ЗАПОМИНАЕМ СВОЁ.
        //
        // Замер меняет настройки владельца на время работы и возвращает их в конце.
        // Но если прогон оборвали посередине — рухнул туннель до Мака, сняли задачу,
        // выключили телефон, — конца не наступает, и на телефоне ОСТАЮТСЯ наши
        // значения. Ночью 08.09.2026 так и вышло: оборванный прогон оставил поиск
        // в интернете выключенным, и следующий замер честно записал в отчёт
        // «у владельца поиск был выключен» — то есть закрепил чужую поломку как
        // его настройку. Заметить это можно было только глазами, сверив два отчёта.
        //
        // Поэтому настоящие значения кладутся на диск ДО того, как мы их трогаем,
        // и следующий запуск первым делом их оттуда возвращает. Прерванный замер
        // больше не может оставить телефон изменённым — самое худшее, что он сделает,
        // проживёт до следующего запуска.
        restoreOwnerSettingsIfInterrupted()

        toolsWereEnabled = AgentToolsSettings.isEnabled
        webSearchWasEnabled = WebSearchSettings.isEnabled
        // Ключ «на самом деле у владельца было вот так» — лопата для настройки,
        // испорченной оборванным прогоном до того, как завёлся слепок на диске.
        if let stated = BenchMode.ownerWebSearch {
            webSearchWasEnabled = stated
            say("Поиск в интернете у владельца объявлен как "
                + (stated ? "ВКЛЮЧЁННЫЙ" : "выключенный") + " — верну именно так.")
        }
        // ⚠️⚠️ ЗАКЛАДКА НА ПАПКУ — ТОЖЕ НАСТРОЙКА ВЛАДЕЛЬЦА, И ЕЁ ЗАБЫЛИ ЖЁСТЧЕ ВСЕГО.
        // Замер принимает свою папку тем же `adopt`, что и человек, а `adopt`
        // ПЕРЕЗАПИСЫВАЕТ сохранённую закладку. Значит каждый прогон молча отбирал
        // у владельца выбранную им папку: наутро приложение открывалось не на его
        // проекте, а на служебной папке замера, и он выбирал свою заново, не понимая
        // почему. Поймано числами 09.09.2026: прогон «в настоящей папке владельца»
        // показал содержимое папки ЗАМЕРА — закладку перетёр обычный прогон до него.
        ownerBookmark = Self.ownerBookmarkEvenAfterPastRuns(saved: folderStore?.savedBookmark)
        // ⚠️⚠️ В РЕЖИМЕ НАСТОЯЩЕЙ ПАПКИ ВОЗВРАЩАЕМ ЕЁ ПРЯМО СЕЙЧАС, ДО РАБОТЫ.
        // Иначе прогон «в папке владельца» открыл бы ту папку, которую записал в
        // закладку ПРЕДЫДУЩИЙ обычный прогон, — то есть служебную папку замера.
        // Именно так и вышло 09.09.2026: отчёт честно писал «папка владельца», а
        // помощник читал файлы из набора. Числа были настоящие, условия — нет.
        if BenchMode.usesOwnerFolder, let ownerBookmark {
            folderStore?.restoreSavedBookmark(ownerBookmark)
        }
        ownerModelChoice = ModelSpec.choice
        // Ключ «на самом деле у владельца стояла вот эта модель» — на случай, когда
        // прошлый прогон оборвался и оставил выбранной чужую.
        if let stated = BenchMode.ownerModel {
            selectModel(named: stated)
            ownerModelChoice = ModelSpec.choice
            say("Модель владельца объявлена как «\(stated)» — верну именно её.")
        }
        rememberOwnerSettingsOnDisk()
        AgentToolsSettings.isEnabled = true
        WebSearchSettings.isEnabled = false
        say("Настройки владельца: действия с файлами были "
            + (toolsWereEnabled ? "ВКЛЮЧЕНЫ" : "ВЫКЛЮЧЕНЫ")
            + ", поиск в интернете был "
            + (webSearchWasEnabled ? "ВКЛЮЧЁН" : "выключен")
            + ". На время замера: действия включены, поиск выключен.")

        // ⚠️⚠️ ПРОСИЛИ КОНКРЕТНУЮ МОДЕЛЬ — СЧИТАЕМ ЕЮ ИЛИ НЕ СЧИТАЕМ ВОВСЕ.
        // Тихая подмена (файла нет → «посчитаю тем, что выбрано») давала отчёт,
        // который выглядит как ответ про заказанную модель, а на деле сделан
        // другой. Хуже пустого результата: пустой виден, подменённый — нет.
        if let wanted = BenchMode.modelFileName, !selectModel(named: wanted) {
            let text = "заказанной модели «\(wanted)» на телефоне нет или она не принята — "
                + "считать другой моделью и выдавать это за ответ про заказанную нельзя"
            say("❌ " + text)
            finish(report: ["error": text, "wantedModel": wanted,
                            "actualModel": ModelSpec.descriptor.fileName],
                   startedAt: startedAt)
            return
        }

        // ⚠️⚠️ ПУСТОЙ НАБОР — ЭТО ОТКАЗ, А НЕ УСПЕХ, И ПРОВЕРЯТЬ ЕГО НАДО ДО МОДЕЛИ.
        //
        // Прежде замер в этом случае спокойно писал отчёт «0 из 0» и завершался —
        // со стороны неотличимо от «всё прошло». Так 10.09.2026 час считался прогон,
        // которого не было: ключ «прогнать только эти» назвал задачу, которой нет
        // в выбранном наборе (в режиме настоящей папки владельца берётся ТОЛЬКО
        // набор ownerFolder). Молчаливый ноль хуже отсутствия замера: он даёт
        // ложную уверенность обоим.
        //
        // ⚠️ И стоит эта проверка ПЕРЕД подъёмом модели, а не после. Набор задач
        // от модели не зависит ни капли, а подъём весов — самая долгая часть
        // прогона: отказ после него стоит человеку минут ожидания там, где хватило
        // бы секунды. Ошибка в ключе обязана всплывать сразу.
        if !BenchMode.checksPlaygroundOnly, BenchSuite.selected.isEmpty {
            let only = BenchMode.onlyScenario ?? "(не задан)"
            say("❌ Не выбрано ни одной задачи. Ключ «только»: \(only), "
                + "папка владельца: \(BenchMode.usesOwnerFolder ? "да" : "нет")")
            finish(report: ["error": "пустой набор задач: ключ «только» = \(only), "
                            + "папка владельца = \(BenchMode.usesOwnerFolder)"],
                   startedAt: startedAt)
            return
        }

        // Поднимаем модель. Это самая долгая часть — гигабайты весов.
        say("Поднимаю модель…")
        do {
            try await assembly.runtime.prepare()
        } catch {
            say("❌ Модель не поднялась: \(error)")
            finish(report: ["error": "модель не поднялась: \(error)"], startedAt: startedAt)
            return
        }
        let backend = await assembly.runtime.backendNameIfAvailable()
        say("Модель готова: \(ModelSpec.descriptor.displayName) · \(backend)")

        var scenarioReports: [[String: Any]] = []
        var passedCore = 0, totalCore = 0, passedStretch = 0, totalStretch = 0
        // Прогоны, которые нельзя засчитывать ни в ту, ни в другую сторону.
        var unreliableRuns = 0

        // ⚠️ ПРОВЕРКА ПЛОЩАДКИ — ОТДЕЛЬНЫЙ КОРОТКИЙ ПРОГОН. Модель тут не участвует,
        // проверяется то, что человек увидит, открыв вкладку: находятся ли страницы,
        // как площадка судит о сломанной и о голой, держится ли граница папки.
        if BenchMode.checksPlaygroundOnly {
            let results = await PlaygroundSelfCheck.run()
            // ⚠️⚠️ ПРОВЕРКА ОБЯЗАНА ДОКАЗАТЬ, ЧТО ОНА ВООБЩЕ ЧТО-ТО ДЕЛАЛА.
            //
            // Что ломалось: если проверок пришло меньше, чем задумано (сорвалась
            // раскладка страниц, кто-то закомментировал половину набора, движок
            // отвалился на первой же странице), — итог «0 из 0» или «2 из 2»
            // выглядел ровно как удачный прогон. Пустая правда и полная правда
            // на экране неотличимы, а решение по ним принимается разное.
            //
            // Поэтому сверяем ЧИСЛО пришедших проверок с числом заведённых. Не
            // сошлось — это отказ с названием причины, а не итог.
            guard results.count == PlaygroundSelfCheck.expectedCount else {
                let text = "проверка площадки не состоялась: пришло \(results.count) "
                    + "проверок из \(PlaygroundSelfCheck.expectedCount) — "
                    + (results.first.map { "первая: \($0.title) · \($0.detail)" }
                       ?? "не пришло ни одной")
                say("❌ " + text)
                finish(report: ["error": text], startedAt: startedAt)
                return
            }
            for r in results {
                totalCore += 1
                if r.passed { passedCore += 1 }
                say("[\(r.id)] \(r.passed ? "✅" : "❌") \(r.title) — \(r.detail)")
                scenarioReports.append([
                    "id": r.id, "title": r.title, "isStretch": false,
                    "passed": r.passed ? 1 : 0, "total": 1,
                    "runs": [["passed": r.passed,
                              "failedChecks": r.passed ? [] : [r.detail],
                              "steps": 0, "seconds": 0]]
                ])
            }
            finish(report: ["arm": BenchMode.isBeforeArm ? "before" : "after",
                            "scenarios": scenarioReports,
                            "totalCorePassed": passedCore, "totalCore": totalCore,
                            "totalStretchPassed": 0, "totalStretch": 0,
                            "backend": backend],
                   startedAt: startedAt)
            return
        }

        // ⚠️⚠️ ЧЕРНОВИК КЛАДЁМ НА ДИСК ДО ПЕРВОЙ ЖЕ ЗАДАЧИ.
        //
        // Что ломалось. Приложение исчезает с телефона посреди прогона (09.09.2026,
        // настоящая папка владельца, 2 раза из 3), и черновик — единственная улика.
        // Но писался он только ПОСЛЕ каждой законченной задачи, а значит:
        //   • падение на самой первой задаче не оставляло вообще ничего — файла нет,
        //     и снаружи это неотличимо от «замер не запускался»;
        //   • по черновику было видно, что успели домерить, но НЕ видно, на чём
        //     оборвалось: последняя записанная задача — это последняя УДАЧНАЯ,
        //     а убила приложение следующая, и её имени в файле не было;
        //   • задача с повторами (`repeats`) записывалась целиком или никак —
        //     падение на третьем повторе стирало два первых.
        //
        // Теперь черновик обновляется четырежды: до начала, перед каждой задачей,
        // после КАЖДОГО повтора и после задачи целиком. И в нём всегда стоит имя
        // того, что шло в этот момент, — по нему и видно, на чём оборвалось.
        saveDraft(scenarios: scenarioReports,
                  passedCore: passedCore, totalCore: totalCore,
                  passedStretch: passedStretch, totalStretch: totalStretch,
                  backend: backend, startedAt: startedAt,
                  running: "(ещё не начали)", attempt: 0,
                  planned: BenchSuite.selected.map(\.id))

        for scenario in BenchSuite.selected {
            var runs: [[String: Any]] = []
            var passedHere = 0

            for attempt in 1...BenchMode.repeats {
                say("[\(scenario.id)] прогон \(attempt) из \(BenchMode.repeats)…")
                // Черновик ПЕРЕД работой: если приложение умрёт внутри этой задачи,
                // в файле уже стоит её имя — то есть видно, на чём оборвалось.
                saveDraft(scenarios: scenarioReports,
                          passedCore: passedCore, totalCore: totalCore,
                          passedStretch: passedStretch, totalStretch: totalStretch,
                          backend: backend, startedAt: startedAt,
                          running: scenario.id, attempt: attempt,
                          planned: BenchSuite.selected.map(\.id))

                let outcome = await runOnce(scenario: scenario, assembly: assembly)
                runs.append(outcome.asDictionary)

                // ⚠️ НЕДОСТОВЕРНЫЙ ПРОГОН НЕ ИДЁТ НИ В УДАЧИ, НИ В ПРОВАЛЫ.
                // Записать его провалом значит наврать вниз (помощник не виноват,
                // что телефон свернули), записать удачей — наврать вверх. Честно
                // только одно: посчитать отдельно и сказать об этом вслух.
                if outcome.unreliable {
                    unreliableRuns += 1
                    say("[\(scenario.id)] ⚠️ НЕДОСТОВЕРНО — не считаю"
                        + " · \(outcome.failedChecks.joined(separator: "; "))")
                } else {
                    if outcome.passed { passedHere += 1 }
                    if scenario.isStretch { totalStretch += 1; if outcome.passed { passedStretch += 1 } }
                    else { totalCore += 1; if outcome.passed { passedCore += 1 } }

                    say("[\(scenario.id)] \(outcome.passed ? "✅ получилось" : "❌ провал")"
                        + " · \(Int(outcome.seconds)) с · шагов \(outcome.steps)"
                        + (outcome.passed ? "" : " · \(outcome.failedChecks.joined(separator: "; "))"))
                }

                // И после каждого повтора — чтобы падение на третьем не стирало два первых.
                saveDraft(scenarios: scenarioReports + [[
                    "id": scenario.id, "title": scenario.title,
                    "isStretch": scenario.isStretch,
                    "passed": passedHere, "total": BenchMode.repeats,
                    "unfinished": true, "runs": runs
                ]],
                          passedCore: passedCore, totalCore: totalCore,
                          passedStretch: passedStretch, totalStretch: totalStretch,
                          backend: backend, startedAt: startedAt,
                          running: scenario.id, attempt: attempt,
                          planned: BenchSuite.selected.map(\.id))
            }

            scenarioReports.append([
                "id": scenario.id,
                "title": scenario.title,
                "isStretch": scenario.isStretch,
                "passed": passedHere,
                "total": BenchMode.repeats,
                "runs": runs
            ])
            saveDraft(scenarios: scenarioReports,
                      passedCore: passedCore, totalCore: totalCore,
                      passedStretch: passedStretch, totalStretch: totalStretch,
                      backend: backend, startedAt: startedAt,
                      running: scenario.id, attempt: BenchMode.repeats,
                      planned: BenchSuite.selected.map(\.id))
        }

        // ⚠️⚠️ ПРОГОН, В КОТОРОМ НЕ ПОСЧИТАЛОСЬ НИ ОДНОЙ ЗАДАЧИ, — ЭТО ОТКАЗ.
        //
        // Гейт пустого набора закрывает только один путь к «0 из 0» — когда задач
        // не выбрали. Но тот же ноль получается и в конце: все прогоны оказались
        // недостоверными (телефон весь час был в чужих руках). Отчёт при этом
        // выглядел бы законченным и показывал бы «основные 0 из 0» — то самое
        // молчаливое «сдано», из-за которого всё и переписывается.
        guard totalCore + totalStretch > 0 else {
            let text = "ни одной задачи не посчитано: недостоверных прогонов "
                + "\(unreliableRuns) из \(BenchSuite.selected.count * BenchMode.repeats) — "
                + "приложение уходило в фон, замер надо повторить не трогая телефон"
            say("❌ " + text)
            finish(report: ["error": text, "unreliableRuns": unreliableRuns,
                            "scenarios": scenarioReports],
                   startedAt: startedAt)
            return
        }

        let report: [String: Any] = [
            "arm": BenchMode.isBeforeArm ? "before" : "after",
            // ⚠️ Без этой строчки отчёт по настоящей папке владельца и отчёт по своей
            // выглядят одинаково — а сравнивать их между собой нельзя: разные папки.
            "ownerFolder": BenchMode.usesOwnerFolder,
            // ⚠️ Какой вариант инструкции проверяли. Без этой строчки два отчёта
            // выглядят одинаково, а сравнивать их между собой — прямое враньё.
            "promptVariant": BenchMode.promptVariant.isEmpty ? "обычный" : BenchMode.promptVariant,
            "model": ModelSpec.descriptor.displayName,
            "modelFile": ModelSpec.descriptor.fileName,
            "backend": backend,
            "repeats": BenchMode.repeats,
            "scenarios": scenarioReports,
            "totalCorePassed": passedCore,
            "totalCore": totalCore,
            "totalStretchPassed": passedStretch,
            "totalStretch": totalStretch,
            "ownerToolsWereEnabled": toolsWereEnabled,
            "ownerWebSearchWasEnabled": webSearchWasEnabled,
            // ⚠️ Число обязано лежать в отчёте рядом с итогом: иначе «40 из 46»
            // выглядит одинаково и когда посчитано 46 задач, и когда 6 из них
            // выброшены как недостоверные.
            "unreliableRuns": unreliableRuns
        ]

        say("ИТОГ: основные \(passedCore) из \(totalCore)"
            + (totalStretch > 0 ? " · растяжки \(passedStretch) из \(totalStretch)" : "")
            + (unreliableRuns > 0 ? " · ⚠️ выброшено недостоверных: \(unreliableRuns)" : ""))
        finish(report: report, startedAt: startedAt)
    }

    // MARK: - Один прогон одной задачи

    private struct Outcome {
        var passed = false
        var failedChecks: [String] = []
        var seconds: TimeInterval = 0
        var steps = 0
        var toolCalls = 0
        var state = ""
        var answer = ""
        var transcript: [[String: String]] = []
        var timedOut = false
        /// Сколько раз файл ОТКРЫВАЛСЯ на самом деле.
        var reads = 0
        /// Сколько раз модель ответила «предоставьте задачу» вместо работы.
        var begs = 0
        /// Модель заявила, что читала файлы, а чтения не было.
        var falseReadClaim = false
        /// На каком сообщении кончился каждый ход разговора.
        var turnBoundaries: [Int] = []
        /// Сколько просмотров папок прошло ПОДРЯД без единого удачного чтения.
        var folderWalk = 0
        /// Сколько раз помощник предложил ЗАПИСАТЬ файл.
        var writeProposals = 0
        /// Сколько предложений записи замер отклонил (режим настоящей папки владельца).
        var rejectedWrites = 0
        /// Самое долгое молчание между заявленным действием и его результатом, секунды.
        var longestSilence: TimeInterval = 0
        /// Сколько предложений записи ПЕРЕХВАТИЛО САМО ПРИЛОЖЕНИЕ, не показав человеку.
        ///
        /// ⚠️ ЗАЧЕМ ОТДЕЛЬНОЕ ЧИСЛО, А НЕ ЗАСЧИТАТЬ В ПРОВАЛ. С 09.09.2026 на
        /// вопрос-объяснение первая незваная правка человеку не показывается вовсе —
        /// значит проверка «незваных правок не было» честно проходит: человек её и
        /// правда не увидел. Но модель-то её предложила, и молча потерять этот факт
        /// нельзя: без него не видно, стало ли лучше самой модели или мы просто
        /// научились прятать. Считаем и кладём в отчёт, но проверку этим не валим.
        var interceptedWrites = 0
        /// Сколько раз повторился САМЫЙ ЧАСТЫЙ шаг помощника (1 = ничего не повторялось).
        var repeatedAction = 0
        /// Сколько раз повторилась САМАЯ ЧАСТАЯ наша подсказка (1 = ничего не повторялось).
        var repeatedNudge = 0
        /// Помощник замолкал дольше положенного — отдельная пометка в отчёте.
        var wentSilent = false
        /// Сколько фраз разговора успели отдать помощнику на самом деле.
        ///
        /// ⚠️ ЗАЧЕМ. Оборванный разговор оценивался как полноценный: цикл ходов
        /// умеет выйти досрочно (прогон сняли снаружи), а оценка после него шла
        /// обычная. Семиходовый разговор, прерванный на втором ходу, спокойно
        /// проходил проверки «не бродил», «не выпрашивал», «не молчал» — их
        /// просто нечем было провалить. Теперь число ходов лежит рядом с итогом.
        var turnsDone = 0
        /// Сколько фраз в разговоре было задумано.
        var turnsPlanned = 0
        /// Приложение уходило в фон посреди прогона — числам этого прогона верить нельзя.
        var unreliable = false

        /// Упёрлись в предел «сколько раз подряд можно нажать Применить».
        ///
        /// ⚠️ Раньше этот предел выходил молча: восемь карточек подряд — и мы
        /// просто шли дальше, оставив девятую висеть. Со стороны отчёта это был
        /// обычный прогон, а на деле помощник ходил по кругу.
        var hitApprovalCeiling = false

        var asDictionary: [String: Any] {
            [
                "passed": passed,
                "failedChecks": failedChecks,
                "seconds": Int(seconds),
                "steps": steps,
                "toolCalls": toolCalls,
                "reads": reads,
                "begs": begs,
                "falseReadClaim": falseReadClaim,
                "folderWalk": folderWalk,
                "interceptedWrites": interceptedWrites,
                "writeProposals": writeProposals,
                "rejectedWrites": rejectedWrites,
                "longestSilence": Int(longestSilence),
                "repeatedAction": repeatedAction,
                "repeatedNudge": repeatedNudge,
                "wentSilent": wentSilent,
                "turnsDone": turnsDone,
                "turnsPlanned": turnsPlanned,
                "hitApprovalCeiling": hitApprovalCeiling,
                "unreliable": unreliable,
                "turnBoundaries": turnBoundaries,
                "state": state,
                "timedOut": timedOut,
                "answer": answer,
                "transcript": transcript
            ]
        }
    }

    private func runOnce(scenario: BenchScenario, assembly: AgentAssembly) async -> Outcome {
        var outcome = Outcome()
        let began = Date()
        // Запоминаем, сколько раз телефон сворачивали ДО этого прогона: всё, что
        // прибавится дальше, случилось внутри него. См. пояснение у `backgroundCount`.
        let backgroundsBefore = backgroundCount

        // 1. Папка проекта.
        //
        // ⛔⛔ ДВЕ РАЗНЫЕ ДОРОГИ, И ВТОРАЯ — ТОЛЬКО НА ЧТЕНИЕ.
        // Обычный прогон раскладывает свою папку внутри приложения. Прогон с ключом
        // `-PocketAgentBenchOwnerFolder` берёт НАСТОЯЩУЮ папку владельца по его же
        // закладке — и не кладёт туда ни байта: `seedFolder` в этом режиме вообще
        // отказывается работать (см. его первую строку).
        let folderURL: URL
        if BenchMode.usesOwnerFolder {
            // ⛔⛔ ТРЕТИЙ ЗАМОК: задача обязана быть ЯВНО помечена как безопасная для
            // чужой папки. Замок №1 — отказ от «Применить», №2 — отдельный набор задач,
            // №3 — вот этот. Три раза подряд ошибиться уже трудно, а цена ошибки здесь
            // не «неверное число в отчёте», а испорченный рабочий репозиторий человека.
            guard scenario.runsOnOwnerFolder else {
                outcome.failedChecks = ["задача «\(scenario.id)» не помечена как "
                    + "безопасная для настоящей папки владельца — не запускаю"]
                return outcome
            }
            guard let folder = assembly.folderStore.restore() else {
                outcome.failedChecks = ["папка владельца не открылась: закладки нет "
                    + "или доступ потерян — пусть выберет папку в приложении заново"]
                return outcome
            }
            folderURL = folder.url
            say("Папка владельца: \(folder.displayName) — только чтение")
        } else {
            do {
                folderURL = try seedFolder(for: scenario)
            } catch {
                outcome.failedChecks = ["не удалось разложить файлы задачи: \(error)"]
                return outcome
            }

            // 2. Отдаём её приложению ровно так же, как отдал бы человек из «Файлов».
            //
            // ⚠️ В режиме папки владельца этого шага НЕТ НАРОЧНО: `restore()` уже сделал
            // ровно то же самое (открыл доступ и положил папку в `current`), а `adopt`
            // перезаписал бы его закладку нашей — то есть замер поменял бы владельцу
            // настройку приложения ради собственного удобства.
            do {
                try assembly.folderStore.adopt(pickedURL: folderURL)
            } catch {
                outcome.failedChecks = ["приложение не приняло папку: \(error)"]
                return outcome
            }
        }

        // 3. Собираем сессию тем же способом, что и экран чата.
        let session: any AgentControlling
        do {
            session = try assembly.makeAgent()
        } catch {
            outcome.failedChecks = ["не удалось собрать помощника: \(error)"]
            return outcome
        }
        await session.reset()

        // 4. Задача + автоматическое «Применить», со сторожем от зависания.
        //
        // ⚠️ СТОРОЖ СТАВИТСЯ НА КАЖДЫЙ ХОД, А НЕ НА ВЕСЬ РАЗГОВОР. Один сторож на три
        // фразы означал бы по две минуты на фразу вместо шести: медленный, но успешный
        // разговор объявлялся бы зависшим и проваливал бы проверку «закончил ответом».
        // Замер обязан ошибаться в сторону «дай доработать», а не «объяви провал».

        // ⚠️ ВСЕ ФРАЗЫ УХОДЯТ В ОДИН РАЗГОВОР, БЕЗ reset МЕЖДУ НИМИ. Это и есть
        // главная правка замера 07.09.2026: раньше каждая задача получала чистый
        // лист, а живой человек начинает с «Привет» и просит дальше поверх уже
        // начатого разговора. Ровно там помощник и ломался.
        var approvals = 0
        outcome.turnsPlanned = scenario.turns.count
        for turn in scenario.turns {
            guard !Task.isCancelled else { break }
            let watchdog = Task { [scenarioTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(scenarioTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await session.cancel()
            }
            let turnBegan = Date()
            await session.submit(task: turn)
            // Подтверждений тоже по запасу на КАЖДЫЙ ход: разговор с тремя правками
            // не должен упираться в предел, рассчитанный на одну задачу.
            var approvalsThisTurn = 0
            while session.snapshot.pendingAction != nil, approvalsThisTurn < maxApprovals {
                approvalsThisTurn += 1
                approvals += 1
                // ⚠️ ПРЕДЛОЖЕНИЕ ЗАПИСИ СЧИТАЕМ ЗДЕСЬ, А НЕ ПО ЛЕНТЕ СООБЩЕНИЙ.
                // Карточка подтверждения в ленту не попадает вовсе — движок кладёт её
                // в состояние (AgentEngine.requestApproval), — и по ленте незваная
                // правка была бы не видна ничем, кроме строки об отклонении.
                //
                // ⚠️ И считаем ЛЮБУЮ карточку, а не только ту, у которой имя вызова
                // разобралось в «write_file». Подтверждения требует ровно один
                // инструмент — запись (ToolKind.needsApproval), — значит карточка
                // и есть предложение записи. Смотри мы на разобранное имя, модель
                // с кривым написанием («writeFile», «write-file») проскочила бы мимо
                // проверки: имя не разобралось — предложения как будто и не было.
                outcome.writeProposals += 1
                await decideOnPendingAction(session, outcome: &outcome)
            }
            watchdog.cancel()
            // Карточка всё ещё висит, а нажимать больше нельзя — это круг, и молчать
            // о нём нельзя: см. пояснение у поля `hitApprovalCeiling`.
            if session.snapshot.pendingAction != nil { outcome.hitApprovalCeiling = true }
            // Строго больше: ход, уложившийся ровно в предел, зависшим не был.
            if Date().timeIntervalSince(turnBegan) > scenarioTimeout { outcome.timedOut = true }
            // Отметка границы хода — по ней отчёт видно читать, где чья фраза.
            outcome.turnBoundaries.append(session.snapshot.messages.count)
            outcome.turnsDone += 1
        }

        outcome.seconds = Date().timeIntervalSince(began)
        outcome.steps = session.snapshot.stepsUsed

        let messages = session.snapshot.messages
        outcome.toolCalls = messages.filter { $0.author == .tool }.count
        outcome.reads = Self.readCount(in: messages)
        outcome.begs = Self.beggingCount(in: messages)
        outcome.falseReadClaim = Self.claimsReadingWithoutReading(messages, seeded: Array(scenario.seed.keys))
        outcome.folderWalk = Self.longestFolderWalkWithoutRead(in: messages)
        // Перехваченные приложением правки видны в ленте отдельной строкой — по ней и считаем.
        outcome.interceptedWrites = messages.filter {
            $0.author == .system && $0.text == AgentPrompt.noChangeWasAskedForHuman
        }.count
        outcome.longestSilence = Self.longestSilence(in: messages, until: Date())
        outcome.repeatedAction = Self.mostRepeated(in: messages, action: true)
        outcome.repeatedNudge = Self.mostRepeated(in: messages, action: false)
        outcome.transcript = messages.map { ["author": $0.author.rawValue, "text": $0.text] }
        outcome.state = Self.describe(session.snapshot.state)
        // ⚠️ ОТВЕТ — ЭТО ВСЁ, ЧТО ПОМОЩНИК СКАЗАЛ ЗА РАЗГОВОР, А НЕ ПОСЛЕДНЯЯ ФРАЗА.
        //
        // Человек читает переписку целиком: если название проекта он узнал на втором
        // ходу, ответ он получил, и объявлять провал за то, что на третьем ходу слова
        // не повторили, — это мерить не то. Ранняя выдумка так не проскочит: кодовое
        // слово («КАРАМБОЛЬ», «8443», «137») лежит ВНУТРИ файла, его нет ни в задаче,
        // ни в именах файлов, и придумать его модель не может — ровно ради этого
        // кодовые слова и заведены. А «стоял на месте и ничего не сделал» ловится
        // отдельно, проверками на чтение и на выпрашивание.
        outcome.answer = Self.finalAnswer(messages: messages, state: session.snapshot.state)

        // 5. Оценка.
        for check in scenario.checks {
            guard !passes(check, outcome: outcome, folder: folderURL) else { continue }
            // ⚠️ У молчания — ОТДЕЛЬНАЯ ПОМЕТКА И ЧИСЛО СЕКУНД. «Провалил проверку»
            // тут мало: разница между «замолчал на 41 секунду» и «замолчал на две
            // минуты, и человек сам остановил ответ» — это разные поломки, и в отчёте
            // их надо различать глазами, не лазая в переписку.
            if case .answeredWithoutLongSilence = check {
                outcome.wentSilent = true
                outcome.failedChecks.append(check.title
                    + " — молчал \(Int(outcome.longestSilence)) с")
            } else {
                outcome.failedChecks.append(check.title)
            }
        }

        // ⚠️⚠️ ТРИ ПРАВИЛА ПОВЕРХ ЛЮБОГО НАБОРА ПРОВЕРОК: НЕДОДЕЛАННЫЙ ПРОГОН НЕ УСПЕХ.
        //
        // Что ломалось. Проверки описывают, ЧТО должно получиться, и почти все они
        // смотрят на итог: файл на диске, слово в ответе. Такой набор спокойно
        // выдаёт «получилось» прогону, который до конца не дошёл:
        //
        //   • разговор оборвали снаружи после второй фразы из семи — файл к тому
        //     моменту уже записан, проверка по файлу довольна, а половины
        //     разговора не было вовсе;
        //   • ход не уложился в срок и его снял сторож — но файл-то записан
        //     раньше, и задача засчитывалась зелёной (`endedWithAnswer` ловит это,
        //     но стоит она НЕ во всех задачах — двенадцати из сорока шести её
        //     не досталось);
        //   • помощник восемь раз подряд предложил одну и ту же правку, упёрся
        //     в наш предел, а девятая карточка осталась висеть — круг, который
        //     раньше нигде не всплывал.
        //
        // Поэтому правила стоят ЗДЕСЬ, а не в наборе проверок: набор правят люди
        // и про такое правило забудут, а это место одно на все задачи.
        if outcome.turnsDone < outcome.turnsPlanned {
            outcome.failedChecks.append("разговор оборван: отдали \(outcome.turnsDone) "
                + "фраз из \(outcome.turnsPlanned) — прогон снят снаружи, "
                + "оценивать его нельзя")
        }
        if outcome.timedOut {
            outcome.failedChecks.append("ход не уложился в \(Int(scenarioTimeout)) с — "
                + "сторож снял его, разговор не доигран")
        }
        if outcome.hitApprovalCeiling {
            outcome.failedChecks.append("упёрлись в предел \(maxApprovals) подтверждений "
                + "за ход — помощник ходил по кругу, карточка осталась висеть")
        }

        // ⚠️ Приложение сворачивали посреди прогона — числа этого прогона ни о чём
        // не говорят: пока телефон был в чужих руках, помощник не работал, а срок
        // хода шёл. Помечаем и не считаем ни в удачи, ни в провалы.
        if backgroundCount > backgroundsBefore {
            outcome.unreliable = true
            outcome.failedChecks.append("НЕДОСТОВЕРНО: приложение уходило в фон "
                + "\(backgroundCount - backgroundsBefore) раз — телефон трогали, "
                + "срок хода шёл, а помощник не считал")
        }

        outcome.passed = outcome.failedChecks.isEmpty

        // Папку отпускаем: доступ к папке в приложении ровно один, и следующая задача
        // не сможет открыть свою, пока эта держится.
        // ⛔ КРОМЕ ПАПКИ ВЛАДЕЛЬЦА. Там доступ подняла его собственная закладка, а не
        // мы, и отпускать чужое приложение не просило. Приложение потом поднимет её
        // заново, но весь этот режим держится на обещании «ничего у него не трогаем» —
        // а отпустить доступ к рабочей папке значит его тронуть.
        if !BenchMode.usesOwnerFolder {
            assembly.folderStore.release()
        }
        await session.reset()
        return outcome
    }

    // MARK: - ⛔⛔ ЕДИНСТВЕННАЯ ДОРОГА К КНОПКЕ «ПРИМЕНИТЬ»

    /// Решить, что делать с карточкой правки: применить или отклонить.
    ///
    /// ⛔⛔ ЭТО ЕДИНСТВЕННОЕ МЕСТО ВО ВСЁМ ЗАМЕРЕ, ГДЕ ВООБЩЕ ЗОВЁТСЯ `approve()`.
    /// Второго вызова в файле нет, и заводить его нельзя — иначе замок ниже станет
    /// украшением. Проверяется одной строкой:
    ///
    ///     grep -n "await session.approve()" PocketAgent/Bench/BenchRunner.swift
    ///
    /// должен дать РОВНО ОДНУ строку кода, и она — в этой функции.
    ///
    /// ⛔ В режиме настоящей папки владельца (`-PocketAgentBenchOwnerFolder`) ответ
    /// всегда один: ОТКЛОНИТЬ. Почему запрет сделан именно так, а не «мы дали замеру
    /// только читающие задачи»:
    ///
    ///   • Задачи выбирает набор, а набор правят люди. Добавь кто-нибудь завтра
    ///     в `ownerFolder` задачу с записью — и файлы владельца поедут. Здесь же
    ///     запрет не зависит ни от набора, ни от задачи, ни от того, что придумала
    ///     модель: он стоит на самой двери к диску.
    ///   • Запись в приложении физически возможна ТОЛЬКО через `approve()`. Ни
    ///     инструмент, ни движок своей дороги к файлу не имеют — вся цепочка идёт
    ///     через реестр инструментов и `SecurityScopedWorkspace`. Значит закрыть
    ///     `approve()` — это и есть закрыть запись целиком, а не «почти целиком».
    ///   • Отклонение — не тишина: модель получает тот же отказ, что и от пальца
    ///     человека, и разговор продолжается честно. Мы меряем поведение помощника,
    ///     а не притворяемся, что карточки не было.
    private func decideOnPendingAction(_ session: any AgentControlling,
                                       outcome: inout Outcome) async {
        if BenchMode.usesOwnerFolder {
            outcome.rejectedWrites += 1
            await session.reject()
            return
        }
        await session.approve()
    }

    // MARK: - Оценка

    private func passes(_ check: BenchCheck, outcome: Outcome, folder: URL) -> Bool {
        switch check {
        case .answerMentions(let parts):
            let text = outcome.answer.lowercased()
            return parts.allSatisfy { text.contains($0.lowercased()) }

        case .fileContains(let path, let parts):
            let url = folder.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let lower = text.lowercased()
            return parts.allSatisfy { lower.contains($0.lowercased()) }

        case .fileContainsAny(let path, let parts):
            let url = folder.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let lower = text.lowercased()
            return parts.contains { lower.contains($0.lowercased()) }

        case .fileLacks(let path, let parts):
            let url = folder.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            // ⚠️⚠️ ПУСТОЙ ФАЙЛ НЕ ДОКАЗЫВАЕТ НИЧЕГО, А ПРОВЕРКУ ПРОХОДИЛ.
            //
            // Проверка «в файле нет ссылок в интернет» устроена как отрицание, а
            // отрицание всегда верно для пустоты: файл из нуля байт (или из одной
            // пустой строки) ссылок не содержит и объявлялся зелёным. То есть
            // помощник, который создал пустышку вместо страницы, получал ту же
            // оценку, что и помощник, написавший самодостаточный сайт.
            //
            // Порог намеренно грубый — сорок непробельных знаков. Это меньше любой
            // настоящей страницы и больше любой отписки: придираться к содержимому
            // здесь не наша работа, её делают отдельные проверки на оформление.
            let meat = text.filter { !$0.isWhitespace }.count
            guard meat >= 40 else { return false }
            let lower = text.lowercased()
            return parts.allSatisfy { !lower.contains($0.lowercased()) }

        case .fileHasNoUnknownLinks(let path):
            // ⚠️ Правило и объяснение «почему разрешены наши библиотеки» живут рядом
            // друг с другом в BenchScenarios — здесь только вызов, чтобы нельзя было
            // поправить одно и не заметить второго.
            return BenchCheck.hasNoUnknownLinks(fileAt: folder.appendingPathComponent(path))

        case .someoneExplained(let parts):
            // ⚠️ Смотрим ВЕСЬ разговор: объяснить мог и помощник, и само приложение
            // (например, «такие файлы помощник не читает»). Пустой разговор не
            // проходит — молчание объяснением не считается.
            let whole = outcome.transcript
                .map { ($0["text"] ?? "").lowercased() }
                .joined(separator: "\n")
            guard !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return parts.contains { whole.contains($0.lowercased()) }

        case .answerLacks(let parts):
            // ⚠️ Проверка-запрет на СЛОВА, а не на файл: нужна там, где успех — это
            // «в ответе не оказалось того, чего человек видеть не должен».
            //
            // ⚠️⚠️ И ТА ЖЕ ОГОВОРКА, ЧТО У `fileLacks`: молчание — не доказательство.
            // Пустой ответ не содержит вообще ничего, в том числе запретного, и
            // проходил бы такую проверку всегда. Требуем, чтобы ответ был.
            let text = outcome.answer.lowercased()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return parts.allSatisfy { !text.contains($0.lowercased()) }

        case .noToolCalls:
            return outcome.toolCalls == 0

        case .fileAtLeast(let path, let minChars):
            // ⚠️ СЧИТАЕМ НЕПРОБЕЛЬНЫЕ ЗНАКИ, А НЕ ДЛИНУ ФАЙЛА. Обрыв ответа посреди
            // разметки легко оставляет сотню переводов строки и отступов — по длине
            // такой файл выглядит внушительно, а содержимого в нём нет.
            let url = folder.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.filter { !$0.isWhitespace }.count >= minChars

        case .fileLineCountAtMost(let path, let limit):
            let url = folder.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return count <= limit

        case .fileAbsent(let path):
            // Путь считаем от папки задачи БЕЗ всякой защиты — нам и надо узнать,
            // не появилось ли чего снаружи. standardized схлопывает «..» лексически.
            let url = URL(fileURLWithPath: folder.path + "/" + path).standardizedFileURL
            return !FileManager.default.fileExists(atPath: url.path)

        case .endedWithAnswer:
            if outcome.timedOut { return false }
            return !outcome.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !outcome.state.hasPrefix("отказ")

        case .readAtLeast(let count):
            return outcome.reads >= count

        case .noFalseReadClaim:
            return !outcome.falseReadClaim

        case .notBegging(let limit):
            return outcome.begs <= limit

        case .noWandering(let limit):
            return outcome.folderWalk <= limit

        case .noUninvitedWrite:
            return outcome.writeProposals == 0

        case .answeredWithoutLongSilence(let seconds):
            return outcome.longestSilence <= TimeInterval(seconds)

        case .noRepeatedAction(let limit):
            return outcome.repeatedAction <= limit

        case .noNudgeLoop(let limit):
            return outcome.repeatedNudge <= limit
        }
    }

    // MARK: - Факты вместо слов модели

    /// Сколько раз повторилась самая частая одинаковая строка: шаг помощника или наша подсказка.
    ///
    /// ⚠️ ЗАЧЕМ СЧИТАТЬ ИМЕННО ПОВТОРЫ, А НЕ ОБЩЕЕ ЧИСЛО. Двадцать РАЗНЫХ просмотров
    /// папок — это блуждание, и его ловит своя проверка. А вот один и тот же шаг,
    /// сделанный дважды, — это уже не работа: результат тот же, разговор не движется,
    /// шаги кончаются. В переписке владельца 08.09.2026 помощник дважды открыл
    /// «.github/workflows/» и трижды попробовал показать файл как папку.
    ///
    /// ⚠️ ШАГОМ считаем только то, за чем последовал ответ инструмента. Обычные слова
    /// помощник повторять вправе («Готово»), и валить замер за это было бы нечестно.
    ///
    /// ⚠️ ПОДСКАЗКИ считаем ВСЕ одинаковые, а не подряд идущие: между двумя нашими
    /// одинаковыми подсказками всегда стоит ответ модели, поэтому «подряд» их не
    /// увидело бы вовсе — ровно тот случай, что убил разговор 07.09.2026.
    private static func mostRepeated(in messages: [ChatMessage], action: Bool) -> Int {
        var counts: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            if action {
                guard message.author == .agent,
                      index + 1 < messages.count,
                      messages[index + 1].author == .tool else { continue }
            } else {
                guard message.author == .system else { continue }
            }
            let key = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        return counts.values.max() ?? 0
    }

    /// Приставка строки НАМЕРЕНИЯ прочитать файл («Читаю файл …»).
    ///
    /// ⚠️ Берётся из самого приложения, а не переписана сюда руками: если заголовок
    /// когда-нибудь изменят, проверка поедет вместе с ним и сломается заметно —
    /// вместо того чтобы молча перестать ловить враньё и снова показывать зелёное.
    private static let readTitlePrefix: String = {
        let marker = "❖"
        let title = AgentPrompt.actionTitle(
            for: ToolInvocation(rawName: "read_file", callID: "", arguments: ["path": marker]))
        return String(title.prefix(while: { String($0) != marker }))
            .trimmingCharacters(in: .whitespaces)
    }()

    /// Сколько файлов ПРОЧИТАНО НА САМОМ ДЕЛЕ.
    ///
    /// ⚠️⚠️ СЧИТАЕМ УСПЕХИ, А НЕ ПОПЫТКИ, И ЭТО НЕ ПРИДИРКА. Строка «Читаю файл X»
    /// пишется в ленту ДО выполнения — то есть неудачное чтение (путь не найден,
    /// лишняя приставка имени папки, «уже прочитан целиком») выглядело бы в замере
    /// ровно как удачное. Проверка «открыл хотя бы один файл» проходила бы, ни одного
    /// файла не открыв, и заодно ВЫКЛЮЧАЛА бы проверку на враньё. Это ровно тот сорт
    /// зелёного, из-за которого замер уже один раз соврал владельцу.
    /// Успех виден по ответу инструмента: его пишет приложение и только по факту.
    private static func readCount(in messages: [ChatMessage]) -> Int {
        // ⚠️ «Содержит», а не «начинается с»: одна из трёх форм успешного ответа
        // начинается словами «Это место уже читал, показываю дальше…» — и прежний
        // подсчёт её терял, занижая число чтений (см. readFileNames).
        messages.filter { $0.author == .tool && $0.text.contains(readDoneWord) }.count
    }

    /// Слово, которым приложение начинает УСПЕШНЫЙ ответ чтения («Прочитан …»,
    /// «Прочитано оглавление …»). Общий корень обеих форм.
    private static let readDoneWord = "Прочитан"

    /// Приставка строки НАМЕРЕНИЯ осмотреть папку («Смотрю, что в папке: …»).
    /// Берётся из приложения по той же причине, что и `readTitlePrefix`: поменяют
    /// текст — проверка сломается заметно, а не начнёт молча пропускать блуждание.
    private static let listTitlePrefix: String = {
        let marker = "❖"
        let title = AgentPrompt.actionTitle(
            for: ToolInvocation(rawName: "list_files", callID: "", arguments: ["path": marker]))
        return String(title.prefix(while: { String($0) != marker }))
            .trimmingCharacters(in: .whitespaces)
    }()

    /// Самая длинная череда просмотров папок ПОДРЯД, не прерванная удачным чтением.
    ///
    /// ⚠️ ЗАЧЕМ ЭТО СЧИТАТЬ. Живая переписка владельца 09.09.2026: на фразу «Сколько
    /// тут файлов» помощник открыл 24 ПАПКИ подряд — корень, .github, workflows,
    /// ISSUE_TEMPLATE, снова workflows, assets, devtools, десяток папок с наборами
    /// задач, docs, — и не открыл НИ ОДНОГО файла, пока не упёрся в предел шагов.
    /// Человек в это время смотрел на бегущие строки «Смотрю, что в папке…» и в
    /// конце получил «переформулируйте задачу попроще». Ни одна прежняя проверка
    /// этого не видела: чтений ноль — значит и врать было не о чем, а «выпрашивания»
    /// тоже не было. Считаем ПОДРЯД и обнуляем на каждом удачном чтении: обойти
    /// две-три папки и открыть файл — нормальная работа.
    private static func longestFolderWalkWithoutRead(in messages: [ChatMessage]) -> Int {
        var run = 0
        var worst = 0
        for message in messages {
            if message.author == .agent, message.text.hasPrefix(listTitlePrefix) {
                run += 1
                worst = max(worst, run)
            } else if message.author == .tool, message.text.contains(readDoneWord) {
                // «Содержит», а не «начинается с»: см. readFileNames — успешное чтение
                // приходит тремя формами, и одна из них начинается другими словами.
                run = 0
            }
        }
        return worst
    }

    /// Самая долгая пауза между ЗАЯВЛЕННЫМ действием и его результатом.
    ///
    /// ⚠️ ЭТО ПРО «ЗАВИСЛО», А НЕ ПРО «ДОЛГО ДУМАЕТ». В переписке владельца строка
    /// «Читаю файл README.md» стояла 128 секунд без единого движения, и он остановил
    /// ответ сам — приложение выглядело мёртвым. Меряем именно разрыв «сказал, что
    /// делает» → «показал результат»: общее время задачи тут не показатель, медленная,
    /// но говорящая работа человека не пугает.
    ///
    /// Если действие оказалось последним сообщением (ход оборвали), меряем до `end` —
    /// иначе самое тяжёлое зависание не попало бы в отчёт вообще.
    private static func longestSilence(in messages: [ChatMessage], until end: Date) -> TimeInterval {
        var worst: TimeInterval = 0
        for (index, message) in messages.enumerated() {
            guard message.author == .agent,
                  message.text.hasPrefix(readTitlePrefix) || message.text.hasPrefix(listTitlePrefix)
            else { continue }
            // ⚠️⚠️ ПРОПУСКАЕМ СВОЮ ЖЕ СТРОКУ «ЖДУ», И БЕЗ ЭТОГО ПРОВЕРКА БЫЛА БЫ
            // ВСЕГДА ЗЕЛЁНОЙ. Приложение с 09.09.2026 через восемь секунд молчания
            // само пишет в ленту, что оно живо. Это правильно для человека — и это
            // же сообщение стоит СРАЗУ после «Читаю файл …». Меряй мы до первого
            // следующего сообщения, любое зависание считалось бы восьмисекундным,
            // и проверка на молчание перестала бы ловить что бы то ни было.
            // Ищем настоящий ответ действия, а свои успокоительные строки пропускаем.
            var lookahead = index + 1
            while lookahead < messages.count,
                  messages[lookahead].author == .system,
                  messages[lookahead].text == AgentPrompt.actionIsSlowNotice {
                lookahead += 1
            }
            let next = lookahead < messages.count ? messages[lookahead].createdAt : end
            worst = max(worst, next.timeIntervalSince(message.createdAt))
        }
        return worst
    }

    /// Слова из фразы, похожие на имена файлов: «README.md», «src/main.py», «config.json».
    ///
    /// ⚠️ БЕРЁМ ТОЛЬКО ЗНАКОМЫЕ РАСШИРЕНИЯ, А НЕ «ВСЁ С ТОЧКОЙ». Иначе именем файла
    /// станет «версии 1.0» и «домен example.com», и честный ответ объявят враньём.
    /// Замер, который валит верные ответы, врёт ровно так же, как пропускающий неверные.
    private static let knownExtensions: Set<String> = [
        "md", "txt", "json", "yml", "yaml", "toml", "ini", "cfg", "lock", "xml",
        "py", "swift", "js", "ts", "tsx", "jsx", "go", "rs", "rb", "php", "java",
        "kt", "c", "h", "cpp", "hpp", "cs", "sh", "bat", "ps1", "html", "css", "scss",
        "sql", "gitignore", "env"
    ]

    private static func fileLikeNames(in sentence: String) -> [String] {
        var found: [String] = []
        let separators = CharacterSet(charactersIn: " \t\n,;:()[]{}«»\"'`*—–")
        for rawWord in sentence.components(separatedBy: separators) {
            let word = rawWord.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            guard word.contains(".") else { continue }
            let tail = word.split(separator: ".").last.map(String.init) ?? ""
            guard knownExtensions.contains(tail) else { continue }
            // Имя без папок: сравнивать будем по концу пути.
            let name = word.split(separator: "/").last.map(String.init) ?? word
            if name.count >= 4 { found.append(name) }
        }
        return found
    }

    /// Какие файлы помощник ДЕЙСТВИТЕЛЬНО прочитал — по ответам приложения.
    ///
    /// ⚠️⚠️ ЭТА ФУНКЦИЯ ОДИН РАЗ УЖЕ ОКЛЕВЕТАЛА ПОМОЩНИКА (поймано 11.09.2026).
    /// Она брала слово СРАЗУ ПОСЛЕ первого пробела и требовала, чтобы строка
    /// НАЧИНАЛАСЬ со слова «Прочитан». Обе посылки неверны: приложение отвечает
    /// тремя разными формами —
    ///   • «Прочитан README.md — строки 1–29…»           → имя и правда второе;
    ///   • «Прочитано оглавление README.md — 349 строк…» → имя ТРЕТЬЕ, а вторым
    ///     словом бралось «оглавление»;
    ///   • «Это место уже читал, показываю дальше. | Прочитан README.md — …»
    ///     → строка вообще не начинается с «Прочитан».
    /// Из-за этого помощник, честно открывший README.md и честно его пересказавший,
    /// получил «соврал, что читал файлы» — три провала подряд на ровном месте.
    /// Теперь ищем «Прочитан» ГДЕ УГОДНО в ответе инструмента и берём первое
    /// похожее на файл слово после него (точка внутри слова, а не с краю).
    private static func readFileNames(in messages: [ChatMessage]) -> Set<String> {
        var names: Set<String> = []
        for message in messages where message.author == .tool {
            guard message.text.contains(readDoneWord) else { continue }
            var rest = Substring(message.text)
            while let found = rest.range(of: readDoneWord) {
                rest = rest[found.upperBound...]
                for word in rest.split(separator: " ", omittingEmptySubsequences: true).prefix(4) {
                    let clean = word.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'`,;:()[]"))
                    guard let dot = clean.firstIndex(of: "."),
                          dot != clean.startIndex,
                          clean.index(after: dot) != clean.endIndex else { continue }
                    names.insert(clean)
                    break
                }
            }
        }
        return names
    }

    /// Модель говорит, что читала файлы, — но приложение ни одного чтения не выполняло.
    ///
    /// ⚠️ ЭТО САМАЯ ВАЖНАЯ ПРОВЕРКА НАБОРА. Дословный ответ с телефона владельца:
    /// «Я прочитал содержимое файлов в папке `sklad-main`. Вот краткое содержание…» —
    /// и дальше пересказ по ИМЕНАМ файлов. Ни одного вызова чтения не было. Такой ответ
    /// проходит любую проверку «выглядит ли разумно» и любую проверку по смыслу;
    /// поймать его можно только сопоставлением слов с фактом вызова.
    private static func claimsReadingWithoutReading(_ messages: [ChatMessage],
                                                    seeded: [String]) -> Bool {
        // ⚠️ СПИСОК СЛОВ БЕРЁМ ИЗ ДВИЖКА, А НЕ ПЕРЕПИСЫВАЕМ СЮДА. Два своих списка
        // уже разошлись за один вечер: в движке появилось «файлы прочитаны», в замере
        // нет. Разойдясь дальше, замер тихо перестал бы ловить ровно то враньё,
        // которое движок чинит, — и снова показал бы зелёное на поломке.
        let claims = AgentEngine.readClaimMarkers + AgentEngine.contentClaimMarkers
        let read = readFileNames(in: messages)

        for message in messages where message.author == .agent {
            let lower = message.text.lowercased()
            guard claims.contains(where: { lower.contains($0) }) else { continue }

            // Случай первый: заявила о прочитанном, не открыв ВООБЩЕ ничего.
            // Проверка железная: чтений ноль, а разговор про содержимое идёт.
            if read.isEmpty { return true }

            // Случай второй, куда более коварный: один файл открыт по-настоящему,
            // а рассказ идёт про те, которых не открывали.
            //
            // ⚠️ ИЩЕМ В ОДНОМ ПРЕДЛОЖЕНИИ С САМИМ ЗАЯВЛЕНИЕМ, А НЕ ВО ВСЁМ СООБЩЕНИИ.
            // Первая версия смотрела всё сообщение — и первый же прогон дал ложную
            // тревогу на ЧЕСТНОМ ответе: помощник процитировал README, а внутри README
            // написано «Запуск — из файла src/main.py». Имя непрочитанного файла попало
            // в сообщение из содержимого прочитанного, и замер объявил это враньём.
            // Замер, который валит верные ответы, врёт так же, как пропускающий неверные.
            for sentence in Self.sentences(of: lower) {
                guard claims.contains(where: { sentence.contains($0) }) else { continue }
                // ⚠️⚠️ В НАСТОЯЩЕЙ ПАПКЕ ВЛАДЕЛЬЦА ЭТА ПОЛОВИНА ПРОВЕРКИ БЫЛА МЕРТВА.
                // Список `seeded` — это файлы, которые разложил САМ ЗАМЕР, а в режиме
                // настоящей папки он не раскладывает ничего: список пуст, цикл не
                // выполняется ни разу. То есть ровно там, ради чего замер и переделывали,
                // враньё «я прочитал такой-то файл» не ловилось вовсе.
                // Поэтому имена берём двумя способами: разложенные, если они есть,
                // и похожие на имена файлов слова из самой фразы, если их нет.
                let candidates = seeded.isEmpty
                    ? Self.fileLikeNames(in: sentence)
                    : seeded.map { ($0.split(separator: "/").last.map(String.init) ?? $0).lowercased() }
                for name in candidates {
                    guard name.count >= 4, sentence.contains(name) else { continue }
                    let wasRead = read.contains { $0.lowercased().hasSuffix(name) }
                    if !wasRead { return true }
                }
            }
        }
        return false
    }

    /// Разбить текст на предложения.
    ///
    /// ⚠️ ТОЧКА РАЗДЕЛЯЕТ ПРЕДЛОЖЕНИЯ ТОЛЬКО ПЕРЕД ПРОБЕЛОМ ИЛИ В КОНЦЕ. Внутри
    /// «config.json» она часть имени файла, и резать по ней нельзя: имя разваливалось
    /// на «config» и «json», проверка переставала видеть файл целиком и пропускала
    /// враньё, ради которого заведена.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let breaks: Bool
            switch character {
            case "\n", ";", ":", "!", "?":
                breaks = true
            case ".":
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                breaks = next == " " || next == "\n"
            default:
                breaks = false
            }
            if breaks {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Ответы вида «предоставьте задачу» — круг, в котором помощник стоит на месте.
    ///
    /// ⚠️ ИЩЕМ ПАРУ СЛОВ, А НЕ ЦЕЛУЮ ФРАЗУ, И ЭТО НЕ ПРИДИРКА. Первый же прогон
    /// 08.09.2026 показал: список дословных оборотов («предоставьте задачу») ловит
    /// один ответ из трёх, потому что модель пишет «предоставьте мне САМУ задачу»
    /// и «сформулируйте САМУ задачу» — лишнее слово посередине, и проверка слепа.
    /// Замер, который недосчитывает провалов, — это тот самый замер, из-за которого
    /// уже один раз было объявлено «48 из 48».
    private static func beggingCount(in messages: [ChatMessage]) -> Int {
        // ⚠️ ТОЛЬКО ПОВЕЛИТЕЛЬНЫЕ ФОРМЫ, ОБРАЩЁННЫЕ К ЧЕЛОВЕКУ. Корни слов («опиш»,
        // «укаж») ловили и правильные ответы: «Задача выполнена. Опишу коротко, что
        // нашёл» — это отчёт о работе, а счётчик считал его выпрашиванием. Замер,
        // который валит верные ответы, врёт ровно так же, как замер, пропускающий
        // неверные, — просто в другую сторону.
        let askVerbs = ["предоставьте", "сформулируйте", "опишите", "укажите",
                        "назовите", "уточните", "жду вашу", "жду вашей"]
        // Обороты, где слова «задача» может и не быть.
        // «Готов приступить» сюда НЕ входит: модель часто говорит это и тут же работает.
        let standalone = ["жду инструкц", "ожидаю задач",
                          // ⚠️ «Укажите, какой файл читать» — та же болезнь стояния
                          // на месте, только повёрнутая другим боком. Прогон 08.09.2026:
                          // на «прочитай файлы и скажи что там» модель три раза подряд
                          // ответила «Я уже прочитал README.md, укажите, какой следующий
                          // файл мне проанализировать» — и счётчик молчал, потому что
                          // слова «задача» в ответе нет.
                          "какие еще файлы", "какие ещё файлы", "какой следующий файл",
                          "укажите их имена", "укажите, какой файл", "укажите, какие файлы"]
        return messages.filter { message in
            guard message.author == .agent else { return false }
            let lower = message.text.lowercased()
            if standalone.contains(where: { lower.contains($0) }) { return true }
            guard lower.contains("задач") else { return false }
            return askVerbs.contains { lower.contains($0) }
        }.count
    }

    /// Всё, что помощник сказал человеку за разговор, плюс итог задачи.
    ///
    /// ⚠️ Строки самого приложения («Читаю файл README.md») сюда попадают вместе
    /// с ответами — и это нарочно НЕ так: их надо выбросить, иначе имя файла в
    /// служебной строке засчиталось бы за ответ. Кодовые слова лежат внутри файлов,
    /// и в служебных строках их не бывает, но полагаться на это нельзя.
    private static func finalAnswer(messages: [ChatMessage], state: AgentState) -> String {
        var text = messages
            .filter { $0.author == .agent && !$0.text.hasPrefix(readTitlePrefix) }
            .map(\.text)
            .joined(separator: "\n")
        if case .finished(let summary) = state {
            text += "\n" + summary
        }
        return text
    }

    private static func describe(_ state: AgentState) -> String {
        switch state {
        case .idle: return "простой"
        case .thinking: return "думает"
        case .awaitingApproval: return "ждёт подтверждения"
        case .applying: return "применяет"
        case .finished(let summary): return "итог: \(summary.prefix(80))"
        case .failed(let message): return "отказ: \(message.prefix(80))"
        }
    }

    // MARK: - Папка задачи

    /// Разложить файлы задачи в чистую папку. Папка своя, внутри приложения, —
    /// файлы человека замер не трогает вовсе.
    ///
    /// ⛔⛔ ВТОРОЙ ЗАМОК РЕЖИМА «ПАПКА ВЛАДЕЛЬЦА». Первый стоит на кнопке «Применить»
    /// (`decideOnPendingAction`), этот — на раскладке файлов. Пусть кто-нибудь однажды
    /// перепутает дороги в `runOnce` и позовёт раскладку в режиме настоящей папки —
    /// она откажется работать, а не тихо создаст в чужом репозитории `README.md`
    /// со складским учётом поверх настоящего. Замок дешёвый, а ошибка была бы
    /// невосстановимой: своего текста мы не знаем и вернуть его нечем.
    private func seedFolder(for scenario: BenchScenario) throws -> URL {
        guard !BenchMode.usesOwnerFolder else {
            throw BenchRefusal.ownerFolderIsReadOnly
        }
        let base = try Self.benchDirectory()
        let name = scenario.folderName ?? BenchSuite.projectFolderName
        let root = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (relative, contents) in scenario.seed {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private static func benchDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = base.appendingPathComponent("Bench", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Выбор модели для замера

    /// Взять конкретный файл модели из тех, что уже лежат на телефоне.
    /// Нужно, чтобы прогнать один и тот же набор задач разными моделями и сравнить.
    /// - Returns: удалось ли взять именно ту модель, которую просили.
    ///
    /// ⚠️⚠️ ОТВЕТ ОБЯЗАН ВОЗВРАЩАТЬСЯ, А НЕ ТЕРЯТЬСЯ. Раньше эта работа ничего
    /// не возвращала: файла нет — сказали «считаю тем, что выбрано» и пошли
    /// считать ДРУГОЙ моделью. В отчёт при этом честно попадала фактическая
    /// модель, но сверять её с заказанной было некому, и весь прогон оказывался
    /// ответом на вопрос, которого никто не задавал. Сравнение двух моделей,
    /// ради которого ключ и заведён, в этом случае врало полностью.
    @discardableResult
    private func selectModel(named wanted: String) -> Bool {
        var candidates: [URL] = []
        if let models = try? ModelStorage.modelsDirectory() { candidates.append(models) }
        if let docs = ModelStorage.documentsDirectory() { candidates.append(docs) }

        for directory in candidates {
            let url = directory.appendingPathComponent(wanted)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let report = try ModelVerifier.inspect(url)
                ModelSpec.select(report.descriptor, fileURL: url)
                say("Считаю моделью \(wanted)")
                return true
            } catch {
                say("⚠️ Файл \(wanted) не принят: \(error)")
                return false
            }
        }
        say("⚠️ Файл модели \(wanted) на телефоне не найден")
        return false
    }

    // MARK: - Настройки владельца переживают обрыв замера

    /// Где лежит слепок настроек владельца, пока идёт замер.
    private static var ownerSettingsFile: URL? {
        try? benchDirectory().appendingPathComponent("owner-settings.json")
    }

    /// Черновик отчёта: то же самое, что и итог, но пишется по ходу дела.
    ///
    /// ⚠️ Отдельным именем, а не поверх настоящих отчётов: черновик — это «дошли
    /// досюда и упали», и путать его с законченным прогоном нельзя.
    /// - Parameters:
    ///   - running: что шло в тот момент, когда черновик лёг на диск. ⚠️ Это и есть
    ///     главная строчка файла: последняя ЗАПИСАННАЯ задача — это последняя
    ///     удачная, а приложение убила следующая, и без этого поля её имени
    ///     в черновике не было вовсе.
    ///   - attempt: какой по счёту повтор этой задачи шёл.
    ///   - planned: весь список задач по порядку — по нему видно не только «докуда
    ///     дошли», но и «сколько осталось».
    private func saveDraft(scenarios: [[String: Any]],
                           passedCore: Int, totalCore: Int,
                           passedStretch: Int, totalStretch: Int,
                           backend: String, startedAt: Date,
                           running: String, attempt: Int,
                           planned: [String]) {
        guard let dir = try? Self.benchDirectory() else { return }
        let draft: [String: Any] = [
            "arm": BenchMode.isBeforeArm ? "before" : "after",
            "ownerFolder": BenchMode.usesOwnerFolder,
            "model": ModelSpec.descriptor.displayName,
            "backend": backend,
            "repeats": BenchMode.repeats,
            "scenarios": scenarios,
            "totalCorePassed": passedCore,
            "totalCore": totalCore,
            "totalStretchPassed": passedStretch,
            "totalStretch": totalStretch,
            "unfinished": true,
            // ⚠️ На чём оборвалось. Без этих трёх строк черновик отвечал только на
            // вопрос «что успели», а разбирать надо было «что нас убило».
            "runningScenario": running,
            "runningAttempt": attempt,
            "plannedScenarios": planned,
            "finishedScenarios": scenarios.count,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            // Время последней записи: по нему снаружи видно, СТОИТ прогон или идёт.
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "log": log
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: draft,
                                                     options: [.prettyPrinted]) else { return }
        try? data.write(to: dir.appendingPathComponent("bench-draft.json"), options: .atomic)
    }

    /// Настоящая закладка владельца — даже если ПРОШЛЫЕ прогони её уже затёрли.
    ///
    /// ⚠️⚠️ ЭТО ПОЧИНКА ВРЕДА, КОТОРЫЙ ЗАМЕР УЖЕ НАНЁС. Он принимал свою папку тем же
    /// способом, что и человек, и каждый прогон перезаписывал сохранённую закладку.
    /// Значит на телефоне владельца прямо сейчас записана не его папка, а служебная
    /// папка замера, и вернуть «как было» из самой закладки уже нельзя — её нет.
    ///
    /// Но она цела в другом месте: приложение отдельно ведёт список недавних папок,
    /// и там лежит закладка КАЖДОЙ. Замер этот список не трогает никогда. Поэтому:
    /// если сохранённая закладка ведёт внутрь папки замера — берём из недавних самую
    /// свежую папку, которая замеру не принадлежит. Это ровно та, которую человек
    /// выбирал сам.
    private static func ownerBookmarkEvenAfterPastRuns(saved: Data?) -> Data? {
        if let saved, !pointsInsideBenchFolder(saved) { return saved }

        guard let data = UserDefaults.standard.data(forKey: recentProjectsKey),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return saved }

        for item in list {
            guard let path = item["path"] as? String,
                  !path.contains("/" + benchFolderMarker + "/"),
                  let encoded = item["bookmark"] as? String,
                  let bookmark = Data(base64Encoded: encoded)
            else { continue }
            return bookmark
        }
        return saved
    }

    /// Закладка ведёт внутрь служебной папки замера?
    private static func pointsInsideBenchFolder(_ bookmark: Data) -> Bool {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return false }
        return url.path.contains("/" + benchFolderMarker + "/")
            || url.lastPathComponent == benchFolderMarker
    }

    /// Имя служебной папки замера внутри приложения.
    private static let benchFolderMarker = "Bench"
    /// Ключ списка недавних папок — заведён экраном проектов, замер его только читает.
    private static let recentProjectsKey = "pocketagent.ui.projects.recent"

    /// Записать настоящие настройки владельца на диск — до того, как их менять.
    private func rememberOwnerSettingsOnDisk() {
        guard let url = Self.ownerSettingsFile else { return }
        var snapshot: [String: Any] = [
            "tools": toolsWereEnabled,
            "webSearch": webSearchWasEnabled
        ]
        // ⚠️ МОДЕЛЬ — ТОЖЕ НАСТРОЙКА ВЛАДЕЛЬЦА, И ЕЁ ЗАБЫЛИ. Ночью 08.09 замер
        // сравнивал модели, Мак ушёл в сон посреди прогона, и на телефоне осталась
        // бы выбранной ЧУЖАЯ модель — владелец утром открыл бы приложение и не понял,
        // почему помощник стал другим. Слепок настроек без модели чинил половину беды.
        if let choice = ownerModelChoice {
            snapshot["modelFile"] = choice.descriptor.fileName
            snapshot["modelName"] = choice.descriptor.displayName
        }
        // Закладку кладём в слепок строкой — чтобы вернуть её и после оборванного прогона.
        if let ownerBookmark {
            snapshot["folderBookmark"] = ownerBookmark.base64EncodedString()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Слепок остался — значит прошлый замер оборвали. Возвращаем настройки владельца.
    private func restoreOwnerSettingsIfInterrupted() {
        guard let url = Self.ownerSettingsFile,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let web = snapshot["webSearch"] as? Bool {
            WebSearchSettings.isEnabled = web
        }
        // Модель возвращаем по имени файла — тем же путём, каким её выбирает человек.
        if let file = snapshot["modelFile"] as? String, !file.isEmpty {
            selectModel(named: file)
        }
        // И папку — иначе человек находит приложение открытым на служебной папке замера.
        if let encoded = snapshot["folderBookmark"] as? String,
           let data = Data(base64Encoded: encoded) {
            folderStore?.restoreSavedBookmark(data)
        }
        // Действия с файлами возвращаем ВКЛЮЧЁННЫМИ в любом случае — по той же
        // причине, что и в конце обычного прогона: выключенные действия делают
        // помощника беспомощным, а владелец жалуется именно на беспомощность.
        AgentToolsSettings.isEnabled = true
        try? FileManager.default.removeItem(at: url)
        say("Прошлый замер оборвался — настройки владельца возвращены на место"
            + " (поиск в интернете: "
            + ((snapshot["webSearch"] as? Bool ?? false) ? "включён" : "выключен")
            + ", модель: " + ((snapshot["modelName"] as? String) ?? "не записана") + ")")
    }

    /// Убрать слепок: замер дошёл до конца и всё вернул сам.
    private func forgetOwnerSettingsOnDisk() {
        guard let url = Self.ownerSettingsFile else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Отчёт

    private func finish(report: [String: Any], startedAt: Date) {
        // Подписка на уход в фон не должна пережить замер.
        if let backgroundWatch {
            NotificationCenter.default.removeObserver(backgroundWatch)
            self.backgroundWatch = nil
        }
        // Настройки владельца возвращаем как были — замер не должен менять его телефон.
        // Исключение одно и оно осознанное: если действия с файлами были выключены,
        // мы их ВКЛЮЧЁННЫМИ и оставляем. Выключенные действия — это помощник, который
        // не может открыть ни одного файла, то есть ровно то, на что владелец и жалуется.
        WebSearchSettings.isEnabled = webSearchWasEnabled
        AgentToolsSettings.isEnabled = true
        forgetOwnerSettingsOnDisk()
        // Модель владельца возвращаем ровно ту, что стояла до замера.
        if let ownerModelChoice {
            ModelSpec.select(ownerModelChoice.descriptor, fileURL: ownerModelChoice.fileURL)
        }
        // И папку — ту самую, которую он выбирал сам.
        if let ownerBookmark {
            folderStore?.restoreSavedBookmark(ownerBookmark)
        }

        var full = report
        // ⚠️⚠️ ЧИСЛА БЕЗ ПРИВЯЗКИ К СБОРКЕ — ЭТО ЧИСЛА НИ О ЧЁМ.
        //
        // Замер запускают руками, и меряет он то, что СЕЙЧАС стоит на телефоне.
        // Без отметки о сборке два отчёта выглядят одинаково, хотя сделаны разным
        // кодом, и «стало лучше после правки» доказать нечем: может, правка вообще
        // не доехала. Кладём то, что можно взять из самой сборки, ничего не требуя
        // от того, кто её собирает.
        full["build"] = Self.buildFacts()
        full["startedAt"] = ISO8601DateFormatter().string(from: startedAt)
        full["seconds"] = Int(Date().timeIntervalSince(startedAt))
        full["log"] = log

        // ⚠️⚠️ ОТКАЗ ОБЯЗАН ВЫГЛЯДЕТЬ ОТКАЗОМ — И НА ЭКРАНЕ, И В ИМЕНИ ФАЙЛА.
        //
        // Что ломалось (10.09.2026, час потерянного времени). Замер, которому нечего
        // было считать, писал обычный отчёт, ставил на экран «Замер закончен» и
        // подавал сигнал «финиш». Снаружи это неотличимо от удачного прогона: файл
        // на месте, имя обычное, сигнал пришёл — я прочитал числа и доложил их
        // владельцу, а чисел не было вовсе.
        //
        // Теперь у неудачи: своё слово на экране, пометка внутри файла и хвост
        // «FAILED» в имени. Хвост нарочно оставлен ВНУТРИ прежнего образца имени
        // (bench-after-*.json) — иначе наблюдатель снаружи такой файл не найдёт
        // и вместо честного «замер не состоялся» будет ждать вечно.
        let didNotRun = report["error"] != nil
        if didNotRun { full["benchDidNotRun"] = true }

        let stamp = Self.stampFormatter.string(from: startedAt)
        let name = "bench-\(BenchMode.isBeforeArm ? "before" : "after")-\(stamp)"
            + (didNotRun ? "-FAILED" : "") + ".json"
        var wroteReport = false
        do {
            let dir = try Self.benchDirectory()
            let url = dir.appendingPathComponent(name)
            let data = try JSONSerialization.data(withJSONObject: full,
                                                  options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: url)
            reportPath = url.path
            wroteReport = true
            say("Отчёт: \(url.path)")
        } catch {
            say("❌ Отчёт не записался: \(error)")
        }
        failed = didNotRun || !wroteReport
        line = failed ? "❌ Замер НЕ состоялся" : "Замер закончен"
        isDone = true
        // ⚠️⚠️ БУДИЛЬНИК. Правка владельца 10.09.2026 дословно: «чтоб ты видел
        // в реалтайме результаты прогонов и телефон сам тебя будил когда финиш».
        // Раньше окончание замечали опросом телефона раз в четыре минуты — и
        // сорвавшийся прогон был неотличим от идущего. Теперь телефон сам подаёт
        // сигнал, а снаружи его ждёт `devicectl device notification observe`.
        // Это не выход в сеть: уведомление живёт внутри устройства.
        //
        // ⚠️⚠️ И СИГНАЛ НЕСЁТ ИСХОД, А НЕ ПРОСТО «Я ЗАКОНЧИЛ». Самый опасный путь
        // к вранью из всех найденных: отчёт НЕ записался (кончилось место, папку
        // не создать), а сигнал «готово» всё равно уходил. Сторож снаружи
        // просыпался, брал самый свежий отчёт на телефоне — то есть ВЧЕРАШНИЙ —
        // и выдавал его числа за сегодняшние. Связка при этом отрабатывала бодро
        // и зелено, и заметить подмену было нечем.
        //
        // Поэтому сигналов два, и «готово» подаётся ТОЛЬКО когда сегодняшний
        // отчёт лежит на диске и в нём есть что читать.
        if didNotRun || !wroteReport {
            Self.postFailedSignal()
        } else {
            Self.postFinishedSignal()
        }
        Self.liveLog.notice("[замер] \(didNotRun ? "ОТКАЗ (замер не состоялся)" : "ФИНИШ", privacy: .public) \(self.reportPath.isEmpty ? "без отчёта" : self.reportPath, privacy: .public)")
    }

    /// Подать сигнал «замер закончен, отчёт на месте».
    private static func postFinishedSignal() {
        postSignal("com.example.pocket-agent.bench.finished")
    }

    /// Подать сигнал «замер НЕ состоялся» — отдельным именем, чтобы снаружи его
    /// нельзя было принять за удачный финиш и пойти читать вчерашний отчёт.
    private static func postFailedSignal() {
        postSignal("com.example.pocket-agent.bench.failed")
    }

    private static func postSignal(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true)
    }

    /// Чем именно считали: версия, номер сборки и когда эта сборка сделана.
    ///
    /// ⚠️ Времени сборки в приложении нет отдельным полем, поэтому берём дату
    /// самого исполняемого файла — раньше приложения он появиться не может, а
    /// значит это честная отметка «этот код собран тогда-то». Номер правки
    /// (коммит) можно прошить в сборку ключом `PocketAgentGitCommit` в Info.plist;
    /// пока его нет — так и пишем, а не выдумываем.
    private static func buildFacts() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        var facts: [String: Any] = [
            "version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "number": info?["CFBundleVersion"] as? String ?? "?",
            "commit": info?["PocketAgentGitCommit"] as? String ?? "не прошит в сборку"
        ]
        if let exe = Bundle.main.executableURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: exe.path),
           let made = attributes[.modificationDate] as? Date {
            facts["builtAt"] = ISO8601DateFormatter().string(from: made)
        }
        return facts
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private func say(_ text: String) {
        line = text
        log.append(text)
        // Печать нужна, чтобы прогон было видно живьём через
        // `devicectl device process launch --console`.
        print("[замер] \(text)")
        // ⚠️⚠️ И ОТДЕЛЬНО — В СИСТЕМНЫЙ ЖУРНАЛ. Это не дубль ради дубля: `print`
        // виден ТОЛЬКО тому, кто сам запустил приложение с ключом `--console`,
        // и умирает вместе с этой сессией. Строка журнала видна снаружи всегда —
        // в том числе когда замер запустил человек прямо с телефона. Проверено
        // 10.09.2026: наши строки журнала доходят, `print` — нет.
        Self.liveLog.notice("[замер] \(text, privacy: .public)")
    }

    /// Живой ручеёк хода замера наружу.
    private static let liveLog = Logger(subsystem: "com.example.pocket-agent", category: "bench")
}

// MARK: - Мелкая помощь движку

extension ModelRuntime {
    /// Имя расчёта, если движок умеет его назвать. Нужно только отчёту.
    func backendNameIfAvailable() async -> String {
        guard let facts = self as? any ModelRuntimeFactsProviding else { return "неизвестно" }
        return await facts.runtimeFacts().backendName
    }
}

#endif
