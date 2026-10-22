// swift-tools-version: 5.9
//
// Пакет движка картинок: stable-diffusion.cpp (leejet) с Metal, модель Qwen-Image-2.1.
//.
//
// Почему СВОЙ пакет и свой фреймворк, а не общий ggml с движком Bonsai: у sd.cpp
// ggml с собственными заплатками, у PrismML — с тернарными форматами. Это две
// разные библиотеки под одинаковыми именами функций. Поэтому sd.cpp вместе со своим
// ggml склеен в один динамический фреймворк, наружу из которого видны ТОЛЬКО
// функции sd.cpp — ни одного ggml_*. Подробно и с проверкой символов —
// tools/mac/pa-vendor.sh, раздел «Второй движок».
//
// ⚠️ Бинарник НЕ в git. Он ОПЦИОНАЛЕН: если sdcpp.xcframework лежит рядом с этим
// файлом — собирается настоящий модуль SDEngine; если нет — подставляется пустая
// заглушка (модуль SDEngineStub), `canImport(SDEngine)` в приложении ложно, и
// проект собирается без движка картинок (так делает CI на чистом клоне). Кладёт его тот же раскладчик, что и движок Bonsai
// (ensure_llama_framework в tools/mac/pa-vendor.sh раскладывает оба движка).
//
// ⚠️ В фреймворке только слой для настоящего айфона (arm64), слоя симулятора нет:
// сборка на мини и доставка идут для устройства. Код приложения обёрнут в
// `#if canImport(SDEngine)`, поэтому без пакета он не ломается.
//
// ⚠️ ОБЁРТКА НАЗЫВАЕТСЯ SDEngine, А НЕ SDCpp — И ЭТО НЕ ВКУС. Диск Мака не различает
// регистр букв: модуль «SDCpp» и модуль фреймворка «sdcpp» для него одно имя, и сборка
// падала «cannot load module 'SDCpp' as 'sdcpp'» (проверка на мини 23.09.2026).

import Foundation
import PackageDescription

// Лежит ли бинарник рядом с манифестом. Манифест — обычный Swift, читать файлы ему можно.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasEngine = FileManager.default.fileExists(atPath: packageDir + "/sdcpp.xcframework")

let package = Package(
  name: "SDCpp",
  platforms: [
    .iOS(.v17),
  ],
  products: [
    // Имя продукта менять НЕЛЬЗЯ (на него ссылается project.yml). Модуль внутри —
    // SDEngine, если движок на месте, иначе SDEngineStub (тогда `import SDEngine` не работает).
    .library(name: "SDEngine", targets: [hasEngine ? "SDEngine" : "SDEngineStub"])
  ],
  targets: hasEngine
    ? [
      .binaryTarget(name: "sdcpp", path: "sdcpp.xcframework"),
      // Посредник: модуль фреймворка называется `sdcpp`, приложение импортирует
      // `SDEngine`. Переименование модуля чинится в одном файле, а не по приложению.
      .target(
        name: "SDEngine",
        dependencies: ["sdcpp"],
        linkerSettings: [
          // Фреймворк сам зовёт Metal и Accelerate; объявляем явно.
          .linkedFramework("Metal"),
          .linkedFramework("MetalKit"),
          .linkedFramework("Accelerate"),
        ]
      ),
    ]
    : [
      .target(name: "SDEngineStub", path: "Sources/SDEngineStub")
    ]
)
