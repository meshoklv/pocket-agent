//
//  EngineJournalSheet.swift
//  PocketAgent
//
//  Журнал последних событий движка: запуск, выбор расчёта (видеочип или процессор),
//  каждый ход модели и каждая ошибка с точным текстом библиотеки.
//
//  ЗАЧЕМ ЭТА СТРАНИЦА СУЩЕСТВУЕТ. Первый живой запуск модели на телефоне владельца
//  закончился красной фразой «Не получилось. Модель ответила неразборчиво» — и это
//  было ВСЁ, что приложение сообщило. Ни что за модель загружена, ни на чём она
//  считает, ни что именно сказала библиотека. Разобрать такую поломку нельзя ни с
//  телефона, ни по переписке. Теперь всё это видно здесь и уезжает в буфер обмена
//  одной кнопкой.
//
//  ⚠️ ПРИВАТНОСТЬ — ПЕРЕСМОТРЕНО 09.08.2026 ПО ПРЯМОМУ РЕШЕНИЮ ВЛАДЕЛЬЦА. Раньше здесь
//  нарочно не было ни текста задач человека, ни ответов модели, ни содержимого файлов —
//  «на всякий случай». Владелец решил иначе: продукт закрытый, приложение личное,
//  без этих данных поломку не разобрать. Теперь тут есть всё это — и страница честно
//  предупреждает об этом сверху (см. `privacyWarning` ниже), а не молчит, что уходит
//  в буфер обмена кнопкой «Скопировать всё». Собирает содержимое `RuntimeJournal`
//  (Contracts.swift) через `EngineJournal` (EngineDiagnostics.swift) — единственный
//  оставшийся фильтр там, `EngineJournalGuard`, больше не прячет содержимое, только
//  режет слишком длинную строку и честно говорит, сколько срезано.
//
//  ГРАНИЦА СЛОЁВ: стекло — только на круглой кнопке закрытия. Строки журнала —
//  обычные непрозрачные подложки Theme.*.
//

import SwiftUI
import UIKit

// MARK: - Буфер обмена

/// Единственное место приложения, которое кладёт текст в буфер обмена.
enum DiagnosticsClipboard {
    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

// MARK: - Страница журнала

struct EngineJournalSheet: View {

    @ObservedObject var app: AppViewModel

    @Environment(\.dismiss) private var dismiss

    /// Текст только что скопирован — подпись на кнопке меняется на «Скопировано».
    @State private var didCopy = false

    /// Тикает раз в секунду вместе с обновлением журнала.
    /// ⚠️ Нужен ради карточки «На чём снято»: свободная память и настройки живут не в
    /// модели экрана, и без тика строка про память замерла бы на первом показанном числе.
    @State private var refreshTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.contentSpacing) {
                Text("Что происходило с моделью")
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)

                privacyWarning
                summaryCard
                conditionsCard
                copyButton

                if app.journalEntries.isEmpty {
                    Text("Пока пусто: движок ещё ничего не делал.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    // ⚠️ Про системный журнал телефона сказано прямо: события дублируются
                    // туда КОРОЧЕ, чем здесь (см. `EngineJournal.systemLogText` в
                    // EngineDiagnostics.swift) — полный текст остаётся только в этом журнале.
                    // Наружу, в сеть, по-прежнему не уходит ничего — и умолчать об этом
                    // было бы нечестно.
                    Text("Сверху — самое свежее. Хранятся последние \(RuntimeJournal.capacity) событий "
                         + "в памяти приложения; в системный журнал телефона те же события "
                         + "идут короче — целиком остаются только здесь. В сеть не уходит ничего.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Порядок обратный: свежее событие человек ищет первым.
                    ForEach(app.journalEntries.reversed()) { entry in
                        row(for: entry)
                    }
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
        .screenBackground()
        .safeAreaInset(edge: .top, spacing: 0) { JournalTopBar { dismiss() } }
        .preferredColorScheme(.dark)
        // Пока страница открыта, журнал подтягивается сам: движок мог как раз
        // сейчас пытаться загрузить модель, и человек смотрит на это вживую.
        .task {
            while !Task.isCancelled {
                app.refreshEngineJournal()
                app.refreshRuntimeFacts()
                refreshTick &+= 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Предупреждение о полноте

    /// Честная замена прежней (уже неверной) оговорки «текст задач и ответы модели сюда
    /// не попадают» — теперь попадают, по решению владельца, и человек должен видеть это
    /// сразу, а не узнавать постфактум, кому переслал журнал кнопкой «Скопировать всё».
    /// Одной строкой, без нотаций — само предупреждение, а не разбор того, почему так.
    private var privacyWarning: some View {
        Text("В журнале — текст задач и куски файлов из этой папки: делиться им можно не со всеми.")
            .font(.footnote)
            .foregroundStyle(Theme.Colors.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Шапка: что за модель и что с ней

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.modelPresence.title)
                .font(.subheadline.bold())
                .foregroundStyle(Theme.textPrimary)

            if let detail = app.modelPresence.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = app.modelPresence.failureText {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure = app.lastEngineFailure {
                Divider()
                    .overlay(Theme.hairline)
                    .padding(.vertical, 2)
                Text("Последняя ошибка — \(failure.stage)")
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.textSecondary)
                Text(failure.technical)
                    .font(Theme.Fonts.code)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - На чём это снято: сборка, система и действующие настройки

    /// ⚠️ ЗАЧЕМ ЭТА КАРТОЧКА. Журнал без сборки и без настроек читается вслепую: непонятно,
    /// на какой версии он снят и что человек вообще выбирал. Ровно на этом 09.08.2026
    /// застрял разбор сброса памяти разговора с 32 000 на 4 096 — по журналу нельзя было
    /// сказать, что лежало в настройках в тот момент. Числа считаются на месте, при каждом
    /// показе: копия настроек однажды показала бы вчерашнюю правду.
    private var conditionsCard: some View {
        // Считаем один раз и заранее: внутри построителя видов объявлениям не место.
        let lines = conditionLines
        return VStack(alignment: .leading, spacing: 4) {
            Text("На чём снято")
                .font(.subheadline.bold())
                .foregroundStyle(Theme.textPrimary)

            // По номеру строки, а не по тексту: две одинаковые строки (например, две
            // запомненные настройки для похожих файлов) сложились бы в одну.
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index])
                    .font(Theme.Fonts.code)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Пересчитывается раз в секунду вместе с журналом — вслед за `refreshTick`.
    /// Дороже этого здесь ничего нет: пара чисел из настроек и один вопрос про память.
    private var conditionLines: [String] {
        _ = refreshTick
        return EngineDiagnostics.headerLines()
    }

    private var copyButton: some View {
        Button {
            // ⚠️ Шапка приклеивается ЗДЕСЬ, а не в тексте от экрана: разбор всегда
            // начинается с вопроса «какая это сборка и какие были настройки».
            DiagnosticsClipboard.copy(
                EngineDiagnostics.fullReport(appendingBody: app.diagnosticsReport)
            )
            didCopy = true
            // Подпись возвращается сама: постоянное «Скопировано» врало бы
            // при следующем открытии страницы.
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Скопировано" : "Скопировать всё",
                  systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(Theme.Fonts.sectionTitle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Metrics.contentSpacing)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Theme.Colors.accent)
    }

    // MARK: - Одна строка журнала

    private func row(for entry: RuntimeEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.timeText)
                    .font(Theme.Fonts.counter)
                    .foregroundStyle(Theme.Colors.textTertiary)
                Text(entry.text)
                    .font(.footnote)
                    .foregroundStyle(color(for: entry.kind))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let detail = entry.detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.Fonts.code)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Metrics.toolRowPaddingHorizontal)
        .padding(.vertical, Theme.Metrics.toolRowPaddingVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.bubbleTool,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.controlCorner, style: .continuous))
    }

    private func color(for kind: RuntimeEventKind) -> Color {
        switch kind {
        case .failure: return Theme.removed
        case .backend: return Theme.Colors.accent
        case .turn:    return Theme.textPrimary
        case .engine:  return Theme.textPrimary
        case .note:    return Theme.textSecondary
        }
    }
}

// MARK: - Шапка страницы

/// Крестик справа сверху — тот же жест закрытия, что и у остальных страниц-шитов.
/// Тип виден только внутри этого файла: одноимённые шапки уже есть в других файлах,
/// а два одинаковых ИМЕНИ, видимых всему модулю, — это провал сборки.
private struct JournalTopBar: View {

    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark",
                              accessibilityTitle: "Закрыть",
                              action: onClose)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
        .padding(.bottom, Theme.Metrics.topFadeHeight)
        .background(alignment: .top) { scrim }
        .accessibilitySortPriority(1)
    }

    /// Подложка — ТОЛЬКО для iOS 17–18.
    /// ⚠️ На iOS 26 своего фона позади стеклянной кнопки быть не должно: стеклу нечего
    /// сэмплить, кроме этого прямоугольника, и оно становится плоской тёмной таблеткой.
    @ViewBuilder
    private var scrim: some View {
        if !GlassAvailability.isLiquidGlassAvailable {
            VStack(spacing: 0) {
                Theme.background
                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: Theme.Metrics.topFadeHeight)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}
