//
//  DemoMode.swift
//  PocketAgent / Demo
//
//  Единственный выключатель демонстрационного режима.
//
//  ЗАЧЕМ ОН ЕСТЬ. На симуляторе в облаке приложение при обычном запуске показывает
//  ровно один экран — предложение скачать модель на 2,6 ГБ. Ни чата, ни карточки
//  подтверждения увидеть нельзя. Демонстрационный режим подменяет ТОЛЬКО источник
//  данных (движок, папку и сессию агента) заранее заготовленными и позволяет снять
//  все экраны без модели, без сети и без единого обращения к файлам.
//
//  ⚠️ БОЕВОЙ РЕЖИМ. Пока флага нет, весь этот модуль мёртв: единственное место,
//  откуда он вообще виден, — одна проверка `DemoMode.isEnabled` в точке входа
//  (PocketAgentApp.swift). Ни один боевой тип про папку Demo/ не знает.
//
//  КАК ВКЛЮЧИТЬ (основной способ — аргумент запуска):
//
//      xcrun simctl launch booted com.example.pocketagent \
//          -PocketAgentDemo YES -PocketAgentDemoScreen chat
//
//  Аргументы вида «-Ключ Значение» система сама кладёт в домен аргументов
//  UserDefaults — он временный (на диск не пишется) и старше всех остальных,
//  поэтому UserDefaults.standard.bool(forKey:) читает их без всякой настройки.
//
//  ЗАПАСНОЙ СПОСОБ — переменные окружения. Нужен там, где аргументы запуска
//  задать неудобно (схема Xcode, скрипт с SIMCTL_CHILD_*):
//
//      xcrun simctl launch --console booted com.example.pocketagent   \
//          # предварительно: export SIMCTL_CHILD_POCKET_AGENT_DEMO=1
//          #                 export SIMCTL_CHILD_POCKET_AGENT_DEMO_SCREEN=approval
//
//  Работают оба; аргумент запуска сильнее переменной окружения.
//

// ⚠️ ВЕСЬ ФАЙЛ — ТОЛЬКО ОТЛАДОЧНАЯ СБОРКА.
// Демонстрационный режим нужен ради снимков экранов на симуляторе, и в сборку
// для магазина ему попадать незачем: там это мёртвый код и выдуманные тексты.
// Конвейер снимков собирает конфигурацию Debug, поэтому съёмке скобки не мешают.
#if DEBUG

import Foundation

/// Какой экран показать в демонстрационном режиме.
/// Значение приходит строкой из `-PocketAgentDemoScreen` (или POCKET_AGENT_DEMO_SCREEN).
enum DemoScreen: String, CaseIterable {
    /// Подготовка: загрузка файла модели с процентами.
    case model
    /// Выбор папки проекта.
    case folder
    /// Рабочий экран: переписка целиком и карточка правки внизу.
    case chat
    /// Тот же рабочий экран, но лента укорочена — карточка правки видна целиком.
    case approval
    /// «О программе».
    case about

    // MARK: - Площадка
    //
    // ⚠️ ЧЕТЫРЕ ОТДЕЛЬНЫХ ЗНАЧЕНИЯ, А НЕ ОДНО. Площадку нельзя показать одним
    // кадром: список карточек, открытая трёхмерная сцена, открытая игра и разбор
    // поломки — это четыре разных экрана. Нажимать в симуляторе некому, поэтому
    // каждый снимается своим запуском, без единого касания.

    /// Список того, что можно открыть: карточки страниц и игр.
    case playgroundList = "playground-list"
    /// Открытая трёхмерная сцена на three.js (библиотека — с полки приложения).
    case playgroundScene = "playground-3d"
    /// Открытая игра на холсте.
    case playgroundGame = "playground-game"
    /// Разбор поломки: что именно сломалось и предложение починить.
    case playgroundBroken = "playground-broken"

    /// Экран площадки — значит папку проекта надо подменить витриной с примерами,
    /// а не выдуманной папкой из DemoScenario.
    var isPlayground: Bool {
        switch self {
        case .playgroundList, .playgroundScene, .playgroundGame, .playgroundBroken:
            return true
        case .model, .folder, .chat, .approval, .about:
            return false
        }
    }
}

enum DemoMode {

    /// Ключ аргумента запуска: `-PocketAgentDemo YES`.
    static let enabledKey = "PocketAgentDemo"
    /// Ключ аргумента запуска: `-PocketAgentDemoScreen chat`.
    static let screenKey = "PocketAgentDemoScreen"

    private static let enabledEnvironmentKey = "POCKET_AGENT_DEMO"
    private static let screenEnvironmentKey = "POCKET_AGENT_DEMO_SCREEN"

    /// Демонстрационный режим включён.
    ///
    /// Считается ОДИН раз за запуск: переключать режим на ходу нельзя, иначе половина
    /// экранов осталась бы на боевых данных, а половина — на поддельных.
    static let isEnabled: Bool = {
        if UserDefaults.standard.bool(forKey: enabledKey) { return true }
        return isTruthy(ProcessInfo.processInfo.environment[enabledEnvironmentKey])
    }()

    /// Какой экран показывать. Аргумент не задан или написан с опечаткой — рабочий экран.
    static let screen: DemoScreen = {
        let raw = UserDefaults.standard.string(forKey: screenKey)
            ?? ProcessInfo.processInfo.environment[screenEnvironmentKey]
        guard let raw else { return .chat }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = DemoScreen(rawValue: clean) { return exact }
        // ⚠️ Короткое «playground» без уточнения — это список площадки.
        // Написать его целиком человеку проще, чем помнить про дефис.
        if clean == "playground" || clean == "площадка" { return .playgroundList }
        return .chat
    }()

    /// «1», «YES», «true», «on» — включено. Всё остальное, включая пустую строку, — нет.
    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "yes", "true", "on": return true
        default: return false
        }
    }
}

#endif
