//
//  HubListMenu.swift
//  PocketAgent
//
//  ОДНА КНОПКА, ЗА КОТОРОЙ ЖИВЁТ ВЕСЬ ПОРЯДОК СПИСКА НАХОДОК.
//
//  ⚠️⚠️ ЗАЧЕМ ФАЙЛ ПОЯВИЛСЯ. На странице поиска было ДВА «Порядка», и они спорили
//  между собой. Один — сплошной переключатель прямо на странице («В тренде ·
//  Нравятся · Качают · Новые»): он менял ВОПРОС к справочнику. Второй — пункт
//  «Порядок» внутри меню отбора («Лёгкие сверху»): он раскладывал уже пришедшее.
//  Человек выбирал в меню «Лёгкие сверху», а на странице горело «Порядок: В тренде» —
//  список стоял не в том порядке, что написано на экране, и понять, кто из двоих
//  победил, было нельзя.
//
//  Теперь порядок один, и он тут. Переключатель со страницы убран совсем — заодно
//  на экране стало на целый ряд меньше, и находки поднялись выше (ROADMAP, раздел 2:
//  «экран говорит только то, что нужно сейчас»).
//
//  ⚠️ ДВА ПУНКТА ЧЕСТНО РАЗВЕДЕНЫ, А НЕ СВАЛЕНЫ В ОДИН СПИСОК, и это главное здесь.
//  Они делают разное, и подписи это говорят:
//    • «Что показать» — какие модели ПРИВЕЗТИ из справочника (список перезапрашивается);
//    • «Порядок» — как разложить то, что уже привезли (никаких запросов).
//  Свалить их в один список из шести пунктов значило бы обещать, что «Лёгкие сверху» —
//  это лёгкие во всём справочнике. Это неправда: лёгкие среди привезённых.
//
//  ⚠️ ПОЧЕМУ МЕНЮ, А НЕ РЯД ПЕРЕКЛЮЧАТЕЛЕЙ — та же причина, что и у кнопки отбора
//  в `ModelListFilter.swift`: ряд переключателей это строки, которые видны всегда,
//  а нужны раз в месяц. Меню занимает место одного значка.
//

import SwiftUI

// MARK: - Общие пункты отбора

/// Пункты, одинаковые для любого списка моделей: порядок, вес, формат, как получить.
///
/// ⚠️ ОТДЕЛЬНЫМ ВИДОМ, ЧТОБЫ ДВА СПИСКА НЕ РАЗЪЕХАЛИСЬ. Ровно эти пункты нужны
/// и на странице находок, и во встроенном списке на вкладке «Модели». Пока
/// `ModelListFilterButton` (файл `UI/ModelListFilter.swift`) держит свою копию —
/// он занят другой правкой; как освободится, его меню заменяется одной строкой
/// `ModelListFilterMenuContent(…)`, и копия исчезает.
struct ModelListFilterMenuContent: View {

    @Binding var filter: ModelListFilter

    /// Как назвать «обычный» порядок именно в этом списке.
    let naturalOrderTitle: String
    /// Виды файлов, которые в списке правда встречаются. Пусто — пункта не будет.
    let formats: [ModelFileFormat]
    /// Способы получить модель, между которыми есть выбор. Пусто — пункта не будет.
    let sources: [ModelSourceFilter]

    var body: some View {
        Picker("Порядок", selection: $filter.order) {
            Text(naturalOrderTitle).tag(ModelListOrder.natural)
            Text("Лёгкие сверху").tag(ModelListOrder.lightestFirst)
        }

        // ⚠️ ВЕС ПОКАЗЫВАЕМ ВСЕГДА, даже если прятать сейчас нечего: это то самое,
        // что владелец и просил («влезет / не влезет в этот телефон»), и оно обязано
        // быть на месте, когда он туда заглянет.
        Picker("Вес", selection: $filter.weight) {
            ForEach(ModelWeightFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }

        // ⚠️ А эти два пункта — только когда в списке есть из чего выбирать. Отбор
        // по формату в списке из одних только папок Apple ничего не может изменить:
        // выбрать можно, а произойти ничего не может.
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
    }
}

// MARK: - Кнопка страницы находок

/// Порядок и отбор находок — одной кнопкой рядом со строкой поиска.
struct HubListMenuButton: View {

    /// Какие модели просить у справочника. Смена этого пункта перезапрашивает список —
    /// делает это сама страница (`ModelSearchView`), у которой есть чем запросить.
    @Binding var sort: HubSortOption
    /// Как разложить и что спрятать из уже пришедшего.
    @Binding var filter: ModelListFilter

    let formats: [ModelFileFormat]
    let sources: [ModelSourceFilter]

    /// Открывал ли человек это меню хоть раз.
    ///
    /// ⚠️ ЗАЧЕМ ПОМНИТЬ. Пока меню ни разу не открывали, рядом со значком стоит слово
    /// «Отбор». Без него это безымянная серая воронка — и владелец, попросивший
    /// сортировку и фильтры, вполне может не найти на экране то, что сам заказал
    /// (ровно так он и обжёгся с этим экраном). Открыл один раз — подпись уходит
    /// навсегда: дальше она только занимает место у строки поиска.
    @AppStorage("pocketagent.hubFilterMenu.seen") private var didOpenMenu = false

    var body: some View {
        Menu {
            // ⚠️ ПЕРВЫМ — то, что меняет вопрос к справочнику. Оно решает, какие
            // модели вообще приедут; всё остальное лишь раскладывает приехавшее.
            Picker("Что показать", selection: $sort) {
                ForEach(HubSortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            ModelListFilterMenuContent(filter: $filter,
                                       // Не «как в справочнике»: справочник прислал
                                       // ровно то, что выбрано пунктом выше, и слово
                                       // «справочник» в двух пунктах подряд опять
                                       // заставило бы гадать, кто из них главнее.
                                       naturalOrderTitle: "Как прислали",
                                       formats: formats,
                                       sources: sources)
        } label: {
            HStack(spacing: 6) {
                // Подпись — только до первого открытия меню.
                if !didOpenMenu {
                    Text("Отбор")
                        .font(.subheadline)
                }
                // ⚠️ Значок залит, когда список стоит не так, как по умолчанию:
                // это единственное, что говорит человеку «список переставлен
                // или часть строк спрятана» без единого лишнего слова.
                Image(systemName: isPlain
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
                    .font(.title3)
            }
            // Палец попадает по кнопке, даже когда подписи уже нет и остался
            // один значок шириной в два десятка точек.
            .frame(minWidth: Theme.Metrics.minimumTapTarget,
                   minHeight: Theme.Metrics.minimumTapTarget,
                   alignment: .trailing)
            .contentShape(Rectangle())
        }
        .foregroundStyle(isPlain ? Theme.textSecondary : Theme.Colors.accent)
        .accessibilityLabel("Порядок и отбор")
        .accessibilityValue(accessibilityValue)
        // ⚠️ Считаем открытие ПО ПЕРВОМУ ВЫБОРУ, а не по касанию кнопки: SwiftUI
        // не сообщает, что меню раскрылось, а гадать по нажатию нельзя — человек
        // мог промахнуться и закрыть его касанием мимо, так и не увидев пунктов.
        .onChange(of: sort) { _, _ in didOpenMenu = true }
        .onChange(of: filter) { _, _ in didOpenMenu = true }
    }

    /// Список стоит ровно так, как по умолчанию: ничего не спрятано и не переставлено.
    private var isPlain: Bool { filter.isDefault && sort == .trending }

    /// Голосом читаем то же, что человек видит по цвету значка.
    private var accessibilityValue: String {
        var parts: [String] = [sort.title]
        if filter.order == .lightestFirst { parts.append("лёгкие сверху") }
        if filter.weight != .any { parts.append(filter.weight.title) }
        if let format = filter.format { parts.append(format.pickerTitle) }
        if filter.source != .any { parts.append(filter.source.title) }
        return parts.joined(separator: ", ")
    }
}
