//
//  PlaygroundView.swift
//  PocketAgent
//
//  Площадка — место, где человек ВИДИТ то, что сделал помощник.
//
//  ⚠️ ЗАЧЕМ ОНА ЕСТЬ (правка владельца 10.09.2026, ROADMAP §18, дословно):
//  «место где можно будет смотреть хтмл всякие которые делает модель, или игры и тд».
//  До неё помощник умел написать игру, а сыграть в неё было негде: человек видел
//  в переписке текст файла и всё. Площадка закрывает круг «попросил → сделал → увидел».
//
//  ⚠️ ГЛАВНОЕ ПОВЕДЕНЧЕСКОЕ РЕШЕНИЕ — СНАЧАЛА ПРОВЕРЯЕМ, ПОТОМ ПОКАЗЫВАЕМ.
//  Владелец дословно: «ваще не показывать плейграунд до того момента пока там не
//  будет ошибок то есть агент сам все починит еще до того как будет показывать
//  пользователю это же гениально». Поэтому нажатие на карточку не открывает страницу
//  сразу: приложение сперва запускает её невидимо, собирает ошибки и, если страница
//  сломана, предлагает починить — а не показывает человеку белый экран.
//
//  ⚠️ И ПОЧЕМУ ПОЧИНКА ВСЁ РАВНО ЧЕРЕЗ ЧЕЛОВЕКА. Ядро продукта — «один шаг, одно
//  подтверждение» (CLAUDE.md): записи файла без явного нажатия быть не может. Значит
//  самопочинка не пишет файл втихую, она отдаёт помощнику текст ошибки как задачу,
//  а правку человек принимает сам — просто он видит уже не поломку, а предложение.
//

import Foundation
import SwiftUI

struct PlaygroundView: View {

    @ObservedObject var app: AppViewModel

    @State private var scan: PlaygroundScan = .empty
    /// ⚠️ ПО УМОЛЧАНИЮ «ИЩУ», А НЕ «ПУСТО». В первый кадр обход ещё не начался,
    /// и прежний флаг `false` рисовал человеку «Пока показывать нечего» — ровно
    /// в тот момент, когда он пришёл сюда потому, что страницу только что сделали.
    @State private var isScanning = true
    /// Проверенные страницы: путь+время изменения → что нашли. Открытая второй раз
    /// страница показывается сразу, без двух секунд ожидания на ровном месте.
    @State private var checked: [String: [PlaygroundIssue]] = [:]
    /// Эту страницу человек уже согласился смотреть со сломанным кодом — не поднимать
    /// над ней ту же полоску сразу же, он про эти ошибки уже прочитал.
    @State private var shownDespiteIssues: String?
    /// Что человек выбрал и что мы сейчас проверяем/показываем.
    @State private var checking: PlaygroundItem?
    @State private var opened: PlaygroundItem?
    @State private var foundIssues: [PlaygroundIssue] = []
    /// Страница проверена и сломана — показываем разбор, а не белый экран.
    @State private var brokenItem: PlaygroundItem?
    @StateObject private var doctor = PlaygroundDoctor()

    /// Наименьшая ширина карточки. Растёт вместе с системным шрифтом — иначе при
    /// крупном шрифте имя файла режется в карточке прежней ширины (правка 11.09.2026).
    /// На самом крупном шрифте сетка честно становится одноколоночной, и это правильно:
    /// лучше одна карточка с целым именем, чем две с огрызками.
    @ScaledMetric(relativeTo: .subheadline) private var cardMinWidth: CGFloat
        = Theme.Metrics.playgroundCardMinWidth

    var body: some View {
        ZStack {
            PlaygroundBackdrop()
            content
        }
        // ⚠️ ОДИН ОБХОД НА ПОЯВЛЕНИЕ, А НЕ ДВА. Раньше сюда же приходил второй
        // `.task` за свежей страницей и запускал СВОЙ обход — в облачной папке
        // владельца это два прохода по шесть секунд подряд до того, как человек
        // хоть что-то увидит. Теперь свежую страницу открывает тот же обход.
        .onDisappear { doctor.stop() }
        .task(id: app.folder?.id) { await rescan() }
        .onChange(of: app.freshPageToShow) { _ in Task { await rescan() } }
        .fullScreenCover(item: $opened) { item in
            PlaygroundStageView(item: item,
                                rootURL: app.folder?.url,
                                onFix: { issues in fix(item: item, issues: issues) },
                                alreadyWarned: shownDespiteIssues == item.relativePath)
        }
        .sheet(item: $brokenItem) { item in
            PlaygroundRepairSheet(item: item,
                                  issues: foundIssues,
                                  onFix: {
                                      brokenItem = nil
                                      fix(item: item, issues: foundIssues)
                                  },
                                  onShowAnyway: {
                                      brokenItem = nil
                                      shownDespiteIssues = item.relativePath
                                      opened = item
                                  })
        }
    }

    // MARK: - Что показываем

    /// ⚠️ ЗАГОЛОВОК СТОИТ НАД ПЕРЕКЛЮЧАТЕЛЕМ, А НЕ ВНУТРИ ОДНОЙ ЕГО ВЕТКИ.
    /// Прежде «Площадка» рисовалась только вместе со списком карточек — а значит
    /// первые до шести секунд, пока идёт обход папки, человек видел кружок и строку
    /// без единого признака, на каком он экране. Название нужно ровно тогда, когда
    /// показывать больше нечего, а не тогда, когда и так всё понятно по карточкам.
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            state
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var state: some View {
        if let path = app.playgroundFixingPath, scan.items.isEmpty {
            // ⚠️ ЭТОЙ ВЕТКОЙ ЭКРАН ЗАКРЫВАЕТСЯ ТОЛЬКО КОГДА ПОКАЗЫВАТЬ БОЛЬШЕ НЕЧЕГО.
            // Раньше она стояла первой и всегда: пока помощник «чинит», человек не мог
            // ни открыть другую страницу, ни увидеть список — экран был занят надписью.
            // Если помощник при этом ничего не переписывал, выйти можно было только
            // перезапуском приложения. Теперь надпись — строка над карточками.
            PlaygroundBusyState(text: Self.fixingText(path))
        } else if app.folder == nil {
            PlaygroundEmptyState(kind: .noFolder) { app.selectTab(.projects) }
        } else if isScanning && scan.items.isEmpty {
            PlaygroundBusyState(text: scanningText)
        } else if scan.items.isEmpty && scan.isPartial {
            // ⚠️ Обход оборвался по сроку, а не папка пуста. Сказать «сделайте
            // страницу» человеку, у которого страница лежит на диске, — враньё.
            // ⚠️ ВТОРОЙ ЗАХОД — С БОЛЬШИМ ТЕРПЕНИЕМ. Повторить тот же обход с тем же
            // сроком значит почти наверняка показать человеку тот же самый экран:
            // папка за эти секунды не уменьшилась. Раз он нажал явно — ждём дольше.
            PlaygroundEmptyState(kind: .didNotFinish) { Task { await rescan(patience: 25) } }
        } else if scan.items.isEmpty {
            PlaygroundEmptyState(kind: .nothingToShow) {
                // ⚠️ Готовая просьба уезжает в поле ввода целиком. С экрана её убрали
                // (там она дублировала эту кнопку), и тем важнее, что кнопка вписывает
                // не пустоту, а рабочий пример: человеку остаётся нажать «отправить»,
                // а не придумывать с нуля, о чём вообще просить помощника.
                app.draft = "Сделай игру крестики-нолики одним файлом game.html"
                app.selectTab(.chat)
            }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                if let path = app.playgroundFixingPath {
                    fixingLine(path)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardMinWidth), spacing: Theme.Metrics.cardPadding)],
                          spacing: Theme.Metrics.cardPadding) {
                    ForEach(Array(scan.items.enumerated()), id: \.element.id) { index, item in
                        PlaygroundCard(item: item,
                                       accent: PlaygroundPalette.accent(for: index),
                                       isBusy: checking?.id == item.id,
                                       // ⚠️ Пока идёт проверка, остальные карточки
                                       // выглядели живыми, а нажатие по ним молча
                                       // ничего не делало. Молчаливый отказ запрещён —
                                       // гасим их видимо.
                                       isBlocked: checking != nil && checking?.id != item.id) {
                            open(item)
                        }
                    }
                }

                if scan.isPartial {
                    // Молчаливая неполнота хуже неполноты названной.
                    Text("Папка большая — показаны первые \(scan.items.count).")
                        .font(Theme.Fonts.caption)
                        // ⚠️ Не `textSecondary`: он для СПЛОШНЫХ подложек и на цветном
                        // фоне проваливается по контрасту (внизу экрана затемнение слабее).
                        // Роль, а не число: см. `textOnColorSecondary` в Theme.swift.
                        .foregroundStyle(Theme.Colors.textOnColorSecondary)
                }
            }
            // Сверху меньше: заголовок уже стоит над списком и свой отступ имеет.
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.top, Theme.Metrics.contentSpacing)
            .padding(.bottom, Theme.Metrics.screenPadding)
            // Воздух после последней карточки. Место под саму панель вкладок
            // резервирует безопасная зона, а не это число.
            .padding(.bottom, Theme.Metrics.sectionSpacing)
        }
        .refreshable { await rescan() }
        .scrollIndicators(.hidden)
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
    }

    /// ⚠️ Без второй строки. Сколько страниц — человек видит по карточкам перед
    /// собой, имя папки живёт на вкладке «Папки». Подпись, повторяющая то, что и так
    /// на экране, — это ровно тот визуальный шум, за который влетало раньше.
    private var header: some View {
        Text("Площадка")
            .font(Theme.Fonts.screenTitle)
            // Заголовок лежит прямо на цветном фоне — отсюда и роль «на цветном».
            .foregroundStyle(Theme.Colors.textOnColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Отступы теперь свои: заголовок вынесен из списка и внешнего
            // `screenPadding` от него больше не получает.
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.top, Theme.Metrics.contentSpacing)
    }

    /// Что показываем, пока помощник переписывает сломанную страницу.
    ///
    /// ⚠️ ОДНА ФРАЗА НА ОБА МЕСТА, И ЭТО НАРОЧНО. Строка над списком и надпись на пустом
    /// экране описывают ровно одно и то же состояние, а говорили о нём по-разному
    /// («Нашёл ошибку в «X» — отдал помощнику, чиню» и «Чиню «X» — как будет готово,
    /// покажу»). Человек видит их в разные секунды одного ожидания и думает, что это
    /// два разных события. Оставлена вторая: она короче и отвечает на единственный
    /// вопрос, который у человека есть, — «и что дальше». Кому именно приложение отдало
    /// работу, ему знать незачем, это наша внутренняя кухня.
    private static func fixingText(_ path: String) -> String {
        "Чиню «\((path as NSString).lastPathComponent)» — как будет готово, покажу."
    }

    /// Что писать, пока идёт обход папки.
    ///
    /// ⚠️ ЖДЁМ КОНКРЕТНУЮ СТРАНИЦУ — ГОВОРИМ ПРО НЕЁ. Человек только что нажал
    /// «Применить» на `game.html` и его увели сюда; строка «смотрю, что есть в папке»
    /// в этот момент читается так, будто про его страницу забыли.
    private var scanningText: String {
        guard let path = app.freshPageToShow else { return "Смотрю, что есть в папке…" }
        return "Открываю «\((path as NSString).lastPathComponent)»…"
    }

    /// Строка «чиню» над карточками. Не заслоняет список: пока помощник правит одну
    /// страницу, человек вправе открыть любую другую.
    ///
    /// ⚠️ ПОДЛОЖКА СПЛОШНАЯ, А НЕ СТЕКЛЯННАЯ. Строка едет вместе со списком, то есть
    /// это ячейка, а не плавающий слой. Стекло на ячейке списка — прямой запрет
    /// (docs/LIQUID-GLASS.md, «анти-паттерны»): и артефакты, и расход батареи, а тут
    /// оно ещё и сэмплило живой цветной фон рядом с работающей моделью. Берём ту же
    /// подложку, что у карточек, — заодно строка встаёт с ними в одну колонку.
    private func fixingLine(_ path: String) -> some View {
        HStack(spacing: Theme.Metrics.contentSpacing) {
            ProgressView().tint(Theme.Colors.textPrimary)
            Text(Self.fixingText(path))
                .font(Theme.Fonts.caption)
                // На сплошной подложке карточки работают обычные роли темы —
                // «на цветном» здесь не про что, фон закрыт наглухо.
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.cardPadding)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner, style: .continuous)
                .fill(Theme.Colors.surface)
        }
    }

    // MARK: - Действия

    /// - Parameter patience: сколько секунд даём обходу. По умолчанию — обычный срок;
    ///   больше просим только тогда, когда человек сам нажал «Искать ещё».
    private func rescan(patience: TimeInterval = 6) async {
        guard let root = app.folder?.url else { scan = .empty; isScanning = false; return }
        isScanning = true
        // Обход трогает диск и докачивает файлы из облака — главному потоку тут делать нечего.
        let found = await Task.detached(priority: .userInitiated) {
            PlaygroundFinder.scan(rawRoot: root, deadline: Date().addingTimeInterval(patience))
        }.value
        scan = found
        isScanning = false
        await openFreshPageIfAny()
    }

    /// Открыть страницу, которую помощник только что записал.
    ///
    /// ⚠️ ЗОВЁТСЯ ИЗ `rescan`, А НЕ СВОИМ `.task`. Прежде у него был отдельный вход,
    /// и он запускал ВТОРОЙ обход — в облачной папке владельца это два прохода по
    /// шесть секунд подряд до того, как человек хоть что-то увидит. А когда второй
    /// вход убрали, вызов потерялся совсем и круг самопочинки перестал замыкаться.
    /// Теперь один обход и одно место, где решается, что открыть.
    private func openFreshPageIfAny() async {
        guard let path = app.freshPageToShow else { return }
        guard let item = matchingItem(path) else {
            // ⚠️ НЕ ЗАБЫВАЕМ МОЛЧА. Файл мог ещё не проявиться в папке (облако,
            // задержка файловой системы). Даём ему секунду и смотрим ещё раз;
            // не нашли и тогда — отпускаем, иначе площадка будет искать вечно.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let root = app.folder?.url
            if let root {
                scan = await Task.detached(priority: .userInitiated) {
                    PlaygroundFinder.scan(rawRoot: root)
                }.value
            }
            guard let retry = matchingItem(path) else { app.dismissFreshPage(); return }
            app.dismissFreshPage()
            open(retry)
            return
        }
        app.dismissFreshPage()
        open(item)
    }

    /// Найти страницу по пути, который назвала модель. Запасной поиск по имени —
    /// потому что модель чаще всего ошибается именно приставкой имени папки.
    private func matchingItem(_ path: String) -> PlaygroundItem? {
        scan.items.first { $0.relativePath == path }
            ?? scan.items.first { $0.name == (path as NSString).lastPathComponent }
    }

    /// Нажали на карточку (или страницу только что записал помощник).
    /// Сперва проверяем невидимо, потом решаем, что делать.
    ///
    /// ⚠️⚠️ СЛОМАННУЮ СТРАНИЦУ ЧИНИМ САМИ, НЕ СПРАШИВАЯ. Правка владельца §18.5
    /// дословно: «чтоб мне не приходилось жать кнопку в самой площадке типа почини».
    /// Поэтому кнопки на пути нет: нашли поломку — отдали помощнику, сказали об этом
    /// словами и увели туда, где человек нажмёт единственное неустранимое «Применить».
    /// Разбор с кнопками остаётся ЗАПАСНЫМ выходом — когда попыток не хватило.
    private func open(_ item: PlaygroundItem) {
        guard let root = app.folder?.url else { return }
        guard checking == nil else { return }
        // ⚠️ ОДНУ И ТУ ЖЕ СТРАНИЦУ ДВАЖДЫ НЕ ПРОВЕРЯЕМ. Проверка стоит около двух
        // секунд, и всё это время сетка погашена: второе нажатие на ту же карточку
        // не имеет права стоить столько же. Ключ — путь ПЛЮС время изменения файла,
        // поэтому переписанная страница проверяется заново (иначе мы показали бы
        // починенную страницу вчерашним приговором).
        let key = checkKey(for: item)
        if let remembered = checked[key] {
            decide(item: item, issues: remembered)
            return
        }
        checking = item
        Task {
            let issues = await doctor.check(fileURL: item.url, rootURL: root)
            checking = nil
            checked[key] = issues
            decide(item: item, issues: issues)
        }
    }

    /// Ключ вердикта: путь плюс время изменения файла.
    ///
    /// ⚠️ ВРЕМЯ БЕРЁМ С ДИСКА, А НЕ ИЗ ОБХОДА. Обход мог пройти пять минут назад,
    /// а помощник переписал файл только что: со старым временем ключ совпал бы,
    /// и починенная страница открылась бы со старым вердиктом «сломана».
    private func checkKey(for item: PlaygroundItem) -> String {
        let stamp = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? item.modifiedAt
        return "\(item.relativePath)#\(stamp.timeIntervalSince1970)"
    }

    /// Что делать с проверенной страницей.
    ///
    /// ⚠️⚠️ ПОРЯДОК ЗДЕСЬ — ГЛАВНОЕ, И ОН ИМЕННО ТАКОЙ.
    /// • НАСТОЯЩАЯ ПОЛОМКА (страница не открылась, ошибка в коде, нет соседнего
    ///   файла) — чиним молча, не спрашивая: правка владельца §18.5 дословно
    ///   «чтоб мне не приходилось жать кнопку в самой площадке типа почини».
    /// • ТОЛЬКО ОФОРМЛЕНИЕ (ссылка в интернет, которой нет у нас на полке) —
    ///   ПОКАЗЫВАЕМ СТРАНИЦУ СРАЗУ. Она открывается и работает, а почему выглядит
    ///   голой — скажет спокойная строка на самой сцене.
    ///
    /// Прежний порядок отдавал помощнику и косметику: человек, нажавший «посмотреть
    /// страницу», дважды уезжал в чат к кнопке «Применить» и видел свою страницу
    /// только после того, как попытки кончались. Это ровно наоборот тому, зачем он
    /// сюда шёл.
    private func decide(item: PlaygroundItem, issues: [PlaygroundIssue]) {
        foundIssues = issues
        guard issues.contains(where: { $0.isBreakage }) else {
            app.notePageWorks(item.relativePath)
            opened = item
            return
        }
        // Раз уж помощник всё равно переписывает файл целиком — скажем ему заодно
        // и про оформление. Второй раз дёргать его из-за этого незачем.
        let forAgent = issues.filter { $0.isWorthFixing }.map(\.lineForAgent)
        if app.canFixPageAutomatically(item.relativePath),
           app.fixPageAutomatically(relativePath: item.relativePath, issues: forAgent) {
            return
        }
        // Попытки кончились ИЛИ помощник ещё не поднялся. Молчаливого отказа тут быть
        // не может: показываем разбор, в котором есть и «Всё равно показать».
        brokenItem = item
    }

    /// Человек сам нажал «Починить» / «Попробовать ещё раз».
    ///
    /// ⚠️ ЗДЕСЬ СЧЁТ ПОПЫТОК НАЧИНАЕТСЯ ЗАНОВО, И ЭТО НАРОЧНО. Потолок в две попытки
    /// защищает от круга, который приложение крутит САМО. А это — прямое решение
    /// человека, принятое после разбора: круга тут быть не может, каждая попытка
    /// стоит ему отдельного нажатия. Прежний комментарий утверждал, что ручная
    /// попытка идёт через тот же счётчик, — это было неправдой: счётчик рос,
    /// но никто его не проверял.
    private func fix(item: PlaygroundItem, issues: [PlaygroundIssue]) {
        opened = nil
        app.notePageWorks(item.relativePath)
        // ⚠️ `tellIfNotReady: true` — потому что это ПРЯМОЕ нажатие человека.
        // Автоматическая попытка при неготовом помощнике молча уступает место
        // разбору, а вот нажатую кнопку проглотить нельзя: молчаливый отказ у нас
        // запрещён, человек должен узнать, почему ничего не произошло.
        app.fixPageAutomatically(relativePath: item.relativePath,
                                 issues: issues.filter { $0.isWorthFixing }.map(\.lineForAgent),
                                 tellIfNotReady: true)
    }
}

// MARK: - Карточка

/// Одна страница в сетке.
///
/// ⚠️ КАРТОЧКА НЕ СТЕКЛЯННАЯ, И ЭТО НЕ НЕДОРАБОТКА. Правило дизайна прямое:
/// стекло только на плавающем слое, на карточках и списках — брак
/// (docs/LIQUID-GLASS.md). Цвет здесь приходит от фона и от цветной обводки,
/// а стекло живёт на кнопках, которые плавают НАД содержимым.
private struct PlaygroundCard: View {

    let item: PlaygroundItem
    let accent: Color
    let isBusy: Bool
    var isBlocked: Bool = false
    let open: () -> Void

    /// Высота плитки со значком. Значок набран ролью `.title2` и растёт сам, а жёсткая
    /// плитка под ним не росла — на крупном системном шрифте карточка оставалась прежней,
    /// и в неё переставало помещаться имя файла. Привязка к той же роли, что и значок.
    @ScaledMetric(relativeTo: .title2) private var tileHeight: CGFloat
        = Theme.Metrics.playgroundTileHeight

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Theme.Metrics.contentSpacing) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Metrics.controlCorner, style: .continuous)
                        .fill(accent.opacity(0.22))
                    if isBusy {
                        ProgressView()
                            .tint(Theme.Colors.textPrimary)
                    } else {
                        Image(systemName: symbolName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }
                .frame(height: tileHeight)

                // ⚠️ ИМЯ ПОКАЗЫВАЕМ ВСЕГДА. Раньше на время проверки оно подменялось
                // словами «Проверяю, работает ли…» — то есть ровно на той карточке,
                // куда человек ткнул, пропадало единственное, что её отличает.
                // Что она занята, уже сказал кружок выше.
                Text(item.name)
                    .font(Theme.Fonts.secondary.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    // Хвост имени значим (`.html`) — режем середину, а не конец.
                    .truncationMode(.middle)

                // Большинство файлов лежит в корне, и подпись «в корне папки»
                // на каждой карточке — одинаковый шум на всей сетке.
                if !item.isAtRoot {
                    Text(item.folderPath)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Metrics.cardPadding)
            .background {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner, style: .continuous)
                    .fill(Theme.Colors.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner, style: .continuous)
                    .stroke(accent.opacity(0.45), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isBlocked)
        .opacity(isBlocked ? 0.6 : 1)
        .accessibilityLabel(Text("Открыть \(item.name)"))
    }

    /// Значок по виду файла.
    ///
    /// ⚠️ РАЗНЫЕ, А НЕ ОДИН НА ВСЕХ. Пока площадка показывала только страницы, значок
    /// угловых скобок был честным. С 11.09.2026 на карточки попадают ещё рисунки,
    /// готовые документы и записки — и документ со значком «код» человек читает как
    /// ошибку приложения. Значок — единственное, чем карточки отличаются, кроме имени;
    /// он обязан говорить правду о том, что откроется.
    private var symbolName: String {
        switch item.url.pathExtension.lowercased() {
        case "svg":            return "photo"
        case "pdf":            return "doc.richtext"
        case "md", "markdown": return "doc.text"
        default:               return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Цвета карточек. Повторяются по кругу — так сетка выглядит живой, но не пёстрой.
enum PlaygroundPalette {

    static let colors: [Color] = [
        Color(red: 0.45, green: 0.42, blue: 1.00),
        Color(red: 0.20, green: 0.72, blue: 1.00),
        Color(red: 0.24, green: 0.86, blue: 0.74),
        Color(red: 1.00, green: 0.55, blue: 0.35),
        Color(red: 1.00, green: 0.78, blue: 0.30),
        Color(red: 0.98, green: 0.44, blue: 0.72)
    ]

    static func accent(for index: Int) -> Color {
        colors[index % colors.count]
    }
}

// MARK: - Пустые состояния

private struct PlaygroundEmptyState: View {

    enum Kind { case noFolder, nothingToShow, didNotFinish }

    let kind: Kind
    let act: () -> Void

    var body: some View {
        VStack(spacing: Theme.Metrics.cardPadding) {
            Image(systemName: iconName)
                .font(Theme.Fonts.emptyStateIcon)
                .foregroundStyle(Theme.Colors.textOnColorSecondary)

            Text(title)
                .font(Theme.Fonts.emptyStateTitle)
                .foregroundStyle(Theme.Colors.textOnColor)
                .multilineTextAlignment(.center)

            if !explanation.isEmpty {
                Text(explanation)
                    .font(Theme.Fonts.secondary)
                // ⚠️ Роль «на цветном», а не 0,62 из `textSecondary`: расчёт контраста
                // и причина этой пары ролей — в Theme.swift рядом с `textOnColorSecondary`.
                // Подложка ниже (0,45 чёрного) фон лишь приглушает, а не отрезает.
                    .foregroundStyle(Theme.Colors.textOnColorSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button(actionTitle, action: act)
                // ⚠️ Размер обязателен: выпуклая стеклянная кнопка берёт высоту по
                // содержимому (~36 точек), а это ниже 44 — минимума, до которого палец
                // не промахивается. В разборе поломки такие же кнопки уже с ним.
                .controlSize(.large)
                .adaptiveGlassButton(prominent: true)
        }
        .padding(Theme.Metrics.sectionSpacing)
        // ⚠️ СПЛОШНАЯ ПОДЛОЖКА ПОД ТЕКСТОМ. Единственное место площадки, где длинный
        // текст лежит прямо на цветном фоне, — и именно тут он тонул.
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner, style: .continuous)
                .fill(.black.opacity(0.45))
        }
        .padding(Theme.Metrics.screenPadding)
    }

    private var iconName: String {
        switch kind {
        case .noFolder:      return "folder.badge.questionmark"
        case .nothingToShow: return "wand.and.stars"
        case .didNotFinish:  return "clock.arrow.circlepath"
        }
    }

    private var title: String {
        switch kind {
        case .noFolder:      return "Папка ещё не выбрана"
        case .nothingToShow: return "Готовых страниц не нашёл"
        case .didNotFinish:  return "Папка большая — дошёл не до конца"
        }
    }

    /// ⚠️ Пустой экран обязан вести дальше, а не просто сообщать о пустоте — но
    /// «вести дальше» это работа КНОПКИ, а не пояснения. Пояснение говорит только,
    /// откуда здесь вообще берутся страницы; готовую просьбу вписывает нажатие.
    private var explanation: String {
        switch kind {
        case .noFolder:
            return "Здесь открываются страницы и игры из вашей папки."
        case .nothingToShow:
            // ⚠️ БЕЗ ГОТОВОЙ ФРАЗЫ В КАВЫЧКАХ. Она слово в слово повторяла то, что
            // кнопка под ней и так вписывает в переписку, — человек читал длинную
            // строку, чтобы узнать ровно то, что сделает одно нажатие. Пояснение
            // говорит, ЧТО тут бывает, а как об этом попросить — берёт на себя кнопка.
            return "Попросите помощника сделать страницу или игру — она появится здесь."
        case .didNotFinish:
            // ⚠️ ПОЯСНЕНИЯ ТУТ НЕТ НАРОЧНО. Оно слово в слово повторяло заголовок
            // («Папка большая — дошёл не до конца»), а два раза об одном — ровно тот
            // лишний текст, за который влетало. Заголовок уже говорит и ЧТО случилось,
            // и почему это не «сделайте страницу»: страница у человека на диске есть,
            // мы просто не досмотрели большую облачную папку за отведённое время.
            return ""
        }
    }

    private var actionTitle: String {
        switch kind {
        case .noFolder:      return "Выбрать папку"
        case .nothingToShow: return "Попросить помощника"
        case .didNotFinish:  return "Искать ещё"
        }
    }
}

private struct PlaygroundBusyState: View {

    let text: String

    var body: some View {
        VStack(spacing: Theme.Metrics.cardPadding) {
            ProgressView().tint(Theme.Colors.textOnColor)
            Text(text)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.Colors.textOnColorSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        // ⚠️ ПОЛЯ И ПОДЛОЖКА — ТО ЖЕ, ЧТО У ПУСТОГО ЭКРАНА РЯДОМ, И ЭТО НЕ КРАСОТА.
        // Строка «Чиню «длинное-имя-страницы.html» — как будет готово, покажу»
        // лежала прямо на цветном пятне и без единого отступа: на узком телефоне она
        // упиралась в оба края экрана, а на янтарном пятне фона белый текст тонул.
        // Соседний пустой экран этот же случай уже закрывает подложкой — держим одинаково.
        .padding(Theme.Metrics.sectionSpacing)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner, style: .continuous)
                .fill(.black.opacity(0.45))
        }
        .padding(Theme.Metrics.screenPadding)
    }
}
