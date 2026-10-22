//
//  BenchLeftovers.swift
//  PocketAgent / Bench
//
//  Возврат настроек владельца, если ЗАМЕР УПАЛ и не успел вернуть их сам.
//
//  ⚠️ ЗАЧЕМ ЭТО ПОЯВИЛОСЬ (09.09.2026, поймано фактом на телефоне владельца).
//  Замер на время прогона гасит поиск в интернете и включает действия с файлами,
//  а в конце возвращает как было. Слепок настоящих настроек он кладёт на диск ещё
//  до того, как их менять, — ровно на случай обрыва. Но читал этот слепок только
//  СЛЕДУЮЩИЙ ЗАПУСК ЗАМЕРА. А приложение в ту ночь дважды исчезло с телефона
//  посреди прогона, и владелец остался с ВЫКЛЮЧЕННЫМ поиском в интернете, ничего
//  об этом не зная: обычный запуск приложения слепок не читал вовсе.
//
//  Теперь читает. Одна проверка при обычном старте: лежит слепок — значит прошлый
//  замер оборвался, возвращаем человеку его настройки и убираем слепок.
//
//  ⚠️ Только отладочная сборка — как и весь замер. В TestFlight и в магазине этого
//  кода нет, и слепку там взяться неоткуда.
//

#if DEBUG

import Foundation

enum BenchLeftovers {

    /// Прошлый замер оборвался — вернуть настройки владельца на место.
    /// Ничего не лежит — тихо выходим, это обычный случай.
    @MainActor
    static func restoreIfAny(folderStore: ProjectRoot) {
        guard let url = try? benchDirectory().appendingPathComponent("owner-settings.json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let web = snapshot["webSearch"] as? Bool {
            WebSearchSettings.isEnabled = web
        }
        // Действия с файлами возвращаем ВКЛЮЧЁННЫМИ в любом случае — по той же причине,
        // что и в самом замере: выключенные действия делают помощника беспомощным,
        // а жалуется владелец именно на беспомощность.
        AgentToolsSettings.isEnabled = true

        // Папка: замер принимает свою тем же способом, что и человек, и это
        // перезаписывает закладку. Возвращаем ту, что была до прогона.
        if let encoded = snapshot["folderBookmark"] as? String,
           let bookmark = Data(base64Encoded: encoded) {
            folderStore.restoreSavedBookmark(bookmark)
        }

        try? FileManager.default.removeItem(at: url)
    }

    /// Та же папка, в которой замер держит свои файлы.
    private static func benchDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        return base.appendingPathComponent("Bench", isDirectory: true)
    }
}

#endif
