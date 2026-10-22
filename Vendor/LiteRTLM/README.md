# LiteRTLM — локальная копия Swift-обёртки

Это **копия Swift-части** библиотеки LiteRT-LM от Google, положенная прямо в наш репозиторий,
чтобы Xcode больше никогда не скачивал 666 МБ ради 100 КБ кода.

---

## 📦 Откуда взято

> • Репозиторий: **https://github.com/google-ai-edge/LiteRT-LM**
> • Версия (тег): **v0.15.0**
> • Что скопировано: содержимое папки `swift/` (без тестов) и файл `LICENSE`
> • Лицензия: **Apache License 2.0**

---

## 🐢 Зачем это сделано

> • Xcode при сборке клонировал **весь репозиторий Google — 666 МБ**. На Маке владельца это
>   **25+ минут** на скорости ~1,3 МБ/с, процессор при этом простаивал: ждали только сеть.
> • Из этих 666 МБ нам нужно было **около 100 КБ** — 11 файлов Swift. Остальное это папка
>   `prebuilt/` со сборками под Android, Linux и Windows, исходники на C++/Rust/Python и прочее,
>   к iPhone отношения не имеющее.
> • Вдобавок часть больших файлов для Android у Google **битая** («remote missing object»)
>   и роняла скачивание целиком.
>
> Теперь код обёртки лежит у нас, а по сети качается **только готовая библиотека**
> `CLiteRTLM.xcframework.zip` с релиза — отдельным файлом, с проверкой контрольной суммы.

---

## ✅ Что скопировано (11 файлов, ~101 КБ)

`Sources/LiteRTLM/`:

> `Benchmark.swift` · `Capabilities.swift` · `Config.swift` · `Conversation.swift` ·
> `Engine.swift` · `ExperimentalFlags.swift` · `LiteRTLMError.swift` · `Message.swift` ·
> `ResponseFormat.swift` · `Tool.swift` · `ToolManager.swift`

Это ровно тот набор, который собирался в цель `LiteRTLM` в оригинальном манифесте
(всё из папки `swift/` за вычетом её секции `exclude`).

## ❌ Что НЕ скопировано и почему

> • **Тесты** — `CapabilitiesTests.swift`, `ConversationTests.swift`, `EngineTests.swift`,
>   `MessageTests.swift`, `ToolTests.swift`. В оригинале они и так исключены из сборки
>   библиотеки; приложению не нужны.
> • **Папка `swift/apple_fm/`** (продукт `LiteRTLMFoundationModels`) — переходник к Apple
>   Foundation Models. Наше приложение его не подключает (см. `project.yml`).
> • **`BUILD` и `Info.plist`** из папки `swift/` — служебные файлы сборочной системы Google
>   (Bazel) и описание бандла готовой библиотеки. В оригинальном манифесте тоже исключены.
> • **Всё остальное содержимое репозитория** — `prebuilt/` (сборки под android_arm64,
>   android_x86_64, linux_arm64, linux_x86_64, windows_x86_64, macos_arm64), `runtime/`,
>   `rust/`, `python/`, `kotlin/`, `js/`, `samples/` и прочее. Это и есть те самые 666 МБ.

---

## ⚖️ Лицензия и изменения

> • Файл `LICENSE` рядом — оригинальная Apache License 2.0 из репозитория Google,
>   скопирован **побайтово**.
> • Файла `NOTICE` в репозитории Google на теге v0.15.0 **нет** — проверено, поэтому
>   переносить было нечего.
> • Уведомления об авторстве сохранены: в каждом из 11 файлов первой строкой стоит
>   `// Copyright 2026 Google LLC` и текст лицензии — мы их не трогали.
> • **Изменений в чужой код мы не вносили.** Все 11 файлов совпадают с оригиналом
>   v0.15.0 побайтово (проверено `cmp`).
> • **`Package.swift` переработан на основе оригинального** — это производная работа,
>   а не наш собственный файл: из манифеста Google дословно взяты обе ссылки на готовые
>   библиотеки, обе контрольные суммы, имя продукта, минимальные версии платформ
>   и структура целей. Поэтому в нём сохранена шапка «Copyright 2026 Google LLC»
>   с текстом Apache 2.0, а перечень наших изменений указан там же, в шапке файла.

---

## 🔄 Как обновиться на новую версию (пошагово)

Пусть новая версия — `vX.Y.Z`. Порядок такой:

**1. Скачать только папку `swift/`, а не весь репозиторий.**
```bash
git clone --filter=blob:none --no-checkout --depth 1 \
  --branch vX.Y.Z https://github.com/google-ai-edge/LiteRT-LM.git /tmp/lrt
cd /tmp/lrt
git sparse-checkout set --no-cone swift Package.swift LICENSE
git checkout
```
Так скачается несколько мегабайт вместо 666 МБ, и битые файлы Android не помешают.

**2. Посмотреть новый `Package.swift` Google** — секцию `exclude` у цели `LiteRTLM`.
В ней перечислено, что в сборку НЕ идёт. Всё остальное из папки `swift/` (файлы `.swift`,
без подпапок) — это и есть новый список того, что надо перенести.

**3. Заменить исходники.**
```bash
rm -f Sources/LiteRTLM/*.swift
# скопировать из /tmp/lrt/swift/ все .swift, КРОМЕ перечисленных в exclude
```
Файлы копировать **как есть, ничего не редактируя** — этого требует лицензия.
Если состав файлов изменился, поправить их список в разделе «Что скопировано» выше.

**4. Обновить ссылки и контрольные суммы в нашем `Package.swift`.**
Взять их из нового `Package.swift` Google — там уже готовые `url` и `checksum` для
`CLiteRTLM` (iPhone) и `CLiteRTLM_mac` (Мак). Заменить в нашем файле обе ссылки, обе суммы
и номер версии в тексте. Проверить, не изменились ли минимальные версии платформ
(`.iOS(...)`, `.macOS(...)`) — если да, перенести и их.

Если у Google сумм почему-то нет, посчитать самому на Маке:
```bash
curl -L -O https://github.com/google-ai-edge/LiteRT-LM/releases/download/vX.Y.Z/CLiteRTLM.xcframework.zip
swift package compute-checksum CLiteRTLM.xcframework.zip
```

**5. Проверить после обновления.**
> • Открыть проект в Xcode и собрать — ошибок компиляции быть не должно.
> • Особое внимание на то, чем пользуется наш код в `PocketAgent/Runtime/`:
>   `Engine`, `EngineConfig`, `Backend` (`.gpu` и `.cpu()`), `SamplerConfig`,
>   `ConversationConfig` (в т.ч. параметр `automaticToolCalling`), `ThinkingConfig`,
>   `Conversation` (`sendMessage`, `sendMessageStream`, `cancel`, `getTokenCount`),
>   `Message` (конструкторы `Message(текст, role:)` и `Message(contents:role:)`,
>   свойства `toolCalls` и `toString`), `Content.toolResponse(name:response:id:)`,
>   `ToolCall` (`name`, `id`, `arguments`), протокол `Tool` и обёртка `@ToolParam`,
>   `LiteRTLMError`.
> • Прогнать на живом устройстве один ход агента с вызовом инструмента — это разом
>   проверяет и загрузку модели, и разбор ответа модели.
> • Убедиться, что в `project.yml` не вернулась зависимость по ссылке на GitHub:
>   пакет должен подключаться локально, из папки `Vendor/LiteRTLM`.
