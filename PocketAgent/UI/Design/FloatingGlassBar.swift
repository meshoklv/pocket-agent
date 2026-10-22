//
//  FloatingGlassBar.swift
//  PocketAgent
//
//  Плавающая стеклянная панель снизу — с зазором от краёв экрана, капсулой,
//  фон сквозь неё размывается. Не прибита к краю.
//
//  Как ставить на экран (рекомендуемый способ — место под панель резервируется само):
//
//      ScrollView { … }
//          .adaptiveScrollEdge(.soft, for: .bottom)
//          .safeAreaInset(edge: .bottom) {
//              FloatingGlassBar {
//                  FloatingGlassBarButton(systemImage: "message", title: "Чат", isSelected: true) { … }
//                  FloatingGlassBarButton(systemImage: "folder", title: "Папка") { … }
//              }
//          }
//
//  ⚠️ Своих фонов и затемнений позади панели не добавлять — они ломают эффект края скролла.
//

import SwiftUI

struct FloatingGlassBar<Content: View>: View {

    /// Как распределено стекло внутри панели.
    enum Style {
        /// Одна общая стеклянная капсула на всю панель.
        /// Содержимое обязано быть БЕЗ своего стекла (`FloatingGlassBarButton` — как раз такое),
        /// иначе получится стекло поверх стекла.
        case unified
        /// Стекла на самой панели нет: его несёт каждый элемент сам
        /// (например, `GlassCircleButton`). Все элементы уже лежат в общем контейнере,
        /// поэтому сливаться и морфиться они будут корректно.
        ///
        /// ⚠️ ЗАГОТОВКА: в MVP боевые экраны её не зовут (вкладок в приложении нет).
        /// Живёт только в превью — но работает и проверена; удалять при чистке не надо,
        /// просто не считать её действующей частью интерфейса.
        case separated
    }

    private let style: Style
    private let isInteractive: Bool
    private let spacing: CGFloat
    private let horizontalInset: CGFloat
    private let bottomInset: CGFloat
    private let content: Content

    /// - Parameter interactive: реакция самого стекла на касание (масштаб, отскок, блик).
    ///   Она рассчитана на элемент, который ЦЕЛИКОМ является одним органом управления, —
    ///   то есть на панель-кнопку. Если внутри капсулы лежит поле ввода и отдельная
    ///   кнопка отправки (экран чата), передавать `false`: иначе вся панель подпрыгивает
    ///   от касания текстового поля, хотя нажимают не её.
    init(style: Style = .unified,
         interactive: Bool = true,
         spacing: CGFloat = Theme.Metrics.glassSpacing,
         horizontalInset: CGFloat = Theme.Metrics.floatingBarSideInset,
         bottomInset: CGFloat = Theme.Metrics.floatingBarBottomInset,
         @ViewBuilder content: () -> Content) {
        self.style = style
        self.isInteractive = interactive
        self.spacing = spacing
        self.horizontalInset = horizontalInset
        self.bottomInset = bottomInset
        self.content = content()
    }

    var body: some View {
        // Контейнер один на всю панель — этого требует Liquid Glass для соседних форм.
        AdaptiveGlassContainer(spacing: spacing) {
            capsule
        }
        // Именно эти два отступа и делают панель «плавающей», а не прибитой к краю.
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, bottomInset)
    }

    @ViewBuilder
    private var capsule: some View {
        switch style {
        case .unified:
            row
                .padding(.horizontal, Theme.Metrics.floatingBarPaddingHorizontal)
                .padding(.vertical, Theme.Metrics.floatingBarPaddingVertical)
                .adaptiveGlassEffect(in: Capsule(), interactive: isInteractive)
        case .separated:
            row
        }
    }

    /// ⚠️ `fixedSize` по вертикали — страховка от растяжения на весь экран.
    /// Панель обязана быть ровно такой высоты, какую просит её содержимое. Стоит внутри
    /// оказаться чему-то без собственной высоты (черта-разделитель, градиент, форма) —
    /// и панель занимает всё предложенное место. Ровно это и случилось на телефоне
    /// владельца: стеклянная капсула растянулась во весь экран, а текст ленты
    /// просвечивал сквозь неё. Ширину не трогаем: панель тянется по ширине намеренно.
    private var row: some View {
        HStack(spacing: spacing) {
            content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Кнопка внутри панели

/// Кнопка для `FloatingGlassBar` со стилем `.unified`.
///
/// ⚠️ ЗАГОТОВКА ПОД ВКЛАДКИ: в MVP вкладок нет, боевые экраны эту кнопку не зовут
/// (в чате внутри капсулы поле ввода, на экранах подготовки — одна широкая кнопка).
/// Используется только в превью.
///
/// Своего стекла у неё НЕТ и быть не должно: стекло уже несёт капсула панели.
/// Выбранный пункт отличается яркостью текста и иконки, а не второй стеклянной подложкой.
struct FloatingGlassBarButton: View {

    /// Что означает кнопка. От этого зависит цвет — и только от этого.
    enum Emphasis {
        /// Обычный пункт панели.
        case standard
        /// Главное действие (отправить, применить).
        case primary
        /// Опасное действие (отклонить, остановить).
        case destructive
    }

    let systemImage: String
    /// Подпись под иконкой. Пустая строка — только иконка.
    var title: String = ""
    var emphasis: Emphasis = .standard
    /// Текущий выбранный пункт: подсвечивается ярче остальных.
    var isSelected: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    // Роль, а не выдуманный размер: иначе иконка не растёт
                    // вместе с подписью при увеличенном системном шрифте.
                    .font(.title3.weight(.medium))
                if !title.isEmpty {
                    Text(title)
                        .font(Theme.Fonts.barLabel)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(title.isEmpty ? systemImage : title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Кнопка лежит НА СТЕКЛЕ, поэтому обычный и выключенный пункт красим смысловыми
    /// ролями, а не белым с прозрачностью: только так надпись переживёт светлый кадр
    /// за стеклом и подхватит «Увеличение контраста».
    /// Смысловые цвета (главное, опасное) остаются собой — они и должны читаться цветом.
    private var foreground: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(Theme.Colors.glassTextTertiary) }
        switch emphasis {
        case .primary:     return AnyShapeStyle(Theme.Colors.accent)
        case .destructive: return AnyShapeStyle(Theme.Colors.danger)
        case .standard:    return isSelected
            ? AnyShapeStyle(Theme.Colors.glassTextPrimary)
            : AnyShapeStyle(Theme.Colors.glassTextSecondary)
        }
    }
}
