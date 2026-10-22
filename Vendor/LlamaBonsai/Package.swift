// swift-tools-version: 5.9
//
// Пакет движка для GGUF-моделей (Bonsai 2 27B и будущие в этом формате).
//
// Почему СВОЙ пакет, а не ещё один binaryTarget внутри LiteRTLM: это чужой
// движок с чужим релизным циклом — PrismML, форк llama.cpp. Стоковый llama.cpp
// тернарные форматы Bonsai НЕ понимает: файлы PTQ1_0/PQ2_0 он отвергает как
// неизвестные, а похожий по имени Q2_0 грузит МОЛЧА и выдаёт мусор. Поэтому
// правило: считается только сборка форка PrismML, версия не старше prism-b10658
// (более старые не читают файлы после «миграции тернарных групп»).
//
// Почему бинарник НЕ в git: скачанный xcframework весит ~310 МБ — крупнее
// лимита GitHub в 100 МБ на файл. Бинарник ОПЦИОНАЛЕН: если llama.xcframework лежит
// рядом с этим файлом — собирается настоящий модуль LlamaBonsai; если нет —
// подставляется заглушка (модуль LlamaBonsaiStub), `canImport(LlamaBonsai)` в
// приложении ложно, и проект собирается без движка (так делает CI на чистом клоне).
// Для запуска моделей Bonsai бинарник нужен, см. BUILD.md. Раньше его клала только tools/check.sh, а
// доставки кода папку Vendor стирали и обратно не клали — первая же доставка
// падала на резолве. Теперь раскладка общая для всех путей: tools/check.sh,
// tools/ship.sh и tools/release-to-testflight.sh зовут tools/mac/pa-vendor.sh
// (кэш ~/pa-vendor с меткой версии, при отсутствии — скачивание с релиза
// PrismML). Собираете руками — запустите раскладчик или положите
// llama.xcframework рядом с этим файлом сами.

import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasEngine = FileManager.default.fileExists(atPath: packageDir + "/llama.xcframework")

let package = Package(
  name: "LlamaBonsai",
  platforms: [
    // Движок PrismML собран с минимумом iOS 16.4; приложение само стоит на 17.0.
    .iOS(.v17),
  ],
  products: [
    // Имя продукта менять НЕЛЬЗЯ (на него ссылается project.yml). Модуль внутри —
    // LlamaBonsai, если движок на месте, иначе LlamaBonsaiStub.
    .library(name: "LlamaBonsai", targets: [hasEngine ? "LlamaBonsai" : "LlamaBonsaiStub"])
  ],
  targets: hasEngine
    ? [
      // Готовая сборка с релиза PrismML: Metal вшит, слайсы iPhone и симулятора внутри.
      .binaryTarget(name: "llama", path: "llama.xcframework"),
      // Посредник: модуль фреймворка `llama`, приложение импортирует `LlamaBonsai`.
      .target(name: "LlamaBonsai", dependencies: ["llama"]),
    ]
    : [
      .target(name: "LlamaBonsaiStub", path: "Sources/LlamaBonsaiStub")
    ]
)
