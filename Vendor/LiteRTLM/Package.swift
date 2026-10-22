// swift-tools-version: 5.9
// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modifications © 2026 Pocket Agent: убраны продукт LiteRTLMFoundationModels
// и тестовые цели, исходники перенесены в Sources/LiteRTLM.
//
// Этот файл — переработка оригинального Package.swift из репозитория Google
// (Apache 2.0, §4(b) — изменения обозначены выше, §4(c) — уведомление об
// авторстве сохранено). Локальная копия Swift-обёртки LiteRT-LM
// (google-ai-edge/LiteRT-LM, тег v0.15.0).
// Подробности — в README.md рядом. Код в Sources/ дословный, ни строки не менялось.
// Лицензия оригинала (Apache 2.0) — в файле LICENSE рядом.
//
// Отличия ЭТОГО манифеста от оригинального Package.swift репозитория Google
// (сам код обёртки при этом не тронут):
//   • нет продукта LiteRTLMFoundationModels и цели swift/apple_fm — приложению он не нужен;
//   • нет тестовых целей (CapabilitiesTests, ConversationTests, ToolTests, EngineTests,
//     MessageTests) — их файлы сюда не копировались;
//   • исходники лежат в стандартной папке Sources/LiteRTLM вместо папки swift,
//     поэтому список exclude не нужен — лишних файлов тут просто нет.
// Всё остальное — имя продукта, минимальные версии платформ, ссылки на готовые
// библиотеки и их контрольные суммы — совпадает с оригиналом v0.15.0 дословно.

import PackageDescription

let package = Package(
  name: "LiteRTLM",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    // Имя менять НЕЛЬЗЯ: приложение пишет `import LiteRTLM`.
    .library(
      name: "LiteRTLM",
      targets: ["LiteRTLM"]
    )
  ],
  targets: [
    // Готовая библиотека для iPhone. Качается отдельным файлом с релиза Google
    // (~десятки МБ), а не клонированием всего репозитория на 666 МБ.
    .binaryTarget(
      name: "CLiteRTLM",
      url:
        "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.15.0/CLiteRTLM.xcframework.zip",
      checksum: "d6ccf6b54362d894ff71a7580c7e446d36767dab908aecfbb16ffca0fa0bc59b"
    ),
    // Та же библиотека для Мака. Приложению не нужна, но цель оставлена как в оригинале,
    // чтобы пакет собирался и под macOS (например, для быстрых проверок в песочнице).
    //
    // ⚠️ ОТКРЫТЫЙ ВОПРОС (проверить на первом же прогоне, а не гадать):
    // не факт, что Xcode уважает condition .when(platforms:) при СКАЧИВАНИИ файла —
    // возможно, он тянет артефакты всех binaryTarget в графе, и тогда на каждый
    // холодный кеш зря приезжает ещё и CLiteRTLM_mac.xcframework.zip.
    // Ответ даёт шаг «Замер» в .github/workflows/build.yml — он печатает
    // `du -sh DerivedData/SourcePackages/artifacts/*` пофайлово. Если в списке
    // окажется CLiteRTLM_mac — убрать отсюда эту цель, зависимость на неё ниже
    // и `.macOS(.v12)` из platforms, а причину дописать в шапку файла.
    .binaryTarget(
      name: "CLiteRTLM_mac",
      url:
        "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.15.0/CLiteRTLM_mac.xcframework.zip",
      checksum: "d23cf189ce8f6bb2556c0a023805e245d1ec862434e501eb60f353488033c1b5"
    ),
    // Сама Swift-обёртка: 11 файлов, скопированы дословно.
    .target(
      name: "LiteRTLM",
      dependencies: [
        .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
        .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])),
      ]
    ),
  ]
)
