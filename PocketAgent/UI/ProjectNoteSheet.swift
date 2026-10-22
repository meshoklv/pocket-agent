//
//  ProjectNoteSheet.swift
//  PocketAgent
//
//  Страница «Заметка о проекте»: человек пишет текст, видит карточку подтверждения
//  и жмёт «Применить». Открывается из раздела «Папки».
//
//  ⚠️ ДВА ШАГА, А НЕ ОДИН, И ЭТО ГЛАВНОЕ. Кнопка «Сохранить» ничего не сохраняет —
//  она показывает ТУ ЖЕ САМУЮ карточку `ApprovalCard`, что и любая правка от модели:
//  какой файл, новый он или нет, сколько строк прибавится, что именно меняется.
//  На диск текст попадает ровно из одного места — `onApprove` этой карточки.
//  Своей «облегчённой» записи для заметки нет и быть не должно: правило «без нажатия
//  ничего не пишется» не знает исключений, даже для нашего собственного файла.
//
//  ⚠️ Состояние страницы (черновик, дифф, «пишу») живёт ЗДЕСЬ, а не в AppViewModel:
//  оно нужно ровно пока страница открыта и исчезает вместе с ней.
//

import SwiftUI

struct ProjectNoteSheet: View {

    /// Корень папки проекта.
    let root: URL
    /// Что лежало в заметке, когда страницу открывали. Пусто — заметки ещё нет.
    let initialText: String
    /// Заметка записана: разделу «Папки» пора перечитать её с диска.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    /// Показанная карточка. nil — человек ещё правит текст.
    @State private var action: PendingAction?
    /// Идёт запись на диск.
    @State private var isApplying = false
    /// Честная строка о том, почему не вышло. nil — говорить нечего.
    @State private var problem: String?

    init(root: URL, initialText: String, onSaved: @escaping () -> Void) {
        self.root = root
        self.initialText = initialText
        self.onSaved = onSaved
        _text = State(initialValue: initialText.isEmpty ? ProjectNote.template : initialText)
    }

    var body: some View {
        Group {
            if let action {
                confirmStage(action)
            } else {
                editStage
            }
        }
        .screenBackground()
        .safeAreaInset(edge: .top, spacing: 0) { NoteSheetTopBar { dismiss() } }
        .preferredColorScheme(.dark)
    }

    // MARK: - Шаг 1: правим текст

    private var editStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Заметка о проекте")
                .font(Theme.Fonts.screenTitle)
                .foregroundStyle(Theme.textPrimary)

            Text("Помощник читает её перед каждой задачей. Коротко: что за проект и чего не трогать.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                // Свой фон у поля ввода на тёмной теме белый — его надо убрать,
                // иначе посреди чёрного экрана светится прямоугольник.
                .scrollContentBackground(.hidden)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.Colors.accent)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .cardSurface()
                .accessibilityLabel("Текст заметки о проекте")

            if let problem {
                problemRow(problem)
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.bottom, 12)
        // Кнопки через safeAreaInset: так они поднимаются над клавиатурой сами,
        // а не прячутся под ней вместе с половиной поля ввода.
        .safeAreaInset(edge: .bottom, spacing: 0) { editButtons }
    }

    private var editButtons: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Text("Отмена")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .cardSurface(cornerRadius: Theme.Metrics.controlCorner)

            Button { prepareCard() } label: {
                Text("Сохранить")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.textOnAccent)
            .background(Theme.Colors.accent,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlCorner,
                                             style: .continuous))
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.vertical, 12)
        .background(Theme.background)
    }

    // MARK: - Шаг 2: карточка подтверждения

    private func confirmStage(_ action: PendingAction) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ApprovalCard(action: action,
                             isApplying: isApplying,
                             onApprove: { apply(action) },
                             onReject: { self.action = nil })
                if let problem {
                    problemRow(problem)
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.bottom, Theme.Metrics.sheetBottomClearance)
        }
        .scrollIndicators(.hidden)
        .adaptiveScrollEdge(.soft, for: [.top, .bottom])
    }

    // MARK: - Дело

    /// Собрать дифф и показать карточку. На диск при этом не попадает ни байта.
    @MainActor
    private func prepareCard() {
        problem = nil
        let root = self.root
        let newText = text
        Task {
            do {
                // Диск может отвечать медленно (iCloud, Working Copy) — не на главном потоке.
                let diff = try await Task.detached(priority: .userInitiated) {
                    try ProjectNote.plan(text: newText, root: root)
                }.value

                // Человек ничего не поменял. Показывать пустую карточку и писать файл
                // ради нуля изменений — обман: «Применить» выглядело бы как работа.
                guard !diff.isIdenticalToDisk else {
                    problem = "Ничего не изменилось — записывать нечего."
                    return
                }

                let invocation = ToolInvocation(rawName: ToolKind.writeFile.rawValue,
                                                callID: "",
                                                arguments: ["path": ProjectNote.fileName,
                                                            "content": diff.newText])
                action = PendingAction(invocation: invocation,
                                       preview: .diff(diff),
                                       title: AgentPrompt.actionTitle(for: invocation,
                                                                      kind: .writeFile))
            } catch {
                problem = Self.describe(error)
            }
        }
    }

    /// ЕДИНСТВЕННОЕ место этого файла, откуда заметка попадает на диск.
    @MainActor
    private func apply(_ action: PendingAction) {
        guard !isApplying, case .diff(let diff) = action.preview else { return }
        isApplying = true
        problem = nil
        let root = self.root
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ProjectNote.save(diff, root: root)
                }.value
                isApplying = false
                onSaved()
                dismiss()
            } catch {
                isApplying = false
                // Частый и понятный случай: файл поменяли из другого приложения, пока
                // человек читал карточку. Дифф устарел — возвращаем к правке, чтобы
                // «Применить» не затирало чужую работу вслепую.
                self.action = nil
                problem = Self.describe(error)
            }
        }
    }

    private func problemRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warning)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Тот же переводчик ошибок, что и на остальных экранах: наши ошибки уже написаны
    /// по-русски, системные превращаются в человеческую фразу.
    private static func describe(_ error: Error) -> String {
        SystemErrorText.russian(for: error)
    }
}

// MARK: - Шапка страницы

/// Крестик справа сверху — тот же жест закрытия, что и на других отдельных страницах.
///
/// ⚠️ Тип виден только внутри этого файла: точно такая же шапка живёт в ApprovalCard.swift,
/// и два одинаковых имени в одном модуле — это провал сборки.
private struct NoteSheetTopBar: View {

    let onClose: () -> Void

    private var fadeHeight: CGFloat { Theme.Metrics.topFadeHeight }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            GlassCircleButton(systemImage: "xmark",
                              accessibilityTitle: "Закрыть",
                              action: onClose)
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.top, Theme.Metrics.floatingBarPaddingVertical)
        .padding(.bottom, fadeHeight)
        .background(alignment: .top) { scrim }
        .accessibilitySortPriority(1)
    }

    /// Подложка — ТОЛЬКО для iOS 17–18: на iOS 26 своего фона позади стекла быть не должно.
    @ViewBuilder
    private var scrim: some View {
        if !GlassAvailability.isLiquidGlassAvailable {
            VStack(spacing: 0) {
                Theme.background
                LinearGradient(colors: [Theme.background, Theme.background.opacity(0)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: fadeHeight)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}
