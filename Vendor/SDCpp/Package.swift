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
// ⚠️ Бинарник НЕ в git и ОБЯЗАН лежать рядом с этим файлом до сборки: без него
// резолв пакета падает. Кладёт его тот же раскладчик, что и движок Bonsai
// (ensure_llama_framework в tools/mac/pa-vendor.sh раскладывает оба движка).
//
// ⚠️ В фреймворке только слой для настоящего айфона (arm64), слоя симулятора нет:
// сборка на мини и доставка идут для устройства. Код приложения обёрнут в
// `#if canImport(SDEngine)`, поэтому без пакета он не ломается.
//
// ⚠️ ОБЁРТКА НАЗЫВАЕТСЯ SDEngine, А НЕ SDCpp — И ЭТО НЕ ВКУС. Диск Мака не различает
// регистр букв: модуль «SDCpp» и модуль фреймворка «sdcpp» для него одно имя, и сборка
// падала «cannot load module 'SDCpp' as 'sdcpp'» (проверка на мини 23.09.2026).

import PackageDescription

let package = Package(
  name: "SDCpp",
  platforms: [
    .iOS(.v17),
  ],
  products: [
    // Имя менять НЕЛЬЗЯ: приложение пишет `import SDEngine`.
    .library(name: "SDEngine", targets: ["SDEngine"])
  ],
  targets: [
    .binaryTarget(name: "sdcpp", path: "sdcpp.xcframework"),
    // Посредник: модуль фреймворка называется `sdcpp`, приложение импортирует
    // `SDEngine`. Переименование модуля чинится в одном файле, а не по приложению.
    .target(
      name: "SDEngine",
      dependencies: ["sdcpp"],
      linkerSettings: [
        // Фреймворк сам зовёт Metal и Accelerate; объявляем явно, чтобы
        // приложение не зависело от того, подтянет ли их кто-то ещё.
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("Accelerate"),
      ]
    ),
  ]
)
