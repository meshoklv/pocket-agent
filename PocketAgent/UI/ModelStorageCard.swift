//
//  ModelStorageCard.swift
//  PocketAgent
//
//  Блок «Модель на телефоне» для страницы «О программе»: сколько места занимает файл
//  модели и кнопка убрать его насовсем.
//
//  Зачем это вообще есть. Модель весит гигабайты, и человек обязан иметь возможность
//  забрать это место обратно, не удаляя приложение целиком. Молчать о том, что внутри
//  приложения лежит такой файл, — нечестно.
//
//  Правила блока:
//    • цифра освобождаемого места — НАСТОЯЩАЯ (файл модели плюс служебный кэш движка),
//      а не размер из каталога;
//    • перед удалением — подтверждение, и в нём прямо сказано, что помощник перестанет
//      работать, пока модель не установят заново;
//    • после удаления показываем, сколько освободилось, — обещание должно быть проверяемым.
//
//  Дизайн: обычная карточка, стекла нет (стекло живёт только на плавающем слое).
//

import SwiftUI

// MARK: - Что показывать и что делать

/// Всё, что странице «О программе» нужно знать про установленную модель.
///
/// Отдельная маленькая структура, а не ссылка на `AppViewModel`, намеренно:
/// «О программе» ничего не знает ни про каталог моделей, ни про движок — и не должна.
struct ModelStorageBinding {
    /// Сколько байт занимает установленная модель со служебными данными. 0 — ничего нет.
    let installedBytes: Int64
    /// Идёт удаление прямо сейчас.
    let isDeleting: Bool
    /// Сколько освободилось после удаления. nil — ещё ничего не удаляли.
    let freedBytes: Int64?
    /// Удалить модель.
    let delete: () -> Void
}

// MARK: - Карточка

struct ModelStorageCard: View {

    /// Что рассказываем про модель — готовыми строками из Contracts.
    let model: ModelInfo
    let storage: ModelStorageBinding

    @State private var isConfirmShown = false

    /// Колонка под иконку. Растёт вместе с системным шрифтом — иконка набрана ролью.
    @ScaledMetric(relativeTo: .title3) private var iconGutter: CGFloat
        = Theme.Metrics.iconGutterWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Модель на телефоне")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            content
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Единственное описание поверхности карточки — Theme.cardSurface().
        .cardSurface()
        .confirmationDialog("Удалить модель?",
                            isPresented: $isConfirmShown,
                            titleVisibility: .visible) {
            Button("Удалить и освободить \(occupiedText)", role: .destructive) {
                storage.delete()
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("""
            Освободится \(occupiedText). Помощник перестанет работать, пока модель не появится снова: \
            её можно будет скачать заново или выбрать файл на телефоне.
            """)
        }
    }

    @ViewBuilder
    private var content: some View {
        if storage.isDeleting {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Удаляю файл модели")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Это быстро — секунда-другая.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } else if storage.installedBytes > 0 {
            installedContent
        } else if let freed = storage.freedBytes {
            removedContent(freed: freed)
        }
    }

    // MARK: - Модель установлена

    private var installedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.title3)
                    .frame(minWidth: iconGutter, alignment: .leading)
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Занимает \(occupiedText)")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text("Файл \(model.fileName) и служебные данные движка.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Button(role: .destructive) {
                isConfirmShown = true
            } label: {
                Text("Удалить модель и освободить место")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .padding(.vertical, Theme.Metrics.contentSpacing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.removed)
            .background(Theme.surfaceHigh, in: Capsule())
        }
    }

    // MARK: - Модель удалена

    private func removedContent(freed: Int64) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .frame(minWidth: iconGutter, alignment: .leading)
                .foregroundStyle(Theme.apply)
            VStack(alignment: .leading, spacing: 4) {
                Text("Освободилось \(bytesText(freed))")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text("Модели на телефоне больше нет. Закройте эту страницу — приложение предложит скачать её заново или выбрать готовый файл.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Мелочи

    /// Сколько реально занято. Именно эту цифру обещаем освободить.
    private var occupiedText: String {
        bytesText(storage.installedBytes)
    }

    /// Размер человеческим языком. Общий форматировщик из Contracts: он всегда ставит
    /// русскую запятую, а ByteCountFormatter брал разделитель из настроек телефона.
    private func bytesText(_ value: Int64) -> String {
        HumanFormat.bytes(value)
    }
}
