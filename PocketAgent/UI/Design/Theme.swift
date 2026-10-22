//
//  Theme.swift
//  PocketAgent
//
//  ЕДИНСТВЕННЫЙ источник цветов, шрифтов, радиусов и отступов приложения.
//  Правило проекта: ни в одном другом файле UI не должно быть литералов вида
//  Color(red:…), .cornerRadius(16), .padding(20) с выдуманным числом — всё берётся отсюда.
//
//  Приложение живёт в тёмной теме: чёрный фон, светлый текст, синие пузыри пользователя.
//  Светлой темы у MVP нет — PocketAgentApp принудительно ставит .preferredColorScheme(.dark).
//

import SwiftUI

enum Theme {

    // MARK: - Цвета

    enum Colors {

        // Фон и поверхности

        /// Фон экрана. Именно чёрный, а не systemBackground: на OLED-экране
        /// плавающая панель читается как отдельный слой только на настоящем чёрном.
        static let background = Color.black
        /// Карточка, пузырь агента, поле ввода. СПЛОШНОЙ цвет — стекло сюда нельзя.
        static let surface = Color(red: 0.11, green: 0.11, blue: 0.12)
        /// Вложенная поверхность внутри карточки (например, блок диффа).
        static let surfaceRaised = Color(red: 0.16, green: 0.16, blue: 0.17)
        /// Тонкая разделительная линия.
        static let separator = Color.white.opacity(0.12)

        // Текст

        /// ⚠️ Эти три — для текста на СПЛОШНЫХ подложках (карточка, пузырь, лента).
        /// На стекле их использовать нельзя: см. glassText* ниже.
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.38)
        /// Текст на заливке главного действия.
        static let textOnAccent = Color.white

        // Текст НА ЦВЕТНОМ ФОНЕ (площадка).
        //
        // ⚠️ ЗАЧЕМ ОТДЕЛЬНАЯ ПАРА, ЕСЛИ ВЫШЕ УЖЕ ЕСТЬ textPrimary/textSecondary.
        // Те три роли рассчитаны на СПЛОШНЫЕ тёмные подложки (карточка, пузырь, лента),
        // где 0,62 даёт около 5:1. У площадки фон другой: цветные пятна, которые ещё и
        // медленно ползут. Белый в 0,62 поверх янтарного пятна даёт около 2,7:1 при норме
        // 4,5:1 — и контраст меняется во времени, то есть «на глаз подобрать» нельзя
        // в принципе. Поэтому на площадке текст поверх фона берёт эти две роли, а не
        // россыпь чисел 0,85 / 0,9 / белый, которая там была до 11.09.2026.
        //
        // ⚠️ Сюда же попадает текст на ПОЛУПРОЗРАЧНОЙ затемняющей подложке (0,45 чёрного):
        // она не отрезает фон, а лишь приглушает его — значит цвет остаётся «на цветном».
        /// Главный текст поверх цветного фона: заголовок экрана, название состояния.
        static let textOnColor = Color.white
        /// Пояснение поверх цветного фона. 0,9, а не 0,62 — по расчёту контраста выше.
        static let textOnColorSecondary = Color.white.opacity(0.9)

        // Текст НА СТЕКЛЕ — только смысловыми ролями, не белым с прозрачностью.
        //
        // ⚠️ Правило, ради которого эти три имени существуют: сквозь стекло видно то,
        // что проезжает под панелью. Жёстко заданный белый с прозрачностью на светлом
        // кадре просто исчезает, и система его не спасёт. Смысловые роли система
        // подстраивает сама — и под фон, и под «Увеличение контраста»,
        // и под «Понижение прозрачности».
        static let glassTextPrimary: HierarchicalShapeStyle = .primary
        static let glassTextSecondary: HierarchicalShapeStyle = .secondary
        static let glassTextTertiary: HierarchicalShapeStyle = .tertiary

        // Смысловые цвета (системная палитра iOS в тёмной теме)

        /// Главное действие: отправить, применить.
        static let accent = Color(red: 0.04, green: 0.52, blue: 1.00)   // #0A84FF
        /// Опасное действие: отклонить, удалить.
        static let danger = Color(red: 1.00, green: 0.27, blue: 0.23)   // #FF453A
        /// Предупреждение: шаги на исходе, файл изменился.
        static let warning = Color(red: 1.00, green: 0.62, blue: 0.04)  // #FF9F0A
        /// Успех: задача выполнена.
        static let success = Color(red: 0.19, green: 0.82, blue: 0.35)  // #30D158

        // Пузыри сообщений (как в iMessage). Стекла здесь нет и быть не может.

        /// Свой пузырь — синий, справа.
        static let bubbleUser = accent
        static let bubbleUserText = textOnAccent
        /// Пузырь агента — тёмно-серый, слева.
        static let bubbleAgent = Color(red: 0.16, green: 0.16, blue: 0.17)
        static let bubbleAgentText = textPrimary
        /// Результат действия инструмента — темнее и глуше, это служебный вывод.
        static let bubbleTool = Color(red: 0.10, green: 0.10, blue: 0.11)
        static let bubbleToolText = Color.white.opacity(0.78)
        /// Системная реплика — тёплая подложка, чтобы отличалась от речи агента.
        static let bubbleSystem = Color(red: 0.22, green: 0.16, blue: 0.05)
        static let bubbleSystemText = Color(red: 1.00, green: 0.85, blue: 0.60)

        // Дифф

        static let diffAddedBackground = Color(red: 0.10, green: 0.26, blue: 0.15)
        static let diffAddedText = Color(red: 0.60, green: 0.95, blue: 0.68)
        static let diffAddedMarker = success

        static let diffRemovedBackground = Color(red: 0.29, green: 0.10, blue: 0.10)
        static let diffRemovedText = Color(red: 1.00, green: 0.64, blue: 0.62)
        static let diffRemovedMarker = danger

        /// Неизменённая строка диффа.
        static let diffContextText = Color.white.opacity(0.60)
        /// Номера строк слева.
        static let diffGutterText = Color.white.opacity(0.32)
        /// Фон всего блока с диффом (подложка строк задаётся отдельно, см. diffRowBackground).
        static let diffBlockBackground = Color(red: 0.07, green: 0.07, blue: 0.08)

        // Стекло

        /// Оттенок стекла для ГЛАВНОГО действия. Использовать только там.
        static let glassTintPrimary = accent
        /// Оттенок стекла для ОПАСНОГО действия. Использовать только там.
        static let glassTintDestructive = danger
        /// Обводка отката на iOS 17–18: настоящему стеклу она не нужна и не ставится.
        static let legacyGlassBorder = Color.white.opacity(0.18)
    }

    // MARK: - Шрифты

    /// Всё через системные роли — иначе ломается «Динамический шрифт» в настройках доступности.
    enum Fonts {
        /// Крупный заголовок экрана, как в системных приложениях.
        static let screenTitle = Font.largeTitle.weight(.bold)
        /// Заголовок карточки или секции.
        static let sectionTitle = Font.headline
        /// Обычный текст и текст пузыря.
        static let body = Font.body
        /// Пояснение под заголовком.
        static let secondary = Font.subheadline
        /// Мелкая подпись: имя автора, счётчик шагов.
        static let caption = Font.caption
        /// Подпись под иконкой в плавающей панели.
        static let barLabel = Font.caption2.weight(.medium)
        /// Путь к файлу, вывод инструмента.
        static let code = Font.system(.footnote, design: .monospaced)
        /// Строка диффа. Моноширинный, чтобы столбцы не плясали.
        static let diffLine = Font.system(.caption, design: .monospaced)
        /// Цифры, которые обновляются на месте (счётчик шагов, проценты загрузки).
        static let counter = Font.footnote.monospacedDigit()

        // Пустой экран («ничего не нашлось», «папка не выбрана»).
        //
        // ⚠️ Роли заведены 11.09.2026, потому что это НЕ единичный случай: тот же
        // «крупный значок + заголовок помельче экранного» стоит и в корневом экране,
        // и в карточке правки — просто там он написан числами (.largeTitle / .title3.bold).
        // Имя роли переживает перебор размеров, литерал в пяти файлах — нет.
        /// Заголовок пустого экрана. Мельче `screenTitle`: пустой экран не заголовок экрана,
        /// он сообщение внутри него, и спорить с настоящим заголовком ему нельзя.
        static let emptyStateTitle = Font.title3.weight(.bold)
        /// Крупный значок над этим заголовком.
        static let emptyStateIcon = Font.largeTitle
    }

    // MARK: - Размеры

    enum Metrics {

        // Отступы

        /// Поля экрана слева и справа.
        static let screenPadding: CGFloat = 20
        /// Расстояние между соседними блоками контента.
        static let contentSpacing: CGFloat = 12
        /// Расстояние между крупными секциями экрана подготовки.
        static let sectionSpacing: CGFloat = 22
        /// Внутренние поля карточки.
        static let cardPadding: CGFloat = 16
        /// Внутренние поля пузыря сообщения.
        static let bubblePaddingHorizontal: CGFloat = 14
        static let bubblePaddingVertical: CGFloat = 10
        /// Насколько пузырь не дотягивается до противоположного края.
        static let bubbleOppositeInset: CGFloat = 56
        /// Внутренние поля капсулы-счётчика («+12», «−3», «новый файл», «Нужно ваше решение»).
        /// Одно число на все такие капсулы: раньше у трёх одинаковых по смыслу было 8, 9 и 10.
        static let badgePaddingHorizontal: CGFloat = 9
        static let badgePaddingVertical: CGFloat = 4
        /// Внутренние поля служебной строки в ленте (вывод инструмента, системная реплика).
        static let toolRowPaddingHorizontal: CGFloat = 12
        static let toolRowPaddingVertical: CGFloat = 10
        /// Внутренние поля ОДНОЙ строки диффа.
        static let diffRowPaddingHorizontal: CGFloat = 6
        static let diffRowPaddingVertical: CGFloat = 2
        /// Внутренние поля служебной плашки внутри блока диффа (заголовок куска,
        /// «ещё N строк без изменений»).
        static let diffNotePaddingHorizontal: CGFloat = 10
        static let diffNotePaddingVertical: CGFloat = 6

        // Колонки

        /// Ширина колонки под иконку в строке «иконка + текст».
        /// ⚠️ Задавать ТОЛЬКО через @ScaledMetric — иконка набирается ролью и растёт
        /// вместе с системным шрифтом, а жёсткая колонка её не удержит.
        static let iconGutterWidth: CGFloat = 26
        /// То же для мелкой иконки служебной строки (вывод инструмента).
        static let compactIconGutterWidth: CGFloat = 16
        /// Кружок с номером шага («1», «2», «3»).
        static let stepBadgeSize: CGFloat = 24
        /// Колонка подписи в строке «Название — значение» на странице «О программе».
        static let labelColumnWidth: CGFloat = 84

        // Сетка площадки
        //
        // ⚠️ ОБА ЧИСЛА — ТОЛЬКО ЧЕРЕЗ @ScaledMetric. До 11.09.2026 они стояли жёсткими
        // прямо в карточке: при крупном системном шрифте имя файла резалось, а плитка
        // со значком оставалась прежней — то есть карточка не росла вместе с текстом,
        // который в ней живёт. Значок набирается ролью и растёт сам, плитка под ним — нет.
        /// Высота плитки со значком на карточке площадки.
        static let playgroundTileHeight: CGFloat = 74
        /// Наименьшая ширина карточки в сетке площадки. Растёт вместе со шрифтом, поэтому
        /// на крупном шрифте сетка честно схлопывается в одну колонку, а не режет имена.
        static let playgroundCardMinWidth: CGFloat = 150

        // Радиусы

        static let bubbleCorner: CGFloat = 18
        static let cardCorner: CGFloat = 20
        static let controlCorner: CGFloat = 14
        static let diffCorner: CGFloat = 12

        // Плавающая панель

        /// Зазор панели от левого и правого краёв экрана — то, что делает её «плавающей».
        static let floatingBarSideInset: CGFloat = 16
        /// Зазор от нижнего края (поверх безопасной зоны).
        static let floatingBarBottomInset: CGFloat = 12
        /// Внутренние поля капсулы панели.
        static let floatingBarPaddingHorizontal: CGFloat = 10
        static let floatingBarPaddingVertical: CGFloat = 8
        /// Внутренние поля СОДЕРЖИМОГО панели (кнопка, полоса загрузки, «готовим движок»).
        /// Одно число на все состояния и на оба экрана подготовки: раньше панель прыгала
        /// по высоте при каждой смене состояния (10 → 16 → 10) и не совпадала с соседним
        /// экраном (14).
        static let floatingBarContentPaddingVertical: CGFloat = 12

        // ⚠️ Место под плавающую панель резервирует `safeAreaInset`, а НЕ число.
        // Готовой константы «запас снизу» здесь намеренно нет: именно из-за неё
        // (96 точек) последняя карточка ленты уезжала под стекло насовсем.

        // Круглые кнопки

        /// Запас сверху под круглую кнопку закрытия на шите («О программе», лицензия).
        static let sheetTopClearance: CGFloat = 56
        /// Запас снизу у экранов-шитов, чтобы последняя строка не липла к краю.
        static let sheetBottomClearance: CGFloat = 40

        /// Круглая кнопка отправки внутри панели ввода.
        static let sendButtonSize: CGFloat = 36

        static let circleButtonSize: CGFloat = 44
        static let circleButtonLargeSize: CGFloat = 56
        /// Доля размера кнопки, которую занимает иконка.
        static let circleButtonIconRatio: CGFloat = 0.42

        /// Толщина кольца хода вокруг круглой кнопки.
        /// ⚠️ Тонкое намеренно: кольцо — фон, а не орган управления. Толстое кольцо
        /// начинает читаться как вторая кнопка вокруг первой.
        static let progressRingWidth: CGFloat = 2.5
        /// Зазор между краем круглой кнопки и кольцом.
        /// ⚠️ Кольцо рисуется НАКЛАДКОЙ поверх кнопки и в её размер не входит — иначе
        /// появление кольца раздвигало бы верхнюю строку экрана и всё бы дёрнулось.
        static let progressRingGap: CGFloat = 3

        // Стекло

        /// Расстояние, на котором соседние стеклянные формы начинают сливаться.
        static let glassSpacing: CGFloat = 10
        /// Высота растворения нижнего края на iOS 17–18.
        static let bottomFadeHeight: CGFloat = 48
        /// Высота растворения ВЕРХНЕГО края на iOS 17–18. Меньше нижнего: сверху подложка
        /// ниже, и полная высота съедала бы заголовок ленты. Одно имя на все экраны —
        /// раньше в чате считали `bottomFadeHeight / 2`, а на экранах подготовки брали 48.
        static let topFadeHeight: CGFloat = 24
        /// Насколько заметен оттенок в откате на iOS 17–18.
        static let legacyTintOpacity: Double = 0.22

        // Прочее

        /// Толщина разделительной линии. Цвет линии — `Theme.hairline`.
        static let hairlineWidth: CGFloat = 1
        /// Минимальная площадь касания по рекомендациям Apple.
        static let minimumTapTarget: CGFloat = 44
    }

    // MARK: - Движение

    /// ⚠️ ПРАВИЛО ДЛИТЕЛЬНОСТЕЙ. Это телефонный интерфейс, а не заставка: анимация
    /// обязана успевать за пальцем. Всё, что человек вызывает нажатием, укладывается
    /// в 0,15–0,22 секунды; дольше 0,3 в приложении нет ничего. Длинная красивая
    /// анимация на экране, где ждут ответа модели, читается как тормоза.
    enum Motion {
        /// Смена вкладки, появление панели — с лёгким отскоком.
        static let snappy = Animation.snappy(duration: 0.28)
        /// Появление нового сообщения в ленте. Самая частая анимация экрана —
        /// поэтому и самая короткая: за секунду их может пройти несколько подряд.
        static let appear = Animation.easeOut(duration: 0.18)
        /// Подмена подписи или значка НА МЕСТЕ (статус в шапке, иконка отправки).
        /// Здесь ничего не двигается — только одно проявляется вместо другого.
        static let swap = Animation.easeInOut(duration: 0.15)
        /// Смена состояния ленты: спокойно, без отскока.
        static let smooth = Animation.smooth(duration: 0.28)
        /// Быстрая смена органа управления внутри панели (отправить ⇄ остановить).
        static let control = Animation.snappy(duration: 0.22)
        /// Появление карточки подтверждения, прокрутка ленты.
        static let gentle = Animation.easeOut(duration: 0.20)
        /// Раскрытие диффа.
        static let expand = Animation.easeInOut(duration: 0.24)
    }
}

// MARK: - Цвета по ролям

extension Theme.Colors {

    /// Фон пузыря по автору сообщения. Экран чата берёт цвета отсюда, а не подбирает свои.
    static func bubbleBackground(for author: ChatAuthor) -> Color {
        switch author {
        case .user:   return bubbleUser
        case .agent:  return bubbleAgent
        case .tool:   return bubbleTool
        case .system: return bubbleSystem
        }
    }

    /// Цвет текста в пузыре по автору сообщения.
    static func bubbleText(for author: ChatAuthor) -> Color {
        switch author {
        case .user:   return bubbleUserText
        case .agent:  return bubbleAgentText
        case .tool:   return bubbleToolText
        case .system: return bubbleSystemText
        }
    }

    /// Цвет строки диффа.
    static func diffText(for kind: DiffLineKind) -> Color {
        switch kind {
        case .added:   return diffAddedText
        case .removed: return diffRemovedText
        case .context: return diffContextText
        }
    }

    /// Подложка ОДНОЙ строки диффа. У неизменённых строк подложки нет.
    static func diffRowBackground(for kind: DiffLineKind) -> Color {
        switch kind {
        case .added:   return diffAddedBackground
        case .removed: return diffRemovedBackground
        case .context: return .clear
        }
    }
}

// MARK: - Готовые оформления

extension View {

    /// Чёрный фон экрана во всю площадь.
    /// ⚠️ Это СПЛОШНОЙ цвет. Стекло во весь экран — запрещённый приём.
    func screenBackground() -> some View {
        background(Theme.Colors.background.ignoresSafeArea())
    }

    /// Поверхность карточки: сплошной фон и скругление.
    /// ⚠️ Намеренно без стекла — стекло живёт только на плавающем слое.
    func cardSurface(cornerRadius: CGFloat = Theme.Metrics.cardCorner) -> some View {
        background(Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

}

// MARK: - Плоские псевдонимы цветов (контракт UI-CONTRACT.md)

/// Экраны писались по `docs/UI-CONTRACT.md`, где цвета зовутся плоско: `Theme.background`.
/// Реализация разложила их по пространствам: `Theme.Colors.background`.
/// Этот слой мирит одно с другим — ничего не переименовывая и не удаляя.
/// Канон для нового кода — `Theme.Colors.*`; плоские имена оставлены для совместимости.
extension Theme {
    static var background: Color { Colors.background }
    static var surface: Color { Colors.surface }
    static var surfaceHigh: Color { Colors.surfaceRaised }
    static var textPrimary: Color { Colors.textPrimary }
    static var textSecondary: Color { Colors.textSecondary }
    static var bubbleUser: Color { Colors.bubbleUser }
    static var bubbleAgent: Color { Colors.bubbleAgent }
    /// Зелёный «получилось»: галочка «модель готова», маркер добавленных строк.
    /// ⚠️ НЕ заливка кнопки «Применить» — там синий `Colors.accent`:
    /// белая подпись на зелёном даёт контраст около 2:1 при норме 4,5:1,
    /// а главным действием палитра называет именно синий.
    static var apply: Color { Colors.success }
    static var added: Color { Colors.diffAddedMarker }
    static var removed: Color { Colors.diffRemovedMarker }
    static var hairline: Color { Colors.separator }
}
