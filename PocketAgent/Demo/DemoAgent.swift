//
//  DemoAgent.swift
//  PocketAgent / Demo
//
//  Поддельная сессия агента: отдаёт заранее заготовленные снимки состояния вместо
//  настоящего цикла «модель → инструмент → подтверждение».
//
//  ⚠️ ЯДРО ПРОДУКТА НЕ ПОДМЕНЕНО. Карточка правки здесь тоже ждёт нажатия: пока
//  человек не нажал «Применить», состояние не двигается. Разница ровно одна —
//  применённая правка никуда не записывается, потому что диска в этом сценарии нет.
//
//  Ни LiteRT-LM, ни файловой системы, ни сети этот файл не касается.
//

// ⚠️ ВЕСЬ ФАЙЛ — ТОЛЬКО ОТЛАДОЧНАЯ СБОРКА.
// Демонстрационный режим нужен ради снимков экранов на симуляторе, и в сборку
// для магазина ему попадать незачем: там это мёртвый код и выдуманные тексты.
// Конвейер снимков собирает конфигурацию Debug, поэтому съёмке скобки не мешают.
#if DEBUG

import Foundation
import Combine

@MainActor
final class DemoAgent: AgentControlling {

    @Published private(set) var snapshot: AgentSnapshot

    /// Какой экран снимаем — от этого зависит только длина стартовой ленты.
    private let screen: DemoScreen

    /// Номер текущего хода. Нужен ровно затем же, зачем и настоящей сессии:
    /// после «Стоп» доигрывающий сценарий не должен переписать состояние.
    private var runID = 0

    init(screen: DemoScreen) {
        self.screen = screen
        self.snapshot = DemoScenario.startingSnapshot(for: screen)
    }

    // MARK: - Задача от человека

    /// В демонстрации сценарий один, поэтому любая задача проигрывает его заново:
    /// «думаю» → шаг чтения с результатом → карточка правки.
    func submit(task: String) async {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !snapshot.isBusy, snapshot.pendingAction == nil else { return }

        let run = beginRun()
        snapshot.stepsUsed = 0
        append(.user, text)
        snapshot.state = .thinking

        await pause(seconds: 1.1)
        guard !isStale(run) else { return }

        snapshot.stepsUsed = 1
        append(.agent, DemoScenario.readAnnouncement)
        append(.tool, DemoScenario.readSummary)
        snapshot.state = .thinking

        await pause(seconds: 1.1)
        guard !isStale(run) else { return }

        snapshot.stepsUsed = 2
        snapshot.state = .awaitingApproval(DemoScenario.pendingAction)
    }

    // MARK: - Решение человека

    /// «Применить». Показываем то же, что показал бы настоящий инструмент записи,
    /// — и НИЧЕГО не пишем: файла на диске у этого сценария нет.
    func approve() async {
        guard case .awaitingApproval(let action) = snapshot.state else { return }

        let run = beginRun()
        snapshot.state = .applying(action)

        await pause(seconds: 0.8)
        guard !isStale(run) else { return }

        // Дифф прикладываем к строке результата — так человек в ленте видит,
        // что именно поменялось, а не только имя файла.
        append(.tool, DemoScenario.appliedSummary, diff: action.fileDiff)
        append(.agent, DemoScenario.finishSummary)
        snapshot.state = .finished(summary: DemoScenario.finishSummary)
    }

    /// «Отклонить». В бою отказ уходит обратно в модель и она отвечает текстом —
    /// здесь ровно то же самое, только ответ заготовлен заранее.
    func reject() async {
        guard case .awaitingApproval(let action) = snapshot.state else { return }

        let run = beginRun()
        append(.system, AgentPrompt.rejectedSummary(action.title))
        snapshot.state = .thinking

        await pause(seconds: 0.8)
        guard !isStale(run) else { return }

        append(.agent, DemoScenario.rejectionReply)
        snapshot.state = .idle
    }

    /// «Стоп» во время «думаю».
    func cancel() async {
        guard snapshot.isBusy else { return }
        runID += 1
        snapshot.state = .idle
        append(.system, AgentPrompt.cancelledNotice)
    }

    /// «Новая задача».
    ///
    /// ⚠️ Здесь демонстрация намеренно отличается от боя: настоящая сессия очищает
    /// ленту, а эта возвращает заготовленную переписку. Причина простая — интерфейс
    /// зовёт reset() сразу после сборки сессии, и с пустой лентой демонстрация
    /// открывалась бы чистым экраном «С чего начнём?». Заодно случайное нажатие
    /// не портит подготовленный кадр.
    func reset() async {
        runID += 1
        snapshot = DemoScenario.startingSnapshot(for: screen)
    }

    // MARK: - Мелочи

    private func beginRun() -> Int {
        runID += 1
        return runID
    }

    private func isStale(_ run: Int) -> Bool {
        run != runID
    }

    private func pause(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func append(_ author: ChatAuthor, _ text: String, diff: FileDiff? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        snapshot.messages.append(ChatMessage(author: author, text: clean, diff: diff))
    }
}

#endif
