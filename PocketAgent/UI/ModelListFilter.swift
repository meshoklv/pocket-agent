//
//  ModelListFilter.swift
//  PocketAgent
//
//  Порядок и отбор в списках моделей — одной кнопкой (.2,
//  слова владельца: «Сделай сортировку моделей по размеру и фильтры»).
//
//  ⚠️ ГЛАВНОЕ ОГРАНИЧЕНИЕ, ПОД КОТОРОЕ ВСЁ И СДЕЛАНО:
//  ЭКРАН НЕ ЗАСОРЯТЬ. Поэтому управление — ОДНА круглая кнопка в строке, которая
//  на экране уже есть (заголовок раздела на вкладке «Модели», строка поиска
//  на странице находок). Ни одной новой строки, пока человек ничего не выбрал:
//  ни подписей, ни «Фильтры», ни ряда переключателей. Выбрал — и только тогда
//  появляется одна короткая строка «Показаны 3 из 12 · Показать все», и только
//  если отбор ПРАВДА что-то спрятал. Порядок («лёгкие сверху») своей строки
//  не получает вовсе: его видно по самому списку.
//
//  ⚠️ ПУНКТЫ «ФОРМАТ» И «КАК ПОЛУЧИТЬ» ПОКАЗЫВАЮТСЯ, ТОЛЬКО ЕСЛИ В СПИСКЕ ЕСТЬ
//  ИЗ ЧЕГО ВЫБИРАТЬ. Отбор по формату в списке из одних только файлов Google —
//  мёртвый пункт: выбрать можно, а произойти ничего не может. Считается это
//  по ПОЛНОМУ списку, до отбора, — иначе выходит ловушка: человек оставил один
//  формат, остальные пункты исчезли вместе со строками, и вернуть их нечем.
//  «Порядок» и «Вес» стоят всегда: это то, что владелец и заказывал, и оно обязано
//  быть на месте, когда он туда заглянет.
//
//  ⚠️ ПРАВИЛО «ВЛЕЗЕТ ИЛИ НЕТ» ЗДЕСЬ НЕ ЖИВЁТ И НЕ ПОВТОРЯЕТСЯ. Оно одно на всё
//  приложение — `Runtime/ModelFitRule.swift`, — и сюда приходит уже посчитанным:
//  у встроенного списка это `ModelOption.memory`, у находок — `HubFileOption.badge`.
//  Второй расчёт памяти в интерфейсе означал бы, что на двух экранах про одну
//  и ту же модель написано разное.
//
//  Выбор человека переживает перезапуск приложения: он лежит в настройках
//  отдельной записью на каждый список (см. `ModelListFilterStorage`).
//

import SwiftUI

// MARK: - Из чего состоит отбор

/// В каком порядке показывать список.
enum ModelListOrder: String, Codable, Sendable, CaseIterable, Identifiable {

    /// Как список сложен сам: у нас — советуем сверху, у справочника — как он прислал.
    case natural
    /// Лёгкие сверху. Ровно то, что просил владелец.
    case lightestFirst

    var id: String { rawValue }
}

/// Отбор по весу: показывать ли то, что этот телефон, скорее всего, не потянет.
///
/// ⚠️ ДВА СОСТОЯНИЯ, А НЕ ТРИ, И НАЗВАНИЕ ЧЕСТНОЕ. Пункт называется «Кроме тяжёлых
/// для телефона», а не «Только те, что влезут»: приложение прячет то, про что ТОЧНО
/// знает, что памяти мало, — и оставляет модели, память под которые измерить
/// не удалось. Назови мы это «только те, что влезут», в списке остались бы строки
/// без всякого обещания, а обещание в подписи было бы.
enum ModelWeightFilter: String, Codable, Sendable, CaseIterable, Identifiable {

    case any
    case exceptHeavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any:         return "Любой"
        case .exceptHeavy: return "Кроме тяжёлых для телефона"
        }
    }
}

/// Отбор по способу получить модель — прямая просьба владельца: «скачивается отсюда
/// или надо положить файлом». На его снимке экрана половина списка помечена
/// «Скачать её отсюда нельзя».
enum ModelSourceFilter: String, Codable, Sendable, CaseIterable, Identifiable {

    case any
    /// Те, что приложение качает само.
    case downloadable
    /// Те, которые придётся принести файлом.
    case fileOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any:          return "Любой"
        case .downloadable: return "Скачиваются отсюда"
        case .fileOnly:     return "Надо положить файлом"
        }
    }
}

/// Что человек выбрал: порядок плюс три отбора.
struct ModelListFilter: Codable, Equatable, Sendable {

    var order: ModelListOrder = .natural
    var weight: ModelWeightFilter = .any
    /// nil — вид файла не важен.
    var format: ModelFileFormat?
    var source: ModelSourceFilter = .any

    /// Человек ничего не трогал.
    var isDefault: Bool {
        order == .natural && !hidesSomething
    }

    /// Отбор, который убирает строки из списка. Порядок сюда не входит: он ничего
    /// не прячет, и предупреждать о нём нечем.
    var hidesSomething: Bool {
        weight != .any || format != nil || source != .any
    }

    /// Показать всё, оставив выбранный порядок.
    ///
    /// ⚠️ Порядок намеренно НЕ сбрасывается: человек нажимает «Показать все», когда
    /// список оказался короче ожидаемого, — а не затем, чтобы список ещё и перескочил
    /// у него под пальцем в другую последовательность.
    mutating func showEverything() {
        weight = .any
        format = nil
        source = .any
    }
}

// MARK: - Память между запусками

/// Отдельная запись на каждый список: у встроенного и у находок из интернета
/// отбор свой, и смешивать их нельзя — это разные списки с разным содержимым.
enum ModelListFilterStorage: String {
    case installList = "pocketagent.modelFilter.install"
    case hubList = "pocketagent.modelFilter.hub"
}

extension ModelListFilter {

    /// ⚠️ Разбор «мягкий», как и у выбранной модели (`Runtime/ModelSpec.swift`):
    /// запись, сделанную прошлой версией приложения, мы молча заменяем настройками
    /// по умолчанию. Уронить экран из-за старой строчки в настройках — худшее,
    /// что тут можно сделать.
    static func load(_ key: ModelListFilterStorage) -> ModelListFilter {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue),
              let saved = try? JSONDecoder().decode(ModelListFilter.self, from: data) else {
            return ModelListFilter()
        }
        return saved
    }

    func save(_ key: ModelListFilterStorage) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key.rawValue)
    }
}

// MARK: - Вид файла человеческим языком

extension ModelFileFormat {

    /// Подпись в меню. Своя, а не `shortName` из правила годности: там имена такие же,
    /// как на самом Hugging Face («LiteRT-LM»), а здесь человек выбирает глазами и ему
    /// важнее, ЧТО он получит — один файл или папку.
    var pickerTitle: String {
        switch self {
        case .litertlm: return "Файл .litertlm"
        case .mlx:      return "Папка MLX"
        case .gguf:     return "GGUF"
        case .other:    return "Другой вид"
        }
    }

    /// Порядок в меню: сперва то, что приложение запускает сегодня.
    var pickerRank: Int {
        switch self {
        case .litertlm: return 0
        case .mlx:      return 1
        case .gguf:     return 2
        case .other:    return 3
        }
    }
}

// MARK: - Встроенный список (вкладка «Модели»)

extension ModelListFilter {

    /// Вид файла у строки встроенного списка.
    ///
    /// ⚠️ ПАПКА ОПОЗНАЁТСЯ «ОТ ПРОТИВНОГО», И ЭТО НЕ ЛЕНЬ. У модели для движка Apple
    /// имя ни о чём не говорит: «Qwen3-4B-Instruct-2507-4bit» — расширения нет вовсе,
    /// и разбор по имени честно отвечает «другой вид». А в ЭТОМ списке видов ровно два:
    /// файл Google и папка Apple — всё остальное приложение отбраковывает ещё при обходе
    /// папок и показывает отдельным списком «не подошли». Значит «не .litertlm и не GGUF»
    /// здесь означает именно папку Apple.
    static func format(of option: ModelOption) -> ModelFileFormat {
        let byName = ModelFileFormat.detect(fileName: option.fileName)
        return byName == .other ? .mlx : byName
    }

    /// Про эту модель приложение ЗНАЕТ, что памяти телефону не хватит.
    /// Неизвестность тяжестью не считается — см. `ModelWeightFilter`.
    static func isHeavy(_ option: ModelOption) -> Bool {
        switch option.memory {
        case .tight, .tooBig: return true
        case .fits, .unknown: return false
        }
    }

    /// Отобрать и разложить в нужном порядке.
    func apply(to options: [ModelOption]) -> [ModelOption] {
        guard !isDefault else { return options }
        return order.sorted(options.filter { keeps($0) }, weight: { $0.byteSize })
    }

    private func keeps(_ option: ModelOption) -> Bool {
        if weight == .exceptHeavy, Self.isHeavy(option) { return false }
        if let format, Self.format(of: option) != format { return false }
        switch source {
        case .any:          return true
        case .downloadable: return option.canDownload
        case .fileOnly:     return !option.canDownload
        }
    }

    // MARK: Какие пункты меню тут вообще что-то меняют

    /// Виды файлов, которые в этом списке правда встречаются.
    static func formats(in options: [ModelOption]) -> [ModelFileFormat] {
        uniqueFormats(options.map { format(of: $0) })
    }

    /// Способы получить модель, которые в этом списке правда встречаются.
    /// Все строки одинаковы — выбирать не из чего, и пункта в меню не будет.
    static func sourceOptions(in options: [ModelOption]) -> [ModelSourceFilter] {
        let canDownload = options.contains { $0.canDownload }
        let needsFile = options.contains { !$0.canDownload }
        return canDownload && needsFile ? [.any, .downloadable, .fileOnly] : []
    }
}

// MARK: - Находки из интернета (страница поиска)

extension ModelListFilter {

    /// Пометка «может не хватить памяти» — то же самое, что «тяжёлая» у встроенного списка.
    /// Красная («на iPhone не работает вовсе») сюда не входит: это не про вес.
    static func isHeavy(_ file: HubFileOption) -> Bool {
        file.badge == .tight
    }

    /// Отобрать файлы внутри каждой находки, выбросить находки, где не осталось ничего,
    /// и разложить оставшееся в нужном порядке.
    ///
    /// ⚠️ ПОМЕТКА НАХОДКИ ПЕРЕСЧИТЫВАЕТСЯ ПО ОСТАВШИМСЯ ФАЙЛАМ. Она собиралась как
    /// «лучшее, что есть среди файлов»; спрячь отбор именно этот лучший файл — и в шапке
    /// осталось бы зелёное «Должна пойти» над списком, где такого файла уже нет.
    func apply(to repos: [HubRepoOption]) -> [HubRepoOption] {
        // Человек ничего не выбирал — отдаём список как есть, не пересобирая каждую
        // находку заново на каждой перерисовке экрана.
        guard !isDefault else { return repos }
        let filtered: [HubRepoOption] = repos.compactMap { repo in
            let files = order.sorted(repo.files.filter { keeps($0) }, weight: { $0.byteSize })
            guard let best = files.min(by: { Self.badgeRank($0.badge) < Self.badgeRank($1.badge) })
            else { return nil }
            guard hidesSomething else { return repo.replacing(files: files) }
            return repo.replacing(files: files, badge: best.badge, badgeTitle: best.badgeTitle)
        }
        // Находку взвешиваем по САМОМУ ЛЁГКОМУ её файлу: именно его вес и стоит
        // в строке находки, и именно им человек меряет модель на глаз.
        return order.sorted(filtered, weight: { $0.files.map(\.byteSize).min() ?? 0 })
    }

    private func keeps(_ file: HubFileOption) -> Bool {
        if weight == .exceptHeavy, Self.isHeavy(file) { return false }
        if let format, file.format != format { return false }
        switch source {
        case .any:          return true
        case .downloadable: return file.canDownload
        case .fileOnly:     return !file.canDownload
        }
    }

    /// Насколько пометка хороша: чем меньше, тем лучше.
    private static func badgeRank(_ badge: HubFitBadge) -> Int {
        switch badge {
        case .ready:      return 0
        case .tight:      return 1
        case .notYet:     return 2
        case .impossible: return 3
        }
    }

    // MARK: Какие пункты меню тут вообще что-то меняют

    static func formats(in repos: [HubRepoOption]) -> [ModelFileFormat] {
        uniqueFormats(repos.flatMap { $0.files.map(\.format) })
    }

    /// На странице находок «положить файлом» не бывает: тут всё либо качается,
    /// либо не отдаётся сервером (закрытый репозиторий, нет места). Поэтому
    /// предлагаем только «Любой» и «Скачиваются отсюда».
    static func sourceOptions(in repos: [HubRepoOption]) -> [ModelSourceFilter] {
        let blocked = repos.contains { $0.files.contains { !$0.canDownload } }
        return blocked ? [.any, .downloadable] : []
    }

    // MARK: Общее

    private static func uniqueFormats(_ all: [ModelFileFormat]) -> [ModelFileFormat] {
        let unique = Set(all)
        guard unique.count > 1 else { return [] }
        return unique.sorted { $0.pickerRank < $1.pickerRank }
    }
}

extension HubRepoOption {

    /// Та же находка, но с другим набором файлов (и, если надо, с пересчитанной пометкой).
    func replacing(files: [HubFileOption],
                   badge: HubFitBadge? = nil,
                   badgeTitle: String? = nil) -> HubRepoOption {
        HubRepoOption(id: id,
                      name: name,
                      authorText: authorText,
                      statsText: statsText,
                      badge: badge ?? self.badge,
                      badgeTitle: badgeTitle ?? self.badgeTitle,
                      noteText: noteText,
                      files: files,
                      pageURL: pageURL,
                      imageKind: imageKind)
    }
}

// MARK: - Сам порядок

private extension ModelListOrder {

    /// Разложить по весу, если человек так попросил.
    ///
    /// ⚠️ РАВНЫЕ ПО ВЕСУ ОСТАЮТСЯ В ПРЕЖНЕМ ПОРЯДКЕ, и это не придирка: обычная
    /// сортировка в Swift равные элементы переставляет как ей удобно, и список
    /// из одинаковых по весу файлов тасовался бы при каждой перерисовке экрана —
    /// прямо под пальцем человека.
    func sorted<T>(_ items: [T], weight: (T) -> Int64) -> [T] {
        guard self == .lightestFirst else { return items }
        return items.enumerated().sorted { left, right in
            let a = weight(left.element)
            let b = weight(right.element)
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
    }
}

// MARK: - Кнопка отбора

/// Одна круглая кнопка, за которой прячется всё управление списком.
///
/// ⚠️ ПОЧЕМУ МЕНЮ, А НЕ РЯД ПЕРЕКЛЮЧАТЕЛЕЙ. Ряд переключателей — это четыре строки
/// на экране, которые видны всегда, а нужны раз в месяц. Меню занимает место одного
/// значка, открывается у самого пальца и закрывается касанием мимо. Ровно по этой же
/// причине меню выбрано для кнопки «Инструменты» в чате (`UI/ToolsMenu.swift`).
struct ModelListFilterButton: View {

    @Binding var filter: ModelListFilter

    /// Как назвать «обычный» порядок именно в этом списке: у нас — «Как в списке»,
    /// у справочника — «Как в справочнике».
    let naturalOrderTitle: String

    /// Виды файлов, которые в списке правда встречаются. Пусто — пункта не будет.
    let formats: [ModelFileFormat]
    /// Способы получить модель, между которыми есть выбор. Пусто — пункта не будет.
    let sources: [ModelSourceFilter]

    var body: some View {
        Menu {
            Picker("Порядок", selection: $filter.order) {
                Text(naturalOrderTitle).tag(ModelListOrder.natural)
                Text("Лёгкие сверху").tag(ModelListOrder.lightestFirst)
            }

            // ⚠️ ВЕС ПОКАЗЫВАЕМ ВСЕГДА, ДАЖЕ ЕСЛИ ПРЯТАТЬ СЕЙЧАС НЕЧЕГО, — в отличие
            // от двух пунктов ниже. Это то самое, что владелец и просил («влезет /
            // не влезет в этот телефон»), и оно должно быть на месте, когда он туда
            // заглянет. У телефона с большим запасом памяти тяжёлых моделей может
            // не оказаться вовсе — и пункт исчез бы ровно у того человека, который
            // его и заказывал.
            Picker("Вес", selection: $filter.weight) {
                ForEach(ModelWeightFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            if !formats.isEmpty {
                Picker("Формат", selection: $filter.format) {
                    Text("Любой").tag(ModelFileFormat?.none)
                    ForEach(formats, id: \.self) { format in
                        Text(format.pickerTitle).tag(ModelFileFormat?.some(format))
                    }
                }
            }

            if !sources.isEmpty {
                Picker("Как получить", selection: $filter.source) {
                    ForEach(sources) { option in
                        Text(option.title).tag(option)
                    }
                }
            }
        } label: {
            // ⚠️ Значок меняется, а не подпись рядом с ним: пока отбор не выбран,
            // рядом с заголовком раздела не должно быть ни одного лишнего слова.
            Image(systemName: filter.isDefault
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .font(.title3)
                .frame(minWidth: Theme.Metrics.minimumTapTarget,
                       minHeight: Theme.Metrics.minimumTapTarget,
                       alignment: .trailing)
                .contentShape(Rectangle())
        }
        .foregroundStyle(filter.isDefault ? Theme.textSecondary : Theme.Colors.accent)
        .accessibilityLabel("Порядок и отбор")
        .accessibilityValue(accessibilityValue)
    }

    /// Голосом читаем то же, что человек видит по цвету значка.
    private var accessibilityValue: String {
        var parts: [String] = []
        if filter.order == .lightestFirst { parts.append("лёгкие сверху") }
        if filter.weight != .any { parts.append(filter.weight.title) }
        if let format = filter.format { parts.append(format.pickerTitle) }
        if filter.source != .any { parts.append(filter.source.title) }
        return parts.isEmpty ? "не выбран" : parts.joined(separator: ", ")
    }
}

// MARK: - Строка «часть списка спрятана»

/// Появляется ТОЛЬКО когда отбор правда что-то спрятал.
///
/// ⚠️ БЕЗ НЕЁ ОТБОР ЧИТАЕТСЯ КАК ПОЛОМКА. Человек выбрал что-то в меню неделю назад,
/// открыл вкладку сегодня и видит три модели вместо двенадцати — и первое, что он
/// подумает, это «список сломался». Одна строка отвечает на оба вопроса сразу:
/// сколько спрятано и как вернуть всё обратно.
///
/// ⚠️ И ЕЁ НЕТ, КОГДА ПРЯТАТЬ НЕЧЕГО. Смена порядка своей строки не получает: то, что
/// лёгкие оказались сверху, видно по самому списку.
struct ModelListFilterNotice: View {

    @Binding var filter: ModelListFilter
    /// Сколько строк осталось после отбора.
    let shown: Int
    /// Сколько их было до него.
    let total: Int
    /// Отступ от краёв. На вкладке «Модели» текст вне карточек выровнен по ВНУТРЕННЕМУ
    /// краю карточки, а на странице находок — по краю экрана; одно число на двоих
    /// означало бы уступ относительно всего остального на одном из экранов.
    ///
    /// ⚠️ Отступ ставит сама строка, а не тот, кто её позвал: обёртка снаружи осталась бы
    /// на экране и тогда, когда самой строки нет, — то есть пустым местом на ровном месте.
    let horizontalInset: CGFloat

    var body: some View {
        if filter.hidesSomething, shown < total {
            HStack(spacing: 10) {
                // ⚠️ «Показано: 3 из 12», а не «Показаны 3 из 12»: с двоеточием строка
                // верна при любом числе, а без него на единице получалось «Показаны 1».
                Text(shown == 0
                     ? "Под отбор ничего не подошло"
                     : "Показано: \(shown) из \(total)")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)

                Button("Показать все") {
                    filter.showEverything()
                }
                .font(.caption.bold())
                .foregroundStyle(Theme.Colors.accent)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalInset)
        }
    }
}
