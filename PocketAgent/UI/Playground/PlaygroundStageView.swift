//
//  PlaygroundStageView.swift
//  PocketAgent
//
//  Сама сцена: страница во весь экран и плавающие стеклянные кнопки над ней.
//
//  ⚠️ ЗДЕСЬ СТЕКЛО УМЕСТНО, И ЭТО ЕДИНСТВЕННОЕ МЕСТО ПЛОЩАДКИ, ГДЕ ОНО ЕСТЬ.
//  Правило дизайна разрешает стекло ровно на плавающем слое НАД контентом
//  (docs/LIQUID-GLASS.md). Кнопки «Закрыть», «Заново» и полоска с ошибкой висят
//  поверх чужой страницы — это и есть тот самый слой.
//
//  ⚠️ ПОЧЕМУ ПОЛОСКА С ОШИБКОЙ ВСЁ-ТАКИ ЕСТЬ, ХОТЯ СТРАНИЦУ УЖЕ ПРОВЕРИЛИ.
//  Проверка до показа ловит то, что случается за первые пару секунд. Игра может
//  сломаться на третьем ходу, когда человек уже играет, — и вот тогда полоска
//  и кнопка «Починить» единственный способ не остаться один на один с поломкой.
//

import SwiftUI

struct PlaygroundStageView: View {

    let item: PlaygroundItem
    let rootURL: URL?
    /// Отдать ошибки помощнику как задачу.
    let onFix: ([PlaygroundIssue]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reloadToken = 0
    @State private var issues: [PlaygroundIssue] = []
    @State private var isIssueBarShown = false
    /// ⚠️ СПОКОЙНАЯ СТРОКА ПРО ИНТЕРНЕТ ГАСНЕТ САМА. Кнопки у неё нет и крестика тоже,
    /// поэтому раньше она занимала низ игры до конца сеанса — ровно «текст, нужный один
    /// раз, но висящий всегда», за который владелец ругает. Сказать надо один раз.
    @State private var isNetworkLineShown = true
    @State private var networkLineTask: Task<Void, Never>?
    /// Человек уже прочитал разбор и сам сказал «показать как есть» — не встречать
    /// его той же полоской в первую же секунду.
    var alreadyWarned: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let rootURL {
                PlaygroundWebView(fileURL: item.url,
                                  rootURL: rootURL,
                                  reloadToken: reloadToken,
                                  onIssue: note)
                    .ignoresSafeArea()
            } else {
                Text("Папка не выбрана. Откройте её на вкладке «Папки».")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding()
            }

            VStack {
                topBar
                Spacer()
                if isIssueBarShown, !breakages.isEmpty {
                    issueBar
                        .padding(.horizontal, Theme.Metrics.floatingBarSideInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if isNetworkLineShown,
                          let network = issues.first(where: { $0.kind == .blockedNetwork || $0.kind == .externalResource }) {
                    // ⚠️ ОТДЕЛЬНАЯ СПОКОЙНАЯ СТРОКА, БЕЗ КНОПКИ «ПОЧИНИТЬ».
                    // Страница просит что-то из интернета, а его в приложении нет
                    // и не будет. Чинить тут нечего — это не поломка страницы,
                    // а наше устройство. Отправлять такое помощнику нельзя: он
                    // открывает файл, видит, что всё правильно, и отвечает
                    // «ошибок нет» — ровно этот круг владелец и поймал 10.09.2026.
                    networkLine(network)
                        .padding(.horizontal, Theme.Metrics.floatingBarSideInset)
                        .transition(.opacity)
                }
            }
            // ⚠️ БОКОВОЙ ОТСТУП — ТОЛЬКО У НИЖНИХ ПОЛОСОК, НЕ У ВСЕГО СЛОЯ.
            // `GlassCircleButtonRow` уже вставляет свои 16 точек внутри себя (так им
            // пользуется чат). Внешний отступ поверх складывался с ним в 32, и круглые
            // кнопки площадки стояли заметно ближе к центру, чем те же кнопки в чате.
            // Верх и низ — по общей мерке плавающего слоя, а не по полю экрана:
            // 20 точек сверху опускали «Закрыть» ниже, чем во всём остальном приложении.
            .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
            .padding(.bottom, Theme.Metrics.floatingBarBottomInset)
        }
        // ⚠️ ОСТАЁТСЯ СТРАХОВКОЙ, ХОТЯ ОБА НАЖАТИЯ ТЕПЕРЬ И САМИ ЗАВЁРНУТЫ В ДВИЖЕНИЕ.
        // Если завтра флаг погасят из третьего места и забудут обёртку — полоска всё
        // равно уедет плавно, а не мигнёт. Движение одно и то же, так что вреда нет.
        .animation(Theme.Motion.gentle, value: isIssueBarShown)
    }

    // MARK: - Плавающий слой

    /// ⚠️ Кнопки — через `GlassCircleButton`/`GlassCircleButtonRow`, а не своим стеклом.
    /// Так во всём приложении, и не по привычке: компонент уже решает общий контейнер
    /// (два стекла рядом без него дают артефакты), диаметр под крупный системный шрифт
    /// и обход бага формы у выпуклой кнопки. Свой `.adaptiveGlassEffect` здесь терял
    /// всё это разом.
    private var topBar: some View {
        GlassCircleButtonRow {
            // ⚠️ «Страницу», а не «площадку»: кнопка закрывает просмотр и возвращает
            // на площадку, а не наоборот. Незрячий человек слышит только эту подпись —
            // для него неточное слово это прямая ложь о том, куда он попадёт.
            GlassCircleButton(systemImage: "xmark",
                              accessibilityTitle: "Закрыть страницу") {
                dismiss()
            }
        } trailing: {
            GlassCircleButton(systemImage: "arrow.clockwise",
                              accessibilityTitle: "Запустить заново") {
                // ⚠️ Гасим тем же движением, каким показывали. Полоска про интернет
                // держится на списке жалоб, а не на своём флаге, — без обёртки она
                // исчезала рывком, хотя гаснуть по сроку умела плавно.
                withAnimation(Theme.Motion.gentle) {
                    issues = []
                    isIssueBarShown = false
                }
                reloadToken += 1
            }
        }
    }

    /// ⚠️ Кнопка ВНУТРИ полоски — БЕЗ своего стекла. Стекло уже несёт сама полоска,
    /// а стекло поверх стекла — брак: движок не умеет сэмплить собственный материал.
    private var issueBar: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.contentSpacing) {
            // ⚠️ ОДНА СТРОКА ВМЕСТО ДВУХ. Раньше сверху стоял заголовок «Страница
            // сломалась», а под ним — «в коде страницы ошибка, сама она не запустится».
            // Это одно и то же, сказанное дважды: значок беды уже говорит, что сломалось,
            // а по делу говорит только вторая строка. Её и оставляем.
            //
            // ⚠️ Человеку — человеческими словами. Сырую строку браузера
            // («Uncaught ReferenceError…») читает помощник, а не он.
            HStack(alignment: .top, spacing: Theme.Metrics.contentSpacing) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Colors.warning)
                Text(breakages.first?.lineForHuman ?? "")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.glassTextPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(Theme.Motion.gentle) { isIssueBarShown = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Colors.glassTextSecondary)
                        .frame(width: Theme.Metrics.minimumTapTarget,
                               height: Theme.Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Скрыть"))
            }

            Button {
                onFix(breakages)
                dismiss()
            } label: {
                Label("Починить", systemImage: "wrench.and.screwdriver")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.glassTextPrimary)
                    .frame(maxWidth: .infinity, minHeight: Theme.Metrics.minimumTapTarget)
                    // ⚠️ Без этого палец попадал только по самим буквам «Починить»:
                    // у кнопки в стиле `.plain` нет заливки, а растянутая рамка сама
                    // по себе нажатие не ловит. Промах по такой кнопке выглядит как
                    // «приложение не отвечает».
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Metrics.cardPadding)
        .adaptiveGlassEffect(in: RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner,
                                                  style: .continuous))
    }

    private func networkLine(_ issue: PlaygroundIssue) -> some View {
        HStack(spacing: Theme.Metrics.contentSpacing) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Theme.Colors.glassTextSecondary)
            Text(issue.lineForHuman)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.glassTextSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, Theme.Metrics.cardPadding)
        .padding(.vertical, Theme.Metrics.contentSpacing)
        .adaptiveGlassEffect()
    }

    // MARK: - Разбор бед

    private var breakages: [PlaygroundIssue] { issues.filter(\.isBreakage) }

    /// ⚠️ Одинаковые жалобы не копим: страница в цикле может прислать одну и ту же
    /// ошибку сотню раз, и полоска станет бесполезной простынёй.
    private func note(_ issue: PlaygroundIssue) {
        guard !issues.contains(where: { $0.kind == issue.kind && $0.text == issue.text }) else { return }
        // ⚠️ ПОЯВЛЕНИЕ — ТОЖЕ ДВИЖЕНИЕ, А НЕ ТОЛЬКО УГАСАНИЕ. Строка про интернет
        // показывается не по своему флагу, а по тому, что в списке жалоб появилась
        // нужная запись, — а список менялся вне анимации, и строка возникала рывком
        // поверх чужой страницы. Гаснуть по сроку она умела плавно (см. ниже), и разница
        // была видна глазом. Одно движение `gentle` — то же, каким живёт вся площадка.
        withAnimation(Theme.Motion.gentle) {
            issues.append(issue)
            if issue.isBreakage, !alreadyWarned { isIssueBarShown = true }
            if issue.kind == .blockedNetwork || issue.kind == .externalResource {
                isNetworkLineShown = true
            }
        }
        if issue.kind == .blockedNetwork || issue.kind == .externalResource {
            hideNetworkLineLater()
        }
    }

    /// Погасить строку про интернет через несколько секунд после последней жалобы.
    private func hideNetworkLineLater() {
        networkLineTask?.cancel()
        networkLineTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7 * 1_000_000_000)
            // ⚠️ Отменённое ожидание срабатывает НЕМЕДЛЕННО, а не молчит. Без этой
            // проверки строка гасла бы сразу при следующей жалобе (промах 10.09.2026,
            // из-за него невидимая проверка площадки была слепой).
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Motion.gentle) { isNetworkLineShown = false }
        }
    }
}

// MARK: - Разбор перед показом

/// Страница проверена ДО показа и оказалась сломанной. Показываем не белый экран,
/// а разбор и одно понятное действие.
///
/// ⚠️ Владелец дословно: «ваще не показывать плейграунд до того момента пока там
/// не будет ошибок». Полностью прятать страницу мы всё же не стали, и вот почему:
/// человек имеет право посмотреть на свою поломку сам, а насильно уведённый экран
/// читается как «приложение решило за меня». Поэтому главная кнопка — «Починить»,
/// а «Всё равно показать» стоит рядом второстепенной.
struct PlaygroundRepairSheet: View {

    let item: PlaygroundItem
    let issues: [PlaygroundIssue]
    let onFix: () -> Void
    let onShowAnyway: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var breakages: [PlaygroundIssue] { issues.filter(\.isBreakage) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardPadding) {
            HStack(spacing: Theme.Metrics.contentSpacing) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.Colors.accent)
                Text("«\(item.name)» починить не вышло")
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metrics.contentSpacing) {
                    ForEach(breakages) { issue in
                        HStack(alignment: .top, spacing: Theme.Metrics.contentSpacing) {
                            Circle()
                                .fill(Theme.Colors.warning)
                                .frame(width: 6, height: 6)
                                .padding(.top, 6)
                            Text(issue.lineForHuman)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(Theme.Metrics.cardPadding)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Metrics.controlCorner, style: .continuous)
                        .fill(Theme.Colors.surfaceRaised)
                }
            }
            .frame(maxHeight: 220)

            Button(action: onFix) {
                Label("Попробовать ещё раз", systemImage: "wand.and.stars")
                    .font(Theme.Fonts.secondary.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            // ⚠️ На СПЛОШНОЙ подложке шита стекло не к месту: сэмплить ему нечего,
            // а два стеклянных элемента рядом ещё и требуют общего контейнера.
            // Канон приложения для такой пары — обычные кнопки (см. карточку правки).
            .buttonStyle(.borderedProminent)
            .tint(Theme.Colors.accent)
            .controlSize(.large)

            Button("Всё равно показать", action: onShowAnyway)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Metrics.sectionSpacing)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.Colors.surface)
    }
}
