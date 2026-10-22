//
//  GlassCompat.swift
//  PocketAgent
//
//  ЕДИНСТВЕННОЕ место во всём проекте, где написано `#available(iOS 26.0, *)`.
//  Экраны зовут только adaptive*-обёртки и НЕ проверяют версию у себя.
//
//  Правила Liquid Glass, которые этот файл обязан удерживать:
//   • стекло — только на плавающем навигационном слое (панель снизу, круглые кнопки, тулбар);
//   • стекла поверх стекла не бывает — один плавающий слой над контентом;
//   • соседние стеклянные элементы живут ТОЛЬКО внутри общего AdaptiveGlassContainer;
//   • тинт — только со смыслом (главное действие, опасное действие), не для красоты.
//
//  Деплой-таргет проекта — iOS 17. На iOS 17–18 честный откат: ultraThinMaterial
//  с тонкой светлой обводкой. Это не «почти стекло», а просто материал, и так и надо.
//

import SwiftUI

// MARK: - Доступность эффекта

/// Есть ли на этом устройстве настоящий Liquid Glass.
/// Нужна экранам, которые хотят чуть иначе разложить отступы на старой iOS.
/// ⚠️ Не использовать для «а нарисую-ка я стекло сам» — своих имитаций стекла в проекте нет.
enum GlassAvailability {
    static var isLiquidGlassAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

// MARK: - Сборка материала (вне ViewBuilder)

/// Собрать Glass с нужными модификаторами.
/// Вынесено в отдельную функцию намеренно: внутри `@ViewBuilder` оператор `if`
/// разбирается как ветвление ВЬЮХ, и обычные присваивания там не компилируются.
@available(iOS 26.0, *)
private func makeGlass(interactive: Bool, tint: Color?) -> Glass {
    var glass: Glass = .regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

// MARK: - Стекло на вьюхе

extension View {

    /// Стекло произвольной формы.
    ///
    /// ⚠️ Паддинги ставить ДО этого модификатора — стекло берёт границы вьюхи вместе с ними.
    /// ⚠️ Вешать только на плавающий навигационный слой. На пузыри сообщений, карточки,
    ///    ячейки списка и фоны во весь экран — нельзя, это брак.
    ///
    /// - Parameters:
    ///   - shape: форма стекла, например `Capsule()` или `.rect(cornerRadius: 20)`.
    ///   - interactive: реакция на касание (масштаб, отскок, блик). Для панелей и кнопок — да.
    ///   - tint: осмысленный оттенок (главное/опасное действие). По умолчанию нет.
    @ViewBuilder
    func adaptiveGlassEffect(in shape: some Shape,
                             interactive: Bool = false,
                             tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(makeGlass(interactive: interactive, tint: tint), in: shape)
        } else {
            self.background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(tint?.opacity(Theme.Metrics.legacyTintOpacity) ?? Color.clear)
                    }
                    .overlay {
                        shape.stroke(Theme.Colors.legacyGlassBorder, lineWidth: 1)
                    }
            }
        }
    }

    /// То же самое, но форма по умолчанию — капсула (как у системного стекла).
    /// Отдельная перегрузка, а не значение по умолчанию у `some Shape`:
    /// у обобщённого параметра значения по умолчанию задать нельзя.
    func adaptiveGlassEffect(interactive: Bool = false,
                             tint: Color? = nil) -> some View {
        adaptiveGlassEffect(in: Capsule(), interactive: interactive, tint: tint)
    }

    /// Стиль стеклянной кнопки.
    /// `prominent` — главное действие (непрозрачная заливка), иначе второстепенное.
    /// Оттенок задавать обычным `.tint(_:)` рядом — и только когда он что-то означает.
    @ViewBuilder
    func adaptiveGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Контейнер для соседних стеклянных элементов

/// Обёртка над `GlassEffectContainer`.
///
/// Стекло не умеет сэмплить другое стекло: два и более `adaptiveGlassEffect` рядом
/// обязаны лежать внутри ОДНОГО такого контейнера, иначе будут артефакты рендера.
/// На iOS 17–18 контейнер прозрачен — просто отдаёт содержимое как есть.
///
/// `spacing` — насколько близко формы должны сойтись, чтобы начать сливаться.
struct AdaptiveGlassContainer<Content: View>: View {

    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = Theme.Metrics.glassSpacing,
         @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Морфинг форм

extension View {

    /// Пометить стеклянный элемент устойчивым идентификатором — тогда при смене раскладки
    /// внутри `withAnimation` одна форма перетечёт в другую, а не мигнёт.
    /// Работает только внутри `AdaptiveGlassContainer`.
    @ViewBuilder
    func adaptiveGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Принудительно слить несколько соседних элементов в одну стеклянную фигуру.
    @ViewBuilder
    func adaptiveGlassUnion(id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectUnion(id: id, namespace: namespace)
        } else {
            self
        }
    }
}

// MARK: - Край скролла

/// Как контент растворяется у края под плавающей панелью.
enum AdaptiveScrollEdgeStyle {
    /// Решает система.
    case automatic
    /// Мягкое размытое затемнение — наш случай для списка под панелью.
    case soft
    /// Резкая граница.
    case hard
}

extension View {

    /// Эффект края скролла: именно он даёт мягкое затемнение там, где список
    /// подныривает под плавающую панель.
    ///
    /// ⚠️ Своих фонов и градиентов позади системных баров не ставить — они этот эффект ломают.
    /// На iOS 17–18 системного эффекта нет; для приблизительного вида есть `adaptiveBottomFade`.
    ///
    /// Ветвление написано через switch намеренно: так системный тип стиля нигде
    /// не называется по имени и его нельзя случайно упомянуть вне проверки версии.
    @ViewBuilder
    func adaptiveScrollEdge(_ style: AdaptiveScrollEdgeStyle = .soft,
                            for edges: Edge.Set = .bottom) -> some View {
        if #available(iOS 26.0, *) {
            switch style {
            case .automatic: self.scrollEdgeEffectStyle(.automatic, for: edges)
            case .soft:      self.scrollEdgeEffectStyle(.soft, for: edges)
            case .hard:      self.scrollEdgeEffectStyle(.hard, for: edges)
            }
        } else {
            self
        }
    }

    /// Откат для iOS 17–18: растворить нижний край контента маской.
    /// На iOS 26 не делает НИЧЕГО — там за это отвечает системный эффект края,
    /// и вторая маска поверх него только испортит картинку.
    @ViewBuilder
    func adaptiveBottomFade(height: CGFloat = Theme.Metrics.bottomFadeHeight) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.mask {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.black)
                    LinearGradient(colors: [Color.black, Color.black.opacity(0)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                        .frame(height: height)
                }
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Панель вкладок

/// Когда системная панель вкладок сжимается в компактный вид.
enum AdaptiveTabBarMinimizeBehavior {
    case automatic
    case onScrollDown
    case never
}

extension View {

    /// Поведение сжатия системной панели вкладок. Вешать на `TabView`.
    /// Нужно только если экран построен на системном `TabView`; у собственной
    /// плавающей панели (`FloatingGlassBar`) этого поведения нет.
    ///
    /// ⚠️ ЗАГОТОВКА: в MVP `TabView` нигде не используется, вкладок в приложении нет,
    /// поэтому этот модификатор не вызывается ни разу. Оставлен на случай появления
    /// вкладок — но действующей частью интерфейса не считается.
    @ViewBuilder
    func adaptiveTabBarMinimize(_ behavior: AdaptiveTabBarMinimizeBehavior = .onScrollDown) -> some View {
        if #available(iOS 26.0, *) {
            switch behavior {
            case .automatic:    self.tabBarMinimizeBehavior(.automatic)
            case .onScrollDown: self.tabBarMinimizeBehavior(.onScrollDown)
            case .never:        self.tabBarMinimizeBehavior(.never)
            }
        } else {
            self
        }
    }
}
