//
//  PocketAgentApp.swift
//  PocketAgent
//
//  Точка входа приложения.
//  Здесь только три вещи: подключение делегата (нужен фоновой загрузке модели),
//  создание композиционного корня и реакция на уход в фон.
//
//  ⚠️ Папку при уходе в фон отпускает РОВНО ОДИН владелец — AppViewModel
//  (он же умеет вернуть доступ при возврате в приложение). Второго вызова release()
//  отсюда быть не должно: два независимых отпускания разъезжаются с восстановлением,
//  и после возврата из фона папка выглядит потерянной.
//

import SwiftUI

@main
struct PocketAgentApp: App {

    /// Делегат нужен ради одного метода: система будит приложение,
    /// когда фоновая загрузка файла модели закончилась.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    /// Композиционный корень: сшивает движок, папку, инструменты и сессию.
    /// Создаётся один раз на всё время жизни приложения.
    @StateObject private var assembly = AgentAssembly()

    init() {
        #if DEBUG
        // Снимок экрана по запросу с Мака (Bench/RemoteSnapshot.swift) — в любом режиме:
        // владелец хочет видеть, что на телефоне на самом деле, а не только журналы.
        RemoteSnapshot.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // ЕДИНСТВЕННОЕ место, где приложение знает про папку Demo/.
            //
            // ⚠️ Вся ветка живёт ТОЛЬКО в отладочной сборке. В сборке для магазина
            // её нет вообще — вместе с ней из приложения выпадает и папка Demo/
            // (её содержимое тоже под #if DEBUG), то есть ни поддельная переписка,
            // ни выдуманный README в TestFlight не уезжают.
            // Снимки экранов собираются отладочной сборкой, поэтому съёмка не страдает.
            //
            // Демонстрационный режим включается только аргументом запуска
            // (-PocketAgentDemo YES) или переменной окружения POCKET_AGENT_DEMO=1 —
            // задать их можно лишь при запуске приложения снаружи, поэтому в обычной
            // жизни условие всегда ложно и собирается ровно то же дерево, что и раньше.
            // Зачем нужен: на симуляторе в облаке иначе виден только экран загрузки
            // модели на 2,6 ГБ. Подробности — PocketAgent/Demo/DemoMode.swift.
            #if DEBUG
            if ImageBenchMode.isEnabled {
                // Удалённый замер картинок: сразу свой экран, чат-модель НЕ грузится
                // (экрана чата нет — `AppViewModel.start` не зовётся). Bench/ImageBench.swift.
                ImageBenchRootView(assembly: assembly)
            } else if BenchMode.isEnabled {
                // Замер: приложение само прогоняет набор задач на живой модели и
                // кладёт отчёт файлом. Подробности — PocketAgent/Bench/BenchMode.swift.
                BenchRootView(assembly: assembly)
            } else if DemoMode.isEnabled {
                DemoRootView()
            } else {
                productionRoot
                    // ⚠️ Прошлый замер мог оборваться и оставить настройки владельца
                    // изменёнными — вернуть их надо при ОБЫЧНОМ старте, а не только
                    // при следующем запуске замера. Подробности — BenchLeftovers.
                    .task { BenchLeftovers.restoreIfAny(folderStore: assembly.folderStore) }
            }
            #else
            productionRoot
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            #if DEBUG
            // В демонстрации боевую сборку не трогаем совсем: иначе первое же
            // сворачивание приложения создало бы настоящий движок модели и владельца
            // папки — ради ничего, ведь останавливать в демонстрации нечего.
            if DemoMode.isEnabled { return }
            // Замер идёт часами и переживает гашение экрана. Прерви мы здесь
            // генерацию и отпусти папку — прогон умер бы на первой же дремоте
            // телефона, и наутро вместо чисел был бы обрыв на середине.
            if BenchMode.isEnabled || ImageBenchMode.isEnabled { return }
            #endif
            // Только прерывание генерации. Папку отпускает AppViewModel.
            assembly.handleEnteredBackground()
        }
    }

    /// Обычное дерево экранов — то самое, что было до появления демонстрации.
    /// Вынесено в отдельное свойство только затем, чтобы не дублировать его
    /// в двух ветках условной сборки.
    @ViewBuilder
    private var productionRoot: some View {
        ContentView(app: assembly.viewModel)
            .onReceive(NotificationCenter.default.publisher(for: .pocketAgentMemoryPressure)) { _ in
                // Система просит освободить память — выгружаем веса модели.
                assembly.handleMemoryPressure()
            }
    }
}
