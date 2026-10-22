//
//  ModelFileHelpSheet.swift
//  PocketAgent
//
//  Отдельная страница «Взять готовый файл»: та же инструкция, что раньше стояла
//  прямо на экране «Модели» (`ModelFileHelpCard`), плюс кнопка выбора файла.
//
//  ⚠️ ПОЯВИЛАСЬ ПОСЛЕ ЖАЛОБЫ ВЛАДЕЛЬЦА (09.08.2026): «работает — из файла — эту
//  плашку куда-то смести, а то бесит, когда листаешь что-то, а она на треть экрана».
//  Инструкция никуда не делась и ничего не потеряла — она переехала за кнопку
//  «…» → «Взять готовый файл» вместо того, чтобы стоять на виду при каждой
//  прокрутке экрана «Модели». Кому она нужна редко — экран короче. Кому нужна —
//  она в одно нажатие, а не удалена совсем.
//
//  ⚠️ КНОПКА ВЫБОРА ФАЙЛА ЗДЕСЬ СВОЯ, А НЕ ОБЩАЯ С ПАНЕЛЬЮ. Нажатие сначала просит
//  закрыть эту страницу (через `onPickFile`) и только ПОСЛЕ закрытия — `ModelSetupView`
//  открывает системный выбор файла в `.sheet(onDismiss:)`. Так на экране всегда ровно
//  один активный модальный слой: показать системное окно «Файлы» поверх ещё не
//  закрывшегося шита — ненадёжный трюк, которого лучше избегать.
//
//  Дизайн: страница-шит, как `AboutView` — обычные карточки, стекло только на
//  круглой кнопке закрытия.
//

import SwiftUI

struct ModelFileHelpSheet: View {

    /// Имя модели, которую советуем новичку: «Gemma 4 E2B».
    let recommendedName: String
    /// Имя её файла — как пример, а не как требование.
    let recommendedFileName: String
    /// Страница модели, если она есть.
    let pageURL: URL?
    /// Человек нажал «Выбрать файл». Страница ничего не открывает сама —
    /// закрывает себя и просит родителя открыть системный выбор файла
    /// уже ПОСЛЕ того, как сама сойдёт с экрана.
    let onPickFile: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                header
                ModelFileHelpCard(recommendedName: recommendedName,
                                  recommendedFileName: recommendedFileName,
                                  pageURL: pageURL)
                pickButton
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            closeLayer
        }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .preferredColorScheme(.dark)
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Свой файл модели")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.textPrimary)

            Text("Если модель уже лежит у вас на телефоне или на компьютере — вот как её найти и отдать приложению.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Кнопка выбора файла

    private var pickButton: some View {
        Button {
            onPickFile()
        } label: {
            // Название совпадает со строкой на экране «Модели» — это одна и та же
            // дверь, и называться она обязана одинаково.
            Text("Выбрать файл или папку")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.textOnAccent)
        .background(Theme.Colors.accent, in: Capsule())
    }

    // MARK: - Круглая стеклянная кнопка закрытия (единственное стекло на странице)

    /// ⚠️ Подложка под кнопкой живёт ТОЛЬКО на iOS 17–18 — тот же приём, что
    /// в `AboutView.closeLayer`. На iOS 26 непрозрачный фон позади стекла запрещён.
    @ViewBuilder
    private var closeLayer: some View {
        if GlassAvailability.isLiquidGlassAvailable {
            closeButtonRow
        } else {
            VStack(spacing: 0) {
                closeButtonRow
                    .background {
                        Theme.background
                            .ignoresSafeArea(edges: .top)
                            .allowsHitTesting(false)
                    }

                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: Theme.Metrics.topFadeHeight)
                    .allowsHitTesting(false)
            }
        }
    }

    private var closeButtonRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark",
                              accessibilityTitle: "Закрыть") {
                dismiss()
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
    }
}
