//
//  ModelsOnPhoneList.swift
//  PocketAgent
//
//  Узкий список того, что УЖЕ лежит на телефоне. Строка на модель: имя, одна пометка
//  («работает сейчас» или «лежит») и размер. Плюс итог сверху: сколько всего файлов
//  и сколько они занимают.
//
//  ⚠️ ЗАЧЕМ ОН ПОЯВИЛСЯ (слова владельца, 09.08.2026): «создай место, где будет список
//  со всеми моделями, которые скачаны, список узкий, чтоб было быстро понятно, что
//  скачано». Раньше ответ на этот вопрос приходилось собирать по кускам: карточка
//  «Нашли модель на телефоне» показывала только НОВЫЕ файлы человека, метка «работает
//  сейчас» жила в списке того, что можно поставить, а сколько всё это занимает,
//  говорила одна строка про удаление внизу экрана. Одним взглядом охватить было нечего.
//
//  ⚠️ ВТОРОГО ИСТОЧНИКА ПРАВДЫ ЗДЕСЬ НЕТ. Список целиком строится по `app.foundOptions` —
//  тому же самому обходу папок (`ModelDiscovery`), по которому работает весь экран.
//  Свой обход диска, свои размеры и свой кэш завести было бы проще всего и хуже всего:
//  два списка неизбежно разошлись бы, и человек читал бы на одном экране две правды.
//
//  ⚠️ ТЕПЕРЬ ОТСЮДА МОЖНО ПОСТАВИТЬ МОДЕЛЬ, И ЭТО НАРОЧНО (10.08.2026).
//  Раньше «Использовать» жило в отдельной большой карточке «Нашли модель на телефоне»
//  выше по экрану — и один и тот же файл человек видел ДВАЖДЫ: строкой здесь и карточкой
//  там. Карточка убрана, действие переехало в строку: у каждой не работающей сейчас
//  модели строка нажимается и ставит её. Один список — один ответ на вопрос
//  «что лежит на телефоне и что с этим можно сделать».
//
//  ⚠️ МОДЕЛЬ, КОТОРУЮ ДВИЖОК НЕ ПОДНИМЕТ, ВИДНО ДО НАЖАТИЯ (10.08.2026). Раньше такая
//  строка вела себя как обычная: человек жал, ждал и получал отказ — при том, что
//  ответ был известен заранее, он написан в описании самой модели. Теперь у неё стоит
//  красный знак и пометка «не запустится», строка не нажимается, а причина занимает
//  ту же одну строку, в которой у остальных стоит оговорка про память. Ни одной новой
//  строки список от этого не получил.
//
//  Что список НЕ делает:
//    • не удаляет файлы, которые человек положил сам. Приложение чужие файлы не трогает —
//      они видны и убираются в «Файлах». Своё удаляем, чужое нет;
//    • не спрашивает подтверждения смены модели сам — вопрос задаёт экран моделей
//      (у него одного все окна этого экрана, иначе они спорят между собой).
//
//  Дизайн: обычная карточка со строками через волосяную черту. Стекла нет — оно живёт
//  только на плавающем слое (docs/LIQUID-GLASS.md).
//

import Foundation
import SwiftUI

struct ModelsOnPhoneList: View {

    @ObservedObject var app: AppViewModel

    /// Спросить про удаление установленной модели.
    ///
    /// ⚠️ Своего окна подтверждения здесь нет намеренно: окно «Удалить модель
    /// с телефона?» уже описано на экране моделей вместе со всеми остальными, а два
    /// таких окна на одном экране спорят между собой — открывается то, что описано
    /// последним (docs/UI-CONTRACT.md).
    let askToDelete: () -> Void

    /// Поставить эту модель. Экран моделей оборачивает вызов вопросом «Сменить модель?»,
    /// когда сменой закрывается начатый разговор.
    let use: (ModelOption) -> Void

    /// Прямо сейчас идёт загрузка, установка или уборка.
    ///
    /// ⚠️ Список при этом ОСТАЁТСЯ НА ЭКРАНЕ — он и раньше был единственным местом, где
    /// видно, что уже лежит на телефоне, а прятать его во время загрузки было главной
    /// жалобой владельца. Нажатия — глушим: ставить вторую модель поверх начатой
    /// установки нечего.
    let isBusy: Bool

    /// Узкая колонка под значок: список должен читаться строчками, а не карточками.
    @ScaledMetric(relativeTo: .footnote) private var iconGutter: CGFloat
        = Theme.Metrics.compactIconGutterWidth

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                heading

                VStack(spacing: 0) {
                    ForEach(rows) { option in
                        row(option)
                        if option.id != lastRowID {
                            divider
                        }
                    }
                }
                .cardSurface()

                if hasPersonalFiles {
                    Text("Свои файлы приложение не удаляет — их можно убрать в «Файлах».")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.horizontal, Theme.Metrics.cardPadding)
                }
            }
        }
    }

    // MARK: - Что показываем

    /// Все файлы моделей, которые приложение видит на телефоне.
    ///
    /// ⚠️ Работающая модель идёт первой: на вопрос «что скачано» человек почти всегда
    /// хочет ответ «а какая из них сейчас в деле» — и не должен искать её глазами.
    private var rows: [ModelOption] {
        let all = app.foundOptions
        return all.filter { app.isRunningModel($0) } + all.filter { !app.isRunningModel($0) }
    }

    private var lastRowID: String? { rows.last?.id }

    /// Сколько всего занято. Складываем размеры тех самых файлов, что показаны
    /// строками, — итог всегда сходится с тем, что человек видит над ним.
    private var totalBytes: Int64 {
        rows.reduce(Int64(0)) { $0 + $1.byteSize }
    }

    private var hasPersonalFiles: Bool {
        rows.contains { $0.origin == .foundInAppFolder }
    }

    // MARK: - Заголовок с итогом

    private var heading: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(Theme.textSecondary)
            Text("Модели на телефоне")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(totalText)
                .font(Theme.Fonts.counter)
                .foregroundStyle(Theme.textSecondary)
        }
        // По внутреннему краю карточки — та же колонка, что и у остального текста.
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .accessibilityElement(children: .combine)
    }

    /// «3 файла · 6,2 ГБ»
    private var totalText: String {
        "\(rows.count) \(Self.fileWord(rows.count)) · \(HumanFormat.bytes(totalBytes))"
    }

    // MARK: - Одна строка

    private func row(_ option: ModelOption) -> some View {
        let isRunning = app.isRunningModel(option)
        let verdict = deadEndReason(option)
        // Работающую модель ставить заново нечего — её строка просто рассказывает.
        // Модель, которую движок не поднимет, ставить тоже нечего: нажатие кончилось бы
        // ожиданием и отказом, а ответ известен заранее.
        let canUse = !isRunning && !isBusy && verdict == nil
        return HStack(spacing: 10) {
            // ⚠️ Не кнопка с `.disabled`, а РАЗНЫЕ строки: погашенная кнопка красит свой
            // текст в серый, и работающая модель — единственная строка, которая нажиматься
            // и не должна, — выглядела бы выключенной, то есть сломанной.
            Group {
                if canUse {
                    Button { use(option) } label: {
                        rowBody(option, isRunning: isRunning, canUse: true, verdict: nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Поставить эту модель")
                } else {
                    rowBody(option, isRunning: isRunning, canUse: false, verdict: verdict)
                }
            }
            // Строка читается вслух одним куском — кнопка удаления в неё не входит,
            // иначе до неё было бы не добраться голосом.
            .accessibilityElement(children: .combine)

            deleteButton(option)
        }
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, 4)
    }

    private func rowBody(_ option: ModelOption,
                         isRunning: Bool,
                         canUse: Bool,
                         verdict: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: verdict != nil
                  ? "xmark.octagon"
                  : (isRunning ? "checkmark.circle.fill" : "shippingbox"))
                .font(.footnote)
                .frame(minWidth: iconGutter, alignment: .leading)
                .foregroundStyle(verdict != nil ? Theme.removed
                                 : (isRunning ? Theme.apply : Theme.Colors.textTertiary))

            VStack(alignment: .leading, spacing: 2) {
                // Имя в одну строку: список ценен тем, что его видно целиком.
                // Обрезаем середину — конец имени файла у моделей самый говорящий.
                Text(option.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(verdict != nil ? "не запустится"
                     : markText(for: option, isRunning: isRunning))
                    .font(.caption)
                    .foregroundStyle(verdict != nil ? Theme.removed
                                     : (isRunning ? Theme.apply : Theme.Colors.textTertiary))
                    .lineLimit(1)

                // Одна оговорка на строку — и приговор старше прикидки памяти.
                // «Может не хватить памяти» у модели, которая не запустится НИКОГДА, —
                // это не предупреждение, а увод в сторону: человек начнёт освобождать
                // место, и оно ничего не изменит.
                if let verdict {
                    Text(verdict)
                        .font(.caption)
                        .foregroundStyle(Theme.removed)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let warning = warningText(option) {
                    // Про память и видеочип молчать нельзя: у такой модели нет запасного
                    // пути, и человек должен знать об этом ДО того, как её поставит.
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Text(option.sizeText)
                .font(Theme.Fonts.counter)
                .foregroundStyle(Theme.textSecondary)

            // Птичка «сюда можно нажать» — обычный признак действующей строки в iOS.
            // Без неё строка выглядит как надпись, и способ поставить лежащую модель
            // человек просто не нашёл бы.
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.textTertiary)
                .opacity(canUse ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Theme.Metrics.minimumTapTarget)
        .contentShape(Rectangle())
    }

    // MARK: - Модель, которую движок не поднимет

    /// Почему эта модель не запустится. nil — приговора нет, строку можно нажимать.
    ///
    /// ⚠️ СПРАШИВАЕМ ДО НАЖАТИЯ, А НЕ ПОСЛЕ. Ответ известен заранее: как модель устроена,
    /// написано в её же описании внутри папки, и это килобайты. Раньше строка молчала,
    /// человек жал, ждал подъёма модели и получал отказ — потраченное впустую время
    /// ровно там, где тратить было нечего.
    ///
    /// ⚠️ ДВА ИСТОЧНИКА, И ВТОРОЙ — НЕ ПЕРЕСТРАХОВКА. Движок помнит свои отказы между
    /// запусками, но помнит их по опознавателю модели, а строка списка зовётся путём
    /// файла внутри приложения — совпадают они не всегда. Поэтому если памяти движка
    /// сказать нечего, читаем описание модели сами.
    private func deadEndReason(_ option: ModelOption) -> String? {
        if let remembered = ModelDeadEnds.shared.reason(forModelID: option.id) {
            return Self.withoutHeadline(remembered)
        }
        guard let type = ModelFolderTypes.shared.modelType(atContainerPath: option.id),
              MLXArchitectures.cachedVerdict(forModelType: type).isNotRunnable else { return nil }
        return MLXArchitectures.shortText(forModelType: type)
    }

    /// Приговор без общей первой фразы («Эта модель устроена иначе — приложение её
    /// не запустит»): ровно это уже сказано пометкой «не запустится» строкой выше,
    /// и напечатанное дважды подряд читается как заедание.
    private static func withoutHeadline(_ reason: String) -> String {
        let headline = MLXArchitectures.notRunnableHeadline
        guard reason.hasPrefix(headline) else { return reason }
        let rest = reason.dropFirst(headline.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? reason : rest
    }

    /// Одна короткая оговорка про модель — или ничего.
    ///
    /// ⚠️ Строк тут ровно одна, хотя оговорок у модели может быть две: список узкий
    /// нарочно («чтоб было быстро понятно, что скачано»). Память важнее видеочипа —
    /// от неё зависит, запустится модель вообще или нет.
    private func warningText(_ option: ModelOption) -> String? {
        switch option.memory {
        case .tight(let text):  return text
        case .tooBig(let text): return text
        case .fits, .unknown:
            if option.requiresGPU {
                return "Считает только на видеочипе — на обычный расчёт перейти не умеет."
            }
            if !option.isKnown {
                return "Модель нам незнакома — проверить её мы не смогли."
            }
            return nil
        }
    }

    /// Одна пометка на строку, и не больше: что с этим файлом.
    ///
    /// ⚠️ Про свой файл говорим отдельно не ради подробности, а ради кнопки: у него
    /// нет корзины, и без пометки её отсутствие выглядело бы как поломка.
    private func markText(for option: ModelOption, isRunning: Bool) -> String {
        if isRunning { return "работает сейчас" }
        switch option.origin {
        case .foundInAppFolder: return "лежит в вашей папке"
        case .bundled:          return "внутри приложения"
        case .installed:        return "лежит"
        case .catalog:          return "лежит"
        }
    }

    /// Корзина есть только у того, что приложение скачало или поставило себе само.
    ///
    /// ⚠️ Файл человека приложение не удаляет: он мог положить его и для другого
    /// приложения. Вшитую в сборку модель удалить нечем — её нет на диске отдельно.
    @ViewBuilder
    private func deleteButton(_ option: ModelOption) -> some View {
        if option.origin == .installed {
            Button(role: .destructive) {
                askToDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.footnote)
                    .frame(width: Theme.Metrics.minimumTapTarget,
                           height: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.removed)
            // Пока идёт уборка или установка, нажатие всё равно ни к чему не приведёт,
            // а кнопка, которая молча ничего не делает, читается как сломанная.
            .disabled(app.isDeletingModel || app.isImportingModel)
            .accessibilityLabel("Удалить \(option.displayName) с телефона")
        }
    }

    // MARK: - Мелочи

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Theme.Metrics.hairlineWidth)
            .padding(.leading, Theme.Metrics.cardPadding)
    }

    /// «1 файл» · «2 файла» · «5 файлов». Иначе на экране получается «3 файл».
    /// Одиннадцать–четырнадцать выведены отдельно: они ведут себя не как один-четыре.
    private static func fileWord(_ count: Int) -> String {
        let hundredRemainder = count % 100
        if hundredRemainder >= 11 && hundredRemainder <= 14 { return "файлов" }
        switch count % 10 {
        case 1:       return "файл"
        case 2, 3, 4: return "файла"
        default:      return "файлов"
        }
    }
}

// MARK: - Как устроены папки, которые уже лежат на телефоне

/// Что написано в описании модели, лежащей по такому пути внутри приложения.
///
/// ⚠️ ЗАЧЕМ ЗАПОМИНАТЬ. Ответ лежит на диске, а тело строки SwiftUI пересчитывает
/// постоянно — каждый шаг полосы загрузки перерисовывает весь экран. Лезть за файлом
/// на диск на каждом кадре нельзя, а описание в уже лежащей папке не меняется.
/// Пустую строку («описания там нет») помним тоже: иначе у файла Google, у которого
/// такого описания и не бывает, мы искали бы его снова и снова.
///
/// ⚠️ Замок, а не главный поток: сюда ходит рисование экрана, и ждать ему нечем.
private final class ModelFolderTypes: @unchecked Sendable {

    static let shared = ModelFolderTypes()

    private let lock = NSLock()
    private var byPath: [String: String] = [:]

    /// Устройство модели, лежащей по этому пути. nil — узнать не по чему.
    func modelType(atContainerPath path: String) -> String? {
        guard !path.isEmpty else { return nil }

        lock.lock()
        let known = byPath[path]
        lock.unlock()
        if let known { return known.isEmpty ? nil : known }

        let type = MLXArchitectures.modelType(
            inFolder: ModelStorage.url(forContainerRelativePath: path)
        )

        lock.lock()
        byPath[path] = type ?? ""
        lock.unlock()
        return type
    }
}
