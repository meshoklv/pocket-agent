//
//  GlassCircleButton.swift
//  PocketAgent
//
//  Круглая стеклянная кнопка-иконка — та самая, что стоит сверху слева и справа
//  («назад», «настройки»), и та, что отправляет задачу.
//
//  ⚠️ Обязательный `.clipShape(Circle())` — обход известного бага: стиль
//  `.glassProminent` вместе с `.buttonBorderShape(.circle)` рисует форму неверно.
//  Убирать его нельзя, даже если на конкретной сборке визуально всё ровно.
//
//  ⚠️ Две такие кнопки рядом — только внутри общего контейнера.
//  Для верхней строки экрана для этого есть готовый `GlassCircleButtonRow`.
//

import SwiftUI

struct GlassCircleButton: View {

    /// Что кнопка означает. От этого — и заливка, и оттенок. Тинт только со смыслом.
    enum Emphasis {
        /// Второстепенное действие: назад, закрыть, настройки. Прозрачное стекло, без оттенка.
        case standard
        /// Главное действие: отправить, применить. Непрозрачное стекло, синий оттенок.
        case primary
        /// Опасное действие: отклонить, остановить. Непрозрачное стекло, красный оттенок.
        case destructive
    }

    let systemImage: String
    /// Название вслух — для VoiceOver. Обязательное: у кнопки-иконки текста нет.
    let accessibilityTitle: String
    var emphasis: Emphasis = .standard
    var size: CGFloat = Theme.Metrics.circleButtonSize
    var isEnabled: Bool = true
    let action: () -> Void

    init(systemImage: String,
         accessibilityTitle: String,
         emphasis: Emphasis = .standard,
         size: CGFloat = Theme.Metrics.circleButtonSize,
         isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityTitle = accessibilityTitle
        self.emphasis = emphasis
        self.size = size
        self.isEnabled = isEnabled
        self.action = action
    }

    /// Совместимый конструктор из `design notes` — экраны писались по нему.
    /// Оставлен рядом с богатым: `prominent` — это `.primary`, обычная кнопка — `.standard`.
    init(systemImage: String,
         accessibilityLabel: String,
         prominent: Bool = false,
         action: @escaping () -> Void) {
        self.init(systemImage: systemImage,
                  accessibilityTitle: accessibilityLabel,
                  emphasis: prominent ? .primary : .standard,
                  action: action)
    }

    /// Насколько система сейчас увеличивает шрифт: сколько точек стоит «100 точек текста».
    ///
    /// ⚠️ Масштабирование живёт ВНУТРИ кнопки намеренно. Раньше его делал снаружи только
    /// экран чата (свой @ScaledMetric и свой потолок), а четыре других места звали кнопку
    /// без параметра — и при крупном системном шрифте одна и та же кнопка в чате росла,
    /// а на экранах подготовки, «О программе» и на страницах-шитах оставалась мелкой.
    /// Само `size` брать за начальное значение @ScaledMetric нельзя: обёртке нужна
    /// константа, а `size` — обычное свойство. Поэтому меряем множитель и умножаем.
    @ScaledMetric(relativeTo: .title3) private var scaleProbe: CGFloat = 100

    /// Настоящий диаметр: заданный размер, увеличенный системным шрифтом,
    /// но не крупнее «большой» круглой кнопки — иначе две кнопки съедают верх экрана.
    private var diameter: CGFloat {
        min(size * (scaleProbe / 100), Theme.Metrics.circleButtonLargeSize)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * Theme.Metrics.circleButtonIconRatio, weight: .semibold))
                .frame(width: diameter, height: diameter)
        }
        .adaptiveGlassButton(prominent: emphasis != .standard)
        .buttonBorderShape(.circle)
        .clipShape(Circle())          // ← обход бага формы, не удалять
        .tint(tint)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(accessibilityTitle))
    }

    /// Оттенок появляется ТОЛЬКО у главного и опасного действия.
    /// У обычной кнопки его нет — крашеное стекло «для красоты» запрещено.
    private var tint: Color? {
        switch emphasis {
        case .standard:    return nil
        case .primary:     return Theme.Colors.glassTintPrimary
        case .destructive: return Theme.Colors.glassTintDestructive
        }
    }
}

// MARK: - Верхняя строка с круглыми кнопками

/// Строка круглых стеклянных кнопок: слева — одни, справа — другие.
///
/// Существует ради одного правила: несколько стеклянных элементов на экране обязаны
/// лежать в ОДНОМ `AdaptiveGlassContainer`. Собранные так кнопки корректно сливаются
/// и морфятся, а не дают артефакты рендера.
///
/// Сама строка стекла не несёт — иначе получилось бы стекло поверх стекла.
struct GlassCircleButtonRow<Leading: View, Trailing: View>: View {

    private let spacing: CGFloat
    private let horizontalInset: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    init(spacing: CGFloat = Theme.Metrics.glassSpacing,
         horizontalInset: CGFloat = Theme.Metrics.floatingBarSideInset,
         @ViewBuilder leading: () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.spacing = spacing
        self.horizontalInset = horizontalInset
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        AdaptiveGlassContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                leading
                Spacer(minLength: Theme.Metrics.contentSpacing)
                trailing
            }
            .padding(.horizontal, horizontalInset)
        }
    }
}
