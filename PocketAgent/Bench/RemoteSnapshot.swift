//
//  RemoteSnapshot.swift
//  PocketAgent / Bench
//
//  Снимок экрана приложения ПО ЗАПРОСУ С МАКА — без рук владельца.
//
//  ЗАЧЕМ (24.09.2026, ROADMAP §24.5). Владелец отдал телефон под замеры и хочет, чтобы
//  мы ВИДЕЛИ, что на нём происходит на самом деле, а не судили по журналам. Снимок
//  экрана с Мака (idevicescreenshot) на iOS 27 без root-туннеля не работает, поэтому
//  приложение снимает себя само: получило системное уведомление — нарисовало своё
//  окно в PNG.
//
//  КАК ЗАПРОСИТЬ (с Мака):
//      xcrun devicectl device notification post --device <UDID> --name pocket-agent.snapshot
//  и забрать:
//      xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
//          --domain-identifier pocket-agent \
//          --source "Library/Application Support/ImageGen/snaps/latest.png" --destination snap.png
//  (всё это делает `tools/phone-image-bench.sh snap`).
//
//  ⚠️ Снимается ТОЛЬКО окно нашего приложения и только когда оно на экране: свёрнутое
//  приложение iOS не выполняет, и снимок придёт, когда его откроют. Уведомление живёт
//  внутри устройства — это не выход в сеть.
//
//  ⚠️ Только отладочная сборка, как и весь замер: в TestFlight этого нет.
//

#if DEBUG

import UIKit
import os

enum RemoteSnapshot {

    /// Имя системного уведомления, по которому снимаем экран.
    static let notificationName = "pocket-agent.snapshot"

    /// Сколько снимков держать: старые стираем, чтобы замер на ночь не съел диск.
    private static let keepCount = 150

    /// Папка снимков: `Library/Application Support/ImageGen/snaps`.
    static var folder: URL? {
        ImageGenEngine.lastRunLogURL?.deletingLastPathComponent()
            .appendingPathComponent("snaps", isDirectory: true)
    }

    private static var installed = false

    /// Подписаться на уведомление. Один раз за запуск; повтор безвреден.
    static func install() {
        guard !installed else { return }
        installed = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                // Приходит на чужом потоке — рисовать окно можно только на главном.
                Task { @MainActor in RemoteSnapshot.take(label: "по запросу") }
            },
            notificationName as CFString, nil, .deliverImmediately)
    }

    /// Снять окно приложения. Возвращает путь к снимку; nil — окна нет (приложение
    /// свёрнуто или ещё не показало ни одного экрана).
    @MainActor @discardableResult
    static func take(label: String) -> URL? {
        guard let folder else { return nil }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              window.bounds.width > 0 else {
            log.notice("[снимок] окна нет — \(label, privacy: .public)")
            return nil
        }
        // afterScreenUpdates: true — снимок того, что на экране СЕЙЧАС, включая
        // только что сменившуюся строку замера, а не прошлый кадр.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let png = image.pngData() else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("snap-\(stamp.string(from: Date())).png")
        do {
            try png.write(to: url, options: .atomic)
            try png.write(to: folder.appendingPathComponent("latest.png"), options: .atomic)
            // Рядом — что это за снимок: время и повод. Скрипт печатает это вместе с картинкой.
            let note = "\(ISO8601DateFormatter().string(from: Date())) \(label) \(url.lastPathComponent)\n"
            try note.data(using: .utf8)?.write(to: folder.appendingPathComponent("latest.txt"), options: .atomic)
        } catch {
            log.error("[снимок] не записался: \(String(describing: error), privacy: .public)")
            return nil
        }
        prune(folder)
        log.notice("[снимок] \(label, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// Стереть самые старые снимки сверх `keepCount`.
    private static func prune(_ folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let snaps = names.filter { $0.hasPrefix("snap-") && $0.hasSuffix(".png") }.sorted()
        guard snaps.count > keepCount else { return }
        for name in snaps.prefix(snaps.count - keepCount) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Имя по времени — сортируется по алфавиту так же, как по времени.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    private static let log = Logger(subsystem: "com.example.pocket-agent", category: "snapshot")
}

#endif
