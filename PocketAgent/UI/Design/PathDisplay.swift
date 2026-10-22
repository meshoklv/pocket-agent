//
//  PathDisplay.swift
//  PocketAgent
//
//  Как показывать путь к файлу на экране шириной с ладонь.
//
//  ⚠️ ЗАЧЕМ ЭТОТ ФАЙЛ. Путь вида `src/components/Header/very_long_name-v2.tsx`
//  на телефоне не помещается в строку, а перенос по умолчанию рвёт его в случайном
//  месте — посреди имени папки, иногда посреди слова. Читать такой путь на карточке
//  подтверждения, где человек решает, пускать ли правку в свои файлы, — мучение.
//
//  Здесь один приём: в путь добавляются НЕВИДИМЫЕ места переноса после разделителей
//  (`/`, `_`, `-`). Ширины они не занимают, на экране их не видно, но строка теперь
//  переносится по папкам и по частям имени, а не как попало.
//
//  ⚠️ В буфер обмена, в озвучку VoiceOver и в любую логику уходит ЧИСТЫЙ путь.
//  Подготовленная строка живёт ровно до отрисовки и дальше никуда не попадает —
//  иначе невидимый знак уехал бы в чужой файл или в поиск и сломал бы сравнение.
//

import Foundation

enum PathDisplay {

    /// Невидимое место переноса. Ширины нет, на экране не видно.
    private static let softBreak: Character = "\u{200B}"

    /// Путь, готовый к показу: те же знаки плюс невидимые места переноса.
    ///
    /// ⚠️ Только для показа. Копировать, сравнивать и передавать дальше — исходную строку.
    static func wrappable(_ path: String) -> String {
        var result = ""
        result.reserveCapacity(path.count + path.count / 3)
        for character in path {
            result.append(character)
            if character == "/" || character == "_" || character == "-" {
                result.append(softBreak)
            }
        }
        return result
    }

    /// Имя файла без папок: `src/ui/Header.tsx` → `Header.tsx`.
    static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Папка, в которой лежит файл, с завершающей косой чертой.
    /// `nil` — файл в корне папки проекта: там на экране уместнее фраза словами,
    /// а не путь (см. `ApprovalCard.pathLine`).
    static func directory(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/") + "/"
    }
}
