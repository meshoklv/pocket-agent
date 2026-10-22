//
//  GlassPreviews.swift
//  PocketAgent
//
//  Превью общих компонентов дизайна — чтобы каждый смотреть в Xcode отдельно,
//  не запуская приложение и не дожидаясь загрузки модели.
//
//  Здесь только показ. Никакой логики, никаких обращений к движку, папке и файлам.
//  Весь файл собирается только в отладочной сборке.
//
//  ⚠️ ЭТО ВИТРИНА КОМПОНЕНТОВ, А НЕ ОБРАЗЕЦ КОМПОНОВКИ ЭКРАНА.
//  Здесь компоненты нарочно собраны в кучу, чтобы разглядеть их рядом.
//  На БОЕВОМ экране стеклянных элементов должно быть не больше трёх, и соседние
//  обязаны лежать в одном AdaptiveGlassContainer (см. docs/LIQUID-GLASS.md).
//  Сейчас так и есть: рабочий экран — три (капсула ввода и две круглые кнопки),
//  остальные экраны — по одному.
//

#if DEBUG
import SwiftUI

// MARK: - Подмостки

/// Чёрный экран с крупным заголовком — чтобы компонент был виден в его настоящей среде.
private struct PreviewStage<Content: View>: View {

    private let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.contentSpacing) {
            Text(title)
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
                .padding(.horizontal, Theme.Metrics.screenPadding)
                .padding(.top, Theme.Metrics.screenPadding)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .screenBackground()
        .preferredColorScheme(.dark)
    }
}

/// Обычная карточка списка. Стекла на ней нет — и не должно быть.
private struct PreviewCard: View {

    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(subtitle)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.cardPadding)
        .cardSurface()
    }
}

/// Лента карточек, которая подныривает под плавающую панель.
private struct PreviewFeed: View {

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Metrics.contentSpacing) {
                ForEach(0..<12, id: \.self) { index in
                    PreviewCard(title: "Файл \(index + 1)",
                                subtitle: "Sources/Feature/Module\(index + 1).swift")
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
        }
        .adaptiveScrollEdge(.soft, for: .bottom)
        .adaptiveBottomFade()
    }
}

// MARK: - Плавающая панель

#Preview("Панель — одна капсула") {
    PreviewStage(title: "Проект") {
        PreviewFeed()
            .safeAreaInset(edge: .bottom) {
                FloatingGlassBar {
                    FloatingGlassBarButton(systemImage: "message",
                                           title: "Чат",
                                           isSelected: true) {}
                    FloatingGlassBarButton(systemImage: "folder",
                                           title: "Файлы") {}
                    FloatingGlassBarButton(systemImage: "gearshape",
                                           title: "Модель") {}
                }
            }
    }
}

#Preview("Панель — действия шага") {
    PreviewStage(title: "Записать README.md") {
        PreviewFeed()
            .safeAreaInset(edge: .bottom) {
                FloatingGlassBar {
                    FloatingGlassBarButton(systemImage: "xmark",
                                           title: "Отклонить",
                                           emphasis: .destructive) {}
                    FloatingGlassBarButton(systemImage: "checkmark",
                                           title: "Применить",
                                           emphasis: .primary) {}
                }
            }
    }
}

#Preview("Панель — раздельное стекло") {
    PreviewStage(title: "Шаг 3 из 12") {
        PreviewFeed()
            .safeAreaInset(edge: .bottom) {
                FloatingGlassBar(style: .separated) {
                    GlassCircleButton(systemImage: "xmark",
                                      accessibilityTitle: "Отклонить",
                                      emphasis: .destructive) {}
                    Spacer(minLength: 0)
                    GlassCircleButton(systemImage: "checkmark",
                                      accessibilityTitle: "Применить",
                                      emphasis: .primary,
                                      size: Theme.Metrics.circleButtonLargeSize) {}
                }
            }
    }
}

// MARK: - Круглые кнопки

#Preview("Круглые кнопки") {
    PreviewStage(title: "Кнопки") {
        VStack(alignment: .leading, spacing: 28) {
            GlassCircleButtonRow {
                GlassCircleButton(systemImage: "chevron.left",
                                  accessibilityTitle: "Назад") {}
            } trailing: {
                GlassCircleButton(systemImage: "ellipsis",
                                  accessibilityTitle: "Ещё") {}
            }

            AdaptiveGlassContainer {
                HStack(spacing: Theme.Metrics.glassSpacing) {
                    GlassCircleButton(systemImage: "arrow.up",
                                      accessibilityTitle: "Отправить задачу",
                                      emphasis: .primary) {}
                    GlassCircleButton(systemImage: "stop.fill",
                                      accessibilityTitle: "Остановить",
                                      emphasis: .destructive) {}
                    GlassCircleButton(systemImage: "arrow.clockwise",
                                      accessibilityTitle: "Начать заново") {}
                    GlassCircleButton(systemImage: "paperplane.fill",
                                      accessibilityTitle: "Недоступно",
                                      isEnabled: false) {}
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
            }

            Text("Крупная кнопка главного действия")
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, Theme.Metrics.screenPadding)

            // Одиночная стеклянная кнопка тоже живёт в контейнере: рядом в кадре
            // есть другое стекло, а стекло не умеет сэмплить стекло — без общего
            // контейнера получаются артефакты рендера. Витрина обязана показывать
            // правильный приём, по ней копируют.
            AdaptiveGlassContainer {
                GlassCircleButton(systemImage: "arrow.up",
                                  accessibilityTitle: "Отправить задачу",
                                  emphasis: .primary,
                                  size: Theme.Metrics.circleButtonLargeSize) {}
                    .padding(.horizontal, Theme.Metrics.screenPadding)
            }
        }
    }
}

// MARK: - Палитра

#Preview("Палитра") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            PreviewSwatchGroup(title: "Поверхности", swatches: [
                PreviewSwatch("Фон экрана", Theme.Colors.background),
                PreviewSwatch("Карточка", Theme.Colors.surface),
                PreviewSwatch("Вложенная", Theme.Colors.surfaceRaised),
                PreviewSwatch("Разделитель", Theme.Colors.separator)
            ])
            PreviewSwatchGroup(title: "Смысл", swatches: [
                PreviewSwatch("Главное", Theme.Colors.accent),
                PreviewSwatch("Опасное", Theme.Colors.danger),
                PreviewSwatch("Внимание", Theme.Colors.warning),
                PreviewSwatch("Успех", Theme.Colors.success)
            ])
            PreviewSwatchGroup(title: "Пузыри", swatches: [
                PreviewSwatch("Свой", Theme.Colors.bubbleUser),
                PreviewSwatch("Агент", Theme.Colors.bubbleAgent),
                PreviewSwatch("Инструмент", Theme.Colors.bubbleTool),
                PreviewSwatch("Система", Theme.Colors.bubbleSystem)
            ])
            PreviewSwatchGroup(title: "Дифф", swatches: [
                PreviewSwatch("Добавлено", Theme.Colors.diffAddedBackground),
                PreviewSwatch("Удалено", Theme.Colors.diffRemovedBackground),
                PreviewSwatch("Фон блока", Theme.Colors.diffBlockBackground)
            ])
        }
        .padding(Theme.Metrics.screenPadding)
    }
    .screenBackground()
    .preferredColorScheme(.dark)
}

/// Один образец палитры. Отдельный тип, а не кортеж: по элементу кортежа
/// нельзя построить ключевой путь, и ForEach такой список не примет.
private struct PreviewSwatch: Identifiable {
    let id: String
    let color: Color

    init(_ name: String, _ color: Color) {
        self.id = name
        self.color = color
    }
}

private struct PreviewSwatchGroup: View {

    let title: String
    let swatches: [PreviewSwatch]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.textPrimary)
            ForEach(swatches) { swatch in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(swatch.color)
                        .frame(width: 52, height: 32)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.Colors.separator, lineWidth: Theme.Metrics.hairlineWidth)
                        }
                    Text(swatch.id)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }
}

// MARK: - Типографика

#Preview("Типографика") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Заголовок экрана").font(Theme.Fonts.screenTitle)
            Text("Заголовок секции").font(Theme.Fonts.sectionTitle)
            Text("Обычный текст сообщения, который занимает несколько строк и переносится.")
                .font(Theme.Fonts.body)
            Text("Пояснение под заголовком").font(Theme.Fonts.secondary)
            Text("Мелкая подпись").font(Theme.Fonts.caption)
            Text("Sources/Runtime/LiteRTRuntime.swift").font(Theme.Fonts.code)
            Text("+  let title = \"Привет\"").font(Theme.Fonts.diffLine)
            Text("Шаг 3 из 12").font(Theme.Fonts.counter)
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.screenPadding)
    }
    .screenBackground()
    .preferredColorScheme(.dark)
}

// MARK: - Пузыри и дифф (контент — без всякого стекла)

#Preview("Пузыри и дифф") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Metrics.contentSpacing) {
            PreviewBubble(author: .user, text: "Посмотри, что в папке, и добавь заголовок в README")
            PreviewBubble(author: .agent, text: "Смотрю содержимое папки проекта.")
            PreviewBubble(author: .tool, text: "README.md · 1.2 КБ\nSources/ · 14 файлов")
            PreviewBubble(author: .system, text: "Достигнут предел в 12 шагов.")

            VStack(alignment: .leading, spacing: 2) {
                PreviewDiffLine(kind: .context, text: "  # Проект")
                PreviewDiffLine(kind: .removed, text: "- Описание появится позже")
                PreviewDiffLine(kind: .added, text: "+ Карманный агент для iPhone")
                PreviewDiffLine(kind: .context, text: "  ")
            }
            .padding(10)
            .background(Theme.Colors.diffBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.diffCorner, style: .continuous))
        }
        .padding(Theme.Metrics.screenPadding)
    }
    .screenBackground()
    .preferredColorScheme(.dark)
}

private struct PreviewBubble: View {

    let author: ChatAuthor
    let text: String

    var body: some View {
        HStack {
            if author == .user { Spacer(minLength: Theme.Metrics.bubbleOppositeInset) }
            Text(text)
                .font(author == .tool ? Theme.Fonts.code : Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.bubbleText(for: author))
                .padding(.horizontal, Theme.Metrics.bubblePaddingHorizontal)
                .padding(.vertical, Theme.Metrics.bubblePaddingVertical)
                // Сплошной цвет. Стекло на пузыре — запрещено.
                .background(Theme.Colors.bubbleBackground(for: author))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.bubbleCorner, style: .continuous))
            if author != .user { Spacer(minLength: Theme.Metrics.bubbleOppositeInset) }
        }
    }
}

private struct PreviewDiffLine: View {

    let kind: DiffLineKind
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Fonts.diffLine)
            .foregroundStyle(Theme.Colors.diffText(for: kind))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.Colors.diffRowBackground(for: kind))
    }
}
#endif
