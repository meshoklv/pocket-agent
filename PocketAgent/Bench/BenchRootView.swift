//
//  BenchRootView.swift
//  PocketAgent / Bench
//
//  Экран замера. Нарочно уродливый и однослойный: он не для человека, а чтобы
//  с телефона было видно, что прогон идёт, а не завис. Настоящий результат —
//  файл отчёта, его забирают с Мака.
//
//  ⚠️ Ни правил оформления, ни «жидкого стекла» здесь не соблюдается намеренно:
//  это служебный экран отладочной сборки, в продукт он не попадает. Тратить на него
//  приёмку интерфейса было бы прямой растратой.
//

#if DEBUG

import SwiftUI

struct BenchRootView: View {

    let assembly: AgentAssembly

    @StateObject private var runner = BenchRunner()
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ⚠️ Заголовок обязан различать «закончен» и «не состоялся». Раньше он
            // писал «Замер закончен» на любой конец — в том числе когда считать было
            // нечего или отчёт не записался, — и с телефона провал выглядел успехом.
            Text(runner.isDone
                 ? (runner.failed ? "❌ Замер НЕ состоялся" : "Замер закончен")
                 : "Идёт замер")
                .font(.headline)
                .foregroundStyle(runner.failed ? Color.red : Color.primary)

            Text(runner.line)
                .font(.footnote)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if !runner.reportPath.isEmpty {
                Text(runner.reportPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            // Один раз за запуск: .task умеет позваться снова при пересборке тела.
            guard !started else { return }
            started = true
            // Телефон не должен уснуть посреди прогона: экран гаснет — приложение
            // уходит в фон, движок прерывает ход, и вместо чисел получается обрыв.
            UIApplication.shared.isIdleTimerDisabled = true
            await runner.run(assembly: assembly)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

#endif
