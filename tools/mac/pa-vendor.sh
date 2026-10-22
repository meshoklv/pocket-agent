#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Раскладчик движка Bonsai: кладёт llama.xcframework в дерево сборки.
#
# Сам по себе файл НЕ запускают — его подключают и зовут функцию:
#     . ~/pa-vendor.sh
#     ensure_llama_framework ~/pocket-agent-build
#
# ⚠️ ЗАЧЕМ ОН ВООБЩЕ ЕСТЬ. Фреймворк движка НЕ в git (310 МБ, лимит GitHub —
#    100 МБ на файл, см. .gitignore). Код на Мак везут через tar и папку Vendor
#    при этом стирают ЦЕЛИКОМ — значит, сразу после заливки фреймворка на месте
#    нет, а резолв пакета LlamaBonsai без бинарника падает: он объявлен в
#    Package.swift обязательным. Раньше раскладка жила только внутри
#    tools/check.sh, а доставки (tools/ship.sh, tools/release-to-testflight.sh)
#    папку стирали и обратно движок не клали — первая же доставка падала на
#    резолве пакета красным потоком SPM. Теперь ВСЕ пути зовут эту функцию,
#    и требование к движку у всех одинаковое.
#
# Откуда берётся движок (по порядку):
#   1. уже лежит в дереве сборки — ничего не делаем;
#   2. кэш ~/pa-vendor/llama.xcframework С МЕТКОЙ правильной версии — копируем;
#   3. кэша нет или он чужой — качаем с релиза PrismML один раз и раскладываем
#      и в кэш, и в дерево.
#
# ⚠️ МЕТКА ВЕРСИИ ОБЯЗАТЕЛЬНА. Кэш без метки или с другой версией не годится:
#    на его место мог попасть стоковый llama.cpp, который тернарные форматы
#    Bonsai не читает, а похожий по имени формат грузит МОЛЧА мусором (см.
#    Vendor/LlamaBonsai/Package.swift). Метка пишется при скачивании рядом с
#    фреймворком: ~/pa-vendor/.pa-llama-version. Метки нет — перекачиваем, а не
#    надеемся наугад.
#
# Функция возвращает НЕноль при ЛЮБОЙ неудаче. Вызывающий обязан на этом
# остановиться с человеческим сообщением — молчаливый красный SPM посреди
# сборки ловится загодя, до долгой работы.
#
# Версию движка меняем ТОЛЬКО в одной строке ниже, больше нигде.
# ─────────────────────────────────────────────────────────────────────────────

# Считается только сборка форка PrismML не старше prism-b10658 (более старые
# не читают файлы после «миграции тернарных групп»). Эта версия прибита при
# подключении движка и проверена на живых Bonsai-моделях.
PA_LLAMA_VERSION="prism-b10709-9a9394a"

_pa_ensure_llama_only() {  # _pa_ensure_llama_only <дерево-сборки>
  tree="${1:-}"
  if [ -z "$tree" ]; then
    echo "❌ _pa_ensure_llama_only: не сказано, в какое дерево класть движок." >&2
    return 1
  fi

  pkg="$tree/Vendor/LlamaBonsai"
  frame="$pkg/llama.xcframework"
  cache="$HOME/pa-vendor"

  # Уже на месте — дальше не лезем: лишний раз копировать 310 МБ не нужно.
  if [ -d "$frame" ]; then
    echo "  движок Bonsai уже на месте"
    return 0
  fi

  mkdir -p "$pkg" || { echo "❌ Не создать папку $pkg." >&2; return 1; }

  # Кэш годен ТОЛЬКО вместе с меткой нужной версии. Проверяем фактом: папка
  # есть, файл-метка есть, строка в нём совпадает целиком.
  if [ -d "$cache/llama.xcframework" ] \
     && [ -f "$cache/.pa-llama-version" ] \
     && grep -qx "$PA_LLAMA_VERSION" "$cache/.pa-llama-version" 2>/dev/null; then
    echo "  беру движок из кэша ~/pa-vendor"
    if cp -R "$cache/llama.xcframework" "$frame" && [ -f "$frame/Info.plist" ]; then
      return 0
    fi
    # Кэш мог покоситься в чужой незавершённой закачке. Полудвижок из него
    # брать нельзя — молча оставить недокопию в дереве хуже честной перекачки.
    echo "  ⚠️ кэш оказался неполным — перекачиваю с релиза" >&2
    rm -rf "$frame"
  fi

  echo "  качаю движок с релиза PrismML ($PA_LLAMA_VERSION, 310 МБ, один раз)…"
  # ⚠️ ИМЕНА РАЗДАЁТ mktemp, А НЕ $$. Две параллельные проверки разных веток
  # качают одновременно, и общее имя означало бы, что одна недокачка становится
  # «готовым архивом» для второй. Вариант с $$ ловили живьём: у параллельных
  # вызовов одной оболочки $$ одинаковый (это номер родителя), и процессы
  # затирали хозяйство друг друга. mktemp гарантирует уникальность имени.
  tmpd="$(mktemp -d /tmp/llama-xcf.XXXXXXXX)" || {
    echo "❌ Не создать временную папку в /tmp для закачки движка." >&2
    return 1
  }
  tmpzip="$tmpd/dl.zip"

  # В кэш ставим копию ПОЛНОСТЬЮ готовой: сначала целиком собираем её рядом под
  # временным именем и только потом переименовываем. Переименование в той же
  # папке мгновенно — параллельный читатель не застанет полфреймворка.
  # ⚠️ Папку-черновик mktemp создаёт, и мы её тут же убираем: cp -R обязан сам
  # СОЗДАТЬ папку с содержимым фреймворка. Если черновик уже существует, cp
  # вложит копию ВНУТРЬ него — и кэш получится каша в каше.
  mkdir -p "$cache" || { echo "❌ Не создать папку кэша $cache." >&2; rm -rf "$tmpd"; return 1; }
  stage="$(mktemp -d "$cache/.pa-llama-incoming.XXXXXXXX")" || {
    echo "❌ Не создать черновик кэша в $cache." >&2
    rm -rf "$tmpd"
    return 1
  }
  rmdir "$stage"

  ok=1
  curl -sL --retry 3 -o "$tmpzip" \
      "https://github.com/PrismML-Eng/llama.cpp/releases/download/$PA_LLAMA_VERSION/llama-$PA_LLAMA_VERSION-xcframework.zip" \
    || ok=0
  if [ "$ok" -eq 1 ]; then
    unzip -q -o "$tmpzip" -d "$tmpd/x" || ok=0
  fi
  # ⚠️ ПУТЬ ВНУТРИ АРХИВА НЕ УГАДЫВАЕМ, А ИЩЕМ. Здесь был прибит гвоздями
  # «xcf/build-apple/llama.xcframework», а в архиве релиза лежит
  # «build-apple/llama.xcframework» — лишняя папка в пути означала, что
  # скачивание НЕ СРАБОТАЛО БЫ НИКОГДА: каждый прогон честно тянул 310 МБ и
  # отвечал «в архиве не та структура». Поймано первым же прогоном на мини
  # 23.09.2026, до этого путь всегда спасался кэшем на Маке владельца.
  # Ищем папку по имени — так нас не ломает ни новая обёртка, ни её потеря.
  if [ "$ok" -eq 1 ]; then
    found="$(find "$tmpd/x" -maxdepth 4 -type d -name llama.xcframework 2>/dev/null | head -1)"
    if [ -z "$found" ] || [ ! -f "$found/Info.plist" ]; then
      echo "  ⚠️ в архиве нет llama.xcframework — релиз переименовали?" >&2
      ok=0
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    cp -R "$found" "$stage" \
      && [ -f "$stage/Info.plist" ] || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    # ⚠️ Порядок «снести старое — переименовать новое» не атомарен, но плохое
    # здесь только одно: параллельный прогон застанет секунду без кэша и
    # скачает сам. Чужой ГОТОВЫЙ расклад это не ломает — у каждого своё дерево.
    rm -rf "$cache/llama.xcframework"
    mv "$stage" "$cache/llama.xcframework" || ok=0
  fi
  if [ "$ok" -eq 1 ] && [ -d "$cache/llama.xcframework/llama.xcframework" ]; then
    # Подпись гонки: mv при занятом адресате не отказал, а ВЛОЖИЛ копию внутрь
    # чужой свежей. Исправляем — чужая копия полная, наша внутри неё лишняя.
    echo "  ⚠️ поймал параллельную закачку — убираю вложенную копию из кэша" >&2
    rm -rf "$cache/llama.xcframework/llama.xcframework"
  fi
  if [ "$ok" -eq 1 ] && [ ! -f "$cache/llama.xcframework/Info.plist" ]; then
    # Финальный факт: в кэше именно фреймворк, а не обрывок. Без этой проверки
    # недокопка молча разъехалась бы по всем деревьям.
    echo "  ⚠️ кэш после раскладки неполный" >&2
    rm -rf "$cache/llama.xcframework"
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    # Метку пишем ПОСЛЕ того, как фреймворк встал на место: кэш без метки
    # заставит следующий прогон перекачать, а метка без кэша — соврать, что всё
    # хорошо.
    printf '%s\n' "$PA_LLAMA_VERSION" > "$cache/.pa-llama-version" || ok=0
  fi

  # Черновики убираем при любом исходе — в /tmp и в кэше им делать нечего.
  rm -rf "$tmpd"
  [ -n "${stage:-}" ] && rm -rf "$stage"

  if [ "$ok" -ne 1 ]; then
    echo "❌ Не удалось скачать и разложить движок Bonsai ($PA_LLAMA_VERSION)." >&2
    echo "   Проверить сеть и релиз: https://github.com/PrismML-Eng/llama.cpp/releases" >&2
    return 1
  fi

  echo "  кладу движок в дерево сборки"
  cp -R "$cache/llama.xcframework" "$frame" && [ -f "$frame/Info.plist" ] || {
    echo "❌ Движок скачан, но в дерево не лёг: $frame." >&2
    return 1
  }
  echo "  скачан и разложен"
  return 0
}

# ═════════════════════════════════════════════════════════════════════════════
# Второй движок — картинки (stable-diffusion.cpp, модель Qwen-Image-2.1).
#
#
# ⚠️ ВСЕ ПУТИ ДОСТАВКИ ЗОВУТ ensure_llama_framework — и теперь она раскладывает
#    ОБА движка. Так не надо править шесть мест вызова (check.sh, ship.sh,
#    release, pa-check, pa-ship, pa-minibuild), и ни один путь не забудет
#    второй движок: без sdcpp.xcframework резолв пакета SDCpp падает ровно так
#    же, как без llama.xcframework.
#
# ⚠️ ГЛАВНОЕ РЕШЕНИЕ — СВОЙ ggml, СПРЯТАННЫЙ ВНУТРИ СВОЕГО ФРЕЙМВОРКА.
#    В llama.xcframework (форк PrismML) уже лежит свой ggml, и он ЭКСПОРТИРУЕТ
#    ~1160 символов ggml_* (проверено nm на мини 23.09.2026). У sd.cpp ggml
#    другой — с собственными заплатками («patched GGML extensions»), а у PrismML
#    — с тернарными форматами. Сесть на один общий ggml нельзя: это две разные
#    библиотеки под одинаковыми именами. Поэтому:
#      • sd.cpp и его ggml собираются статически и склеиваются в ОДИН
#        динамический фреймворк sdcpp.framework;
#      • наружу из него видны ТОЛЬКО функции sd.cpp (список ниже) — ни одного
#        ggml_*. Приложение ggml напрямую не зовёт, а каждый фреймворк зовёт
#        свою копию: конфликта имён при сборке нет, и путать копии загрузчику
#        нечего;
#      • в ggml есть один Objective-C класс (GGMLMetalClass), а классы ObjC
#        регистрируются по имени глобально, мимо списка экспорта. На деле он
#        компилируется только БЕЗ вшитых шейдеров — при GGML_METAL_EMBED_LIBRARY
#        его нет ни у нас, ни у llama (проверено objdump по готовому приложению
#        23.09.2026: классов ObjC нет ни в одном из двух фреймворков). Переименование
#        при компиляции оставлено как страховка на случай смены флагов;
#      • шейдеры Metal вшиты в бинарь (GGML_METAL_EMBED_LIBRARY) — у каждого
#        фреймворка свои, файл default.metallib в бандле не ищется.
#
# Откуда берётся фреймворк (по порядку):
#   1. уже лежит в дереве сборки;
#   2. кэш ~/pa-vendor/sdcpp.xcframework с меткой нужной версии;
#   3. на Маке владельца — забрать готовый кэш с мини (он его уже собрал);
#   4. собрать из исходников (минуты на мини; cmake подтягивается сам).
# Бинарника нет в git: он большой и воспроизводимо собирается из закреплённого
# коммита.
#
# Версию меняем ТОЛЬКО здесь. В закреплённом коммите уже есть Qwen-Image-2.1
# (#2032, #2035) и правка «mmapped weights through Metal buffers» (#2037).
# Меняешь сборку (флаги, список экспорта) — подними хвост -vN в метке, иначе
# машины со старым кэшем продолжат брать старый бинарь.
# ═════════════════════════════════════════════════════════════════════════════
PA_SD_COMMIT="88411ef1e0688ff2df1010aeeb5d92b2d8cea2be"
PA_SD_VERSION="sdcpp-88411ef-v13"  # v13: + п.15 — шаг FLUX.3 режется по блокам (без этого iOS обрывал весь шаг одним буфером), 16.10.2026
                                   # v12: + п.14 — FLUX.3 Image Klein (перенос апстрима 8cd731e7b4), 16.10.2026
                                   # v11: v10a + v10b вместе — все варианты нейроблоков в одной сборке: режимы 3..6 (п.12, инженер A) и 7 (п.13, инженер B; до слияния был 4), 25.09.2026
                                   # v10b: п.13 инженера B — переупаковка весов q4_K плитками при загрузке и ядро (тогда GGML_METAL_NAX=4, теперь 7), 25.09.2026
                                   # v10a: п.12 — ядра NAXA для матричных блоков A19, режимы GGML_METAL_NAX=3..6 (инженер A), 25.09.2026
                                   # v9: RoPE Qwen-Image 2.1 одной операцией (ggml_rope_pa_table), срезы вокруг внимания без копий, выселение «сперва дешевле просящей», SD_KEEP_ENCODER только если влезает всё, 24.09.2026
                                   # v8: v8: замер ядра на размерах Qwen-Image 2.1, раскладка слоя по операциям (SD_PROFILE_BLOCK), рисующая часть выселяется последней, журнал памяти, SD_KEEP_ENCODER, 24.09.2026
                                   # v7: v6d (ядра MLX, модель открыта между картинками) + v6a (проявка крупными плитками, веса между вызовами), 24.09.2026
                                   # v6a: + проявка крупными плитками (резы, im2col, перестановки), SD_KEEP_WEIGHTS
                                   # v6d: ядра MLX — отдельной библиотекой, основная без них; нет библиотеки — отказ, а не падение; счёт ядер в журнал, 24.09.2026
                                   # v6c: + ядро умножения по схеме MLX (GGML_METAL_NAX) и замер ядра sd_pa_kernel_bench
                                   # v5: + проявка в half (SD_VAE_F16), подгрузка весов не в колбэке шагов
PA_CMAKE_VERSION="3.31.8"

ensure_llama_framework() {  # ensure_llama_framework <дерево-сборки>
  _pa_ensure_llama_only "$@" || return 1
  ensure_sd_framework "$@"
}

_pa_sd_cache_ok() {  # _pa_sd_cache_ok <папка-кэша>
  [ -f "$1/sdcpp.xcframework/Info.plist" ] \
    && grep -qx "$PA_SD_VERSION" "$1/.pa-sd-version" 2>/dev/null
}

ensure_sd_framework() {  # ensure_sd_framework <дерево-сборки>
  tree="${1:-}"
  [ -n "$tree" ] || { echo "❌ ensure_sd_framework: не сказано дерево." >&2; return 1; }
  pkg="$tree/Vendor/SDCpp"
  frame="$pkg/sdcpp.xcframework"
  cache="$HOME/pa-vendor"
  if [ -d "$frame" ]; then
    echo "  движок картинок уже на месте"
    return 0
  fi
  mkdir -p "$pkg" "$cache" || return 1

  # Мак владельца сам не собирает — забираем то, что уже собрал мини.
  # Хост mini-office прописан в ~/.ssh/config Мака.
  if ! _pa_sd_cache_ok "$cache" && [ -z "${PA_SD_NO_MINI:-}" ] \
     && ssh -o BatchMode=yes -o ConnectTimeout=15 mini-office \
          "grep -qx '$PA_SD_VERSION' ~/Developer/pa-vendor/.pa-sd-version" 2>/dev/null; then
    echo "  забираю движок картинок с мини"
    rm -rf "$cache/.sd-incoming"
    if rsync -a mini-office:Developer/pa-vendor/sdcpp.xcframework/ "$cache/.sd-incoming/" \
       && [ -f "$cache/.sd-incoming/Info.plist" ]; then
      rm -rf "$cache/sdcpp.xcframework"
      mv "$cache/.sd-incoming" "$cache/sdcpp.xcframework" \
        && printf '%s\n' "$PA_SD_VERSION" > "$cache/.pa-sd-version"
    fi
    rm -rf "$cache/.sd-incoming"
  fi

  if ! _pa_sd_cache_ok "$cache"; then
    echo "  собираю движок картинок из исходников ($PA_SD_VERSION, один раз)…"
    pa_build_sd_framework "$cache" || return 1
  fi

  cp -R "$cache/sdcpp.xcframework" "$frame" && [ -f "$frame/Info.plist" ] || {
    echo "❌ Движок картинок есть в кэше, но в дерево не лёг: $frame." >&2
    return 1
  }
  echo "  движок картинок разложен"
}

# Наши правки поверх закреплённого коммита. Первый запуск на телефоне 24.09.2026:
# рисование упало с «Discarded (victim of GPU error/recovery)» — это «невинная
# жертва», настоящую ошибку ggml не напечатал.
#   1) ggml-metal: при сбое печатать ВСЕ упавшие командные буферы в порядке
#      исполнения — чтобы в журнал попадала первая, настоящая ошибка видеочипа;
#   2) sd.cpp: переменная SD_FORCE_SEGMENTED_COMPUTE режет граф рисующей части
#      по слоям (штатный механизм движка, обычно он включается только при нехватке
#      памяти). Один шаг Qwen-Image целиком — это один многосекундный командный
#      буфер Metal, а iOS такие обрывает. Приложение ставит переменную само;
#   3) sd.cpp: переменная SD_SEGMENT_TIMING печатает время каждого куска в журнал —
#      чтобы с телефона было видно, какие слои съедают шаг;
#   4) ggml-metal: в тензорном умножении (матричные блоки A19/M5) активации
#      переводятся в half и кладутся в общую память группы — блоки считают только
#      half x half, а float уводил умножение на обычные вычислители. Плюс двойной
#      буфер вместо второго барьера на шаг. По умолчанию ВКЛ, выключается
#      GGML_METAL_TENSOR_F16=0;
#   5) sd.cpp: подгрузка весов (счёт тензоров) больше не зовёт колбэк шагов — при
#      турбо (4 шага) первый кусок из 4 тензоров выдавал себя за шаги рисования,
#      и строка шагов в «Подробностях» была из нулей;
#   6) sd.cpp: переменная SD_VAE_F16 переводит bf16-веса проявки в half прямо в графе.
#      Свёртки проявки у Qwen-Image 2.1 все с глубиной 1 и уже идут 2D-путём
#      (медленный kernel_conv_3d не участвует — проверено по файлу 24.09.2026), но
#      bf16 x f32 на матричных блоках A19 шло как bfloat x bfloat, которые блоки
#      не считают сами; half x half — считают. На M1 без блоков скорость та же,
#      картинка совпадает побитово.
#   7) ggml-metal: ядро умножения kernel_mul_mm_nax* по схеме MLX (steel/gemm/nax.h и
#      quantized_nax.h, MIT) для матричных блоков A19/M5: каждая SIMD-группа считает
#      свою подплитку 32x32 кусками 16x32x16 на execution_simdgroup с операндами в
#      регистрах; веса Q4_K/Q4_0/Q3_K/F16/… разворачиваются в half-плитку со сдвигом
#      строк, активации читаются прямо в регистры и сужаются в half; шаг K 64.
#      Две плитки: 64x64 (4 SIMD-группы, по умолчанию) и 128x128 (16). Режим —
#      GGML_METAL_NAX (0 выкл, 1, 2; нет переменной — 1), читается на каждом умножении.
#      Ядра — в ОТДЕЛЬНОЙ библиотеке шейдеров (собирается при первом подходящем
#      умножении); основная собирается как до v6c. Не собрались — умножение старым.
#      v6d, после падения на телефоне 24.09.2026 18:08 (EXC_BAD_ACCESS 0x18 в
#      ggml_metal_library_get_pipeline, библиотека устройства NULL): нет библиотеки —
#      досборка в устройство, а если никак — отказ вычисления с причиной, не падение.
#      Какое ядро реально взято и почему — строки «PA NAX: умножение …» и счёт за
#      картинку (sd_pa_kernel_stats) в журнале запуска.
#      Плюс sd_pa_kernel_bench(): замер старого и нового ядра на размерах рисующей
#      части прямо на телефоне — точность против процессора и время.
#      На M1 блоков нет: проверено офлайн-компиляцией под iphoneos -std=metal4.0 и
#      на M1 с эмуляцией матричного блока (раскладка регистров — как у MLX).
#   8) v6a, sd.cpp — проявка Qwen-Image 2.1 крупными плитками:
#      • SD_VAE_SEGMENTS режет граф проявки по остаточным блокам (штатные метки движка
#        были закомментированы) — кусок работы видеочипа короткий при любой плитке,
#        и 512² проявляется одной плиткой вместо 9 перекрывающихся 16×16;
#      • SD_VAE_FAST — быстрые пути одного кадра: свёртка без отдельной копии полей и без
#        лишней перестановки выхода, развёртка полосами по SD_VAE_BAND_MB (пик памяти
#        ~1 ГБ вместо 1,9), «повтор с перестановками» в ярусах подъёма — одним увеличением;
#      • подгрузка весов больше не спит по 200 мс между проверками (каждая подгрузка
#        длилась не меньше 0,2 с — на проявке это 9 плиток × 0,2 с);
#      • SD_KEEP_WEIGHTS=1 — веса рисующей части и проявки не выселяются в конце вызова
#        (энкодер — выселяется; при нехватке места менеджер выселяет сам).
#   9) v6a, ggml-metal — развёртка im2col «плоским» ядром (группа потоков на точку выхода;
#      штатное — 9 потоков на группу, выключается GGML_METAL_IM2COL_FLAT=0) и cont()
#      переставленного f32-тензора плитками 32×32 (GGML_METAL_PA_TRANSPOSE=0 — штатно).
#      Замер на мини 24.09.2026, 1 шаг, та же скрытая картинка: проявка 512² 26,5 → 6,7 с,
#      768² 48,2 → 14,6 с; 512² побитово равна проявке целиком без плиток.
#      Ядро умножения (mul_mm, п.7) здесь не тронуто; накладываются после п.7.
#  10) v8, sd.cpp, после п.9:
#      • sd_pa_kernel_bench («Проверить ядро») — размеры НАСТОЯЩЕЙ Qwen-Image 2.1: скрытый 4096,
#        MLP 12288, 1037 и 1024 токена; типы q4_K/q5_K/q8_0/q4_0/f16; «блок» = 4·A + 2·B + C и шаг
#        (×32 слоя); строки KB/KBBLOCK/KBACC «ключ=значение» для разбора; какое ядро реально взято;
#      • SD_PROFILE_BLOCK=<N> (+ SD_PROFILE_STEP, по умолчанию 2) — слой N рисующей части ещё раз
#        поштучно по операциям с ожиданием видеочипа: строки «PA PROFILE» (умножения по типу и
#        размеру, внимание, нормировки, RoPE, поэлементные, перестановки). Выход слоя не меняется;
#      • при SD_KEEP_WEIGHTS менеджер памяти выселяет давние веса по рангу: энкодер и прочее →
#        проявка → рисующая часть последней (штатно — чистая давность, и первой уходила именно
#        рисующая часть). SD_RESIDENCY_LOG=1 — строки «PA RESIDENCY»: кто кого выселил и сколько
#        каждой части лежит в памяти после вызова. SD_KEEP_ENCODER=1 (по умолчанию выкл) — держать
#        между картинками и энкодер условий.
#  11) v9, после п.10:
#      • ggml: GGML_ROPE_TYPE_PA_TABLE / ggml_rope_pa_table — RoPE по готовой таблице 2x2 на пару
#        (та же pe, что у sd.cpp: [[cos,-sin],[sin,cos]]) одной операцией внутри GGML_OP_ROPE; ядро
#        Metal kernel_rope_pa_table_f32 читает переставленный вид q/k и пишет сразу [d, L, H] —
#        без REPEAT, без MUL/ADD по половинкам, без CONT до и после; эталон на процессоре;
#      • sd.cpp, Qwen-Image 2.1: q/k через эту RoPE; срезы по токенам вокруг внимания и в modulate —
#        видами без копий; v в half одним приведением из переставленного вида (ggml_extend).
#        SD_PA_ROPE=0 — граф v8 целиком (для сравнения A/B). Замер блока 10 на телефоне
#        24.09.2026: RoPE+копии ~100–150 мс из ~300 мс блока;
#      • менеджер памяти при SD_KEEP_WEIGHTS: сперва выселяются части ДЕШЕВЛЕ просящей (энкодер
#        для рисующей части), потом её собственные куски — рисующая часть больше не выселяет
#        свои следующие куски, пока в памяти лежит энкодер; SD_KEEP_ENCODER действует, только
#        если все веса влезают в бюджет (иначе строка «PA RESIDENCY SD_KEEP_ENCODER не действует»).
#  12) v10a, после п.11 — умножение на матричных
#      блоках A19, режимы GGML_METAL_NAX=3..6 (0..2 — как были). Своя библиотека шейдеров (собирается
#      при первом умножении в этих режимах; не собралась — умножение прежним путём), свой крючок в начале
#      ggml_metal_op_mul_mat; берёт только плоские умножения с float-активациями, K кратно 32, >8 токенов,
#      веса f16/q4_0/q8_0/q4_K/q5_K/q6_K. Во всех режимах активации переводятся в half один раз на
#      умножение в постоянный буфер видеочипа (GGML_METAL_NAXA_ACT=f32 — читать float, как патч 7),
#      плитки обходятся полосами по GGML_METAL_NAXA_SWZ плиток весов (по умолчанию 8, 1 — построчно):
#      • 3 — «прямое» ядро: SIMD-группа сама грузит фрагменты весов и активаций из памяти в регистры,
#        веса q4_K/q4_0/q8_0 разворачиваются прямо в регистрах, без общей памяти и барьеров с памятью
#        (как fp16-ядро MLX и W4A8 Cider); плитка 128 токенов × 128 весов, 16 групп по 32×32;
#      • 4 — «два прохода»: веса слоя → half в тот же буфер (до ~100 МБ на 12288×4096), затем прямое ядро
#        режима 3 на плотных half-весах — потолок без цены K-квантов;
#      • 5 — «прямое», плитка 64 × 128, 4 группы по 32×64 (больше счёта на одну загрузку);
#      • 6 — веса через общую память, но двойной буфер и ОДИН барьер на шаг K=32, плитка 64 × 128.
#      Отдельного ядра на «хвост» токенов (1054 = 1024 + 30) нет: SIMD-группы без живых строк
#      не считают вовсе, у прямых ядер нет общих барьеров — пустая часть плитки ничего не стоит.
#      Замер «Проверить ядро» (п.10) гоняет и режимы 3..6 (PA_KERNEL_BENCH_MODES, PA_KERNEL_BENCH_TYPES —
#      свой список); в журнал — строки «PA NAXA: умножение …» и счёт за картинку под строкой патча 7.
#      GGML_METAL_PA_NAX_EMU=1 — только для проверки на мини (M1): блок 16×32×16 считается обычными
#      simdgroup-матрицами с той же раскладкой. Проверено на мини 25.09.2026: точность всех режимов
#      и типов равна старому ядру (f16 0,0010, q4_K 0,0216 …, 30 размеров рисующей части — без ошибок);
#      картинка 512² зерно 42: без переменной — до бита v9, режимы 3–6 — 57,2 дБ к v9.
#      Скорость — только на телефоне (tools/bench/image-plans/na-A.json).
#  13) инженер B, после п.12 (своя правка, общих ядер нет):
#      режим GGML_METAL_NAX=7 (в v10b был 4; 4 теперь — «два прохода» п.12) — веса линейных слоёв рисующей части (transformer_blocks.*.weight, q4_K)
#      при загрузке ПЕРЕУПАКОВЫВАЮТСЯ «плитками» (src/pa_repack.h): те же 144 байта на 256 весов,
#      только в другом порядке — каждой нити SIMD-группы её кусок правого операнда matmul2d 16x32x16
#      лежит одним uint4. Память не растёт (0 %), числа не меняются (масштаб d·sc и сдвиг dmin·m,
#      как в dequantize_q4_K). Новый тип ggml GGML_TYPE_PA_Q4_K_T («pa_q4_K_t») несёт раскладку с
#      тензором, и такие веса считает только ядро режима 7 (любое число токенов); процессор их не
#      читает. Ядро kernel_mul_mm_pa4_* (имя осталось от прежнего номера) — СВОЯ маленькая библиотека шейдеров из строки в
#      ggml-metal-ops.cpp: основная и библиотека MLX (п.7) не тронуты; нет блоков или ядро не
#      собралось — веса просто не переупаковываются (строка «PA NAX4: режим 7 — …» в журнале).
#      Ядро: без общей памяти и барьеров, веса прямо в регистры, развёртка в регистрах, шаг K 256,
#      volatile compiler_barrier как у MLX/Cider; плитки GGML_METAL_NAX7_TILE (старое имя GGML_METAL_NAX4_TILE тоже
#      понимается) = b (64x64, по умолчанию), a (64x128), c (128x128), d (64x128 1x4), e (128x128, 16 групп). GGML_METAL_PA4_EMU=1 или общий с п.12 GGML_METAL_PA_NAX_EMU=1 — только для проверки на M1
#      (блок 16x32x16 обычными simdgroup_matrix). В «Проверить ядро» — раздел «Режим 7» (строки KB4* — имя
#      строк оставлено ради разбора), при своём PA_KERNEL_BENCH_MODES — только если в списке есть 7;
#      в счёте за картинку — хвост «режим 7: pa_q4_K_t → B4 b (f32) ×N» на строке патча 7.
#      v11 (25.09.2026): п.12 и п.13 в одной сборке. Порядок наложения — 12, потом 13; правки п.13
#      в ggml-metal-ops.cpp и pa_kernel_bench.cpp пересобраны поверх п.12. Общий план телефона —
#      tools/bench/image-plans/na-final.json.
#  14) v12 — FLUX.3 Image Klein, перенос апстрима; подробности у «патч 14» ниже.
#  15) v13 — точки разреза шага FLUX.3 (иначе iOS обрывает шаг); у «патч 15» ниже.
# Исходники каждый раз возвращаются к чистому коммиту и правятся заново.
pa_sd_apply_patches() {  # pa_sd_apply_patches <исходники> <журнал>
  src="$1"; log="$2"
  git -C "$src" checkout -q -- . >>"$log" 2>&1 \
    && git -C "$src/ggml" checkout -q -- . >>"$log" 2>&1 \
    || { echo "❌ не вернул исходники движка к чистому коммиту — см. $log" >&2; return 1; }
  # checkout не трогает файлы, которых нет в коммите, а правка v6c такой создаёт —
  # без удаления вторая сборка в той же папке упала бы на «файл уже существует».
  rm -f "$src/src/pa_kernel_bench.cpp"
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_PATCH' \
    || { echo "❌ правка sd.cpp не легла — см. $log" >&2; return 1; }
diff --git a/src/core/ggml_runner.cpp b/src/core/ggml_runner.cpp
index 5957321..6b34098 100644
--- a/src/core/ggml_runner.cpp
+++ b/src/core/ggml_runner.cpp
@@ -1,4 +1,5 @@
 #include <algorithm>
+#include <cstdlib>
 #include <exception>
 #include <map>
 #include <utility>
@@ -835,7 +836,10 @@ std::optional<Tensor<float>> GGMLRunner::execute_graph(ggml_cgraph* graph, int n
     const bool segmented = !is_multi_device() && !sd_backend_is_cpu(runtime_backend) &&
                            manager != nullptr && manager->segmented_compute_enabled() &&
                            cached_plan.valid && cached_plan.has_cuts && cached_plan.segments.size() > 1 &&
-                           !fits(memory_requests(full_measurement.buffers, cache_.pending_bytes(graph)), params);
+                           // PocketAgent: SD_FORCE_SEGMENTED_COMPUTE режет граф по слоям даже когда он
+                           // влезает в память: на iOS один долгий командный буфер Metal система обрывает.
+                           (std::getenv("SD_FORCE_SEGMENTED_COMPUTE") != nullptr ||
+                            !fits(memory_requests(full_measurement.buffers, cache_.pending_bytes(graph)), params));
     ggml_graph_cut::Plan monolithic_plan;
     if (!segmented) {
         monolithic_plan.segments.emplace_back();
@@ -968,9 +972,17 @@ std::optional<Tensor<float>> GGMLRunner::execute_graph(ggml_cgraph* graph, int n
         }
         LOG_DEBUG("%s executing segment %zu/%zu: %s", get_desc().c_str(),
                   index + 1, plan.segments.size(), segment.group_name.c_str());
+        // PocketAgent: SD_SEGMENT_TIMING печатает время каждого куска — чтобы на телефоне
+        // было видно, куда уходит шаг рисования.
+        const bool pa_timing = std::getenv("SD_SEGMENT_TIMING") != nullptr;
+        const int64_t pa_t0  = pa_timing ? ggml_time_us() : 0;
         if (!execute_segment(segment_graph, n_threads)) {
             return fail_segment("execution");
         }
+        if (pa_timing) {
+            LOG_INFO("%s segment %zu/%zu %s: %.1f ms", get_desc().c_str(), index + 1,
+                     plan.segments.size(), segment.group_name.c_str(), (ggml_time_us() - pa_t0) / 1000.0);
+        }
         auto cache_status = cache_.capture(segment_graph);
         if (cache_status == GGML_STATUS_SUCCESS) {
             cache_status = cut_cache_.capture(graph, segment, get_desc().c_str());
PA_SD_PATCH
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V5_PATCH' \
    || { echo "❌ правка sd.cpp v5 (проявка в half, колбэк шагов) не легла — см. $log" >&2; return 1; }
diff --git a/src/core/util.cpp b/src/core/util.cpp
--- a/src/core/util.cpp
+++ b/src/core/util.cpp
@@ -600,7 +600,10 @@
 void pretty_bytes_progress(int step, int steps, uint64_t bytes_processed, float elapsed_seconds) {
     if (sd_progress_cb) {
-        float time = elapsed_seconds / (step + 1e-6f);
-        sd_progress_cb(step, steps, time, sd_progress_cb_data);
+        // PocketAgent: подгрузка весов НЕ идёт в колбэк шагов. Со «с диска» каждый
+        // шаг подгружает куски заново, и счёт «1 из 4 тензоров» первого куска
+        // турбо (4 шага) приложение принимало за шаги рисования — строка шагов
+        // в «Подробностях» была из нулей.
+        (void) elapsed_seconds;
         return;
     }
     if (step == 0) {
diff --git a/src/model/vae/wan_vae.hpp b/src/model/vae/wan_vae.hpp
--- a/src/model/vae/wan_vae.hpp
+++ b/src/model/vae/wan_vae.hpp
@@ -1,6 +1,7 @@
 #ifndef __SD_MODEL_VAE_WAN_VAE_HPP__
 #define __SD_MODEL_VAE_WAN_VAE_HPP__

+#include <cstdlib>
 #include <map>
 #include <memory>
 #include <utility>
@@ -91,6 +92,14 @@
                 }
                 ggml_tensor* x2 = ggml_reshape_4d(ctx->ggml_ctx, x, x->ne[0], x->ne[1], in_channels, 1);
                 ggml_tensor* w2 = ggml_reshape_4d(ctx->ggml_ctx, w, w->ne[0], w->ne[1], in_channels, out_channels);
+                // PocketAgent: SD_VAE_F16 — веса проявки bf16 переводятся в half прямо в графе
+                // (через f32: Metal не копирует bf16 → f16 напрямую). Тогда и развёртка
+                // свёртки (im2col) идёт в half, а не f32, и умножение — half × half, которое
+                // матричные блоки A19 считают сами; bf16 × f32 они не берут.
+                if (w2->type == GGML_TYPE_BF16 && std::getenv("SD_VAE_F16") != nullptr) {
+                    w2 = ggml_cast(ctx->ggml_ctx, w2, GGML_TYPE_F32);
+                    w2 = ggml_cast(ctx->ggml_ctx, w2, GGML_TYPE_F16);
+                }
                 x2              = ggml_ext_conv_2d(ctx->ggml_ctx, x2, w2, b,
                                                    std::get<2>(stride), std::get<1>(stride), 0, 0,
                                                    std::get<2>(dilation), std::get<1>(dilation),
PA_SD_V5_PATCH
  git -C "$src/ggml" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_GGML_PATCH' \
    || { echo "❌ правка ggml-metal не легла — см. $log" >&2; return 1; }
diff --git a/src/ggml-metal/ggml-metal-context.m b/src/ggml-metal/ggml-metal-context.m
index 32d97cd..8d1ae52 100644
--- a/src/ggml-metal/ggml-metal-context.m
+++ b/src/ggml-metal/ggml-metal-context.m
@@ -247,7 +247,12 @@ void ggml_metal_synchronize(ggml_metal_t ctx) {
     {
         const int n_cb = ctx->n_cb;
 
-        for (int cb_idx = 0; cb_idx <= n_cb; ++cb_idx) {
+        // PocketAgent: проверяем в порядке ИСПОЛНЕНИЯ (буфер главного потока n_cb
+        // уходит первым) и печатаем ВСЕ упавшие, а не только первый по номеру —
+        // иначе в журнал попадает «невинная жертва», а настоящая ошибка теряется.
+        bool pa_failed = false;
+        for (int k = 0; k <= n_cb; ++k) {
+            const int cb_idx = (k == 0) ? n_cb : k - 1;
             id<MTLCommandBuffer> cmd_buf = ctx->cmd_bufs[cb_idx].obj;
             if (!cmd_buf) {
                 continue;
@@ -255,14 +260,17 @@ void ggml_metal_synchronize(ggml_metal_t ctx) {
 
             MTLCommandBufferStatus status = [cmd_buf status];
             if (status != MTLCommandBufferStatusCompleted) {
-                GGML_LOG_ERROR("%s: error: command buffer %d failed with status %d\n", __func__, cb_idx, (int) status);
+                GGML_LOG_ERROR("%s: error: command buffer %d (run order %d) failed with status %d\n", __func__, cb_idx, k, (int) status);
                 if (status == MTLCommandBufferStatusError) {
                     GGML_LOG_ERROR("error: %s\n", [[cmd_buf error].localizedDescription UTF8String]);
                 }
-                ctx->has_error = true;
-                return;
+                pa_failed = true;
             }
         }
+        if (pa_failed) {
+            ctx->has_error = true;
+            return;
+        }
     }
 
     // release any completed extra command buffers
PA_GGML_PATCH
  git -C "$src/ggml" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_GGML_TENSOR_PATCH' \
    || { echo "❌ правка тензорного умножения ggml-metal не легла — см. $log" >&2; return 1; }
diff --git a/src/ggml-metal/ggml-metal-device.cpp b/src/ggml-metal/ggml-metal-device.cpp
--- a/src/ggml-metal/ggml-metal-device.cpp
+++ b/src/ggml-metal/ggml-metal-device.cpp
@@ -786,6 +786,12 @@
 
         const size_t smem_a = NRA * N_MM_NK_TOTAL * sizeof(ggml_fp16_t);
         res.smem = smem_a;
+        if (ggml_metal_device_get_props(ggml_metal_library_get_device(lib))->tensor_f16b) {
+            // PocketAgent: + плитка активаций в half, и обе плитки — в двух экземплярах
+            // (двойной буфер вместо второго барьера на каждом шаге по K): 24 КБ.
+            const size_t smem_b = NRB * N_MM_NK_TOTAL * sizeof(ggml_fp16_t);
+            res.smem = 2 * (smem_a + smem_b);
+        }
     } else {
         res.nr0 = 64;
         res.nr1 = 32;
diff --git a/src/ggml-metal/ggml-metal-device.h b/src/ggml-metal/ggml-metal-device.h
--- a/src/ggml-metal/ggml-metal-device.h
+++ b/src/ggml-metal/ggml-metal-device.h
@@ -261,6 +261,7 @@
     bool has_unified_memory;
     bool has_bfloat;
     bool has_tensor;
+    bool tensor_f16b; // PocketAgent: активации в тензорном mul_mm — half в общей памяти группы
     bool use_residency_sets;
     bool use_shared_buffers;
 
diff --git a/src/ggml-metal/ggml-metal-device.m b/src/ggml-metal/ggml-metal-device.m
--- a/src/ggml-metal/ggml-metal-device.m
+++ b/src/ggml-metal/ggml-metal-device.m
@@ -222,6 +222,10 @@
                     [prep setObject:@"1" forKey:@"GGML_METAL_HAS_TENSOR"];
                 }
 
+                if (ggml_metal_device_get_props(dev)->tensor_f16b) {
+                    [prep setObject:@"1" forKey:@"GGML_METAL_TENSOR_F16B"];
+                }
+
 #if GGML_METAL_EMBED_LIBRARY
                 [prep setObject:@"1" forKey:@"GGML_METAL_EMBED_LIBRARY"];
 #endif
@@ -859,6 +863,20 @@
                 }
             }
 
+            // PocketAgent: в тензорном mul_mm активации (src1) переводятся в half и кладутся
+            // в общую память группы, чтобы матричные блоки A19/M5 получали half x half:
+            // FP32 они не считают, и float-активации из памяти устройства уводят умножение
+            // на обычные вычислители.
+            // Точность — как у обычного simdgroup-пути, который и так режет активации до half.
+            // По умолчанию ВКЛ, выключается GGML_METAL_TENSOR_F16=0 (переключатель в приложении).
+            dev->props.tensor_f16b = dev->props.has_tensor;
+            {
+                const char * pa_f16 = getenv("GGML_METAL_TENSOR_F16");
+                if (pa_f16 != NULL && pa_f16[0] == '0') {
+                    dev->props.tensor_f16b = false;
+                }
+            }
+
             dev->props.use_residency_sets = true;
 #if defined(GGML_METAL_HAS_RESIDENCY_SETS)
             dev->props.use_residency_sets = getenv("GGML_METAL_NO_RESIDENCY") == nil;
@@ -938,6 +956,7 @@
             GGML_LOG_INFO("%s: has unified memory    = %s\n", __func__, dev->props.has_unified_memory      ? "true" : "false");
             GGML_LOG_INFO("%s: has bfloat            = %s\n", __func__, dev->props.has_bfloat              ? "true" : "false");
             GGML_LOG_INFO("%s: has tensor            = %s\n", __func__, dev->props.has_tensor              ? "true" : "false");
+            GGML_LOG_INFO("%s: tensor half B (PA)    = %s\n", __func__, dev->props.tensor_f16b             ? "true" : "false");
             GGML_LOG_INFO("%s: use residency sets    = %s\n", __func__, dev->props.use_residency_sets      ? "true" : "false");
             GGML_LOG_INFO("%s: use shared buffers    = %s\n", __func__, dev->props.use_shared_buffers      ? "true" : "false");
 
diff --git a/src/ggml-metal/ggml-metal.metal b/src/ggml-metal/ggml-metal.metal
--- a/src/ggml-metal/ggml-metal.metal
+++ b/src/ggml-metal/ggml-metal.metal
@@ -10141,6 +10141,117 @@
     const int ra = tgpig.y * NRA;
     const int rb = tgpig.x * NRB;
 
+#if defined(GGML_METAL_TENSOR_F16B)
+    // PocketAgent: матричные блоки A19/M5 считают half x half, а FP32 — нет. Штатно B
+    // (активации, float) читался прямо из памяти устройства, и умножение уходило на
+    // обычные вычислители. Здесь B переводится в SB (half; у bf16-весов — bfloat) и
+    // кладётся в общую память группы рядом с A — как в обычном simdgroup-пути, который
+    // и так режет активации до half, так что точность та же.
+    // Обе плитки — в двух экземплярах: шаг K пишет в один, пока другой ещё читает
+    // умножение прошлого шага, поэтому барьер на шаг один, а не два.
+    // Место в общей памяти задаёт ggml_metal_library_get_pipeline_mul_mm (24 КБ).
+    constexpr int SA_TILE = NRA * N_MM_NK_TOTAL;
+    constexpr int SB_TILE = NRB * N_MM_NK_TOTAL;
+    threadgroup SA * sa_base = (threadgroup SA *)(shmem);
+    threadgroup SB * sb_base = (threadgroup SB *)(shmem + 2 * SA_TILE * sizeof(SA));
+
+    constexpr int A_WORK_ITEMS = NRA * N_MM_NK;
+    constexpr int B_WORK_ITEMS = NRB * (N_MM_NK_TOTAL / 4);
+    constexpr int NUM_THREADS = N_SIMDWIDTH * N_MM_SIMD_GROUP_X * N_MM_SIMD_GROUP_Y;
+
+    device const T1 * ptrB = (device const T1 *)(srcB + args.nb12*i12 + args.nb13*i13);
+    const int strideB = args.nb11 / sizeof(T1);
+
+    mpp::tensor_ops::matmul2d<
+        mpp::tensor_ops::matmul2d_descriptor(
+            NRB, NRA, N_MM_NK_TOTAL, false, true, true,
+            mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate),
+        execution_simdgroups<N_MM_SIMD_GROUP_X * N_MM_SIMD_GROUP_Y>> mm;
+
+    auto tA0 = tensor(sa_base, dextents<int32_t, 2>(N_MM_NK_TOTAL, NRA));
+    auto tB0 = tensor(sb_base, dextents<int32_t, 2>(N_MM_NK_TOTAL, NRB));
+    auto cT = mm.get_destination_cooperative_tensor<decltype(tB0), decltype(tA0), float>();
+
+    short buf = 0;
+    for (int loop_k = 0; loop_k < K; loop_k += N_MM_NK_TOTAL, buf ^= 1) {
+        threadgroup SA * sa = sa_base + buf * SA_TILE;
+        threadgroup SB * sb = sb_base + buf * SB_TILE;
+
+        // === A: веса, развёртка в SA (как в штатном ядре) ===
+        for (int work = tiitg; work < A_WORK_ITEMS; work += NUM_THREADS) {
+            const int row = work / N_MM_NK;
+            const int k_chunk = work % N_MM_NK;
+            const int k_pos = loop_k + k_chunk * 16;
+            const short k_base = k_chunk * 16;
+
+            if (ra + row < M) {
+                if (is_same<T0_4x4, block_q>::value && FC_mul_mm_bc_inp) {
+                    device const T0 * row_ptr = (device const T0 *)(srcA + args.nb01 * (ra + row) + offset0);
+
+                    FOR_UNROLL (short i = 0; i < 16; i++) {
+                        sa[row * N_MM_NK_TOTAL + (k_base + i)] = (k_pos + i < K) ? (SA) row_ptr[k_pos + i] : (SA)0;
+                    }
+                } else {
+                    const int block_idx = k_pos / (16 * nl);
+                    const short il = (k_pos / 16) % nl;
+
+                    device const block_q * row_ptr = (device const block_q *)(srcA + args.nb01 * (ra + row) + offset0);
+
+                    SA_4x4 temp_a;
+                    dequantize_func(row_ptr + block_idx, il, temp_a);
+
+                    FOR_UNROLL (short i = 0; i < 16; i++) {
+                        sa[row * N_MM_NK_TOTAL + (k_base + i)] = (k_pos + i < K) ? temp_a[i/4][i%4] : (SA)0;
+                    }
+                }
+            } else {
+                FOR_UNROLL (short i = 0; i < 16; i++) {
+                    sa[row * N_MM_NK_TOTAL + (k_base + i)] = (SA)0;
+                }
+            }
+        }
+
+        // === B: активации, по 4 подряд, перевод в SB ===
+        for (int work = tiitg; work < B_WORK_ITEMS; work += NUM_THREADS) {
+            const int col = work / (N_MM_NK_TOTAL / 4);
+            const short k4 = (work % (N_MM_NK_TOTAL / 4)) * 4;
+            const int k_pos = loop_k + k4;
+            threadgroup SB * dstB = sb + col * N_MM_NK_TOTAL + k4;
+
+            if (rb + col < N) {
+                device const T1 * src = ptrB + (int64_t)(rb + col) * strideB + k_pos;
+                if (!FC_mul_mm_bc_inp) {
+                    // K кратно 32: четвёрка целиком внутри строки (так же читает и
+                    // обычный simdgroup-путь — векторно, без проверок).
+                    const vec<T1, 4> v = *((device const vec<T1, 4> *) src);
+                    FOR_UNROLL (short i = 0; i < 4; i++) {
+                        dstB[i] = (SB) v[i];
+                    }
+                } else {
+                    FOR_UNROLL (short i = 0; i < 4; i++) {
+                        dstB[i] = (k_pos + i < K) ? (SB) src[i] : (SB)0;
+                    }
+                }
+            } else {
+                FOR_UNROLL (short i = 0; i < 4; i++) {
+                    dstB[i] = (SB)0;
+                }
+            }
+        }
+
+        threadgroup_barrier(mem_flags::mem_threadgroup);
+
+        // === Умножение: half x half из общей памяти группы ===
+        auto mA = tensor(sa, dextents<int32_t, 2>(N_MM_NK_TOTAL, NRA));
+        auto mB = tensor(sb, dextents<int32_t, 2>(N_MM_NK_TOTAL, NRB));
+
+        mm.run(mB, mA, cT);
+
+        // Второго барьера нет: следующий шаг пишет в другой экземпляр, а в этот
+        // запишет только через шаг — после барьера, которого все достигнут, лишь
+        // закончив это умножение.
+    }
+#else
     // Threadgroup memory for dequantized A tile only
     threadgroup SA * sa = (threadgroup SA *)(shmem);
 
@@ -10219,6 +10330,8 @@
         threadgroup_barrier(mem_flags::mem_threadgroup);
     }
 
+#endif // GGML_METAL_TENSOR_F16B
+
     // Store result tile to output matrix (with batch offset)
     // cT.store handles bounds checking via tD's extents (M, N)
     device float * dstBatch = (device float *)dst + im * N * M;
PA_GGML_TENSOR_PATCH
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V6C_PATCH' \
    || { echo "❌ правка sd.cpp v6c (замер ядра) не легла — см. $log" >&2; return 1; }
diff --git a/include/stable-diffusion.h b/include/stable-diffusion.h
index a2bfdb6..07d3f89 100644
--- a/include/stable-diffusion.h
+++ b/include/stable-diffusion.h
@@ -611,6 +611,11 @@ SD_API void save_imatrix(const char* imatrix_path);
 SD_API void enable_imatrix_collection(void);
 SD_API void disable_imatrix_collection(void);
 
+// PocketAgent: замер ядра умножения на видеочипе (штатное против схемы MLX) —
+// отчёт строками, первая — итог. Модель не нужна.
+SD_API const char* sd_pa_kernel_bench(void);
+// PocketAgent: какие ядра умножения реально брались с прошлого сброса (строка для журнала).
+SD_API const char* sd_pa_kernel_stats(int reset);
 SD_API const char* sd_commit(void);
 SD_API const char* sd_version(void);
 
diff --git a/src/pa_kernel_bench.cpp b/src/pa_kernel_bench.cpp
new file mode 100644
index 0000000..a9c7851
--- /dev/null
+++ b/src/pa_kernel_bench.cpp
@@ -0,0 +1,429 @@
+// PocketAgent: замер ядра умножения на телефоне.
+//
+// Зачем. Ядро по схеме MLX (kernel_mul_mm_nax*, правка движка v6c) работает только на
+// матричных блоках A19/M5 — на Мак-мини (M1) их нет, и ни правильность, ни скорость там
+// не проверить. Эта функция одним нажатием в приложении прогоняет умножения размеров
+// рисующей части Qwen-Image штатным ядром и новым (обе плитки) и отдаёт отчёт строками:
+//   • точность — полное сравнение с эталоном на процессоре (float, double-сумма) на
+//     маленьком случае с неровными краями, и выборочное (256 точек) на больших;
+//   • время — лучший из трёх прогонов после прогрева, и во сколько раз быстрее.
+// Модель не нужна: веса и активации случайные, память — сотни мегабайт на время замера.
+// Режим ядра, который действовал до замера, возвращается в конце.
+
+#include "stable-diffusion.h"
+
+#include "ggml-alloc.h"
+#include "ggml-backend.h"
+#include "ggml.h"
+
+#include <algorithm>
+#include <cmath>
+#include <cstdlib>
+#include <cstdarg>
+#include <cstdio>
+#include <cstring>
+#include <random>
+#include <string>
+#include <vector>
+
+#if defined(__APPLE__)
+extern "C" {
+void ggml_metal_pa_set_nax(int mode);
+int  ggml_metal_pa_get_nax(void);
+int  ggml_metal_pa_nax_compiled(void);
+void ggml_metal_pa_nax_stats(char * buf, size_t len, int reset);
+}
+#endif
+
+namespace {
+
+std::string g_pa_report;
+
+struct PaLog {
+    std::string text;
+};
+
+void pa_log_cb(enum ggml_log_level level, const char* text, void* user) {
+    if (!user || !text) {
+        return;
+    }
+    auto* log = (PaLog*) user;
+    // Нужны предупреждения/ошибки и наши строки — не весь журнал подъёма видеочипа.
+    if (level >= GGML_LOG_LEVEL_WARN || strstr(text, "(PA)") || strstr(text, "PA NAX") ||
+        strstr(text, "GPU name") || strstr(text, "has tensor")) {
+        log->text += text;
+    }
+}
+
+void appendf(std::string& s, const char* fmt, ...) {
+    char buf[1024];
+    va_list ap;
+    va_start(ap, fmt);
+    vsnprintf(buf, sizeof(buf), fmt, ap);
+    va_end(ap);
+    s += buf;
+}
+
+const char* mode_name(int mode) {
+    switch (mode) {
+        case 0: return "старое";
+        case 1: return "MLX 64x64";
+        case 2: return "MLX 128x128";
+        default: return "?";
+    }
+}
+
+// Одно умножение: веса [M строк x K] типа type, активации float [N токенов x K].
+struct PaCase {
+    ggml_context* ctx      = nullptr;
+    ggml_backend_buffer_t buf = nullptr;
+    ggml_tensor* a         = nullptr;
+    ggml_tensor* b         = nullptr;
+    ggml_tensor* c         = nullptr;
+    ggml_cgraph* gf        = nullptr;
+
+    ~PaCase() {
+        if (buf) ggml_backend_buffer_free(buf);
+        if (ctx) ggml_free(ctx);
+    }
+
+    bool init(ggml_backend_t be, ggml_type type, int M, int K, int N, uint32_t seed) {
+        ggml_init_params ip = {};
+        ip.mem_size   = ggml_tensor_overhead() * 8 + ggml_graph_overhead();
+        ip.mem_buffer = nullptr;
+        ip.no_alloc   = true;
+        ctx           = ggml_init(ip);
+        if (!ctx) return false;
+        a  = ggml_new_tensor_2d(ctx, type, K, M);
+        b  = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, N);
+        c  = ggml_mul_mat(ctx, a, b);
+        gf = ggml_new_graph(ctx);
+        ggml_build_forward_expand(gf, c);
+        buf = ggml_backend_alloc_ctx_tensors(ctx, be);
+        if (!buf) return false;
+
+        // Заполняем кусками, чтобы не держать на процессоре гигабайт float разом.
+        std::mt19937 rng(seed);
+        std::uniform_real_distribution<float> uw(-1.0f, 1.0f);
+        const size_t row_a = ggml_row_size(type, K);
+        const int chunk = std::max(1, (1 << 20) / K);
+        std::vector<float> tmp((size_t) chunk * K);
+        std::vector<uint8_t> q((size_t) chunk * row_a);
+        for (int r0 = 0; r0 < M; r0 += chunk) {
+            const int nr = std::min(chunk, M - r0);
+            for (size_t i = 0; i < (size_t) nr * K; i++) tmp[i] = 0.05f * uw(rng);
+            ggml_quantize_chunk(type, tmp.data(), q.data(), 0, nr, K, nullptr);
+            ggml_backend_tensor_set(a, q.data(), (size_t) r0 * row_a, (size_t) nr * row_a);
+        }
+        for (int r0 = 0; r0 < N; r0 += chunk) {
+            const int nr = std::min(chunk, N - r0);
+            for (size_t i = 0; i < (size_t) nr * K; i++) tmp[i] = uw(rng);
+            ggml_backend_tensor_set(b, tmp.data(), (size_t) r0 * K * sizeof(float), (size_t) nr * K * sizeof(float));
+        }
+        return true;
+    }
+
+    // Строка весов m в float (так, как её видит видеочип после развёртки).
+    void weight_row(int m, int K, std::vector<float>& out) const {
+        const size_t row = ggml_row_size(a->type, K);
+        std::vector<uint8_t> raw(row);
+        ggml_backend_tensor_get(a, raw.data(), (size_t) m * row, row);
+        out.resize(K);
+        ggml_get_type_traits(a->type)->to_float(raw.data(), out.data(), K);
+    }
+
+    void act_row(int n, int K, std::vector<float>& out) const {
+        out.resize(K);
+        ggml_backend_tensor_get(b, out.data(), (size_t) n * K * sizeof(float), (size_t) K * sizeof(float));
+    }
+};
+
+// Прогон: прогрев + 3 замера. Возвращает лучшее время в мс, <0 — сбой видеочипа.
+double run_timed(ggml_backend_t be, ggml_cgraph* gf, int reps) {
+    if (ggml_backend_graph_compute(be, gf) != GGML_STATUS_SUCCESS) return -1.0;
+    ggml_backend_synchronize(be);
+    double best = 1e30;
+    for (int i = 0; i < reps; i++) {
+        const int64_t t0 = ggml_time_us();
+        if (ggml_backend_graph_compute(be, gf) != GGML_STATUS_SUCCESS) return -1.0;
+        ggml_backend_synchronize(be);
+        best = std::min(best, (ggml_time_us() - t0) / 1000.0);
+    }
+    return best;
+}
+
+}  // namespace
+
+const char* sd_pa_kernel_bench(void) {
+    g_pa_report.clear();
+    std::string& R = g_pa_report;
+    PaLog log;
+    ggml_log_set(pa_log_cb, &log);
+
+#if !defined(__APPLE__)
+    R = "Проверка ядра: только на Apple\n";
+    ggml_log_set(nullptr, nullptr);
+    return R.c_str();
+#else
+    ggml_time_init();
+
+    // Видеочип: сперва через реестр бэкенда Metal по имени, потом любой GPU/IGPU,
+    // потом любое устройство с именем MTL*. Телефон 24.09.2026 ответил «не открылся»
+    // на простом поиске по типу — теперь при неудаче в отчёт идёт список устройств
+    // и журнал ggml, чтобы было видно почему.
+    std::string devs;
+    ggml_backend_dev_t dev = nullptr;
+    if (ggml_backend_reg_t reg = ggml_backend_reg_by_name("Metal")) {
+        if (ggml_backend_reg_dev_count(reg) > 0) dev = ggml_backend_reg_dev_get(reg, 0);
+    }
+    for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
+        ggml_backend_dev_t d = ggml_backend_dev_get(i);
+        const auto t = ggml_backend_dev_type(d);
+        appendf(devs, "  устройство %zu: %s (%s), тип %d\n", i, ggml_backend_dev_name(d),
+                ggml_backend_dev_description(d), (int) t);
+        const char* nm = ggml_backend_dev_name(d);
+        if (!dev && (t == GGML_BACKEND_DEVICE_TYPE_GPU || t == GGML_BACKEND_DEVICE_TYPE_IGPU ||
+                     (nm && strncmp(nm, "MTL", 3) == 0))) {
+            dev = d;
+        }
+    }
+    ggml_backend_t be = dev ? ggml_backend_dev_init(dev, nullptr) : nullptr;
+    if (!be) {
+        R = dev ? "Проверка ядра: видеочип найден, но не открылся — см. журнал\n"
+                : "Проверка ядра: видеочип не найден — см. журнал\n";
+        R += "реестр бэкендов: " + std::to_string(ggml_backend_reg_count()) + ", устройств: " +
+             std::to_string(ggml_backend_dev_count()) + "\n" + devs;
+        if (!log.text.empty()) R += "Журнал ggml:\n" + log.text;
+        ggml_log_set(nullptr, nullptr);
+        return R.c_str();
+    }
+
+    const int mode_before = ggml_metal_pa_get_nax();
+    // -1 — ядра MLX ещё не собирали (соберутся на первом подходящем умножении), 0 — нет
+    const int compiled_at_start = ggml_metal_pa_nax_compiled();
+
+    std::vector<int> modes = {0};
+    if (compiled_at_start != 0) {
+        modes.push_back(1);
+        modes.push_back(2);
+    }
+
+    std::string head, body, summary;
+    appendf(head, "Проверка ядра умножения (ROADMAP §24), видеочип %s\n", ggml_backend_dev_description(dev));
+    appendf(head, "ядро по схеме MLX: %s; режим в работе: %s\n",
+            compiled_at_start == 0 ? "нет (нет матричных блоков или не собралось раньше)" : "есть матричные блоки",
+            compiled_at_start == 0 ? mode_name(0) : mode_name(mode_before));
+
+    bool any_fail  = false;
+    bool any_error = false;
+    // Сбой видеочипа переводит контекст в «ошибку» до пересоздания: пересоздаём, а режим,
+    // на котором упало, дальше не гоняем — иначе каждый следующий прогон тоже «упадёт».
+    bool mode_dead[3] = { false, false, false };
+    auto gpu_failed = [&](int mode) {
+        any_error       = true;
+        mode_dead[mode] = true;
+        ggml_backend_free(be);
+        be = ggml_backend_dev_init(dev, nullptr);
+    };
+    // Короткий прогон (только точность и один размер) — для проверки самой проверки.
+    const bool quick = getenv("PA_KERNEL_BENCH_QUICK") != nullptr;
+
+    // --- 1. Точность: маленький случай с неровными краями, полное сравнение ---
+    {
+        const int M = 200, K = 512, N = 100;
+        const ggml_type types[] = { GGML_TYPE_F16, GGML_TYPE_Q4_K, GGML_TYPE_Q4_0, GGML_TYPE_Q3_K };
+        appendf(body, "\nТочность, %dx%d x %d токенов (эталон — процессор, float/double), макс. ошибка / сред. модуль:\n", M, K, N);
+        for (ggml_type type : types) {
+            PaCase pc;
+            if (!pc.init(be, type, M, K, N, 1234)) {
+                appendf(body, "  %s: не выделилась память\n", ggml_type_name(type));
+                any_error = true;
+                continue;
+            }
+            // эталон
+            std::vector<double> ref((size_t) M * N);
+            std::vector<float> wr, ar;
+            std::vector<std::vector<float>> W(M);
+            for (int m = 0; m < M; m++) pc.weight_row(m, K, W[m]);
+            double mean_abs = 0;
+            for (int n = 0; n < N; n++) {
+                pc.act_row(n, K, ar);
+                for (int m = 0; m < M; m++) {
+                    double s = 0;
+                    for (int k = 0; k < K; k++) s += (double) W[m][k] * ar[k];
+                    ref[(size_t) n * M + m] = s;
+                    mean_abs += std::fabs(s);
+                }
+            }
+            mean_abs /= (double) M * N;
+            appendf(body, "  %-5s", ggml_type_name(type));
+            double err_old = -1;
+            for (int mode : modes) {
+                if (!be) break;
+                if (mode_dead[mode]) { appendf(body, " · %s пропущено", mode_name(mode)); continue; }
+                ggml_metal_pa_set_nax(mode);
+                std::vector<float> out((size_t) M * N, NAN);
+                if (ggml_backend_graph_compute(be, pc.gf) != GGML_STATUS_SUCCESS) {
+                    appendf(body, " · %s: СБОЙ видеочипа", mode_name(mode));
+                    gpu_failed(mode);
+                    continue;
+                }
+                ggml_backend_synchronize(be);
+                ggml_backend_tensor_get(pc.c, out.data(), 0, out.size() * sizeof(float));
+                double maxe = 0;
+                bool bad = false;
+                for (size_t i = 0; i < out.size(); i++) {
+                    if (!std::isfinite(out[i])) { bad = true; break; }
+                    maxe = std::max(maxe, std::fabs(out[i] - ref[i]));
+                }
+                const double rel = maxe / std::max(1e-12, mean_abs);
+                if (mode == 0) err_old = rel;
+                // Годно, если не хуже штатного втрое и в пределах половинной точности.
+                const bool ok = !bad && (mode == 0 || rel <= std::max(3.0 * err_old, 0.02));
+                if (!ok && mode != 0) any_fail = true;
+                if (bad) appendf(body, " · %s: НЕ ЧИСЛА", mode_name(mode));
+                else appendf(body, " · %s %.4f%s", mode_name(mode), rel, ok ? "" : " ОШИБКА");
+            }
+            body += "\n";
+        }
+    }
+
+    // --- 2. Скорость на размерах рисующей части ---
+    struct Sz { ggml_type type; int M, K, N; };
+    const Sz sizes[] = {
+        { GGML_TYPE_Q4_K,  3072,  3072, 1024 },
+        { GGML_TYPE_Q4_K, 12288,  3072, 1024 },
+        { GGML_TYPE_Q4_K,  3072, 12288, 1024 },
+        { GGML_TYPE_Q4_K,  3072,  3072, 2304 },
+        { GGML_TYPE_Q4_K, 12288,  4096, 2304 },
+        { GGML_TYPE_F16,   3072,  3072, 1024 },
+        { GGML_TYPE_F16,  12288,  3072, 1024 },
+        { GGML_TYPE_F16,  12288,  4096, 2304 },
+        { GGML_TYPE_Q4_0, 12288,  3072, 1024 },
+        { GGML_TYPE_Q3_K, 12288,  3072, 1024 },
+    };
+    appendf(body, "\nСкорость (лучший из 3 прогонов, мс; в скобках трлн операций/с), выход x вход x токены:\n");
+    double best_gain = 0;
+    std::string best_gain_what;
+    double sum_old = 0, sum_new[3] = {0, 0, 0};
+    int n_sum = 0;
+    for (const Sz& s : sizes) {
+        if (!be) break;
+        if (quick && &s != &sizes[0]) break;
+        PaCase pc;
+        if (!pc.init(be, s.type, s.M, s.K, s.N, 42)) {
+            appendf(body, "  %s %dx%dx%d: не выделилась память\n", ggml_type_name(s.type), s.M, s.K, s.N);
+            any_error = true;
+            continue;
+        }
+        const double flop = 2.0 * s.M * s.K * s.N;
+        appendf(body, "  %-5s %5dx%5dx%4d:", ggml_type_name(s.type), s.M, s.K, s.N);
+
+        // выборочная проверка: 256 точек против процессора
+        std::mt19937 rng(7);
+        std::vector<std::pair<int, int>> pts;
+        for (int i = 0; i < 256; i++) pts.push_back({ (int) (rng() % s.N), (int) (rng() % s.M) });
+        std::vector<double> ref(pts.size());
+        double mean_abs = 0;
+        {
+            std::vector<float> w, x;
+            for (size_t i = 0; i < pts.size(); i++) {
+                pc.weight_row(pts[i].second, s.K, w);
+                pc.act_row(pts[i].first, s.K, x);
+                double acc = 0;
+                for (int k = 0; k < s.K; k++) acc += (double) w[k] * x[k];
+                ref[i] = acc;
+                mean_abs += std::fabs(acc);
+            }
+            mean_abs /= pts.size();
+        }
+
+        double t_old = -1, err_old = -1;
+        bool row_ok = true;
+        for (int mode : modes) {
+            if (!be) break;
+            if (mode_dead[mode]) { appendf(body, " · %s пропущено", mode_name(mode)); row_ok = false; continue; }
+            ggml_metal_pa_set_nax(mode);
+            const double t = run_timed(be, pc.gf, 3);
+            if (t < 0) {
+                appendf(body, " · %s СБОЙ видеочипа", mode_name(mode));
+                gpu_failed(mode);
+                row_ok = false;
+                continue;
+            }
+            double maxe = 0;
+            bool bad = false;
+            for (size_t i = 0; i < pts.size(); i++) {
+                float v = NAN;
+                ggml_backend_tensor_get(pc.c, &v, ((size_t) pts[i].first * s.M + pts[i].second) * sizeof(float), sizeof(float));
+                if (!std::isfinite(v)) { bad = true; break; }
+                maxe = std::max(maxe, std::fabs(v - ref[i]));
+            }
+            const double rel = maxe / std::max(1e-12, mean_abs);
+            if (mode == 0) { t_old = t; err_old = rel; }
+            const bool ok = !bad && (mode == 0 || rel <= std::max(3.0 * err_old, 0.02));
+            if (!ok) { any_fail = true; row_ok = false; }
+            appendf(body, " · %s %.1f (%.2f)%s", mode_name(mode), t, flop / (t * 1e-3) / 1e12,
+                    bad ? " НЕ ЧИСЛА" : (ok ? "" : " ОШИБКА"));
+            if (mode != 0 && t_old > 0 && ok) {
+                appendf(body, " ×%.2f", t_old / t);
+                if (t_old / t > best_gain) {
+                    best_gain = t_old / t;
+                    char w[128];
+                    snprintf(w, sizeof(w), "%s, %s %dx%dx%d", mode_name(mode), ggml_type_name(s.type), s.M, s.K, s.N);
+                    best_gain_what = w;
+                }
+            }
+            if (row_ok) {
+                if (mode == 0) sum_old += t; else sum_new[mode] += t;
+            }
+        }
+        if (row_ok) n_sum++;
+        body += "\n";
+    }
+
+    ggml_metal_pa_set_nax(-1);  // обратно к тому, что задаёт приложение (GGML_METAL_NAX)
+    if (be) ggml_backend_free(be);
+    ggml_log_set(nullptr, nullptr);
+
+    // Итоговая строка — её приложение показывает человеку.
+    const int compiled = ggml_metal_pa_nax_compiled();
+    appendf(head, "ядра MLX после замера: %s\n", compiled == 1 ? "собраны" : (compiled == 0 ? "НЕ собрались — считало старое" : "не понадобились"));
+    if (compiled != 1) {
+        summary = "Ядро MLX не собрано — работает старое";
+    } else if (any_fail) {
+        summary = "Ядро MLX считает НЕВЕРНО — выключите «Ядро MLX»";
+    } else if (any_error) {
+        summary = mode_dead[1] || mode_dead[2] ? "Ядро MLX уронило видеочип — выключите «Ядро MLX»"
+                                               : "Сбой видеочипа при замере — см. журнал";
+    } else if (n_sum > 0 && sum_old > 0) {
+        char b[256];
+        snprintf(b, sizeof(b), "Верно · всего: старое %.0f мс, MLX 64 — %.0f (×%.2f), MLX 128 — %.0f (×%.2f)",
+                 sum_old, sum_new[1], sum_old / std::max(1e-9, sum_new[1]),
+                 sum_new[2], sum_old / std::max(1e-9, sum_new[2]));
+        summary = b;
+    } else {
+        summary = "Замер не дал чисел — см. журнал";
+    }
+
+    R = summary + "\n" + head + body;
+    if (!best_gain_what.empty()) {
+        appendf(R, "\nЛучше всего: ×%.2f (%s)\n", best_gain, best_gain_what.c_str());
+    }
+    if (!log.text.empty()) {
+        R += "\nЖурнал видеочипа за замер:\n" + log.text;
+    }
+    return R.c_str();
+#endif
+}
+
+const char* sd_pa_kernel_stats(int reset) {
+    static char buf[4096];
+#if defined(__APPLE__)
+    ggml_metal_pa_nax_stats(buf, sizeof(buf), reset);
+#else
+    (void) reset;
+    snprintf(buf, sizeof(buf), "PA NAX: не Apple");
+#endif
+    return buf;
+}
PA_SD_V6C_PATCH
  git -C "$src/ggml" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_GGML_V6C_PATCH' \
    || { echo "❌ правка ggml-metal v6c (ядро по схеме MLX) не легла — см. $log" >&2; return 1; }
diff --git a/src/ggml-metal/ggml-metal-context.m b/src/ggml-metal/ggml-metal-context.m
index 8d1ae52..271edb6 100644
--- a/src/ggml-metal/ggml-metal-context.m
+++ b/src/ggml-metal/ggml-metal-context.m
@@ -110,7 +110,9 @@ ggml_metal_t ggml_metal_init(ggml_metal_device_t dev) {
     }
 
     res->dev = dev;
-    res->lib = ggml_metal_device_get_library(dev);
+    // PocketAgent: операции берут библиотеку УСТРОЙСТВА, а не контекста — если её нет,
+    // дособрать в устройство, иначе первая же операция падает по адресу 0x18.
+    res->lib = ggml_metal_device_ensure_library(dev);
     if (res->lib == NULL) {
         GGML_LOG_WARN("%s: the device does not have a precompiled Metal library - this is unexpected\n", __func__);
         GGML_LOG_WARN("%s: will try to compile it on the fly\n", __func__);
@@ -449,6 +451,13 @@ enum ggml_status ggml_metal_graph_compute(ggml_metal_t ctx, struct ggml_cgraph *
         return GGML_STATUS_FAILED;
     }
 
+    // PocketAgent: операции берут библиотеку устройства; без неё — отказ с причиной,
+    // а не падение приложения на первом же конвейере.
+    if (ggml_metal_device_ensure_library(ctx->dev) == NULL) {
+        GGML_LOG_ERROR("%s: библиотека шейдеров Metal не собралась — считать нечем\n", __func__);
+        return GGML_STATUS_FAILED;
+    }
+
     // number of nodes encoded by the main thread (empirically determined)
     const int n_main = MAX(64, 0.1*gf->n_nodes);
 
diff --git a/src/ggml-metal/ggml-metal-device.cpp b/src/ggml-metal/ggml-metal-device.cpp
index 920cf14..ab8aa87 100644
--- a/src/ggml-metal/ggml-metal-device.cpp
+++ b/src/ggml-metal/ggml-metal-device.cpp
@@ -8,6 +8,191 @@
 #include <memory>
 #include <string>
 #include <unordered_map>
+#include <atomic>
+#include <cstdio>
+#include <cstdlib>
+#include <mutex>
+#include <unordered_set>
+
+// PocketAgent: режим ядра умножения по схеме MLX (см. ggml-metal-device.h).
+static std::atomic<int> g_pa_nax_mode{-1};
+static std::atomic<int> g_pa_nax_compiled{-1};
+
+void ggml_metal_pa_set_nax(int mode) {
+    g_pa_nax_mode.store(mode);
+}
+
+int ggml_metal_pa_get_nax(void) {
+    const int m = g_pa_nax_mode.load();
+    if (m >= 0) {
+        return m;
+    }
+    // Переменная читается на каждом выборе ядра (не один раз за жизнь приложения):
+    // выключатель в приложении действует со следующей картинки, без перезапуска.
+    const char * e = getenv("GGML_METAL_NAX");
+    if (e == nullptr || e[0] == '\0') {
+        return 1; // по умолчанию ВКЛ, если ядра собрались
+    }
+    const int v = atoi(e);
+    return (v >= 0 && v <= 2) ? v : 1;
+}
+
+int ggml_metal_pa_nax_compiled(void) {
+    return g_pa_nax_compiled.load();
+}
+
+void ggml_metal_pa_nax_set_compiled(int v) {
+    g_pa_nax_compiled.store(v);
+}
+
+// Какое ядро умножения реально взято — чтобы с телефона было видно, работает ли
+// новое или молча уступает старому. Каждое новое сочетание «тип весов → ядро (причина)»
+// пишется в журнал один раз; счёт за картинку отдаёт ggml_metal_pa_nax_stats.
+static std::mutex g_pa_stat_mu;
+static std::unordered_map<std::string, long> g_pa_stat;
+
+static void pa_nax_count(const ggml_tensor * op, int kernel, const char * why) {
+    char key[160];
+    if (kernel > 0) {
+        snprintf(key, sizeof(key), "%s → MLX %s", ggml_type_name(op->src[0]->type), kernel == 2 ? "128" : "64");
+    } else {
+        snprintf(key, sizeof(key), "%s → старое (%s)", ggml_type_name(op->src[0]->type), why && why[0] ? why : "?");
+    }
+    std::lock_guard<std::mutex> lk(g_pa_stat_mu);
+    long & c = g_pa_stat[key];
+    if (c++ == 0) {
+        GGML_LOG_INFO("PA NAX: умножение %s [%lldx%lld x %lld]\n", key,
+                      (long long) op->src[0]->ne[1], (long long) op->src[0]->ne[0], (long long) op->src[1]->ne[1]);
+    }
+}
+
+void ggml_metal_pa_nax_stats(char * buf, size_t len, int reset) {
+    std::string out = "PA NAX: ядра собраны = " + std::to_string(g_pa_nax_compiled.load()) +
+                      ", режим " + std::to_string(ggml_metal_pa_get_nax()) + "; умножений:";
+    std::lock_guard<std::mutex> lk(g_pa_stat_mu);
+    for (const auto & kv : g_pa_stat) {
+        out += " " + kv.first + " ×" + std::to_string(kv.second) + ";";
+    }
+    if (g_pa_stat.empty()) {
+        out += " не было";
+    }
+    if (reset) {
+        g_pa_stat.clear();
+    }
+    if (buf && len) {
+        snprintf(buf, len, "%s", out.c_str());
+    }
+}
+
+// Какие веса умеет kernel_mul_mm_nax: имя в шейдере совпадает с ggml_type_name.
+static bool pa_nax_type_ok(ggml_type t) {
+    switch (t) {
+        case GGML_TYPE_F16:
+        case GGML_TYPE_Q4_0:
+        case GGML_TYPE_Q4_1:
+        case GGML_TYPE_Q5_0:
+        case GGML_TYPE_Q5_1:
+        case GGML_TYPE_Q8_0:
+        case GGML_TYPE_Q2_K:
+        case GGML_TYPE_Q3_K:
+        case GGML_TYPE_Q4_K:
+        case GGML_TYPE_Q5_K:
+        case GGML_TYPE_Q6_K:
+            return true;
+        default:
+            return false;
+    }
+}
+
+// Ядро по схеме MLX, если оно подходит к этому умножению; иначе pipeline == nullptr
+// и вызывающий берёт штатное. Условия — ровно те, что ядро предполагает без проверок:
+// K кратно 64 (шаг разворота весов), активации float подряд и выровнены по 16 байт
+// (читаются по четыре), выход подряд.
+static ggml_metal_pipeline_with_params pa_nax_pipeline(ggml_metal_library_t lib, const ggml_tensor * op, const char ** why) {
+    ggml_metal_pipeline_with_params res = {};
+    res.pipeline = nullptr;
+
+    const int mode = ggml_metal_pa_get_nax();
+    if (mode <= 0) {
+        *why = "режим выключен";
+        return res;
+    }
+    const ggml_metal_device_props * props = ggml_metal_device_get_props(ggml_metal_library_get_device(lib));
+    if (!props->has_tensor || !props->pa_nax) {
+        *why = "нет ядер MLX в библиотеке";
+        return res;
+    }
+
+    const ggml_tensor * s0 = op->src[0];
+    const ggml_tensor * s1 = op->src[1];
+    if (!pa_nax_type_ok(s0->type) || s1->type != GGML_TYPE_F32 || op->type != GGML_TYPE_F32) {
+        *why = "тип весов/активаций";
+        return res;
+    }
+    if (s0->ne[0] % 64 != 0 || s0->nb[0] != ggml_type_size(s0->type)) {
+        *why = "K не кратно 64";
+        return res;
+    }
+    if (s1->nb[0] != sizeof(float) || s1->nb[1] % 16 != 0 || s1->nb[2] % 16 != 0 || s1->nb[3] % 16 != 0) {
+        *why = "активации не подряд";
+        return res;
+    }
+    if (op->nb[0] != sizeof(float) || op->nb[1] != (size_t) op->ne[0] * sizeof(float)) {
+        *why = "выход не подряд";
+        return res;
+    }
+
+    // сюда не должны прийти, но на всякий случай — штатное ядро само проверяет то же
+    if (s1->ne[2] > INT16_MAX || s1->ne[3] > INT16_MAX) {
+        *why = "пакет слишком большой";
+        return res;
+    }
+
+    const int cfg = mode;
+    const int bw  = cfg == 2 ? 128 : 64;  // строки весов на группу
+    const int bt  = cfg == 2 ? 128 : 64;  // токены на группу
+    const int nsg = cfg == 2 ? 16  : 4;
+
+    char base[256];
+    snprintf(base, sizeof(base), "kernel_mul_mm_nax%d_%s_f32", cfg, ggml_type_name(s0->type));
+
+    // Не собравшийся конвейер не пробуем на каждом умножении заново.
+    static std::mutex pa_mu;
+    static std::unordered_set<std::string> pa_failed;
+    {
+        std::lock_guard<std::mutex> lk(pa_mu);
+        if (pa_failed.count(base)) {
+            *why = "конвейер не годится";
+            return res;
+        }
+    }
+
+    // Ядра лежат в отдельной библиотеке — основную (на ней весь движок) не трогаем.
+    ggml_metal_library_t nlib = ggml_metal_device_get_library_nax(ggml_metal_library_get_device(lib));
+    if (nlib == nullptr) {
+        *why = "ядра MLX не собрались";
+        return res;
+    }
+    ggml_metal_pipeline_with_params p = ggml_metal_library_get_pipeline(nlib, base);
+    if (!p.pipeline) {
+        p = ggml_metal_library_compile_pipeline(nlib, base, base, nullptr);
+    }
+    if (!p.pipeline || ggml_metal_pipeline_max_theads_per_threadgroup(p) < 32 * nsg) {
+        std::lock_guard<std::mutex> lk(pa_mu);
+        if (pa_failed.insert(base).second) {
+            GGML_LOG_WARN("%s: PA NAX: %s не годится (%s) — умножение штатным ядром\n", __func__, base,
+                          p.pipeline ? "мало нитей на группу" : "не собрался");
+        }
+        *why = "конвейер не годится";
+        return res;
+    }
+
+    p.nr0  = bw;
+    p.nr1  = bt;
+    p.nsg  = nsg;
+    p.smem = (size_t) bw * (64 + 8) * sizeof(ggml_fp16_t);
+    return p;
+}
 
 struct ggml_metal_device_deleter {
     void operator()(ggml_metal_device_t ctx) {
@@ -760,6 +945,16 @@ ggml_metal_pipeline_with_params ggml_metal_library_get_pipeline_mul_mm(ggml_meta
     const int16_t r2   = (int16_t) (ne12 / op->src[0]->ne[2]);
     const int16_t r3   = (int16_t) (ne13 / op->src[0]->ne[3]);
 
+    {
+        // PocketAgent: сначала ядро по схеме MLX (матричные блоки A19/M5), если подходит.
+        const char * why = "";
+        ggml_metal_pipeline_with_params pa = pa_nax_pipeline(lib, op, &why);
+        pa_nax_count(op, pa.pipeline ? ggml_metal_pa_get_nax() : 0, why);
+        if (pa.pipeline) {
+            return pa;
+        }
+    }
+
     snprintf(base, 256, "kernel_mul_mm_%s_%s", ggml_type_name(tsrc0), ggml_type_name(tsrc1));
     snprintf(name, 256, "%s_bci=%d_bco=%d_ne12=%d_ne13=%d_r2=%d_r3=%d",
              base, bc_inp, bc_out, ne12, ne13, r2, r3);
diff --git a/src/ggml-metal/ggml-metal-device.h b/src/ggml-metal/ggml-metal-device.h
index 87b6742..a88dd3b 100644
--- a/src/ggml-metal/ggml-metal-device.h
+++ b/src/ggml-metal/ggml-metal-device.h
@@ -262,6 +262,7 @@ struct ggml_metal_device_props {
     bool has_bfloat;
     bool has_tensor;
     bool tensor_f16b; // PocketAgent: активации в тензорном mul_mm — half в общей памяти группы
+    bool pa_nax;      // PocketAgent: пробовать ядра kernel_mul_mm_nax* (схема MLX, отдельная библиотека)
     bool use_residency_sets;
     bool use_shared_buffers;
 
@@ -326,6 +327,21 @@ void   ggml_metal_buffer_clear        (ggml_metal_buffer_t buf, uint8_t value);
 //
 struct ggml_metal_buffer_id ggml_metal_buffer_get_id(ggml_metal_buffer_t buf, const struct ggml_tensor * t);
 
+// PocketAgent: умножение на матричных блоках A19/M5 по схеме MLX (kernel_mul_mm_nax*).
+// Режим: 0 — штатное тензорное ядро, 1 — плитка 64x64 (4 SIMD-группы), 2 — 128x128 (16).
+// -1 — брать из переменной GGML_METAL_NAX (нет переменной — 1). Меняется на лету:
+// конвейеры кэшируются по имени, так что замер ядра переключает режим между прогонами.
+void ggml_metal_pa_set_nax(int mode);
+int  ggml_metal_pa_get_nax(void);
+// 1 — ядра собрались в библиотеке, 0 — нет (выключено или не собралось), -1 — ещё не знаем
+int  ggml_metal_pa_nax_compiled(void);
+void ggml_metal_pa_nax_set_compiled(int v);
+// Счёт выбранных ядер умножения с прошлого сброса (строка для журнала).
+void ggml_metal_pa_nax_stats(char * buf, size_t len, int reset);
+// Отдельная библиотека с ядрами по схеме MLX (NULL — нет/не собралась) и досборка основной.
+ggml_metal_library_t ggml_metal_device_get_library_nax(ggml_metal_device_t dev);
+ggml_metal_library_t ggml_metal_device_ensure_library(ggml_metal_device_t dev);
+
 #ifdef __cplusplus
 }
 #endif
diff --git a/src/ggml-metal/ggml-metal-device.m b/src/ggml-metal/ggml-metal-device.m
index 9e0832f..71729f0 100644
--- a/src/ggml-metal/ggml-metal-device.m
+++ b/src/ggml-metal/ggml-metal-device.m
@@ -104,7 +104,17 @@ int ggml_metal_pipeline_max_theads_per_threadgroup(struct ggml_metal_pipeline_wi
     NSLock * lock;
 };
 
+// PocketAgent: общая сборка библиотеки шейдеров. pa_nax — собрать ОТДЕЛЬНУЮ библиотеку
+// с ядрами по схеме MLX (kernel_mul_mm_nax*). Основная библиотека собирается ровно как
+// до правки v6c — без них: если компилятор телефона новое ядро не примет, это не должно
+// касаться библиотеки, на которой работает весь движок (падение 24.09.2026 18:08).
+static ggml_metal_library_t pa_library_init_ex(ggml_metal_device_t dev, bool pa_nax);
+
 ggml_metal_library_t ggml_metal_library_init(ggml_metal_device_t dev) {
+    return pa_library_init_ex(dev, false);
+}
+
+static ggml_metal_library_t pa_library_init_ex(ggml_metal_device_t dev, bool pa_nax) {
     id<MTLLibrary> library = nil;
     id<MTLDevice> device = ggml_metal_device_get_obj(dev);
 
@@ -226,6 +236,12 @@ ggml_metal_library_t ggml_metal_library_init(ggml_metal_device_t dev) {
                     [prep setObject:@"1" forKey:@"GGML_METAL_TENSOR_F16B"];
                 }
 
+                // PocketAgent: ядра умножения по схеме MLX (kernel_mul_mm_nax*) — только
+                // в отдельной библиотеке (ggml_metal_device_get_library_nax)
+                if (pa_nax) {
+                    [prep setObject:@"1" forKey:@"GGML_METAL_PA_NAX"];
+                }
+
 #if GGML_METAL_EMBED_LIBRARY
                 [prep setObject:@"1" forKey:@"GGML_METAL_EMBED_LIBRARY"];
 #endif
@@ -352,6 +368,12 @@ ggml_metal_device_t ggml_metal_library_get_device(ggml_metal_library_t lib) {
 }
 
 struct ggml_metal_pipeline_with_params ggml_metal_library_get_pipeline(ggml_metal_library_t lib, const char * name) {
+    if (lib == NULL) {
+        // PocketAgent: без библиотеки — пустой конвейер и строка в журнал, а не падение
+        GGML_LOG_ERROR("%s: нет библиотеки шейдеров Metal (конвейер %s)\n", __func__, name);
+        struct ggml_metal_pipeline_with_params none = { nil, 0, 0, 0, 0, false, false };
+        return none;
+    }
     [lib->lock lock];
 
     struct ggml_metal_pipeline_with_params res = {
@@ -382,6 +404,11 @@ struct ggml_metal_pipeline_with_params ggml_metal_library_compile_pipeline(ggml_
         /*.cnt      =*/ false,
     };
 
+    if (lib == NULL) {
+        GGML_LOG_ERROR("%s: нет библиотеки шейдеров Metal (конвейер %s)\n", __func__, name);
+        return res;
+    }
+
     [lib->lock lock];
 
     res.pipeline = ggml_metal_pipelines_get(lib->pipelines, name);
@@ -534,6 +561,11 @@ void ggml_metal_encoder_end_encoding(ggml_metal_encoder_t encoder) {
 
     ggml_metal_library_t library;
 
+    // PocketAgent: отдельная библиотека с ядрами по схеме MLX; nax_state: 0 — не собирали,
+    // 1 — собрана, -1 — не собралась (больше не пробуем)
+    ggml_metal_library_t library_nax;
+    int                  nax_state;
+
     struct ggml_metal_device_props props;
 
     // virtual address for GPU memory allocations
@@ -877,6 +909,14 @@ ggml_metal_device_t ggml_metal_device_init(int device) {
                 }
             }
 
+            // PocketAgent: ядра умножения по схеме MLX (крупные плитки, операнды в регистрах,
+            // execution_simdgroup) собираются всегда, когда есть тензорный путь, — чтобы замер
+            // ядра в приложении мог сравнить их со штатным даже при выключенном режиме.
+            // Какой режим действует — GGML_METAL_NAX (0 выкл, 1 — 64x64, 2 — 128x128; нет — 1)
+            // или ggml_metal_pa_set_nax. Не собрались на телефоне — библиотека пересобирается без них.
+            dev->props.pa_nax = dev->props.has_tensor;
+            ggml_metal_pa_nax_set_compiled(dev->props.pa_nax ? -1 : 0);
+
             dev->props.use_residency_sets = true;
 #if defined(GGML_METAL_HAS_RESIDENCY_SETS)
             dev->props.use_residency_sets = getenv("GGML_METAL_NO_RESIDENCY") == nil;
@@ -915,6 +955,8 @@ ggml_metal_device_t ggml_metal_device_init(int device) {
             if (!dev->library) {
                 GGML_LOG_ERROR("%s: error: failed to create library\n", __func__);
             }
+            dev->library_nax = NULL;
+            dev->nax_state   = 0;
 
             if (dev->props.use_residency_sets) {
                 dev->rsets = ggml_metal_rsets_init(dev);
@@ -957,6 +999,7 @@ ggml_metal_device_t ggml_metal_device_init(int device) {
             GGML_LOG_INFO("%s: has bfloat            = %s\n", __func__, dev->props.has_bfloat              ? "true" : "false");
             GGML_LOG_INFO("%s: has tensor            = %s\n", __func__, dev->props.has_tensor              ? "true" : "false");
             GGML_LOG_INFO("%s: tensor half B (PA)    = %s\n", __func__, dev->props.tensor_f16b             ? "true" : "false");
+            GGML_LOG_INFO("%s: tensor NAX (PA)       = %s, mode %d\n", __func__, dev->props.pa_nax ? "true" : "false", ggml_metal_pa_get_nax());
             GGML_LOG_INFO("%s: use residency sets    = %s\n", __func__, dev->props.use_residency_sets      ? "true" : "false");
             GGML_LOG_INFO("%s: use shared buffers    = %s\n", __func__, dev->props.use_shared_buffers      ? "true" : "false");
 
@@ -979,6 +1022,11 @@ void ggml_metal_device_free(ggml_metal_device_t dev) {
     ggml_metal_library_free(dev->library);
     dev->library = NULL;
 
+    if (dev->library_nax) {
+        ggml_metal_library_free(dev->library_nax);
+        dev->library_nax = NULL;
+    }
+
     if (dev->mtl_queue) {
         [dev->mtl_queue release];
         dev->mtl_queue = nil;
@@ -1004,6 +1052,42 @@ ggml_metal_library_t ggml_metal_device_get_library(ggml_metal_device_t dev) {
     return dev->library;
 }
 
+// PocketAgent: основная библиотека не собралась при подъёме устройства (бывает — и тогда
+// каждый контекст собирал СВОЮ, а умножения и прочие операции брали библиотеку устройства,
+// NULL, и падали обращением по адресу 0x18). Собрать ещё раз и положить в устройство.
+ggml_metal_library_t ggml_metal_device_ensure_library(ggml_metal_device_t dev) {
+    @synchronized (dev->mtl_device) {
+        if (dev->library == NULL) {
+            GGML_LOG_WARN("%s: библиотеки шейдеров у устройства нет — собираю заново\n", __func__);
+            dev->library = ggml_metal_library_init(dev);
+            if (dev->library == NULL) {
+                GGML_LOG_ERROR("%s: библиотека шейдеров Metal не собралась\n", __func__);
+            }
+        }
+        return dev->library;
+    }
+}
+
+// PocketAgent: библиотека с ядрами по схеме MLX — собирается один раз, при первом умножении,
+// которому она подходит. Не собралась — NULL навсегда, умножение идёт старым ядром.
+ggml_metal_library_t ggml_metal_device_get_library_nax(ggml_metal_device_t dev) {
+    if (!dev->props.pa_nax) {
+        return NULL;
+    }
+    @synchronized (dev->mtl_device) {
+        if (dev->nax_state == 0) {
+            GGML_LOG_INFO("%s: PA NAX: собираю ядра по схеме MLX отдельной библиотекой\n", __func__);
+            dev->library_nax = pa_library_init_ex(dev, true);
+            dev->nax_state   = dev->library_nax ? 1 : -1;
+            ggml_metal_pa_nax_set_compiled(dev->library_nax ? 1 : 0);
+            if (!dev->library_nax) {
+                GGML_LOG_WARN("%s: PA NAX: ядра по схеме MLX не собрались — умножение старым ядром\n", __func__);
+            }
+        }
+        return dev->library_nax;
+    }
+}
+
 void ggml_metal_device_rsets_add(ggml_metal_device_t dev, ggml_metal_rset_t rset) {
     if (rset == nil) {
         return;
diff --git a/src/ggml-metal/ggml-metal.metal b/src/ggml-metal/ggml-metal.metal
index e00e710..5cfb8a5 100644
--- a/src/ggml-metal/ggml-metal.metal
+++ b/src/ggml-metal/ggml-metal.metal
@@ -10989,6 +10989,259 @@ template [[host_name("kernel_mul_mm_iq1_m_f16")]]   kernel mul_mm_t kernel_mul_m
 template [[host_name("kernel_mul_mm_iq4_nl_f16")]]  kernel mul_mm_t kernel_mul_mm<half,   half4x4,   simdgroup_half8x8,   half,   half2x4,   simdgroup_half8x8,   block_iq4_nl,  2,     dequantize_iq4_nl,  float,  float4x4,  half, half2x4>;
 template [[host_name("kernel_mul_mm_iq4_xs_f16")]]  kernel mul_mm_t kernel_mul_mm<half,   half4x4,   simdgroup_half8x8,   half,   half2x4,   simdgroup_half8x8,   block_iq4_xs,  QK_NL, dequantize_iq4_xs,  float,  float4x4,  half, half2x4>;
 
+#if defined(GGML_METAL_HAS_TENSOR) && defined(GGML_METAL_PA_NAX)
+
+//
+// PocketAgent: умножение на матричных блоках A19/M5 по схеме MLX (GGML_METAL_PA_NAX)
+//
+// Схема взята из MLX: mlx/backend/metal/kernels/steel/gemm/nax.h и quantized_nax.h
+// (qmm_t_nax_tgp_impl), Copyright © 2025 Apple Inc., лицензия MIT.
+//
+// Чем отличается от штатного тензорного kernel_mul_mm (и почему он медленный на A19):
+//   • штатный зовёт ОДИН matmul2d на всю группу (execution_simdgroups<4>) с операндами
+//     в памяти — MPP сам раскладывает их по регистрам на каждом шаге; у MLX каждая
+//     SIMD-группа считает СВОЮ подплитку 32x32 кусками 16x32x16 на execution_simdgroup,
+//     а операнды уже лежат в регистрах (cooperative tensor) — так блоки и загружаются;
+//   • шаг по K 64 вместо 32 — вдвое меньше барьеров на тот же объём умножения;
+//   • активации (float) читаются прямо в регистры и тут же сужаются в half — блоки
+//     получают half x half (FP32 они не считают); общую память занимают только веса;
+//   • веса разворачиваются в half-плитку [BW][BK+8]: +8 — сдвиг строк против
+//     конфликтов банков памяти, как у MLX.
+// Раскладка элементов cooperative tensor для 16x32x16 на одной SIMD-группе Apple
+// не документирует — она взята у MLX, где проверена на M5 (get_coord ниже).
+//
+// Плитка группы: BT токенов x BW строк весов, WT x WW SIMD-групп, у каждой 32x32.
+// Применяется только когда K кратно 64 и активации float подряд (выбор — на хосте,
+// ggml_metal_library_get_pipeline_mul_mm), иначе работает штатное ядро.
+//
+namespace pa_nax {
+
+typedef vec<half,  8> frag_h;   // кусок 16x16: 32 нити x 8 значений
+typedef vec<float, 8> frag_f;
+
+// Нить lane владеет строками fm и fm+8, столбцами fn..fn+3 куска 16x16 (как у MLX).
+static inline short2 frag_coord(ushort lane) {
+    const short qid = lane >> 2;
+    const short fm  = ((qid & 4) | ((lane >> 1) & 3));
+    const short fn  = ((qid & 2) | (lane & 1)) * 4;
+    return short2(fn, fm);
+}
+
+// C(16x32) += A(16x16) * B^T, где B — два куска 16x16 в виде [строка весов][k].
+static inline void mma(thread frag_f & c0, thread frag_f & c1,
+                       thread const frag_h & a, thread const frag_h & b0, thread const frag_h & b1) {
+    constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
+        16, 32, 16, false, true, true,
+        mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
+    mpp::tensor_ops::matmul2d<desc, execution_simdgroup> op;
+
+    auto ca = op.template get_left_input_cooperative_tensor<half, half, float>();
+    auto cb = op.template get_right_input_cooperative_tensor<half, half, float>();
+    auto cc = op.template get_destination_cooperative_tensor<decltype(ca), decltype(cb), float>();
+
+    FOR_UNROLL (short i = 0; i < 8; i++) {
+        ca[i]     = a[i];
+        cb[i]     = b0[i];
+        cb[8 + i] = b1[i];
+        cc[i]     = c0[i];
+        cc[8 + i] = c1[i];
+    }
+
+    op.run(ca, cb, cc);
+
+    FOR_UNROLL (short i = 0; i < 8; i++) {
+        c0[i] = cc[i];
+        c1[i] = cc[8 + i];
+    }
+}
+
+} // namespace pa_nax
+
+template<
+    typename block_q, short nl, void (*dequantize_func)(device const block_q *, short, thread half4x4 &),
+    short BT, short BW, short WT, short WW>
+[[kernel, max_total_threads_per_threadgroup(WT * WW * 32)]]
+void kernel_mul_mm_nax(
+        constant ggml_metal_kargs_mul_mm & args,
+        device const char * srcA,
+        device const char * srcB,
+        device       char * dst,
+        threadgroup  char * shmem [[threadgroup(0)]],
+        uint3  tgpig [[threadgroup_position_in_grid]],
+        ushort tiitg [[thread_index_in_threadgroup]],
+        ushort sgitg [[simdgroup_index_in_threadgroup]],
+        ushort lane  [[thread_index_in_simdgroup]]) {
+    using namespace pa_nax;
+
+    constexpr short BK  = 64;            // шаг по K на один разворот весов
+    constexpr short BKP = BK + 8;        // строка плитки весов со сдвигом
+    constexpr short SK  = 32;            // K за один проход по регистрам
+    constexpr short TK  = SK / 16;
+    constexpr short ST  = BT / WT;       // подплитка SIMD-группы: токены
+    constexpr short SW  = BW / WW;       //                        строки весов
+    constexpr short TT  = ST / 16;
+    constexpr short TW  = SW / 16;
+    constexpr int   NTH = WT * WW * 32;
+    constexpr int   A_ITEMS = BW * (BK / 16);
+
+    static_assert(TW % 2 == 0, "подплитка по весам должна быть кратна 32");
+
+    const int K = args.ne00;
+    const int M = args.ne0;   // строки весов = столбцы результата
+    const int N = args.ne1;   // токены
+
+    const int im  = tgpig.z;
+    const int i12 = im % args.ne12;
+    const int i13 = im / args.ne12;
+    const uint64_t offset0 = (uint64_t)(i12 / args.r2) * args.nb02 + (uint64_t)(i13 / args.r3) * args.nb03;
+
+    const int w0 = tgpig.y * BW;
+    const int t0 = tgpig.x * BT;
+
+    const short sg_t = ST * (sgitg / WW);
+    const short sg_w = SW * (sgitg % WW);
+
+    const short n_t = (short) clamp(N - (t0 + sg_t), 0, (int) ST);   // живые токены подплитки
+    const short n_w = (short) clamp(M - (w0 + sg_w), 0, (int) SW);   // живые строки весов
+
+    threadgroup half * ws = (threadgroup half *) shmem;   // [BW][BKP]
+
+    const int ldx = (int)(args.nb11 / sizeof(float));
+    device const float * xb = (device const float *)(srcB + args.nb12 * i12 + args.nb13 * i13)
+                            + (int64_t)(t0 + sg_t) * ldx;
+
+    const short2 fc = frag_coord(lane);
+
+    frag_f D[TT][TW];
+    FOR_UNROLL (short i = 0; i < TT; i++) {
+        FOR_UNROLL (short j = 0; j < TW; j++) {
+            D[i][j] = frag_f(0.0f);
+        }
+    }
+
+    for (int k0 = 0; k0 < K; k0 += BK) {
+        // все SIMD-группы дочитали плитку прошлого шага
+        threadgroup_barrier(mem_flags::mem_threadgroup);
+
+        // === веса: развернуть BW x 64 в half ===
+        for (int work = tiitg; work < A_ITEMS; work += NTH) {
+            const short row = work / (BK / 16);
+            const short kc  = work % (BK / 16);
+            const int   kp  = k0 + kc * 16;
+
+            half4x4 tmp;
+            if (w0 + row < M) {
+                device const block_q * rp = (device const block_q *)(srcA + args.nb01 * (w0 + row) + offset0);
+                dequantize_func(rp + kp / (16 * nl), (short)((kp / 16) % nl), tmp);
+            } else {
+                tmp = half4x4(0.0h);
+            }
+
+            threadgroup half4 * d4 = (threadgroup half4 *)(ws + row * BKP + kc * 16);
+            d4[0] = tmp[0];
+            d4[1] = tmp[1];
+            d4[2] = tmp[2];
+            d4[3] = tmp[3];
+        }
+
+        threadgroup_barrier(mem_flags::mem_threadgroup);
+
+        if (n_t > 0 && n_w > 0) {
+            FOR_UNROLL (short kk = 0; kk < BK; kk += SK) {
+                frag_h A[TT][TK];   // активации: [токен][k]
+                frag_h B[TW][TK];   // веса:      [строка весов][k]
+
+                FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+                    FOR_UNROLL (short tk = 0; tk < TK; tk++) {
+                        FOR_UNROLL (short r = 0; r < 2; r++) {
+                            const short row = tt * 16 + fc.y + r * 8;
+                            float4 v = float4(0.0f);
+                            if (row < n_t) {
+                                v = *((device const float4 *)(xb + (int64_t) row * ldx + k0 + kk + tk * 16 + fc.x));
+                            }
+                            A[tt][tk][r * 4 + 0] = (half) v[0];
+                            A[tt][tk][r * 4 + 1] = (half) v[1];
+                            A[tt][tk][r * 4 + 2] = (half) v[2];
+                            A[tt][tk][r * 4 + 3] = (half) v[3];
+                        }
+                    }
+                }
+
+                FOR_UNROLL (short tw = 0; tw < TW; tw++) {
+                    FOR_UNROLL (short tk = 0; tk < TK; tk++) {
+                        FOR_UNROLL (short r = 0; r < 2; r++) {
+                            const short row = sg_w + tw * 16 + fc.y + r * 8;
+                            const half4 v = *((threadgroup const half4 *)(ws + row * BKP + kk + tk * 16 + fc.x));
+                            B[tw][tk][r * 4 + 0] = v[0];
+                            B[tw][tk][r * 4 + 1] = v[1];
+                            B[tw][tk][r * 4 + 2] = v[2];
+                            B[tw][tk][r * 4 + 3] = v[3];
+                        }
+                    }
+                }
+
+                FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+                    FOR_UNROLL (short tw = 0; tw < TW; tw += 2) {
+                        FOR_UNROLL (short tk = 0; tk < TK; tk++) {
+                            mma(D[tt][tw], D[tt][tw + 1], A[tt][tk], B[tw][tk], B[tw + 1][tk]);
+                        }
+                    }
+                }
+            }
+        }
+    }
+
+    // === результат: dst[токен][строка весов], float ===
+    if (n_t > 0 && n_w > 0) {
+        device float * dp = (device float *) dst + (int64_t) im * N * M
+                          + (int64_t)(t0 + sg_t) * M + (w0 + sg_w);
+
+        FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+            FOR_UNROLL (short tw = 0; tw < TW; tw++) {
+                FOR_UNROLL (short r = 0; r < 2; r++) {
+                    const short row = tt * 16 + fc.y + r * 8;
+                    if (row < n_t) {
+                        const short col = tw * 16 + fc.x;
+                        device float * p = dp + (int64_t) row * M + col;
+                        FOR_UNROLL (short j = 0; j < 4; j++) {
+                            if (col + j < n_w) {
+                                p[j] = D[tt][tw][r * 4 + j];
+                            }
+                        }
+                    }
+                }
+            }
+        }
+    }
+}
+
+#define PA_NAX_INST(cfg, tname, bq, nl, dq, BT, BW, WT, WW) \
+template [[host_name("kernel_mul_mm_nax" #cfg "_" #tname "_f32")]] [[kernel]] \
+decltype(kernel_mul_mm_nax<bq, nl, dq, BT, BW, WT, WW>) kernel_mul_mm_nax<bq, nl, dq, BT, BW, WT, WW>;
+
+// cfg 1: 64 токена x 64 веса, 4 SIMD-группы (как quantized_nax у MLX)
+// cfg 2: 128 x 128, 16 SIMD-групп (как крупные fp16-плитки steel_gemm_fused_nax у MLX)
+#define PA_NAX_INST_TYPE(tname, bq, nl, dq) \
+    PA_NAX_INST(1, tname, bq, nl, dq,  64,  64, 2, 2) \
+    PA_NAX_INST(2, tname, bq, nl, dq, 128, 128, 4, 4)
+
+PA_NAX_INST_TYPE(f16,  half4x4,    1,     dequantize_f16)
+PA_NAX_INST_TYPE(q4_0, block_q4_0, 2,     dequantize_q4_0)
+PA_NAX_INST_TYPE(q4_1, block_q4_1, 2,     dequantize_q4_1)
+PA_NAX_INST_TYPE(q5_0, block_q5_0, 2,     dequantize_q5_0)
+PA_NAX_INST_TYPE(q5_1, block_q5_1, 2,     dequantize_q5_1)
+PA_NAX_INST_TYPE(q8_0, block_q8_0, 2,     dequantize_q8_0)
+PA_NAX_INST_TYPE(q2_K, block_q2_K, QK_NL, dequantize_q2_K)
+PA_NAX_INST_TYPE(q3_K, block_q3_K, QK_NL, dequantize_q3_K)
+PA_NAX_INST_TYPE(q4_K, block_q4_K, QK_NL, dequantize_q4_K)
+PA_NAX_INST_TYPE(q5_K, block_q5_K, QK_NL, dequantize_q5_K)
+PA_NAX_INST_TYPE(q6_K, block_q6_K, QK_NL, dequantize_q6_K)
+
+#undef PA_NAX_INST_TYPE
+#undef PA_NAX_INST
+
+#endif // GGML_METAL_PA_NAX
+
 //
 // indirect matrix-matrix multiplication
 //
PA_GGML_V6C_PATCH
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V6A_PATCH' \
    || { echo "❌ правка sd.cpp v6a (проявка крупными плитками, веса между вызовами) не легла — см. $log" >&2; return 1; }
--- a/src/model/vae/wan_vae.hpp
+++ b/src/model/vae/wan_vae.hpp
@@ -13,9 +13,79 @@
 #include "model_loader.h"
 
 namespace WAN {
+    // PocketAgent: SD_VAE_FAST — быстрые пути проявки одного кадра.
+    inline bool pa_vae_fast() { return std::getenv("SD_VAE_FAST") != nullptr; }
 
     constexpr int CACHE_T = 2;
 
+    // PocketAgent: порог развёртки одной свёртки проявки (SD_VAE_BAND_MB, по умолчанию 256 МБ).
+    inline size_t pa_band_bytes() {
+        const char* v = std::getenv("SD_VAE_BAND_MB");
+        const long mb = v != nullptr ? std::atol(v) : 256;
+        return (size_t)(mb > 16 ? mb : 16) * 1024 * 1024;
+    }
+
+    // PocketAgent: SD_VAE_FAST — 2D-свёртка проявки (шаг 1, поля p) полосами по высоте.
+    // x: [W, H, IC, 1] f32, w: [KW, KH, IC, OC]. Результат: [OW, OH, OC, 1].
+    // • Развёртка (im2col) крупной плитки — самый большой тензор проявки: на 512² при 288
+    //   каналах это 1,36 ГБ. Полосы по SD_VAE_BAND_MB считаются по очереди, и распределитель
+    //   памяти графа отдаёт буфер развёртки следующей полосе — пик памяти в разы ниже.
+    //   Полосы читают вход «окном» строк (без копии), лишние строки на стыках отбрасываются.
+    // • Для одного кадра выход умножения уже лежит как [OW·OH, OC] = [OW, OH, OC, 1], и
+    //   штатная копия с перестановкой (ggml_conv_2d → cont) ничего не меняет — её нет.
+    // Числа те же: то же умножение над теми же строками развёртки.
+    inline ggml_tensor* pa_conv2d(GGMLRunnerContext* ctx, ggml_tensor* x, ggml_tensor* w, ggml_tensor* b, int p) {
+        ggml_context* g = ctx->ggml_ctx;
+        if (w->type == GGML_TYPE_BF16 && std::getenv("SD_VAE_F16") != nullptr) {
+            w = ggml_cast(g, ggml_cast(g, w, GGML_TYPE_F32), GGML_TYPE_F16);
+        }
+        const ggml_type it = w->type == GGML_TYPE_BF16 ? GGML_TYPE_F32 : GGML_TYPE_F16;
+        const int64_t W = x->ne[0], H = x->ne[1], IC = x->ne[2];
+        const int64_t KW = w->ne[0], KH = w->ne[1], OC = w->ne[3];
+        const int64_t OW = W + 2 * p - KW + 1;
+        const int64_t OH = H + 2 * p - KH + 1;
+        ggml_tensor* w2 = ggml_reshape_2d(g, w, KW * KH * IC, OC);
+
+        const size_t row_bytes = (size_t)OW * IC * KH * KW * ggml_type_size(it);
+        const size_t limit     = pa_band_bytes();
+        int64_t nb             = (int64_t)((OH * row_bytes + limit - 1) / limit);
+        nb                     = std::max<int64_t>(1, std::min<int64_t>(nb, OH));
+
+        ggml_tensor* out = nullptr;
+        if (nb == 1) {
+            ggml_tensor* ic = ggml_im2col(g, w, x, 1, 1, p, p, 1, 1, true, it);  // [IC·KH·KW, OW, OH, 1]
+            out             = ggml_mul_mat(g, ggml_reshape_2d(g, ic, ic->ne[0], OW * OH), w2);
+        } else {
+            const int64_t rows = (OH + nb - 1) / nb;
+            for (int64_t r0 = 0; r0 < OH; r0 += rows) {
+                const int64_t r1 = std::min(OH, r0 + rows);
+                // строка выхода r берёт строки входа r-p … r-p+KH-1 (вне [0,H) — нули)
+                const int64_t i0 = std::max<int64_t>(0, r0 - p);
+                const int64_t i1 = std::min<int64_t>(H, r1 - p + KH - 1);
+                ggml_tensor* xv  = ggml_view_4d(g, x, W, i1 - i0, IC, 1, x->nb[1], x->nb[2], x->nb[3], i0 * x->nb[1]);
+                ggml_tensor* ic  = ggml_im2col(g, w, xv, 1, 1, p, p, 1, 1, true, it);
+                const int64_t orows = ic->ne[2];
+                ggml_tensor* mm  = ggml_mul_mat(g, ggml_reshape_2d(g, ic, ic->ne[0], OW * orows), w2);  // [OW·orows, OC]
+                // строка j полосы — это строка i0+j выхода
+                ggml_tensor* v = ggml_view_2d(g, mm, OW * (r1 - r0), OC, mm->nb[1], (r0 - i0) * OW * mm->nb[0]);
+                out            = out == nullptr ? v : ggml_concat(g, out, v, 0);
+            }
+        }
+        out = ggml_reshape_4d(g, out, OW, OH, OC, 1);
+        if (b != nullptr) {
+            out = ggml_add_inplace(g, out, ggml_reshape_4d(g, b, 1, 1, OC, 1));
+        }
+        return out;
+    }
+
+    // PocketAgent: Conv2d с доступом к весам — для полосной свёртки в Resample (SD_VAE_FAST).
+    class PAConv2d : public Conv2d {
+    public:
+        using Conv2d::Conv2d;
+        ggml_tensor* pa_weight() { return params["weight"]; }
+        ggml_tensor* pa_bias() { return bias ? params["bias"] : nullptr; }
+    };
+
     class CausalConv3d : public GGMLBlock {
     protected:
         int64_t in_channels;
@@ -82,7 +152,17 @@
                 lp2 -= (int)cache_x->ne[2];
             }
 
-            x = ggml_ext_pad_ext(ctx->ggml_ctx, ctx->backend, x, lp0, rp0, lp1, rp1, lp2, rp2, 0, 0, ctx->circular_x_enabled, ctx->circular_y_enabled);
+            // PocketAgent: SD_VAE_FAST — у 2D-пути (один кадр, ядро глубины 1) поля по ширине
+            // и высоте даёт сама развёртка (im2col, нули те же), а не отдельная копия с полями:
+            // на Metal это две полные копии тензора (дополнение справа + сдвиг, #850).
+            const bool pa_pad_in_conv = pa_vae_fast() && w->ne[2] == 1 && x->ne[2] == 1 && x->ne[3] == in_channels &&
+                                        lp2 == 0 && rp2 == 0 && lp0 == rp0 && lp1 == rp1 && lp0 == lp1 &&
+                                        std::get<2>(stride) == 1 && std::get<1>(stride) == 1 &&
+                                        std::get<2>(dilation) == 1 && std::get<1>(dilation) == 1 &&
+                                        !ctx->circular_x_enabled && !ctx->circular_y_enabled;
+            if (!pa_pad_in_conv) {
+                x = ggml_ext_pad_ext(ctx->ggml_ctx, ctx->backend, x, lp0, rp0, lp1, rp1, lp2, rp2, 0, 0, ctx->circular_x_enabled, ctx->circular_y_enabled);
+            }
             if (w->ne[2] == 1 && x->ne[2] == 1 && x->ne[3] == in_channels) {
                 // One frame through a one-frame-deep kernel is a 2D conv; backends without
                 // im2col_3d (Metal) otherwise fall back to a much slower direct conv_3d.
@@ -99,6 +179,10 @@
                     w2 = ggml_cast(ctx->ggml_ctx, w2, GGML_TYPE_F32);
                     w2 = ggml_cast(ctx->ggml_ctx, w2, GGML_TYPE_F16);
                 }
+                if (pa_pad_in_conv) {
+                    ggml_tensor* y = pa_conv2d(ctx, x2, w2, b, lp0);
+                    return ggml_reshape_4d(ctx->ggml_ctx, y, y->ne[0], y->ne[1], 1, out_channels);
+                }
                 x2              = ggml_ext_conv_2d(ctx->ggml_ctx, x2, w2, b,
                                                    std::get<2>(stride), std::get<1>(stride), 0, 0,
                                                    std::get<2>(dilation), std::get<1>(dilation),
@@ -174,13 +258,13 @@
             : dim(dim), mode(mode) {
             if (mode == "upsample2d") {
                 if (wan2_2) {
-                    blocks["resample.1"] = std::shared_ptr<GGMLBlock>(new Conv2d(dim, dim, {3, 3}, {1, 1}, {1, 1}));
+                    blocks["resample.1"] = std::shared_ptr<GGMLBlock>(new PAConv2d(dim, dim, {3, 3}, {1, 1}, {1, 1}));
                 } else {
                     blocks["resample.1"] = std::shared_ptr<GGMLBlock>(new Conv2d(dim, dim / 2, {3, 3}, {1, 1}, {1, 1}));
                 }
             } else if (mode == "upsample3d") {
                 if (wan2_2) {
-                    blocks["resample.1"] = std::shared_ptr<GGMLBlock>(new Conv2d(dim, dim, {3, 3}, {1, 1}, {1, 1}));
+                    blocks["resample.1"] = std::shared_ptr<GGMLBlock>(new PAConv2d(dim, dim, {3, 3}, {1, 1}, {1, 1}));
                 } else {
                     blocks["resample.1"] = std::shared_ptr<GGMLBlock>(new Conv2d(dim, dim / 2, {3, 3}, {1, 1}, {1, 1}));
                 }
@@ -266,7 +350,13 @@
                 } else if (mode == "downsample3d") {
                     x = ggml_ext_pad(ctx->ggml_ctx, x, 1, 1, 0, 0, ctx->circular_x_enabled, ctx->circular_y_enabled);
                 }
-                x = resample_1->forward(ctx, x);
+                auto pa_rs = std::dynamic_pointer_cast<PAConv2d>(blocks["resample.1"]);
+                if (pa_vae_fast() && pa_rs != nullptr && x->ne[3] == 1 && !ctx->circular_x_enabled &&
+                    !ctx->circular_y_enabled && ctx->weight_adapter == nullptr && ggml_is_contiguous(x)) {
+                    x = pa_conv2d(ctx, x, pa_rs->pa_weight(), pa_rs->pa_bias(), 1);
+                } else {
+                    x = resample_1->forward(ctx, x);
+                }
                 x = ggml_ext_cont(ctx->ggml_ctx, ggml_ext_torch_permute(ctx->ggml_ctx, x, 0, 1, 3, 2));  // (c, t, h, w)
             }
 
@@ -370,6 +460,30 @@
             int64_t H = x->ne[1];
             int64_t W = x->ne[0];
 
+            // PocketAgent: SD_VAE_FAST — один кадр (картинка): короткий путь без склеек и
+            // трёх перестановок. Для одного кадра этот обход — просто «каждая точка входа ×2
+            // по ширине и высоте» с выбором каналов; формулы сверены с полным путём побитово
+            // (numpy на всех трёх соотношениях каналов проявки Qwen-Image 2.1, 24.09.2026).
+            // Полный путь считал два кадра и выбрасывал один, переставляя весь тензор трижды.
+            if (pa_vae_fast() && T == 1 && first_chunk && factor_s == 2) {
+                if (in_channels == out_channels) {
+                    return ggml_upscale(ctx->ggml_ctx, x, 2, GGML_SCALE_MODE_NEAREST);
+                }
+                if (in_channels == 2 * out_channels && factor_t == 2) {
+                    // выход co = вход 2·co+1
+                    auto v = ggml_view_4d(ctx->ggml_ctx, x, W, H, 1, out_channels,
+                                          x->nb[1], x->nb[2], x->nb[3] * 2, x->nb[3]);
+                    return ggml_upscale(ctx->ggml_ctx, ggml_cont(ctx->ggml_ctx, v), 2, GGML_SCALE_MODE_NEAREST);
+                }
+                if (in_channels == 2 * out_channels && factor_t == 1) {
+                    // выход (co, 2h+dy, w') = вход (2·co+dy, h, w'/2)
+                    auto r = ggml_reshape_4d(ctx->ggml_ctx, x, W, H, 2, out_channels);
+                    r      = ggml_cont(ctx->ggml_ctx, ggml_permute(ctx->ggml_ctx, r, 0, 2, 1, 3));  // [W, 2, H, Co]
+                    r      = ggml_reshape_4d(ctx->ggml_ctx, r, W, 2 * H, 1, out_channels);
+                    return ggml_interpolate(ctx->ggml_ctx, r, 2 * W, 2 * H, 1, out_channels, GGML_SCALE_MODE_NEAREST);
+                }
+            }
+
             auto x_ = x;
             for (int64_t i = 1; i < repeats; i++) {
                 x = ggml_concat(ctx->ggml_ctx, x, x_, 2);
@@ -580,7 +694,8 @@
                              int64_t b,
                              std::vector<ggml_tensor*>& feat_cache,
                              int& feat_idx,
-                             int chunk_idx) {
+                             int chunk_idx,
+                             const std::string& pa_cut = "") {
             // x: [b*c, t, h, w]
             GGML_ASSERT(b == 1);
             ggml_tensor* x_copy = x;
@@ -591,17 +706,27 @@
                 auto block             = std::dynamic_pointer_cast<ResidualBlock>(blocks[block_name]);
 
                 x = block->forward(ctx, x, b, feat_cache, feat_idx);
+                // PocketAgent: SD_VAE_SEGMENTS — рез после каждого остаточного блока (см. Decoder3d).
+                if (!pa_cut.empty()) {
+                    sd::ggml_graph_cut::mark_graph_cut(x, pa_cut + ".res." + std::to_string(i), "x");
+                }
             }
 
             if (up_flag) {
                 std::string block_name = "upsamples." + std::to_string(i);
                 auto block             = std::dynamic_pointer_cast<Resample>(blocks[block_name]);
                 x                      = block->forward(ctx, x, b, feat_cache, feat_idx, chunk_idx);
+                if (!pa_cut.empty()) {
+                    sd::ggml_graph_cut::mark_graph_cut(x, pa_cut + ".resample", "x");
+                }
 
                 auto avg_shortcut = std::dynamic_pointer_cast<DupUp3D>(blocks["avg_shortcut"]);
                 auto shortcut     = avg_shortcut->forward(ctx, x_copy, chunk_idx == 0, b);
 
                 x = ggml_add(ctx->ggml_ctx, x, shortcut);
+                if (!pa_cut.empty()) {
+                    sd::ggml_graph_cut::mark_graph_cut(x, pa_cut + ".out", "x");
+                }
             }
 
             return x;
@@ -981,13 +1106,31 @@
             } else {
                 x = conv1->forward(ctx, x);
             }
-            // sd::ggml_graph_cut::mark_graph_cut(x, "wan_vae.decoder.prelude", "x");
+            // PocketAgent: SD_VAE_SEGMENTS режет проявку на куски по остаточным блокам —
+            // тем же штатным механизмом, что режет шаг рисования (SD_FORCE_SEGMENTED_COMPUTE).
+            // Без резов проявка кадра — один граф, и на iOS долгий командный буфер видеочипа
+            // система обрывает; поэтому проявляли мелкими плитками 16×16, а плитки
+            // перекрываются и считают одни и те же точки по 2–3 раза. С резами кусок работы
+            // видеочипа — один блок, и плитку можно брать крупной.
+            // Только для одного кадра: у видео между кусками живёт кэш кадров.
+            const bool pa_cuts = std::getenv("SD_VAE_SEGMENTS") != nullptr && x->ne[2] == 1 && chunk_idx == 0;
+            if (pa_cuts) {
+                sd::ggml_graph_cut::mark_graph_cut(x, "wan_vae.decoder.prelude", "x");
+            }
 
             // middle
             x = middle_0->forward(ctx, x, b, feat_cache, feat_idx);
+            if (pa_cuts) {
+                sd::ggml_graph_cut::mark_graph_cut(x, "wan_vae.decoder.mid.0", "x");
+            }
             x = middle_1->forward(ctx, x, b);
+            if (pa_cuts) {
+                sd::ggml_graph_cut::mark_graph_cut(x, "wan_vae.decoder.mid.1", "x");
+            }
             x = middle_2->forward(ctx, x, b, feat_cache, feat_idx);
-            // sd::ggml_graph_cut::mark_graph_cut(x, "wan_vae.decoder.mid", "x");
+            if (pa_cuts) {
+                sd::ggml_graph_cut::mark_graph_cut(x, "wan_vae.decoder.mid.2", "x");
+            }
 
             // upsamples
             std::vector<int64_t> dims = {dim_mult[dim_mult.size() - 1] * dim};
@@ -999,7 +1142,8 @@
                 if (wan2_2) {
                     auto layer = std::dynamic_pointer_cast<Up_ResidualBlock>(blocks["upsamples." + std::to_string(index++)]);
 
-                    x = layer->forward(ctx, x, b, feat_cache, feat_idx, chunk_idx);
+                    x = layer->forward(ctx, x, b, feat_cache, feat_idx, chunk_idx,
+                                       pa_cuts ? "wan_vae.decoder.up." + std::to_string(i) : std::string());
                 } else {
                     for (int j = 0; j < num_res_blocks + 1; j++) {
                         auto layer = std::dynamic_pointer_cast<ResidualBlock>(blocks["upsamples." + std::to_string(index++)]);
--- a/src/model_loader.cpp
+++ b/src/model_loader.cpp
@@ -1315,20 +1315,30 @@
             });
         }
 
+        // PocketAgent: ждём рабочих часто (2 мс), а полоску печатаем, как раньше, раз в 200 мс.
+        // Штатно главный поток спал по 200 мс между проверками, и любая подгрузка длилась
+        // не меньше 0,2 с, даже когда читать было нечего: проявка «с диска» платила это
+        // на каждой плитке и каждом куске (замер на M1 24.09.2026: 22 подгрузки по 0,20 с,
+        // из них чтение — 0,02 с).
+        int64_t pa_last_progress = -1000;
         while (true) {
             size_t current_idx = tensor_idx.load();
             if (current_idx >= tensors_to_process.size() || failed) {
                 break;
             }
-            size_t curr_num       = total_tensors_processed + current_idx;
-            float elapsed_seconds = (ggml_time_ms() - t_start) / 1000.0f;
-            if (log_progress && total_tensors_to_process > 0) {
-                pretty_bytes_progress(static_cast<int>(curr_num),
-                                      static_cast<int>(total_tensors_to_process),
-                                      bytes_processed.load(),
-                                      elapsed_seconds);
+            const int64_t pa_now = ggml_time_ms();
+            if (pa_now - pa_last_progress >= (total_tensors_to_process <= 4 ? 10 : 200)) {
+                pa_last_progress      = pa_now;
+                size_t curr_num       = total_tensors_processed + current_idx;
+                float elapsed_seconds = (pa_now - t_start) / 1000.0f;
+                if (log_progress && total_tensors_to_process > 0) {
+                    pretty_bytes_progress(static_cast<int>(curr_num),
+                                          static_cast<int>(total_tensors_to_process),
+                                          bytes_processed.load(),
+                                          elapsed_seconds);
+                }
             }
-            std::this_thread::sleep_for(std::chrono::milliseconds(total_tensors_to_process <= 4 ? 10 : 200));
+            std::this_thread::sleep_for(std::chrono::milliseconds(2));
         }
 
         for (auto& w : workers) {
--- a/src/core/ggml_runner.h
+++ b/src/core/ggml_runner.h
@@ -155,6 +155,7 @@
     ggml_context* compute_ctx = nullptr;
     bool runner_started_      = false;
     bool graph_active_        = false;
+    bool pa_destroying_       = false;  // PocketAgent: из деструктора веса выселяем всегда
 
     size_t max_graph_vram_bytes        = 0;
     bool graph_cut_layer_split_enabled = false;
@@ -281,6 +282,11 @@
 
     void runner_end();
 
+    // PocketAgent: чьи веса SD_KEEP_WEIGHTS=1 оставляет в памяти после вызова —
+    // рисующая часть и проявка (переопределено в DiffusionModelRunner и VAE).
+    // Энкодеры условий — нет: они самые большие и нужны лишь в начале картинки.
+    virtual bool pa_keep_weights_ok() const { return false; }
+
 public:
     virtual std::string get_desc() = 0;
 
--- a/src/core/ggml_runner.cpp
+++ b/src/core/ggml_runner.cpp
@@ -493,7 +493,19 @@
             if (parameter != nullptr)
                 tensors.push_back(parameter);
         }
-        manager->evict_compute_backend_params(tensors);
+        // PocketAgent: SD_KEEP_WEIGHTS=1 — веса рисующей части и проявки остаются в памяти
+        // видеочипа после вызова (контекст живёт между картинками): следующая картинка
+        // не читает их заново (+7 с на первом шаге у телефона), а плитки проявки — между
+        // собой. Энкодеры (4,3 ГБ) выселяются, как раньше; SD_KEEP_WEIGHTS=all держит и их.
+        // Отказов памяти это не добавляет: оставленные веса не закреплены, и при нехватке
+        // места менеджер выселяет их сам — сначала веса текущего графа, потом самые давние
+        // (ModelManager::ensure_compute_backend_capacity).
+        const char* pa_keep = std::getenv("SD_KEEP_WEIGHTS");
+        const bool pa_keep_on = !pa_destroying_ && pa_keep != nullptr && pa_keep[0] != '\0' && pa_keep[0] != '0' &&
+                                (pa_keep_weights_ok() || std::string(pa_keep) == "all");
+        if (!pa_keep_on) {
+            manager->evict_compute_backend_params(tensors);
+        }
         manager->remove_runtime_owner(reinterpret_cast<uintptr_t>(this));
     }
     runner_started_ = false;
@@ -511,6 +523,7 @@
 }
 
 GGMLRunner::~GGMLRunner() {
+    pa_destroying_ = true;
     runner_end();
     free_compute_ctx();
     free_params_ctx();
--- a/src/model/diffusion/model.hpp
+++ b/src/model/diffusion/model.hpp
@@ -184,6 +184,8 @@
 protected:
     std::string prefix;
 
+    bool pa_keep_weights_ok() const override { return true; }  // PocketAgent: SD_KEEP_WEIGHTS
+
     std::vector<float> finish_rope_pe(Rope::Embedding embedding) {
         Rope::apply_circular(embedding, circular_x_enabled, circular_y_enabled);
         return std::move(embedding.values);
--- a/src/model/vae/vae.hpp
+++ b/src/model/vae/vae.hpp
@@ -9,6 +9,7 @@
 
 struct VAE : public GGMLRunner {
 protected:
+    bool pa_keep_weights_ok() const override { return true; }  // PocketAgent: SD_KEEP_WEIGHTS
     SDVersion version;
     std::string weight_prefix;
     bool scale_input                                      = true;
PA_SD_V6A_PATCH
  git -C "$src/ggml" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_GGML_V6A_PATCH' \
    || { echo "❌ правка ggml-metal v6a (im2col, перестановки) не легла — см. $log" >&2; return 1; }
--- a/src/ggml-metal/ggml-metal.metal
+++ b/src/ggml-metal/ggml-metal.metal
@@ -4944,6 +4944,64 @@
 template [[host_name("kernel_im2col_f32")]] kernel im2col_t kernel_im2col<float>;
 template [[host_name("kernel_im2col_f16")]] kernel im2col_t kernel_im2col<half>;
 
+// PocketAgent: im2col «плоский». Штатное ядро берёт на группу потоков одну точку выхода
+// и один входной канал — это 9 потоков на группу (ядро 3×3, один кадр) и десятки миллионов
+// групп: на проявке Qwen-Image 2.1 развёртка шла в 5–10 раз дольше самого умножения
+// (замер на M1 24.09.2026: 5,5 с из 13,9 с на картинку 512²). Здесь группа — одна точка
+// выхода целиком: потоки идут подряд по строке IC·KH·KW, запись сплошная, а соседние
+// потоки читают соседние по kw точки одной строки входа. Результат — та же развёртка,
+// побитово. Выключается GGML_METAL_IM2COL_FLAT=0.
+typedef void (im2col_flat_t)(
+        constant ggml_metal_kargs_im2col & args,
+        device const float * x,
+        device        char * dst,
+        uint3 tgpig[[threadgroup_position_in_grid]],
+        uint3  tgpg[[threadgroups_per_grid]],
+        uint3 tpitg[[thread_position_in_threadgroup]],
+        uint3   ntg[[threads_per_threadgroup]]);
+
+template <typename T>
+kernel void kernel_im2col_flat(
+        constant ggml_metal_kargs_im2col & args,
+        device const float * x,
+        device        char * dst,
+        uint3 tgpig[[threadgroup_position_in_grid]],
+        uint3  tgpg[[threadgroups_per_grid]],
+        uint3 tpitg[[thread_position_in_threadgroup]],
+        uint3   ntg[[threads_per_threadgroup]]) {
+    // сетка: (OW, OH, N), потоки — вдоль IC·KH·KW
+    const int iow = tgpig[0];
+    const int ioh = tgpig[1];
+    const int in  = tgpig[2];
+    const int OW  = tgpg[0];
+    const int OH  = tgpg[1];
+
+    device T * pdst = (device T *) dst + ((int64_t) in*OH*OW + (int64_t) ioh*OW + iow)*args.CHW;
+    device const float * px = x + (int64_t) in*args.ofs0;
+
+    const int iw0 = iow*args.s0 - args.p0;
+    const int ih0 = ioh*args.s1 - args.p1;
+
+    for (int chw = tpitg[0]; chw < args.CHW; chw += ntg[0]) {
+        const int iic = chw / args.KHW;
+        const int r   = chw - iic*args.KHW;
+        const int ikh = r / args.KW;
+        const int ikw = r - ikh*args.KW;
+
+        const int iih = ih0 + ikh*args.d1;
+        const int iiw = iw0 + ikw*args.d0;
+
+        float v = 0.0f;
+        if (iih >= 0 && iih < args.IH && iiw >= 0 && iiw < args.IW) {
+            v = px[(int64_t) iic*args.ofs1 + (int64_t) iih*args.IW + iiw];
+        }
+        pdst[chw] = (T) v;
+    }
+}
+
+template [[host_name("kernel_im2col_flat_f32")]] kernel im2col_flat_t kernel_im2col_flat<float>;
+template [[host_name("kernel_im2col_flat_f16")]] kernel im2col_flat_t kernel_im2col_flat<half>;
+
 // TODO: optimize
 typedef void (im2col_ext_t)(
         constant ggml_metal_kargs_im2col & args,
@@ -7999,6 +8057,51 @@
 
 typedef decltype(kernel_cpy_t_t<float, float>) kernel_cpy_t;
 
+// PocketAgent: cont() переставленного f32-тензора плитками 32×32 через общую память группы.
+// Штатный kernel_cpy_t_t читает вход вдоль оси 0 выхода; у перестановки каналов
+// (RMS-норма проявки: [W,H,1,C] → [C,W,H,1] и обратно) соседние потоки читают точки
+// на целую плоскость друг от друга, и копия шла в разы медленнее памяти. Здесь чтение
+// идёт вдоль оси, непрерывной во входе, запись — вдоль оси, непрерывной в выходе.
+// Значения переносятся как есть — результат побитово тот же.
+kernel void kernel_pa_transpose_f32(
+        constant ggml_metal_kargs_pa_transpose & args,
+        device  const char * src,
+        device        char * dst,
+        threadgroup float  * shmem [[threadgroup(0)]],
+        uint3   tgpig[[threadgroup_position_in_grid]],
+        ushort3 tpitg[[thread_position_in_threadgroup]]) {
+    const int i0b = tgpig.x*32;
+    const int ikb = tgpig.y*32;
+    const int ia  = tgpig.z % args.nea;
+    const int ib  = tgpig.z / args.nea;
+
+    const int tx = tpitg.x;  // 0..31
+    const int ty = tpitg.y;  // 0..7
+
+    device const char * s = src + ia*args.sa + ib*args.sb;
+    device       char * d = dst + ia*args.da + ib*args.db;
+
+    // чтение: поток tx — вдоль оси k (непрерывна во входе)
+    for (int j = ty; j < 32; j += 8) {
+        const int i0 = i0b + j;
+        const int ik = ikb + tx;
+        if (i0 < args.ne0 && ik < args.nek) {
+            shmem[j*33 + tx] = *((device const float *)(s + i0*args.s0 + ik*args.sk));
+        }
+    }
+
+    threadgroup_barrier(mem_flags::mem_threadgroup);
+
+    // запись: поток tx — вдоль оси 0 (непрерывна в выходе)
+    for (int j = ty; j < 32; j += 8) {
+        const int i0 = i0b + tx;
+        const int ik = ikb + j;
+        if (i0 < args.ne0 && ik < args.nek) {
+            *((device float *)(d + i0*args.d0 + ik*args.dk)) = shmem[tx*33 + j];
+        }
+    }
+}
+
 template [[host_name("kernel_cpy_f32_f32")]]   kernel kernel_cpy_t kernel_cpy_t_t<float,   float>;
 template [[host_name("kernel_cpy_f32_f16")]]   kernel kernel_cpy_t kernel_cpy_t_t<float,   half>;
 template [[host_name("kernel_cpy_f32_i32")]]   kernel kernel_cpy_t kernel_cpy_t_t<float,   int32_t>;
--- a/src/ggml-metal/ggml-metal-ops.cpp
+++ b/src/ggml-metal/ggml-metal-ops.cpp
@@ -2081,6 +2081,62 @@
     GGML_TENSOR_LOCALS( int32_t, ne,  op,         ne);
     GGML_TENSOR_LOCALS(uint64_t, nb,  op,         nb);
 
+    // PocketAgent: перестановка осей f32 — плитками (kernel_pa_transpose_f32), если вход
+    // непрерывен не вдоль оси 0, а вдоль другой оси k. GGML_METAL_PA_TRANSPOSE=0 — штатно.
+    {
+        const char * pa_tr = getenv("GGML_METAL_PA_TRANSPOSE");
+        int k = -1;
+        if (!(pa_tr != nullptr && pa_tr[0] == '0') &&
+            op->src[0]->type == GGML_TYPE_F32 && op->type == GGML_TYPE_F32 &&
+            ggml_are_same_shape(op->src[0], op) && ggml_is_contiguous(op) &&
+            nb00 != sizeof(float) && ne00 > 1) {
+            const uint64_t nbs[4] = { nb00, nb01, nb02, nb03 };
+            const int64_t  nes[4] = { ne00, ne01, ne02, ne03 };
+            for (int i = 1; i < 4; ++i) {
+                if (nbs[i] == sizeof(float) && nes[i] > 1) {
+                    k = i;
+                    break;
+                }
+            }
+            if (k > 0) {
+                int oth[2];
+                int no = 0;
+                for (int i = 1; i < 4; ++i) {
+                    if (i != k) {
+                        oth[no++] = i;
+                    }
+                }
+                const uint64_t nbd[4] = { nb0, nb1, nb2, nb3 };
+                ggml_metal_kargs_pa_transpose targs = {
+                    /*.ne0 =*/ (int32_t) nes[0],
+                    /*.nek =*/ (int32_t) nes[k],
+                    /*.nea =*/ (int32_t) nes[oth[0]],
+                    /*.neb =*/ (int32_t) nes[oth[1]],
+                    /*.s0  =*/ nbs[0],
+                    /*.sk  =*/ nbs[k],
+                    /*.sa  =*/ nbs[oth[0]],
+                    /*.sb  =*/ nbs[oth[1]],
+                    /*.d0  =*/ nbd[0],
+                    /*.dk  =*/ nbd[k],
+                    /*.da  =*/ nbd[oth[0]],
+                    /*.db  =*/ nbd[oth[1]],
+                };
+                auto tp = ggml_metal_library_get_pipeline(lib, "kernel_pa_transpose_f32");
+                if (!tp.pipeline) {
+                    tp = ggml_metal_library_compile_pipeline(lib, "kernel_pa_transpose_f32", "kernel_pa_transpose_f32", nullptr);
+                }
+                ggml_metal_encoder_set_pipeline(enc, tp);
+                ggml_metal_encoder_set_bytes   (enc, &targs, sizeof(targs), 0);
+                ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op->src[0]), 1);
+                ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op),         2);
+                ggml_metal_encoder_set_threadgroup_memory_size(enc, 32*33*sizeof(float), 0);
+                ggml_metal_encoder_dispatch_threadgroups(enc, (targs.ne0 + 31)/32, (targs.nek + 31)/32,
+                                                         targs.nea*targs.neb, 32, 8, 1);
+                return 1;
+            }
+        }
+    }
+
     auto pipeline = ggml_metal_library_get_pipeline_cpy(lib, op->src[0]->type, op->type);
 
     GGML_ASSERT(ne00 % ggml_blck_size(op->src[0]->type) == 0);
@@ -3986,7 +4042,20 @@
 
     auto pipeline = ggml_metal_library_get_pipeline_im2col(lib, op);
 
-    if (KH*KW <= ggml_metal_pipeline_max_theads_per_threadgroup(pipeline)) {
+    // PocketAgent: плоское ядро — группа потоков на точку выхода, потоки вдоль IC·KH·KW
+    // (выбор ядра — в ggml_metal_library_get_pipeline_im2col, условие то же).
+    const char * pa_flat = getenv("GGML_METAL_IM2COL_FLAT");
+    if (is_2D && !(pa_flat != nullptr && pa_flat[0] == '0')) {
+        const int nth = std::min(ggml_metal_pipeline_max_theads_per_threadgroup(pipeline),
+                                 std::max(32, std::min(256, (CHW + 31)/32*32)));
+
+        ggml_metal_encoder_set_pipeline(enc, pipeline);
+        ggml_metal_encoder_set_bytes   (enc, &args, sizeof(args), 0);
+        ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op->src[1]), 1);
+        ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op),         2);
+
+        ggml_metal_encoder_dispatch_threadgroups(enc, OW, OH, N, nth, 1, 1);
+    } else if (KH*KW <= ggml_metal_pipeline_max_theads_per_threadgroup(pipeline)) {
         const uint64_t ntptg0 = std::min(ggml_metal_pipeline_max_theads_per_threadgroup(pipeline)/(KH*KW), N);
 
         ggml_metal_encoder_set_pipeline(enc, pipeline);
--- a/src/ggml-metal/ggml-metal-device.cpp
+++ b/src/ggml-metal/ggml-metal-device.cpp
@@ -1821,18 +1821,24 @@
 
     GGML_TENSOR_LOCALS(int64_t, ne0, op->src[0], ne);
 
-    GGML_ASSERT(ggml_is_contiguous(op->src[1]));
     GGML_ASSERT(op->src[1]->type == GGML_TYPE_F32);
     GGML_ASSERT(op->type         == GGML_TYPE_F16 || op->type == GGML_TYPE_F32);
 
     const bool is_2D = ((const int32_t *)(op->op_params))[6] == 1;
+    // PocketAgent: «окно» строк (не сплошной вход) допускает только плоское ядро — см. ниже.
+    const char * pa_flat0 = getenv("GGML_METAL_IM2COL_FLAT");
+    GGML_ASSERT(ggml_is_contiguous(op->src[1]) || (is_2D && !(pa_flat0 != nullptr && pa_flat0[0] == '0')));
     const int64_t KH = is_2D ? ne01 : 1;
     const int64_t KW = ne00;
 
     char base[256];
     char name[256];
 
-    if (KH*KW <= 1024) {
+    // PocketAgent: плоское ядро для 2D (см. kernel_im2col_flat), GGML_METAL_IM2COL_FLAT=0 — штатное.
+    const char * pa_flat = getenv("GGML_METAL_IM2COL_FLAT");
+    if (is_2D && !(pa_flat != nullptr && pa_flat[0] == '0')) {
+        snprintf(base, 256, "kernel_im2col_flat_%s", ggml_type_name(op->type));
+    } else if (KH*KW <= 1024) {
         snprintf(base, 256, "kernel_im2col_%s", ggml_type_name(op->type));
     } else {
         snprintf(base, 256, "kernel_im2col_ext_%s", ggml_type_name(op->type));
--- a/src/ggml-metal/ggml-metal-device.m
+++ b/src/ggml-metal/ggml-metal-device.m
@@ -1255,7 +1255,17 @@
         case GGML_OP_ROPE_BACK:
             return true;
         case GGML_OP_IM2COL:
-            return ggml_is_contiguous(op->src[1]) && op->src[1]->type == GGML_TYPE_F32 && (op->type == GGML_TYPE_F16 || op->type == GGML_TYPE_F32);
+            {
+                // PocketAgent: плоское 2D-ядро читает и «окно» строк (строки подряд, каналы
+                // с любым шагом) — так проявка режет развёртку полосами без копии входа.
+                const char * pa_flat = getenv("GGML_METAL_IM2COL_FLAT");
+                const bool pa_rows = ((const int32_t *)(op->op_params))[6] == 1 &&
+                                     !(pa_flat != NULL && pa_flat[0] == '0') &&
+                                     op->src[1]->nb[0] == sizeof(float) &&
+                                     op->src[1]->nb[1] == op->src[1]->ne[0]*sizeof(float) &&
+                                     op->src[1]->nb[2] % sizeof(float) == 0 && op->src[1]->nb[3] % sizeof(float) == 0;
+                return (ggml_is_contiguous(op->src[1]) || pa_rows) && op->src[1]->type == GGML_TYPE_F32 && (op->type == GGML_TYPE_F16 || op->type == GGML_TYPE_F32);
+            }
         case GGML_OP_CONV_2D:
             return ggml_is_contiguous(op->src[0]) &&
                    op->src[1]->type == GGML_TYPE_F32 &&
--- a/src/ggml-metal/ggml-metal-impl.h
+++ b/src/ggml-metal/ggml-metal-impl.h
@@ -292,6 +292,23 @@
     uint64_t nb3;
 } ggml_metal_kargs_cpy;
 
+// PocketAgent: перестановка осей f32 плитками (kernel_pa_transpose_f32): ось 0 выхода
+// непрерывна в выходе, ось k — во входе; a, b — две оставшиеся оси.
+typedef struct {
+    int32_t  ne0;
+    int32_t  nek;
+    int32_t  nea;
+    int32_t  neb;
+    uint64_t s0;   // шаги во входе, в байтах
+    uint64_t sk;
+    uint64_t sa;
+    uint64_t sb;
+    uint64_t d0;   // шаги в выходе, в байтах
+    uint64_t dk;
+    uint64_t da;
+    uint64_t db;
+} ggml_metal_kargs_pa_transpose;
+
 typedef struct {
     int64_t  ne10;
     int64_t  ne11;
PA_GGML_V6A_PATCH
  # 10) v8 — замер ядра на размерах Qwen-Image 2.1, раскладка слоя (SD_PROFILE_BLOCK),
  #     порядок выселения весов и журнал памяти (SD_RESIDENCY_LOG), SD_KEEP_ENCODER.
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V8_PATCH' \
    || { echo "❌ правка движка v8 (замер ядра, раскладка слоя, память) не легла — см. $log" >&2; return 1; }
diff --git a/src/core/ggml_runner.cpp b/src/core/ggml_runner.cpp
index 4f2024e..f51f3ed 100644
--- a/src/core/ggml_runner.cpp
+++ b/src/core/ggml_runner.cpp
@@ -462,6 +462,7 @@ bool GGMLRunner::runner_start() {
         return true;
     }
     cache_.clear();
+    pa_profile_seen_ = 0;
     workspace_.set_extra_backends(extra_runtime_backends);
     if (auto manager = residency_manager.lock()) {
         manager->set_workspace_reclaimer(reinterpret_cast<uintptr_t>(this), [this]() {
@@ -500,13 +501,27 @@ void GGMLRunner::runner_end() {
         // Отказов памяти это не добавляет: оставленные веса не закреплены, и при нехватке
         // места менеджер выселяет их сам — сначала веса текущего графа, потом самые давние
         // (ModelManager::ensure_compute_backend_capacity).
+        // SD_KEEP_ENCODER=1 (v8, по умолчанию выкл) — держать и энкодер условий (и прочие части
+        // вне рисующей/проявки): новое описание не читает 4,3 ГБ заново (~5–7 с на телефоне), но
+        // тогда в памяти ~8,8 ГБ весов — на телефоне столько, скорее всего, не влезет в бюджет,
+        // и менеджер будет выселять по кругу. Сколько реально держится — строка PA RESIDENCY.
         const char* pa_keep = std::getenv("SD_KEEP_WEIGHTS");
-        const bool pa_keep_on = !pa_destroying_ && pa_keep != nullptr && pa_keep[0] != '\0' && pa_keep[0] != '0' &&
-                                (pa_keep_weights_ok() || std::string(pa_keep) == "all");
+        const char* pa_keep_enc = std::getenv("SD_KEEP_ENCODER");
+        const bool pa_keep_enc_on = pa_keep_enc != nullptr && pa_keep_enc[0] != '\0' && pa_keep_enc[0] != '0';
+        const bool pa_keep_on = !pa_destroying_ &&
+                                ((pa_keep != nullptr && pa_keep[0] != '\0' && pa_keep[0] != '0' &&
+                                  (pa_keep_weights_ok() || std::string(pa_keep) == "all")) ||
+                                 (pa_keep_enc_on && !pa_keep_weights_ok()));
         if (!pa_keep_on) {
             manager->evict_compute_backend_params(tensors);
         }
         manager->remove_runtime_owner(reinterpret_cast<uintptr_t>(this));
+        const char* pa_rlog = std::getenv("SD_RESIDENCY_LOG");
+        if (!pa_destroying_ && pa_rlog != nullptr && pa_rlog[0] != '\0' && pa_rlog[0] != '0') {
+            LOG_INFO("PA RESIDENCY after %s (%s): %s; budget %.0f MB", get_desc().c_str(),
+                     pa_keep_on ? "kept" : "evicted", manager->pa_residency_summary(runtime_backend).c_str(),
+                     max_graph_vram_bytes / 1048576.0);
+        }
     }
     runner_started_ = false;
 }
@@ -767,6 +782,160 @@ bool GGMLRunner::fits(const std::vector<DeviceMemoryRequest>& requests,
     return true;
 }
 
+// PocketAgent: SD_PROFILE_BLOCK=<номер слоя> — раскладка одного куска рисующей части по
+// операциям. На выбранном проходе кусок
+// считается НЕ одним заходом, а по одной операции, с ожиданием видеочипа после каждой, и
+// время складывается по видам: умножения (по типу весов и размеру), внимание, нормировки,
+// RoPE, поэлементные, перестановки/копии.
+// ⚠️ Это и есть настоящее вычисление куска (не повтор): повтор после обычного прохода
+// испортил бы картинку — распределитель памяти отдаёт место входов куска и «операций на
+// месте» следующим операциям (проверено на мини 24.09.2026: повтор давал белую картинку).
+// Каждая операция — ровно один раз, в том же порядке, поэтому результат тот же; различие
+// только в том, что соседние операции не склеиваются (fusion) — возможны расхождения
+// в последних битах. Поштучно каждая операция платит за свой командный буфер, поэтому
+// сумма больше обычного времени куска — сравнивать с соседними слоями в журнале.
+static bool pa_is_view_op(ggml_op op) {
+    return op == GGML_OP_NONE || op == GGML_OP_VIEW || op == GGML_OP_RESHAPE ||
+           op == GGML_OP_PERMUTE || op == GGML_OP_TRANSPOSE;
+}
+
+static const char* pa_profile_group(const ggml_tensor* t) {
+    switch (t->op) {
+        case GGML_OP_MUL_MAT:
+        case GGML_OP_MUL_MAT_ID:
+            return "matmul";
+        case GGML_OP_FLASH_ATTN_EXT:
+        case GGML_OP_SOFT_MAX:
+            return "attention";
+        case GGML_OP_NORM:
+        case GGML_OP_RMS_NORM:
+        case GGML_OP_GROUP_NORM:
+        case GGML_OP_L2_NORM:
+            return "norm";
+        case GGML_OP_ROPE:
+            return "rope";
+        case GGML_OP_CONT:
+        case GGML_OP_CPY:
+        case GGML_OP_DUP:
+        case GGML_OP_CONCAT:
+        case GGML_OP_GET_ROWS:
+        case GGML_OP_SET_ROWS:
+        case GGML_OP_REPEAT:
+            return "layout";
+        case GGML_OP_ADD:
+        case GGML_OP_ADD1:
+        case GGML_OP_SUB:
+        case GGML_OP_MUL:
+        case GGML_OP_DIV:
+        case GGML_OP_SCALE:
+        case GGML_OP_UNARY:
+        case GGML_OP_GLU:
+        case GGML_OP_SQR:
+        case GGML_OP_SQRT:
+        case GGML_OP_CLAMP:
+            return "elementwise";
+        default:
+            return "other";
+    }
+}
+
+static bool pa_profile_execute(ggml_backend_t backend, ggml_cgraph* graph, const std::string& desc,
+                               const std::string& group, int pass) {
+    ggml_init_params params;
+    params.mem_size   = ggml_graph_overhead_custom(4, false) + 1024;
+    params.mem_buffer = nullptr;
+    params.no_alloc   = true;
+    ggml_context* ctx = ggml_init(params);
+    if (ctx == nullptr) {
+        return false;
+    }
+    ggml_cgraph* one = ggml_new_graph_custom(ctx, 4, false);
+
+    struct Acc {
+        double ms   = 0;
+        double flop = 0;
+        int count   = 0;
+    };
+    std::map<std::string, Acc> by_key;
+    std::map<std::string, double> by_group;
+    const int n_nodes = ggml_graph_n_nodes(graph);
+    double total      = 0;
+    int timed         = 0;
+    for (int i = 0; i < n_nodes; ++i) {
+        ggml_tensor* node = ggml_graph_node(graph, i);
+        if (pa_is_view_op(node->op)) {
+            continue;
+        }
+        ggml_graph_clear(one);
+        ggml_graph_add_node(one, node);
+        const int64_t t0 = ggml_time_us();
+        if (ggml_backend_graph_compute(backend, one) != GGML_STATUS_SUCCESS) {
+            ggml_free(ctx);
+            LOG_WARN("PA PROFILE %s %s: видеочип отказал на операции %d (%s)", desc.c_str(), group.c_str(), i,
+                     ggml_op_desc(node));
+            return false;
+        }
+        ggml_backend_synchronize(backend);
+        const double ms = (ggml_time_us() - t0) / 1000.0;
+
+        char key[256];
+        double flop     = 0;
+        const char* grp = pa_profile_group(node);
+        if (node->op == GGML_OP_MUL_MAT) {
+            const ggml_tensor* w = node->src[0];
+            const ggml_tensor* x = node->src[1];
+            flop = 2.0 * (double) w->ne[0] * (double) w->ne[1] * (double) x->ne[1] * (double) x->ne[2] * (double) x->ne[3];
+            snprintf(key, sizeof(key), "mul_mat %s %lldx%lld x%lld act=%s", ggml_type_name(w->type),
+                     (long long) w->ne[1], (long long) w->ne[0], (long long) (x->ne[1] * x->ne[2] * x->ne[3]),
+                     ggml_type_name(x->type));
+        } else if (node->op == GGML_OP_FLASH_ATTN_EXT) {
+            const ggml_tensor* q = node->src[0];
+            const ggml_tensor* k = node->src[1];
+            flop = 4.0 * (double) q->ne[0] * (double) q->ne[1] * (double) k->ne[1] * (double) q->ne[2] * (double) q->ne[3];
+            snprintf(key, sizeof(key), "flash_attn d%lld q%lld kv%lld heads%lld k=%s%s", (long long) q->ne[0],
+                     (long long) q->ne[1], (long long) k->ne[1], (long long) q->ne[2], ggml_type_name(k->type),
+                     node->src[3] != nullptr ? " mask" : "");
+        } else {
+            snprintf(key, sizeof(key), "%s %s %s[%lld,%lld,%lld,%lld]", grp, ggml_op_desc(node), ggml_type_name(node->type),
+                     (long long) node->ne[0], (long long) node->ne[1], (long long) node->ne[2], (long long) node->ne[3]);
+        }
+        Acc& acc = by_key[key];
+        acc.ms += ms;
+        acc.flop += flop;
+        acc.count++;
+        by_group[grp] += ms;
+        total += ms;
+        timed++;
+    }
+    ggml_free(ctx);
+
+    LOG_INFO("PA PROFILE %s %s (pass %d): per-op sum %.1f ms, ops %d (nodes %d); fusion off, one command buffer per op",
+             desc.c_str(), group.c_str(), pass, total, timed, n_nodes);
+    std::string groups;
+    for (const char* g : {"matmul", "attention", "norm", "rope", "elementwise", "layout", "other"}) {
+        auto it = by_group.find(g);
+        if (it == by_group.end()) {
+            continue;
+        }
+        char part[96];
+        snprintf(part, sizeof(part), "%s%s=%.1f(%.0f%%)", groups.empty() ? "" : " ", g, it->second,
+                 total > 0 ? 100.0 * it->second / total : 0.0);
+        groups += part;
+    }
+    LOG_INFO("PA PROFILE groups ms: %s", groups.c_str());
+    std::vector<std::pair<std::string, Acc>> rows(by_key.begin(), by_key.end());
+    std::sort(rows.begin(), rows.end(), [](const auto& a, const auto& b) { return a.second.ms > b.second.ms; });
+    for (const auto& row : rows) {
+        if (row.second.flop > 0) {
+            LOG_INFO("PA PROFILE op %s: %dx %.2f ms (%.2f TFLOPS)", row.first.c_str(), row.second.count,
+                     row.second.ms, row.second.flop / (row.second.ms * 1e-3) / 1e12);
+        } else {
+            LOG_INFO("PA PROFILE op %s: %dx %.2f ms", row.first.c_str(), row.second.count, row.second.ms);
+        }
+    }
+    return true;
+}
+
 bool GGMLRunner::execute_segment(ggml_cgraph* graph, int n_threads) {
     if (sd_backend_is_cpu(runtime_backend)) {
         sd_backend_cpu_set_n_threads(runtime_backend, n_threads);
@@ -988,13 +1157,42 @@ std::optional<Tensor<float>> GGMLRunner::execute_graph(ggml_cgraph* graph, int n
         // PocketAgent: SD_SEGMENT_TIMING печатает время каждого куска — чтобы на телефоне
         // было видно, куда уходит шаг рисования.
         const bool pa_timing = std::getenv("SD_SEGMENT_TIMING") != nullptr;
-        const int64_t pa_t0  = pa_timing ? ggml_time_us() : 0;
-        if (!execute_segment(segment_graph, n_threads)) {
+        // PocketAgent: SD_PROFILE_BLOCK=<номер слоя> — этот кусок на проходе SD_PROFILE_STEP
+        // (по умолчанию 2-м: первый шаг ещё грузит веса) считается поштучно по операциям.
+        bool pa_profile_now = false;
+        int pa_profile_pass = 0;
+        if (const char* pa_prof = std::getenv("SD_PROFILE_BLOCK")) {
+            const std::string want = std::string("transformer_blocks.") + pa_prof;
+            const std::string& g   = segment.group_name;
+            if (segmented && pa_prof[0] != '\0' && g.size() >= want.size() &&
+                g.compare(g.size() - want.size(), want.size(), want) == 0 &&
+                (g.size() == want.size() || g[g.size() - want.size() - 1] == '.')) {
+                const char* pa_step_env = std::getenv("SD_PROFILE_STEP");
+                const int pa_step       = pa_step_env != nullptr && atoi(pa_step_env) > 0 ? atoi(pa_step_env) : 2;
+                pa_profile_pass         = ++pa_profile_seen_;
+                if (pa_profile_pass == pa_step) {
+                    if (workspace_.scheduler() != nullptr || sd_get_backend_eval_callback() != nullptr) {
+                        LOG_WARN("PA PROFILE %s: кусок идёт через планировщик — раскладку не делаю", g.c_str());
+                    } else {
+                        pa_profile_now = true;
+                    }
+                }
+            }
+        }
+        const int64_t pa_t0 = ggml_time_us();
+        if (pa_profile_now) {
+            if (!pa_profile_execute(runtime_backend, segment_graph, get_desc(), segment.group_name, pa_profile_pass)) {
+                last_compute_status_ = GGML_STATUS_FAILED;
+                return fail_segment("execution (profile)");
+            }
+            workspace_.synchronize();
+        } else if (!execute_segment(segment_graph, n_threads)) {
             return fail_segment("execution");
         }
         if (pa_timing) {
-            LOG_INFO("%s segment %zu/%zu %s: %.1f ms", get_desc().c_str(), index + 1,
-                     plan.segments.size(), segment.group_name.c_str(), (ggml_time_us() - pa_t0) / 1000.0);
+            LOG_INFO("%s segment %zu/%zu %s: %.1f ms%s", get_desc().c_str(), index + 1,
+                     plan.segments.size(), segment.group_name.c_str(), (ggml_time_us() - pa_t0) / 1000.0,
+                     pa_profile_now ? " (поштучно, PA PROFILE)" : "");
         }
         auto cache_status = cache_.capture(segment_graph);
         if (cache_status == GGML_STATUS_SUCCESS) {
diff --git a/src/core/ggml_runner.h b/src/core/ggml_runner.h
index 4f16149..5729672 100644
--- a/src/core/ggml_runner.h
+++ b/src/core/ggml_runner.h
@@ -156,6 +156,7 @@ protected:
     bool runner_started_      = false;
     bool graph_active_        = false;
     bool pa_destroying_       = false;  // PocketAgent: из деструктора веса выселяем всегда
+    int pa_profile_seen_      = 0;      // PocketAgent: сколько раз за вызов прошёл кусок SD_PROFILE_BLOCK
 
     size_t max_graph_vram_bytes        = 0;
     bool graph_cut_layer_split_enabled = false;
diff --git a/src/device_residency_manager.h b/src/device_residency_manager.h
index 0a2a889..794d98f 100644
--- a/src/device_residency_manager.h
+++ b/src/device_residency_manager.h
@@ -3,6 +3,7 @@
 
 #include <cstdint>
 #include <functional>
+#include <string>
 #include <vector>
 
 #include "ggml-backend.h"
@@ -68,6 +69,9 @@ struct DeviceResidencyManager {
     virtual bool activate_prefetched_params(uintptr_t owner_id,
                                             const std::vector<ggml_tensor*>& tensors) = 0;
     virtual void clear_prefetched_params(uintptr_t owner_id)                          = 0;
+    // PocketAgent: сводка для журнала — сколько весов каждой части сейчас в памяти
+    // видеочипа и что говорит устройство о свободной памяти (SD_RESIDENCY_LOG).
+    virtual std::string pa_residency_summary(ggml_backend_t backend) const { return {}; }
 };
 
 // Transitional alias for model constructors that have not yet adopted the
diff --git a/src/model_manager.cpp b/src/model_manager.cpp
index 5bdf59c..62560a5 100644
--- a/src/model_manager.cpp
+++ b/src/model_manager.cpp
@@ -2,6 +2,7 @@
 
 #include <algorithm>
 #include <cstdint>
+#include <cstdlib>
 #include <iterator>
 #include <mutex>
 #include <tuple>
@@ -11,6 +12,39 @@
 #include "core/util.h"
 #include "model/adapter/lora.hpp"
 
+// PocketAgent: ранги выселения при SD_KEEP_WEIGHTS (меньше — выселяется раньше).
+static bool pa_env_on(const char* name) {
+    const char* v = std::getenv(name);
+    return v != nullptr && v[0] != '\0' && v[0] != '0';
+}
+
+static int pa_keep_rank_enabled() {
+    // SD_EVICT_PLAIN_LRU=1 — штатный порядок (чистая давность), для сравнения A/B на телефоне.
+    if (pa_env_on("SD_EVICT_PLAIN_LRU")) {
+        return 0;
+    }
+    return pa_env_on("SD_KEEP_WEIGHTS") || pa_env_on("SD_KEEP_ENCODER") ? 1 : 0;
+}
+
+static int pa_keep_rank(ModelComponent c) {
+    switch (c) {
+        case ModelComponent::Diffusion:
+        case ModelComponent::HighNoiseDiffusion:
+            return 3;
+        case ModelComponent::Conditioner:
+            return pa_env_on("SD_KEEP_ENCODER") ? 2 : 0;
+        case ModelComponent::VAE:
+        case ModelComponent::PreviewVAE:
+            return 1;
+        default:
+            return 0;
+    }
+}
+
+static bool pa_residency_log_enabled() {
+    return pa_env_on("SD_RESIDENCY_LOG");
+}
+
 static size_t aligned_offset(const void* buffer, size_t offset, size_t alignment) {
     GGML_ASSERT(alignment != 0 && (alignment & (alignment - 1)) == 0);
     size_t align = (alignment - ((reinterpret_cast<uintptr_t>(buffer) + offset) % alignment)) % alignment;
@@ -1711,6 +1745,41 @@ ModelManager::CapacityCheck ModelManager::check_capacity(
     return result;
 }
 
+std::map<ModelComponent, size_t> ModelManager::pa_resident_by_component() const {
+    std::map<ModelComponent, size_t> out;
+    for (const auto& state : tensor_states_) {
+        if (state == nullptr || state->tensor == nullptr) {
+            continue;
+        }
+        const bool resident = state->compute_backend == state->params_backend
+                                  ? state->loaded_to_params_backend
+                                  : state->staged_to_compute_backend;
+        if (resident) {
+            out[state->component] += ggml_nbytes(state->tensor);
+        }
+    }
+    return out;
+}
+
+std::string ModelManager::pa_residency_summary(ggml_backend_t backend) const {
+    std::string s;
+    for (const auto& kv : pa_resident_by_component()) {
+        s += sd_format("%s%s %.0f MB", s.empty() ? "" : " · ", model_component_name(kv.first), kv.second / 1048576.0);
+    }
+    if (s.empty()) {
+        s = "весов в памяти нет";
+    }
+    if (backend != nullptr) {
+        if (auto device = ggml_backend_get_device(backend)) {
+            size_t free_bytes = 0, total_bytes = 0;
+            ggml_backend_dev_memory(device, &free_bytes, &total_bytes);
+            s += sd_format(" | устройство: свободно %.0f / всего %.0f MB, учтено весов %.0f MB", free_bytes / 1048576.0,
+                           total_bytes / 1048576.0, compute_backend_resident_bytes(backend) / 1048576.0);
+        }
+    }
+    return s;
+}
+
 bool ModelManager::fits_compute_backend_capacity(
     const DeviceMemoryRequest& request,
     const std::vector<ggml_tensor*>& required_params) const {
@@ -1742,6 +1811,38 @@ bool ModelManager::ensure_compute_backend_capacity(
     if (fits()) {
         return true;
     }
+    // PocketAgent: SD_RESIDENCY_LOG — кто и сколько выселил (по частям модели), чтобы с телефона
+    // было видно, почему следующий шаг заново читает веса. Пишется по выходу из функции.
+    struct PaEvictLog {
+        const ModelManager* mm;
+        std::map<ModelComponent, size_t> before;
+        ModelComponent who = ModelComponent::Count;
+        size_t need        = 0;
+        bool on            = false;
+        ~PaEvictLog() {
+            if (!on) {
+                return;
+            }
+            auto after = mm->pa_resident_by_component();
+            std::string freed;
+            for (const auto& kv : before) {
+                const size_t now = after.count(kv.first) ? after[kv.first] : 0;
+                if (kv.second > now) {
+                    freed += sd_format(" %s -%.0f MB", model_component_name(kv.first), (kv.second - now) / 1048576.0);
+                }
+            }
+            if (!freed.empty()) {
+                LOG_INFO("PA RESIDENCY evict for %s (needs %.0f MB):%s", model_component_name(who),
+                         need / 1048576.0, freed.c_str());
+            }
+        }
+    } pa_evict_log{this};
+    if (pa_residency_log_enabled()) {
+        pa_evict_log.on     = true;
+        pa_evict_log.before = pa_resident_by_component();
+        pa_evict_log.who    = required_states.empty() ? ModelComponent::Count : required_states.front()->component;
+        pa_evict_log.need   = compute_backend_alloc_size(required_states, true);
+    }
     for (const auto& entry : workspace_reclaimers_) {
         if (entry.first != request.owner_id) {
             entry.second();
@@ -1804,9 +1905,22 @@ bool ModelManager::ensure_compute_backend_capacity(
             global_candidates.push_back(state.get());
         }
     }
+    // PocketAgent: при SD_KEEP_WEIGHTS давние веса выселяются не «все подряд по давности», а
+    // сперва те, что дешевле вернуть: энкодер и прочее → проявка (0,6 ГБ) → рисующая часть
+    // (3,9–7,4 ГБ) последней. Штатный порядок чистой давности на картинке №2 выбрасывал именно
+    // рисующую часть — она старше всех (последний раз работала до проявки прошлой картинки),
+    // и первый шаг платил её подгрузку, хотя SD_KEEP_WEIGHTS её «оставил». Внутри одного ранга —
+    // давность, как было. SD_KEEP_ENCODER=1 поднимает энкодер над проявкой.
+    const int pa_rank_keep = pa_keep_rank_enabled();
     std::stable_sort(global_candidates.begin(),
                      global_candidates.end(),
-                     [](const TensorState* lhs, const TensorState* rhs) {
+                     [pa_rank_keep](const TensorState* lhs, const TensorState* rhs) {
+                         if (pa_rank_keep) {
+                             const int lr = pa_keep_rank(lhs->component), rr = pa_keep_rank(rhs->component);
+                             if (lr != rr) {
+                                 return lr < rr;
+                             }
+                         }
                          return lhs->last_use_epoch < rhs->last_use_epoch;
                      });
     for (TensorState* state : global_candidates) {
diff --git a/src/model_manager.h b/src/model_manager.h
index f3a6e32..e7ea8d4 100644
--- a/src/model_manager.h
+++ b/src/model_manager.h
@@ -293,6 +293,11 @@ public:
     bool activate_prefetched_params(uintptr_t owner_id,
                                     const std::vector<ggml_tensor*>& tensors) override;
     void clear_prefetched_params(uintptr_t owner_id) override;
+    std::string pa_residency_summary(ggml_backend_t backend) const override;
+
+private:
+    // PocketAgent: сколько байт весов каждой части сейчас в памяти вычислителя.
+    std::map<ModelComponent, size_t> pa_resident_by_component() const;
 };
 
 #endif  // __MODEL_MANAGER_H__
diff --git a/src/pa_kernel_bench.cpp b/src/pa_kernel_bench.cpp
index a9c7851..a4d5ae7 100644
--- a/src/pa_kernel_bench.cpp
+++ b/src/pa_kernel_bench.cpp
@@ -3,11 +3,32 @@
 // Зачем. Ядро по схеме MLX (kernel_mul_mm_nax*, правка движка v6c) работает только на
 // матричных блоках A19/M5 — на Мак-мини (M1) их нет, и ни правильность, ни скорость там
 // не проверить. Эта функция одним нажатием в приложении прогоняет умножения размеров
-// рисующей части Qwen-Image штатным ядром и новым (обе плитки) и отдаёт отчёт строками:
+// рисующей части Qwen-Image 2.1 штатным ядром и новым (обе плитки) и отдаёт отчёт строками:
 //   • точность — полное сравнение с эталоном на процессоре (float, double-сумма) на
 //     маленьком случае с неровными краями, и выборочное (256 точек) на больших;
-//   • время — лучший из трёх прогонов после прогрева, и во сколько раз быстрее.
-// Модель не нужна: веса и активации случайные, память — сотни мегабайт на время замера.
+//   • время — лучший из трёх прогонов после прогрева, и во сколько раз быстрее;
+//   • «блок» — время всех умножений одного слоя рисующей части (4·A + 2·B + C, см. ниже)
+//     и шага (32 слоя) — чтобы сравнивать с «segment … transformer_blocks» в журнале картинки.
+//
+// v8 (24.09.2026): размеры — НАСТОЯЩИЕ у Qwen-Image 2.1 (sd.cpp 88411ef,
+// model/diffusion/qwen_image_2_1.hpp): скрытый размер 4096, MLP 12288, один общий поток
+// текст+картинка, 1037 токенов на 512² (1024 картинки + 13 текста; бывает и ровно 1024).
+// Прежние размеры (3072 — у Qwen-Image 1) давали число про чужую модель
+//. В одном слое:
+//   A  to_q, to_k, to_v, to_out.0 — 4096 → 4096, ×4;
+//   B  img_mlp.proj, img_mlp.gate_layer — 4096 → 12288, ×2;
+//   C  img_mlp.out — 12288 → 4096, ×1.
+// Типы весов: q4_K и q5_K (файл Q4_K_S), q8_0 и q4_0 (кандидаты), f16.
+// Плюс «хвост»: 4096 → 4096 на 13 токенах (проекция текста txt_in, раз на шаг) — как ядро
+// переносит почти пустую плитку.
+//
+// Формат для разбора: первая строка — итог для экрана; строки «KB …», «KBBLOCK …»,
+// «KBACC …» — ключ=значение через пробел, одна строка на размер/тип. Режимы:
+// old — штатное ядро, nax64 — MLX 64×64, nax128 — MLX 128×128. У каждого режима:
+// _ms (лучшее время), _tf (трлн операций/с), _err (макс. ошибка / средний модуль),
+// _ok (1 — точность в норме), _k (какое ядро реально взял видеочип: old/nax64/nax128/mix).
+//
+// Модель не нужна: веса и активации случайные, память — до ~350 МБ на время замера.
 // Режим ядра, который действовал до замера, возвращается в конце.
 
 #include "stable-diffusion.h"
@@ -18,12 +39,13 @@
 
 #include <algorithm>
 #include <cmath>
-#include <cstdlib>
 #include <cstdarg>
 #include <cstdio>
+#include <cstdlib>
 #include <cstring>
 #include <random>
 #include <string>
+#include <thread>
 #include <vector>
 
 #if defined(__APPLE__)
@@ -51,7 +73,8 @@ void pa_log_cb(enum ggml_log_level level, const char* text, void* user) {
     // Нужны предупреждения/ошибки и наши строки — не весь журнал подъёма видеочипа.
     if (level >= GGML_LOG_LEVEL_WARN || strstr(text, "(PA)") || strstr(text, "PA NAX") ||
         strstr(text, "GPU name") || strstr(text, "has tensor")) {
-        log->text += text;
+        // Строки «PA NAX: умножение …» при 30 размерах забили бы отчёт — оставляем первые.
+        if (log->text.size() < 6000) log->text += text;
     }
 }
 
@@ -73,53 +96,121 @@ const char* mode_name(int mode) {
     }
 }
 
-// Одно умножение: веса [M строк x K] типа type, активации float [N токенов x K].
+const char* mode_key(int mode) {
+    switch (mode) {
+        case 0: return "old";
+        case 1: return "nax64";
+        case 2: return "nax128";
+        default: return "m?";
+    }
+}
+
+// Какое ядро реально взяли за прогон — по счёту ggml-metal (сброс перед прогоном).
+std::string kernel_taken() {
+#if defined(__APPLE__)
+    char buf[2048];
+    ggml_metal_pa_nax_stats(buf, sizeof(buf), 1);
+    const char* tail = strstr(buf, "умножений:");
+    const std::string s = tail ? tail : buf;
+    const bool k128 = s.find("MLX 128") != std::string::npos;
+    const bool k64  = s.find("MLX 64") != std::string::npos;
+    const bool kold = s.find("старое") != std::string::npos;
+    const int n = (int) k128 + (int) k64 + (int) kold;
+    if (n == 0) return "none";
+    if (n > 1) return "mix";
+    return k128 ? "nax128" : (k64 ? "nax64" : "old");
+#else
+    return "none";
+#endif
+}
+
+// Случайные числа для весов: один общий запас float на самый большой размер (12288×4096),
+// заполненный быстрым генератором — mt19937 на 50 млн чисел занял бы секунды на телефоне.
+struct FloatPool {
+    std::vector<float> w;  // [-0.05, 0.05)
+    std::vector<float> x;  // [-1, 1)
+    void fill(size_t nw, size_t nx) {
+        uint64_t s = 0x9E3779B97F4A7C15ull;
+        auto next = [&s]() {
+            s ^= s << 13; s ^= s >> 7; s ^= s << 17;
+            return (float) ((s >> 40) * (1.0 / 16777216.0));  // [0,1)
+        };
+        w.resize(nw);
+        for (auto& v : w) v = 0.1f * next() - 0.05f;
+        x.resize(nx);
+        for (auto& v : x) v = 2.0f * next() - 1.0f;
+    }
+};
+
+// Квантование строк весов в несколько потоков (процессор — узкое место подготовки замера).
+void quantize_rows(ggml_type type, const float* src, uint8_t* dst, int nrows, int K) {
+    const size_t row = ggml_row_size(type, K);
+    int nt = (int) std::thread::hardware_concurrency();
+    nt = std::max(1, std::min(nt, 6));
+    if (nrows < 64) nt = 1;
+    std::vector<std::thread> th;
+    const int per = (nrows + nt - 1) / nt;
+    for (int t = 0; t < nt; t++) {
+        const int r0 = t * per, r1 = std::min(nrows, r0 + per);
+        if (r0 >= r1) break;
+        th.emplace_back([=]() {
+            ggml_quantize_chunk(type, src + (size_t) r0 * K, dst + (size_t) r0 * row, 0, r1 - r0, K, nullptr);
+        });
+    }
+    for (auto& t : th) t.join();
+}
+
+// Одно умножение: веса [M строк x K] типа type, активации float [Nmax токенов x K];
+// графы на Nmax и на каждом меньшем N из списка — это виды тех же активаций (первые N строк),
+// веса заливаются один раз.
 struct PaCase {
-    ggml_context* ctx      = nullptr;
+    ggml_context* ctx         = nullptr;
     ggml_backend_buffer_t buf = nullptr;
-    ggml_tensor* a         = nullptr;
-    ggml_tensor* b         = nullptr;
-    ggml_tensor* c         = nullptr;
-    ggml_cgraph* gf        = nullptr;
+    ggml_tensor* a            = nullptr;
+    ggml_tensor* b            = nullptr;
+    std::vector<int> ns;
+    std::vector<ggml_tensor*> c;
+    std::vector<ggml_cgraph*> gf;
 
     ~PaCase() {
         if (buf) ggml_backend_buffer_free(buf);
         if (ctx) ggml_free(ctx);
     }
 
-    bool init(ggml_backend_t be, ggml_type type, int M, int K, int N, uint32_t seed) {
+    bool init(ggml_backend_t be, ggml_type type, int M, int K, const std::vector<int>& n_list,
+              const FloatPool& pool) {
+        ns = n_list;
+        const int Nmax = *std::max_element(ns.begin(), ns.end());
         ggml_init_params ip = {};
-        ip.mem_size   = ggml_tensor_overhead() * 8 + ggml_graph_overhead();
+        ip.mem_size   = ggml_tensor_overhead() * (4 + 3 * ns.size()) + ggml_graph_overhead() * ns.size();
         ip.mem_buffer = nullptr;
         ip.no_alloc   = true;
         ctx           = ggml_init(ip);
         if (!ctx) return false;
-        a  = ggml_new_tensor_2d(ctx, type, K, M);
-        b  = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, N);
-        c  = ggml_mul_mat(ctx, a, b);
-        gf = ggml_new_graph(ctx);
-        ggml_build_forward_expand(gf, c);
+        a = ggml_new_tensor_2d(ctx, type, K, M);
+        b = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, Nmax);
+        for (int n : ns) {
+            ggml_tensor* bn = n == Nmax ? b : ggml_view_2d(ctx, b, K, n, b->nb[1], 0);
+            ggml_tensor* cn = ggml_mul_mat(ctx, a, bn);
+            ggml_cgraph* g  = ggml_new_graph(ctx);
+            ggml_build_forward_expand(g, cn);
+            c.push_back(cn);
+            gf.push_back(g);
+        }
         buf = ggml_backend_alloc_ctx_tensors(ctx, be);
         if (!buf) return false;
 
-        // Заполняем кусками, чтобы не держать на процессоре гигабайт float разом.
-        std::mt19937 rng(seed);
-        std::uniform_real_distribution<float> uw(-1.0f, 1.0f);
+        if ((size_t) M * K > pool.w.size() || (size_t) Nmax * K > pool.x.size()) return false;
+        // Веса: кусками по ~64 МБ квантованных, чтобы не держать всё на процессоре разом.
         const size_t row_a = ggml_row_size(type, K);
-        const int chunk = std::max(1, (1 << 20) / K);
-        std::vector<float> tmp((size_t) chunk * K);
-        std::vector<uint8_t> q((size_t) chunk * row_a);
+        const int chunk    = std::max(64, (int) ((64u << 20) / row_a));
+        std::vector<uint8_t> q((size_t) std::min(chunk, M) * row_a);
         for (int r0 = 0; r0 < M; r0 += chunk) {
             const int nr = std::min(chunk, M - r0);
-            for (size_t i = 0; i < (size_t) nr * K; i++) tmp[i] = 0.05f * uw(rng);
-            ggml_quantize_chunk(type, tmp.data(), q.data(), 0, nr, K, nullptr);
+            quantize_rows(type, pool.w.data() + (size_t) r0 * K, q.data(), nr, K);
             ggml_backend_tensor_set(a, q.data(), (size_t) r0 * row_a, (size_t) nr * row_a);
         }
-        for (int r0 = 0; r0 < N; r0 += chunk) {
-            const int nr = std::min(chunk, N - r0);
-            for (size_t i = 0; i < (size_t) nr * K; i++) tmp[i] = uw(rng);
-            ggml_backend_tensor_set(b, tmp.data(), (size_t) r0 * K * sizeof(float), (size_t) nr * K * sizeof(float));
-        }
+        ggml_backend_tensor_set(b, pool.x.data(), 0, (size_t) Nmax * K * sizeof(float));
         return true;
     }
 
@@ -138,7 +229,7 @@ struct PaCase {
     }
 };
 
-// Прогон: прогрев + 3 замера. Возвращает лучшее время в мс, <0 — сбой видеочипа.
+// Прогон: прогрев + reps замеров. Возвращает лучшее время в мс, <0 — сбой видеочипа.
 double run_timed(ggml_backend_t be, ggml_cgraph* gf, int reps) {
     if (ggml_backend_graph_compute(be, gf) != GGML_STATUS_SUCCESS) return -1.0;
     ggml_backend_synchronize(be);
@@ -166,6 +257,7 @@ const char* sd_pa_kernel_bench(void) {
     return R.c_str();
 #else
     ggml_time_init();
+    const int64_t t_start = ggml_time_us();
 
     // Видеочип: сперва через реестр бэкенда Metal по имени, потом любой GPU/IGPU,
     // потом любое устройство с именем MTL*. Телефон 24.09.2026 ответил «не открылся»
@@ -213,6 +305,8 @@ const char* sd_pa_kernel_bench(void) {
     appendf(head, "ядро по схеме MLX: %s; режим в работе: %s\n",
             compiled_at_start == 0 ? "нет (нет матричных блоков или не собралось раньше)" : "есть матричные блоки",
             compiled_at_start == 0 ? mode_name(0) : mode_name(mode_before));
+    appendf(head, "размеры Qwen-Image 2.1: скрытый 4096, MLP 12288, токенов 1037 и 1024; "
+                  "блок = 4·A(4096→4096) + 2·B(4096→12288) + C(12288→4096), шаг = 32 блока\n");
 
     bool any_fail  = false;
     bool any_error = false;
@@ -225,24 +319,28 @@ const char* sd_pa_kernel_bench(void) {
         ggml_backend_free(be);
         be = ggml_backend_dev_init(dev, nullptr);
     };
-    // Короткий прогон (только точность и один размер) — для проверки самой проверки.
+    // Короткий прогон (точность и первый размер) — для проверки самой проверки.
     const bool quick = getenv("PA_KERNEL_BENCH_QUICK") != nullptr;
 
+    FloatPool pool;
+    pool.fill(quick ? (size_t) 4096 * 4096 : (size_t) 12288 * 4096, (size_t) 1037 * 12288);
+
     // --- 1. Точность: маленький случай с неровными краями, полное сравнение ---
     {
         const int M = 200, K = 512, N = 100;
-        const ggml_type types[] = { GGML_TYPE_F16, GGML_TYPE_Q4_K, GGML_TYPE_Q4_0, GGML_TYPE_Q3_K };
+        const ggml_type types[] = { GGML_TYPE_F16, GGML_TYPE_Q4_K, GGML_TYPE_Q5_K, GGML_TYPE_Q8_0,
+                                    GGML_TYPE_Q4_0, GGML_TYPE_Q3_K };
         appendf(body, "\nТочность, %dx%d x %d токенов (эталон — процессор, float/double), макс. ошибка / сред. модуль:\n", M, K, N);
         for (ggml_type type : types) {
             PaCase pc;
-            if (!pc.init(be, type, M, K, N, 1234)) {
+            if (!pc.init(be, type, M, K, { N }, pool)) {
                 appendf(body, "  %s: не выделилась память\n", ggml_type_name(type));
                 any_error = true;
                 continue;
             }
             // эталон
             std::vector<double> ref((size_t) M * N);
-            std::vector<float> wr, ar;
+            std::vector<float> ar;
             std::vector<std::vector<float>> W(M);
             for (int m = 0; m < M; m++) pc.weight_row(m, K, W[m]);
             double mean_abs = 0;
@@ -257,19 +355,24 @@ const char* sd_pa_kernel_bench(void) {
             }
             mean_abs /= (double) M * N;
             appendf(body, "  %-5s", ggml_type_name(type));
+            std::string kb;
+            appendf(kb, "KBACC type=%s M=%d K=%d N=%d", ggml_type_name(type), M, K, N);
             double err_old = -1;
             for (int mode : modes) {
                 if (!be) break;
                 if (mode_dead[mode]) { appendf(body, " · %s пропущено", mode_name(mode)); continue; }
                 ggml_metal_pa_set_nax(mode);
+                kernel_taken();  // сброс счёта
                 std::vector<float> out((size_t) M * N, NAN);
-                if (ggml_backend_graph_compute(be, pc.gf) != GGML_STATUS_SUCCESS) {
+                if (ggml_backend_graph_compute(be, pc.gf[0]) != GGML_STATUS_SUCCESS) {
                     appendf(body, " · %s: СБОЙ видеочипа", mode_name(mode));
+                    appendf(kb, " %s_ok=0 %s_gpu=fail", mode_key(mode), mode_key(mode));
                     gpu_failed(mode);
                     continue;
                 }
                 ggml_backend_synchronize(be);
-                ggml_backend_tensor_get(pc.c, out.data(), 0, out.size() * sizeof(float));
+                const std::string taken = kernel_taken();
+                ggml_backend_tensor_get(pc.c[0], out.data(), 0, out.size() * sizeof(float));
                 double maxe = 0;
                 bool bad = false;
                 for (size_t i = 0; i < out.size(); i++) {
@@ -283,103 +386,189 @@ const char* sd_pa_kernel_bench(void) {
                 if (!ok && mode != 0) any_fail = true;
                 if (bad) appendf(body, " · %s: НЕ ЧИСЛА", mode_name(mode));
                 else appendf(body, " · %s %.4f%s", mode_name(mode), rel, ok ? "" : " ОШИБКА");
+                appendf(kb, " %s_err=%.5f %s_ok=%d %s_k=%s", mode_key(mode), bad ? -1.0 : rel,
+                        mode_key(mode), ok ? 1 : 0, mode_key(mode), taken.c_str());
             }
             body += "\n";
+            body += kb + "\n";
         }
     }
 
-    // --- 2. Скорость на размерах рисующей части ---
-    struct Sz { ggml_type type; int M, K, N; };
-    const Sz sizes[] = {
-        { GGML_TYPE_Q4_K,  3072,  3072, 1024 },
-        { GGML_TYPE_Q4_K, 12288,  3072, 1024 },
-        { GGML_TYPE_Q4_K,  3072, 12288, 1024 },
-        { GGML_TYPE_Q4_K,  3072,  3072, 2304 },
-        { GGML_TYPE_Q4_K, 12288,  4096, 2304 },
-        { GGML_TYPE_F16,   3072,  3072, 1024 },
-        { GGML_TYPE_F16,  12288,  3072, 1024 },
-        { GGML_TYPE_F16,  12288,  4096, 2304 },
-        { GGML_TYPE_Q4_0, 12288,  3072, 1024 },
-        { GGML_TYPE_Q3_K, 12288,  3072, 1024 },
+    // --- 2. Скорость на размерах рисующей части Qwen-Image 2.1 ---
+    struct Sz { const char* op; int M, K; int per_block; };
+    const Sz shapes[] = {
+        { "A_attn",  4096,  4096, 4 },   // to_q, to_k, to_v, to_out.0
+        { "B_up",   12288,  4096, 2 },   // img_mlp.proj, img_mlp.gate_layer
+        { "C_down",  4096, 12288, 1 },   // img_mlp.out
     };
+    const ggml_type types[] = { GGML_TYPE_Q4_K, GGML_TYPE_Q5_K, GGML_TYPE_Q8_0, GGML_TYPE_Q4_0, GGML_TYPE_F16 };
+    const std::vector<int> n_list = { 1037, 1024 };
+
     appendf(body, "\nСкорость (лучший из 3 прогонов, мс; в скобках трлн операций/с), выход x вход x токены:\n");
+    // время блока: [тип][N][режим]
+    struct BlockAcc { double ms[3] = {0, 0, 0}; bool ok[3] = {true, true, true}; int parts = 0; };
+    std::vector<std::vector<BlockAcc>> block(sizeof(types) / sizeof(types[0]), std::vector<BlockAcc>(n_list.size()));
     double best_gain = 0;
     std::string best_gain_what;
-    double sum_old = 0, sum_new[3] = {0, 0, 0};
-    int n_sum = 0;
-    for (const Sz& s : sizes) {
-        if (!be) break;
-        if (quick && &s != &sizes[0]) break;
-        PaCase pc;
-        if (!pc.init(be, s.type, s.M, s.K, s.N, 42)) {
-            appendf(body, "  %s %dx%dx%d: не выделилась память\n", ggml_type_name(s.type), s.M, s.K, s.N);
-            any_error = true;
-            continue;
-        }
-        const double flop = 2.0 * s.M * s.K * s.N;
-        appendf(body, "  %-5s %5dx%5dx%4d:", ggml_type_name(s.type), s.M, s.K, s.N);
+    size_t mem_peak = 0;
+
+    auto time_case = [&](PaCase& pc, const char* op, ggml_type type, int M, int K, size_t ni,
+                         BlockAcc* acc, int per_block) {
+        const int N = pc.ns[ni];
+        const double flop = 2.0 * M * K * (double) N;
+        appendf(body, "  %-6s %-5s %5dx%5dx%4d:", op, ggml_type_name(type), M, K, N);
+        std::string kb;
+        appendf(kb, "KB op=%s type=%s M=%d K=%d N=%d per_block=%d", op, ggml_type_name(type), M, K, N, per_block);
 
         // выборочная проверка: 256 точек против процессора
         std::mt19937 rng(7);
         std::vector<std::pair<int, int>> pts;
-        for (int i = 0; i < 256; i++) pts.push_back({ (int) (rng() % s.N), (int) (rng() % s.M) });
+        for (int i = 0; i < 256; i++) pts.push_back({ (int) (rng() % N), (int) (rng() % M) });
         std::vector<double> ref(pts.size());
         double mean_abs = 0;
         {
             std::vector<float> w, x;
             for (size_t i = 0; i < pts.size(); i++) {
-                pc.weight_row(pts[i].second, s.K, w);
-                pc.act_row(pts[i].first, s.K, x);
-                double acc = 0;
-                for (int k = 0; k < s.K; k++) acc += (double) w[k] * x[k];
-                ref[i] = acc;
-                mean_abs += std::fabs(acc);
+                pc.weight_row(pts[i].second, K, w);
+                pc.act_row(pts[i].first, K, x);
+                double s = 0;
+                for (int k = 0; k < K; k++) s += (double) w[k] * x[k];
+                ref[i] = s;
+                mean_abs += std::fabs(s);
             }
             mean_abs /= pts.size();
         }
 
         double t_old = -1, err_old = -1;
-        bool row_ok = true;
         for (int mode : modes) {
             if (!be) break;
-            if (mode_dead[mode]) { appendf(body, " · %s пропущено", mode_name(mode)); row_ok = false; continue; }
+            if (mode_dead[mode]) {
+                appendf(body, " · %s пропущено", mode_name(mode));
+                appendf(kb, " %s_ok=0 %s_gpu=skipped", mode_key(mode), mode_key(mode));
+                if (acc) acc->ok[mode] = false;
+                continue;
+            }
             ggml_metal_pa_set_nax(mode);
-            const double t = run_timed(be, pc.gf, 3);
+            kernel_taken();  // сброс счёта
+            const double t = run_timed(be, pc.gf[ni], 3);
             if (t < 0) {
                 appendf(body, " · %s СБОЙ видеочипа", mode_name(mode));
+                appendf(kb, " %s_ok=0 %s_gpu=fail", mode_key(mode), mode_key(mode));
+                if (acc) acc->ok[mode] = false;
                 gpu_failed(mode);
-                row_ok = false;
                 continue;
             }
+            const std::string taken = kernel_taken();
             double maxe = 0;
             bool bad = false;
             for (size_t i = 0; i < pts.size(); i++) {
                 float v = NAN;
-                ggml_backend_tensor_get(pc.c, &v, ((size_t) pts[i].first * s.M + pts[i].second) * sizeof(float), sizeof(float));
+                ggml_backend_tensor_get(pc.c[ni], &v, ((size_t) pts[i].first * M + pts[i].second) * sizeof(float), sizeof(float));
                 if (!std::isfinite(v)) { bad = true; break; }
                 maxe = std::max(maxe, std::fabs(v - ref[i]));
             }
             const double rel = maxe / std::max(1e-12, mean_abs);
             if (mode == 0) { t_old = t; err_old = rel; }
             const bool ok = !bad && (mode == 0 || rel <= std::max(3.0 * err_old, 0.02));
-            if (!ok) { any_fail = true; row_ok = false; }
-            appendf(body, " · %s %.1f (%.2f)%s", mode_name(mode), t, flop / (t * 1e-3) / 1e12,
+            if (!ok) any_fail = true;
+            const double tf = flop / (t * 1e-3) / 1e12;
+            appendf(body, " · %s %.2f (%.2f)%s", mode_name(mode), t, tf,
                     bad ? " НЕ ЧИСЛА" : (ok ? "" : " ОШИБКА"));
+            if (taken != mode_key(mode)) appendf(body, " [взято: %s]", taken.c_str());
+            appendf(kb, " %s_ms=%.3f %s_tf=%.3f %s_err=%.5f %s_ok=%d %s_k=%s", mode_key(mode), t, mode_key(mode), tf,
+                    mode_key(mode), bad ? -1.0 : rel, mode_key(mode), ok ? 1 : 0, mode_key(mode), taken.c_str());
             if (mode != 0 && t_old > 0 && ok) {
                 appendf(body, " ×%.2f", t_old / t);
                 if (t_old / t > best_gain) {
                     best_gain = t_old / t;
-                    char w[128];
-                    snprintf(w, sizeof(w), "%s, %s %dx%dx%d", mode_name(mode), ggml_type_name(s.type), s.M, s.K, s.N);
+                    char w[160];
+                    snprintf(w, sizeof(w), "%s, %s %s %dx%dx%d", mode_name(mode), op, ggml_type_name(type), M, K, N);
                     best_gain_what = w;
                 }
             }
-            if (row_ok) {
-                if (mode == 0) sum_old += t; else sum_new[mode] += t;
+            if (acc) {
+                acc->ms[mode] += t * per_block;
+                if (!ok) acc->ok[mode] = false;
             }
         }
-        if (row_ok) n_sum++;
         body += "\n";
+        body += kb + "\n";
+    };
+
+    for (size_t ti = 0; ti < sizeof(types) / sizeof(types[0]); ti++) {
+        const ggml_type type = types[ti];
+        for (const Sz& s : shapes) {
+            if (!be) break;
+            if (quick && !(ti == 0 && &s == &shapes[0])) break;
+            PaCase pc;
+            if (!pc.init(be, type, s.M, s.K, n_list, pool)) {
+                appendf(body, "  %-6s %s %dx%d: не выделилась память\n", s.op, ggml_type_name(type), s.M, s.K);
+                appendf(body, "KB op=%s type=%s M=%d K=%d alloc=fail\n", s.op, ggml_type_name(type), s.M, s.K);
+                any_error = true;
+                for (auto& acc : block[ti]) for (int m = 0; m < 3; m++) acc.ok[m] = false;
+                continue;
+            }
+            mem_peak = std::max(mem_peak, ggml_backend_buffer_get_size(pc.buf));
+            for (size_t ni = 0; ni < n_list.size(); ni++) {
+                time_case(pc, s.op, type, s.M, s.K, ni, &block[ti][ni], s.per_block);
+                block[ti][ni].parts++;
+            }
+        }
+        if (quick) break;
+    }
+
+    // «Хвост»: проекция текста, 13 токенов (раз на шаг, не в блоке).
+    if (be && !quick) {
+        PaCase pc;
+        if (pc.init(be, GGML_TYPE_Q4_K, 4096, 4096, { 13 }, pool)) {
+            time_case(pc, "T_txt13", GGML_TYPE_Q4_K, 4096, 4096, 0, nullptr, 0);
+        }
+    }
+
+    // --- 3. Блок и шаг ---
+    appendf(body, "\nБлок (все умножения одного слоя, мс) и шаг (x32), по типам весов:\n");
+    std::string summary_block;
+    for (size_t ti = 0; ti < sizeof(types) / sizeof(types[0]); ti++) {
+        for (size_t ni = 0; ni < n_list.size(); ni++) {
+            const BlockAcc& acc = block[ti][ni];
+            if (acc.parts != 3) continue;
+            const int N = n_list[ni];
+            const double flop = 2.0 * N * (4.0 * 4096 * 4096 + 2.0 * 12288 * 4096 + 1.0 * 4096 * 12288);
+            appendf(body, "  %-5s N=%4d:", ggml_type_name(types[ti]), N);
+            std::string kb;
+            appendf(kb, "KBBLOCK type=%s N=%d gflop=%.1f", ggml_type_name(types[ti]), N, flop / 1e9);
+            for (int mode : modes) {
+                if (!acc.ok[mode] || acc.ms[mode] <= 0) {
+                    appendf(body, " · %s —", mode_name(mode));
+                    appendf(kb, " %s_ok=0", mode_key(mode));
+                    continue;
+                }
+                const double tf = flop / (acc.ms[mode] * 1e-3) / 1e12;
+                appendf(body, " · %s %.1f мс (%.2f), шаг %.2f с", mode_name(mode), acc.ms[mode], tf, acc.ms[mode] * 32 / 1000.0);
+                if (mode != 0 && acc.ok[0] && acc.ms[0] > 0) appendf(body, " ×%.2f", acc.ms[0] / acc.ms[mode]);
+                appendf(kb, " %s_ms=%.2f %s_tf=%.3f %s_step_s=%.3f %s_ok=1", mode_key(mode), acc.ms[mode], mode_key(mode), tf,
+                        mode_key(mode), acc.ms[mode] * 32 / 1000.0, mode_key(mode));
+            }
+            body += "\n";
+            body += kb + "\n";
+            // Итог для экрана — по файлу, который сейчас рисует (q4_K), на 1037 токенах.
+            if (types[ti] == GGML_TYPE_Q4_K && N == 1037 && acc.ok[0] && acc.ms[0] > 0) {
+                char b[256];
+                if (modes.size() > 1) {
+                    auto part = [&](int m) {
+                        char p[64];
+                        if (acc.ok[m] && acc.ms[m] > 0) snprintf(p, sizeof(p), "%.0f (×%.2f)", acc.ms[m], acc.ms[0] / acc.ms[m]);
+                        else snprintf(p, sizeof(p), "—");
+                        return std::string(p);
+                    };
+                    snprintf(b, sizeof(b), "блок q4_K: старое %.0f мс, MLX 64 — %s, MLX 128 — %s",
+                             acc.ms[0], part(1).c_str(), part(2).c_str());
+                } else {
+                    snprintf(b, sizeof(b), "блок q4_K: старое %.0f мс", acc.ms[0]);
+                }
+                summary_block = b;
+            }
+        }
     }
 
     ggml_metal_pa_set_nax(-1);  // обратно к тому, что задаёт приложение (GGML_METAL_NAX)
@@ -389,19 +578,17 @@ const char* sd_pa_kernel_bench(void) {
     // Итоговая строка — её приложение показывает человеку.
     const int compiled = ggml_metal_pa_nax_compiled();
     appendf(head, "ядра MLX после замера: %s\n", compiled == 1 ? "собраны" : (compiled == 0 ? "НЕ собрались — считало старое" : "не понадобились"));
-    if (compiled != 1) {
-        summary = "Ядро MLX не собрано — работает старое";
-    } else if (any_fail) {
+    appendf(head, "KBINFO compiled=%d mode_before=%d quick=%d seconds=%.1f buf_peak_mb=%.0f\n", compiled, mode_before,
+            quick ? 1 : 0, (ggml_time_us() - t_start) / 1e6, mem_peak / 1048576.0);
+    if (any_fail) {
         summary = "Ядро MLX считает НЕВЕРНО — выключите «Ядро MLX»";
     } else if (any_error) {
         summary = mode_dead[1] || mode_dead[2] ? "Ядро MLX уронило видеочип — выключите «Ядро MLX»"
                                                : "Сбой видеочипа при замере — см. журнал";
-    } else if (n_sum > 0 && sum_old > 0) {
-        char b[256];
-        snprintf(b, sizeof(b), "Верно · всего: старое %.0f мс, MLX 64 — %.0f (×%.2f), MLX 128 — %.0f (×%.2f)",
-                 sum_old, sum_new[1], sum_old / std::max(1e-9, sum_new[1]),
-                 sum_new[2], sum_old / std::max(1e-9, sum_new[2]));
-        summary = b;
+    } else if (!summary_block.empty()) {
+        summary = (compiled == 1 ? "Верно · " : "Ядро MLX не собрано · ") + summary_block;
+    } else if (compiled != 1) {
+        summary = "Ядро MLX не собрано — работает старое";
     } else {
         summary = "Замер не дал чисел — см. журнал";
     }
PA_SD_V8_PATCH
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V9_PATCH' \
    || { echo "❌ правка sd.cpp v9 (RoPE одной операцией, выселение) не легла — см. $log" >&2; return 1; }
--- a/src/model/diffusion/qwen_image_2_1.hpp
+++ b/src/model/diffusion/qwen_image_2_1.hpp
@@ -5,6 +5,33 @@
 
 namespace Qwen {
 
+    // PocketAgent (движок v9, ROADMAP §24.5): SD_PA_ROPE=0 возвращает граф v8 — RoPE из
+    // REPEAT+MUL+ADD с копиями и копии срезов вокруг внимания. По умолчанию ВКЛ.
+    __STATIC_INLINE__ bool pa_rope_fused_enabled() {
+        const char* v = std::getenv("SD_PA_ROPE");
+        return v == nullptr || v[0] == '\0' || v[0] != '0';
+    }
+
+    // PocketAgent: RoPE одной операцией (ggml_rope_pa_table) по той же таблице pe, что и
+    // Rope::apply_rope: x [d, H, L, N] → [d, L, H*N], непрерывный. Замер блока 10 на телефоне
+    // (24.09.2026): штатная RoPE (REPEAT+MUL+ADD+CONT на q и k) — ~100–150 мс из ~300 мс блока,
+    // больше всех умножений q/k/v/out. Счёт тот же: x0*m0 + x1*m1 по парам (2j, 2j+1).
+    // Вычислитель не умеет (не Metal/CPU) или размеры не те — обычный путь.
+    __STATIC_INLINE__ ggml_tensor* pa_apply_rope(GGMLRunnerContext* ctx, ggml_tensor* x, ggml_tensor* pe) {
+        const int64_t d_head = x->ne[0], n_head = x->ne[1], L = x->ne[2], N = x->ne[3];
+        if (pa_rope_fused_enabled() && x->type == GGML_TYPE_F32 && pe->type == GGML_TYPE_F32 &&
+            d_head % 2 == 0 && pe->ne[0] == 2 && pe->ne[1] == 2 && pe->ne[2] == d_head / 2 && pe->ne[3] == L &&
+            ggml_is_contiguous(pe)) {
+            auto table = ggml_reshape_2d(ctx->ggml_ctx, pe, 2 * d_head, L);
+            auto view  = ggml_permute(ctx->ggml_ctx, x, 0, 2, 1, 3);  // [d, L, H, N]
+            auto out   = ggml_rope_pa_table(ctx->ggml_ctx, view, table);
+            if (ctx->backend == nullptr || ggml_backend_supports_op(ctx->backend, out)) {
+                return ggml_reshape_3d(ctx->ggml_ctx, out, d_head, L, n_head * N);
+            }
+        }
+        return Rope::apply_rope(ctx->ggml_ctx, x, pe);
+    }
+
     struct QwenImage21Config {
         int64_t in_channels       = 64;
         int64_t out_channels      = 64;
@@ -186,8 +213,11 @@
             auto v = project("to_v");
             q      = std::dynamic_pointer_cast<RMSNorm>(blocks["norm_q"])->forward(ctx, q);
             k      = std::dynamic_pointer_cast<RMSNorm>(blocks["norm_k"])->forward(ctx, k);
-            q      = Rope::apply_rope(ctx->ggml_ctx, q, pe);
-            k      = Rope::apply_rope(ctx->ggml_ctx, k, pe);
+            q      = pa_apply_rope(ctx, q, pe);
+            k      = pa_apply_rope(ctx, k, pe);
+            // PocketAgent v9: срезы по токенам — видами, без копий (внимание и приведение k/v
+            // к half читают с любыми шагами). SD_PA_ROPE=0 — копии, как в v8.
+            const bool pa_views = !pa_rope_fused_enabled();
             if (cache.mode == QwenImage21PrefixCache::Mode::STORE) {
                 auto persist = [&](ggml_tensor* tensor, int axis, const char* name) {
                     auto part = ggml_ext_slice(ctx->ggml_ctx, tensor, axis, 0, cache.prefix_length);
@@ -212,9 +242,9 @@
             } else {
                 for (size_t i = 0; i < segments.size(); ++i) {
                     const auto& segment = segments[i];
-                    auto sq             = ggml_ext_slice(ctx->ggml_ctx, q, 1, segment.start, segment.end);
-                    auto sk             = ggml_ext_slice(ctx->ggml_ctx, k, 1, 0, segment.end);
-                    auto sv             = ggml_ext_slice(ctx->ggml_ctx, v, 2, 0, segment.end);
+                    auto sq             = ggml_ext_slice(ctx->ggml_ctx, q, 1, segment.start, segment.end, pa_views);
+                    auto sk             = ggml_ext_slice(ctx->ggml_ctx, k, 1, 0, segment.end, pa_views);
+                    auto sv             = ggml_ext_slice(ctx->ggml_ctx, v, 2, 0, segment.end, pa_views);
                     auto out            = ggml_ext_attention_ext(ctx, sq, sk, sv, heads, masks[i], true, ctx->flash_attn_enabled);
                     result              = result == nullptr ? out : ggml_concat(ctx->ggml_ctx, result, out, 1);
                 }
@@ -248,11 +278,14 @@
                 row = gate ? ggml_tanh(ctx, row) : ggml_scale_bias(ctx, row, 1.f, 1.f);
                 return ggml_mul(ctx, part, row);
             };
-            auto target = apply(ggml_ext_slice(ctx, x, 1, prefix_length, x->ne[1]), rows[0]);
+            // PocketAgent v9: срез x [C, L] по токенам — уже непрерывный кусок памяти, копия не нужна
+            // (4 копии [4096,1024] на слой, ~11 мс на телефоне). SD_PA_ROPE=0 — как в v8.
+            const bool pa_copy = !pa_rope_fused_enabled() || !ggml_is_contiguous(x) || x->ne[2] != 1 || x->ne[3] != 1;
+            auto target = apply(ggml_ext_slice(ctx, x, 1, prefix_length, x->ne[1], pa_copy), rows[0]);
             if (prefix_length == 0) {
                 return target;
             }
-            auto prefix = apply(ggml_ext_slice(ctx, x, 1, 0, prefix_length), rows[1]);
+            auto prefix = apply(ggml_ext_slice(ctx, x, 1, 0, prefix_length, pa_copy), rows[1]);
             return ggml_concat(ctx, prefix, target, 1);
         }
 
--- a/src/core/ggml_extend.cpp
+++ b/src/core/ggml_extend.cpp
@@ -1,3 +1,4 @@
+#include <cstdlib>
 #include "core/ggml_extend.h"
 
 #include <cmath>
@@ -674,6 +675,16 @@
         }
         k_in = ggml_cast(ctx, k_in, GGML_TYPE_F16);
 
+        // PocketAgent (движок v9): без отдельной копии перестановки — приведение к half само
+        // читает переставленный вид и пишет непрерывно (одна операция вместо CONT + CPY).
+        // SD_PA_ROPE=0 — как было.
+        const char* pa_rope_env = std::getenv("SD_PA_ROPE");
+        const bool pa_v_direct  = !pad_head && kv_scale == 1.0f && v_in->type == GGML_TYPE_F32 &&
+                                 (pa_rope_env == nullptr || pa_rope_env[0] != '0');
+        if (pa_v_direct) {
+            v_in = ggml_cast(ctx, ggml_permute(ctx, v_in, 0, 2, 1, 3), GGML_TYPE_F16);
+            v_in = ggml_reshape_3d(ctx, v_in, d_head, L_k, n_kv_head * N);
+        } else {
         v_in = ggml_ext_cont(ctx, ggml_permute(ctx, v_in, 0, 2, 1, 3));
         v_in = ggml_reshape_3d(ctx, v_in, d_head, L_k, n_kv_head * N);
         if (pad_head) {
@@ -683,6 +694,7 @@
             v_in = ggml_ext_scale(ctx, v_in, kv_scale);
         }
         v_in = ggml_cast(ctx, v_in, GGML_TYPE_F16);
+        }
 
         if (mask_in != nullptr) {
             // ggml_flash_attn_ext expects the mask as a contiguous F16 tensor shaped
--- a/src/model_manager.cpp
+++ b/src/model_manager.cpp
@@ -1761,6 +1761,16 @@
     return out;
 }
 
+size_t ModelManager::pa_total_weight_bytes() const {
+    size_t total = 0;
+    for (const auto& state : tensor_states_) {
+        if (state != nullptr && state->tensor != nullptr) {
+            total += ggml_nbytes(state->tensor);
+        }
+    }
+    return total;
+}
+
 std::string ModelManager::pa_residency_summary(ggml_backend_t backend) const {
     std::string s;
     for (const auto& kv : pa_resident_by_component()) {
@@ -1885,6 +1895,35 @@
         return fits();
     };
 
+    // PocketAgent (движок v9): при SD_KEEP_WEIGHTS сперва выселяются части ДЕШЕВЛЕ просящей
+    // (ранг ниже: энкодер для рисующей части; энкодер и прочее для проявки), и только потом —
+    // собственные куски просящей по штатному «обратному порядку». Замер на телефоне 24.09.2026
+    // с SD_KEEP_ENCODER=1: энкодер 4,3 ГБ оставался, а рисующая часть на каждом куске выселяла
+    // СВОИ следующие куски («evict for Diffusion model: Diffusion model -117 MB» ×32 на шаг) —
+    // шаги 15–21 с вместо 9,7. Выселять надо энкодер.
+    if (pa_keep_rank_enabled() && !required_states.empty()) {
+        const int pa_need_rank = pa_keep_rank(required_states.front()->component);
+        std::vector<TensorState*> cheaper;
+        for (const auto& state : tensor_states_) {
+            if (state != nullptr && pa_keep_rank(state->component) < pa_need_rank) {
+                cheaper.push_back(state.get());
+            }
+        }
+        std::stable_sort(cheaper.begin(), cheaper.end(), [](const TensorState* lhs, const TensorState* rhs) {
+            const int lr = pa_keep_rank(lhs->component), rr = pa_keep_rank(rhs->component);
+            if (lr != rr) {
+                return lr < rr;
+            }
+            return lhs->last_use_epoch < rhs->last_use_epoch;
+        });
+        for (TensorState* state : cheaper) {
+            add_evictable_state(state);
+            if (release_eviction_states()) {
+                return true;
+            }
+        }
+    }
+
     for (const auto& candidate_params : preferred_eviction_order) {
         std::vector<TensorState*> candidate_states;
         if (!resolve_required_tensor_states(candidate_params, candidate_states)) {
--- a/src/model_manager.h
+++ b/src/model_manager.h
@@ -294,6 +294,8 @@
                                     const std::vector<ggml_tensor*>& tensors) override;
     void clear_prefetched_params(uintptr_t owner_id) override;
     std::string pa_residency_summary(ggml_backend_t backend) const override;
+    // PocketAgent (v9): сколько весов у всех частей вместе (в памяти или нет).
+    size_t pa_total_weight_bytes() const override;
 
 private:
     // PocketAgent: сколько байт весов каждой части сейчас в памяти вычислителя.
--- a/src/device_residency_manager.h
+++ b/src/device_residency_manager.h
@@ -72,6 +72,8 @@
     // PocketAgent: сводка для журнала — сколько весов каждой части сейчас в памяти
     // видеочипа и что говорит устройство о свободной памяти (SD_RESIDENCY_LOG).
     virtual std::string pa_residency_summary(ggml_backend_t backend) const { return {}; }
+    // PocketAgent (v9): все веса всех частей вместе, в байтах (0 — неизвестно).
+    virtual size_t pa_total_weight_bytes() const { return 0; }
 };
 
 // Transitional alias for model constructors that have not yet adopted the
--- a/src/core/ggml_runner.cpp
+++ b/src/core/ggml_runner.cpp
@@ -507,7 +507,18 @@
         // и менеджер будет выселять по кругу. Сколько реально держится — строка PA RESIDENCY.
         const char* pa_keep = std::getenv("SD_KEEP_WEIGHTS");
         const char* pa_keep_enc = std::getenv("SD_KEEP_ENCODER");
-        const bool pa_keep_enc_on = pa_keep_enc != nullptr && pa_keep_enc[0] != '\0' && pa_keep_enc[0] != '0';
+        bool pa_keep_enc_on = pa_keep_enc != nullptr && pa_keep_enc[0] != '\0' && pa_keep_enc[0] != '0';
+        // PocketAgent (v9): держать энкодер имеет смысл, только если в бюджет влезают ВСЕ веса.
+        // На телефоне 24.09.2026 бюджет ~4,5 ГБ при весах 8,8 ГБ — энкодер вытеснял рисующую
+        // часть по кускам на каждом шаге (шаги 15–21 с вместо 9,7). Не влезает — выселяем как обычно.
+        if (pa_keep_enc_on && !pa_keep_weights_ok() && max_graph_vram_bytes > 0) {
+            const size_t pa_all = manager->pa_total_weight_bytes();
+            if (pa_all > 0 && pa_all + 256ull * 1024 * 1024 > (size_t) max_graph_vram_bytes) {
+                pa_keep_enc_on = false;
+                LOG_INFO("PA RESIDENCY SD_KEEP_ENCODER не действует: весов %.0f MB, бюджет %.0f MB",
+                         pa_all / 1048576.0, max_graph_vram_bytes / 1048576.0);
+            }
+        }
         const bool pa_keep_on = !pa_destroying_ &&
                                 ((pa_keep != nullptr && pa_keep[0] != '\0' && pa_keep[0] != '0' &&
                                   (pa_keep_weights_ok() || std::string(pa_keep) == "all")) ||
PA_SD_V9_PATCH
  git -C "$src/ggml" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_GGML_V9_PATCH' \
    || { echo "❌ правка ggml v9 (ggml_rope_pa_table) не легла — см. $log" >&2; return 1; }
--- a/include/ggml.h
+++ b/include/ggml.h
@@ -252,6 +252,8 @@
 #define GGML_ROPE_TYPE_MROPE  8
 #define GGML_ROPE_TYPE_VISION 24
 #define GGML_ROPE_TYPE_IMROPE 40 // binary: 101000
+// PocketAgent: RoPE по готовой таблице 2x2 на каждую пару (src1 — таблица f32), см. ggml_rope_pa_table
+#define GGML_ROPE_TYPE_PA_TABLE 128
 
 #define GGML_MROPE_SECTIONS   4
 
@@ -1856,6 +1858,17 @@
             float                 beta_fast,
             float                 beta_slow);
 
+    // PocketAgent: RoPE по готовой таблице (Qwen-Image 2.1 и др. из sd.cpp).
+    //   a     — [d, L, H, N], любые шаги (обычно переставленный вид [d, H, L, N]);
+    //   table — f32, непрерывная, [4*(d/2), L]: на пару j токена l — матрица 2x2
+    //           {m0, m1, m2, m3}, и out[2j] = x[2j]*m0 + x[2j+1]*m1, out[2j+1] = x[2j]*m2 + x[2j+1]*m3
+    //           (раскладка pe у sd.cpp: [[cos, -sin], [sin, cos]]).
+    //   Результат — НЕПРЕРЫВНЫЙ [d, L, H, N]: перестановка входа уходит внутрь того же прохода.
+    GGML_API struct ggml_tensor * ggml_rope_pa_table(
+            struct ggml_context * ctx,
+            struct ggml_tensor  * a,
+            struct ggml_tensor  * table);
+
     // multi-dimensional RoPE, for Qwen-VL and similar vision models
     // mode can be either VISION, MROPE, IMROPE, cannot be combined with NORMAL or NEOX
     // sections specify how many dimensions to rotate in each section:
--- a/src/ggml.c
+++ b/src/ggml.c
@@ -4314,6 +4314,38 @@
     return result;
 }
 
+// PocketAgent: RoPE по готовой таблице — одна операция вместо REPEAT+MUL+ADD и копий.
+// Живёт внутри GGML_OP_ROPE (режим GGML_ROPE_TYPE_PA_TABLE), чтобы не добавлять новую
+// операцию во все вычислители: src[1] здесь — таблица f32, а не позиции.
+struct ggml_tensor * ggml_rope_pa_table(
+        struct ggml_context * ctx,
+        struct ggml_tensor  * a,
+        struct ggml_tensor  * table) {
+    GGML_ASSERT(a->type == GGML_TYPE_F32);
+    GGML_ASSERT(a->ne[0] % 2 == 0);
+    GGML_ASSERT(table->type == GGML_TYPE_F32);
+    GGML_ASSERT(ggml_is_contiguous(table));
+    GGML_ASSERT(table->ne[0] == 2*a->ne[0]);
+    GGML_ASSERT(table->ne[1] == a->ne[1]);
+    GGML_ASSERT(ggml_nelements(table) == table->ne[0]*table->ne[1]);
+
+    struct ggml_tensor * result = ggml_new_tensor(ctx, GGML_TYPE_F32, GGML_MAX_DIMS, a->ne);
+
+    int32_t params[15] = { 0, (int32_t) a->ne[0], GGML_ROPE_TYPE_PA_TABLE, 0, 0 };
+    const float one = 1.0f, zero = 0.0f;
+    memcpy(params + 5, &one,  sizeof(float)); // freq_base (не используется)
+    memcpy(params + 6, &one,  sizeof(float)); // freq_scale
+    memcpy(params + 7, &zero, sizeof(float)); // ext_factor
+    memcpy(params + 8, &one,  sizeof(float)); // attn_factor
+    ggml_set_op_params(result, params, sizeof(params));
+
+    result->op     = GGML_OP_ROPE;
+    result->src[0] = a;
+    result->src[1] = table;
+
+    return result;
+}
+
 struct ggml_tensor * ggml_rope(
         struct ggml_context * ctx,
         struct ggml_tensor  * a,
--- a/src/ggml-cpu/ops.cpp
+++ b/src/ggml-cpu/ops.cpp
@@ -6138,12 +6138,47 @@
     }
 }
 
+// PocketAgent: RoPE по готовой таблице (GGML_ROPE_TYPE_PA_TABLE, см. ggml_rope_pa_table).
+// Эталон для процессора: на телефоне считает видеочип, здесь — чтобы режим не падал
+// молча в обычную RoPE, если граф когда-нибудь уйдёт на процессор.
+static void ggml_compute_forward_rope_pa_table(const ggml_compute_params * params, ggml_tensor * dst) {
+    const ggml_tensor * src0  = dst->src[0];
+    const ggml_tensor * table = dst->src[1];
+    GGML_ASSERT(src0->type == GGML_TYPE_F32 && table->type == GGML_TYPE_F32 && dst->type == GGML_TYPE_F32);
+
+    const int64_t d  = src0->ne[0];
+    const int64_t nr = src0->ne[1]*src0->ne[2]*src0->ne[3];
+    const int64_t dr = (nr + params->nth - 1)/params->nth;
+    const int64_t r0 = dr*params->ith;
+    const int64_t r1 = MIN(r0 + dr, nr);
+
+    for (int64_t r = r0; r < r1; ++r) {
+        const int64_t i1 = r % src0->ne[1];
+        const int64_t i2 = (r / src0->ne[1]) % src0->ne[2];
+        const int64_t i3 = r / (src0->ne[1]*src0->ne[2]);
+        const char  * x  = (const char *) src0->data + i1*src0->nb[1] + i2*src0->nb[2] + i3*src0->nb[3];
+        float       * y  = (float *) ((char *) dst->data + i1*dst->nb[1] + i2*dst->nb[2] + i3*dst->nb[3]);
+        const float * m  = (const float *) table->data + i1*table->ne[0];
+        for (int64_t j = 0; j < d/2; ++j) {
+            const float x0 = *(const float *) (x + (2*j + 0)*src0->nb[0]);
+            const float x1 = *(const float *) (x + (2*j + 1)*src0->nb[0]);
+            y[2*j + 0] = x0*m[4*j + 0] + x1*m[4*j + 1];
+            y[2*j + 1] = x0*m[4*j + 2] + x1*m[4*j + 3];
+        }
+    }
+}
+
 void ggml_compute_forward_rope(
         const ggml_compute_params * params,
         ggml_tensor * dst) {
 
     const ggml_tensor * src0 = dst->src[0];
 
+    if (((const int32_t *) dst->op_params)[2] & GGML_ROPE_TYPE_PA_TABLE) {
+        ggml_compute_forward_rope_pa_table(params, dst);
+        return;
+    }
+
     switch (src0->type) {
         case GGML_TYPE_F16:
             {
--- a/src/ggml-metal/ggml-metal.metal
+++ b/src/ggml-metal/ggml-metal.metal
@@ -4863,6 +4863,40 @@
     }
 }
 
+// PocketAgent: RoPE по готовой таблице 2x2 (GGML_ROPE_TYPE_PA_TABLE, ggml_rope_pa_table).
+// src0 — вид [d, L, H, N] с любыми шагами (обычно переставленный [d, H, L, N]), src1 — таблица
+// f32 [4*(d/2), L], dst — непрерывный [d, L, H, N]. Группа потоков — одна строка (l, h, n),
+// поток — пара (2j, 2j+1): тот же счёт x0*m0 + x1*m1, что у sd.cpp (ggml_mul + ggml_add),
+// но за один проход, без REPEAT, без копий и без перестановок до и после.
+kernel void kernel_rope_pa_table_f32(
+        constant ggml_metal_kargs_rope & args,
+        device const char * src0,
+        device const char * src1,
+        device const char * src2,
+        device       char * dst,
+        ushort  tiitg[[thread_index_in_threadgroup]],
+        ushort3 tptg [[threads_per_threadgroup]],
+        uint3   tgpig[[threadgroup_position_in_grid]]) {
+    // Без слияния умножения со сложением (fma): штатный путь считает произведения отдельными
+    // операциями MUL и складывает их ADD — так результат совпадает с ним до бита.
+#pragma METAL fp contract(off)
+    const int i3 = tgpig[2];
+    const int i2 = tgpig[1];
+    const int i1 = tgpig[0];
+
+    device const char  * x = src0 + i3*args.nb03 + i2*args.nb02 + i1*args.nb01;
+    device       float * y = (device float *) (dst + i3*args.nb3 + i2*args.nb2 + i1*args.nb1);
+    device const float4 * m = (device const float4 *) src1 + (int64_t) i1*(args.ne00/2);
+
+    for (int j = tiitg; j < args.ne00/2; j += tptg.x) {
+        const float x0 = *(device const float *) (x + (2*j + 0)*args.nb00);
+        const float x1 = *(device const float *) (x + (2*j + 1)*args.nb00);
+        const float4 mm = m[j];
+        y[2*j + 0] = x0*mm[0] + x1*mm[1];
+        y[2*j + 1] = x0*mm[2] + x1*mm[3];
+    }
+}
+
 typedef decltype(kernel_rope_norm<float>) kernel_rope_norm_t;
 typedef decltype(kernel_rope_neox<float>) kernel_rope_neox_t;
 typedef decltype(kernel_rope_multi<float>) kernel_rope_multi_t;
--- a/src/ggml-metal/ggml-metal-device.cpp
+++ b/src/ggml-metal/ggml-metal-device.cpp
@@ -1977,6 +1977,15 @@
 
     const int mode = ((const int32_t *) op->op_params)[2];
 
+    // PocketAgent: RoPE по готовой таблице — своё ядро, без констант функции.
+    if (!is_back && (mode & GGML_ROPE_TYPE_PA_TABLE)) {
+        ggml_metal_pipeline_with_params pa = ggml_metal_library_get_pipeline(lib, "kernel_rope_pa_table_f32");
+        if (!pa.pipeline) {
+            pa = ggml_metal_library_compile_pipeline(lib, "kernel_rope_pa_table_f32", "kernel_rope_pa_table_f32", nullptr);
+        }
+        return pa;
+    }
+
     const bool is_neox   = mode & GGML_ROPE_TYPE_NEOX;
     const bool is_mrope  = mode & GGML_ROPE_TYPE_MROPE;
     const bool is_imrope = mode == GGML_ROPE_TYPE_IMROPE;
--- a/src/ggml-metal/ggml-metal-device.m
+++ b/src/ggml-metal/ggml-metal-device.m
@@ -1336,6 +1336,14 @@
         case GGML_OP_RMS_NORM:
             return has_simdgroup_reduction && (ggml_is_contiguous_rows(op->src[0]));
         case GGML_OP_ROPE:
+            // PocketAgent: RoPE по готовой таблице — только f32 и чётная длина головы.
+            if (((const int32_t *) op->op_params)[2] & GGML_ROPE_TYPE_PA_TABLE) {
+                return op->src[0]->type == GGML_TYPE_F32 && op->src[1] != NULL &&
+                       op->src[1]->type == GGML_TYPE_F32 && ggml_is_contiguous(op->src[1]) &&
+                       op->type == GGML_TYPE_F32 && op->src[0]->ne[0] % 2 == 0 &&
+                       ggml_is_contiguous(op);
+            }
+            return true;
         case GGML_OP_ROPE_BACK:
             return true;
         case GGML_OP_IM2COL:
--- a/src/ggml-metal/ggml-metal-ops.cpp
+++ b/src/ggml-metal/ggml-metal-ops.cpp
@@ -3896,6 +3896,32 @@
     ggml_metal_library_t lib = ctx->lib;
     ggml_metal_encoder_t enc = ctx->enc;
 
+    // PocketAgent: RoPE по готовой таблице (ggml_rope_pa_table): src[1] — таблица, позиций нет.
+    if (((const int32_t *) op->op_params)[2] & GGML_ROPE_TYPE_PA_TABLE) {
+        ggml_metal_kargs_rope args = {};
+        args.ne00 = op->src[0]->ne[0]; args.ne01 = op->src[0]->ne[1];
+        args.ne02 = op->src[0]->ne[2]; args.ne03 = op->src[0]->ne[3];
+        args.nb00 = op->src[0]->nb[0]; args.nb01 = op->src[0]->nb[1];
+        args.nb02 = op->src[0]->nb[2]; args.nb03 = op->src[0]->nb[3];
+        args.ne0  = op->ne[0]; args.ne1 = op->ne[1]; args.ne2 = op->ne[2]; args.ne3 = op->ne[3];
+        args.nb0  = op->nb[0]; args.nb1 = op->nb[1]; args.nb2 = op->nb[2]; args.nb3 = op->nb[3];
+        args.n_dims = (int32_t) op->src[0]->ne[0];
+
+        auto pipeline = ggml_metal_library_get_pipeline_rope(lib, op);
+
+        ggml_metal_encoder_set_pipeline(enc, pipeline);
+        ggml_metal_encoder_set_bytes   (enc, &args, sizeof(args), 0);
+        ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op->src[0]), 1);
+        ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op->src[1]), 2);
+        ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op->src[0]), 3);
+        ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op),         4);
+
+        const int nth = std::min(1024, (int) (op->src[0]->ne[0]/2));
+        ggml_metal_encoder_dispatch_threadgroups(enc, op->src[0]->ne[1], op->src[0]->ne[2], op->src[0]->ne[3], nth, 1, 1);
+
+        return 1;
+    }
+
     GGML_TENSOR_LOCALS( int32_t, ne0, op->src[0], ne);
     GGML_TENSOR_LOCALS(uint64_t, nb0, op->src[0], nb);
     GGML_TENSOR_LOCALS( int32_t, ne1, op->src[1], ne);
PA_GGML_V9_PATCH
  # >>> патч 12 (инженер A)
  # Режимы GGML_METAL_NAX=3..6, описание — п.12 выше. Отдельные ядра, своя
  # библиотека шейдеров, свой крючок в ggml_metal_op_mul_mat; режимы 0..2 не тронуты.
  git -C "$src/ggml" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_GGML_V12A_PATCH' \
    || { echo "❌ правка ggml v12a (ядра NAXA, режимы 3–6) не легла — см. $log" >&2; return 1; }
--- a/src/ggml-metal/ggml-metal-device.h
+++ b/src/ggml-metal/ggml-metal-device.h
@@ -297,6 +297,22 @@
 void ggml_metal_device_event_free(ggml_metal_device_t dev, ggml_metal_event_t ev);
 void ggml_metal_device_event_synchronize(ggml_metal_device_t dev, ggml_metal_event_t ev);
 
+// PocketAgent, патч 12 (инженер A): режимы GGML_METAL_NAX=3..6 (kernel_mul_mm_naxa*).
+// Своя библиотека шейдеров (собирается при первом умножении в этих режимах; NULL — нет
+// матричных блоков или не собралась) и постоянный буфер под half-активации / half-веса.
+// Возможны на устройстве с тензорным путём или с GGML_METAL_PA_NAX_EMU=1 (эмуляция на M1).
+bool                 ggml_metal_device_pa_naxa_possible(ggml_metal_device_t dev);
+ggml_metal_library_t ggml_metal_device_get_library_naxa(ggml_metal_device_t dev);
+// Буфер видеочипа не меньше nbytes, живёт до конца процесса (старый при росте не освобождается:
+// его ещё могут читать командные буферы в полёте). metal == NULL — не выделился.
+struct ggml_metal_buffer_id ggml_metal_device_pa_scratch(ggml_metal_device_t dev, size_t nbytes);
+// Режим инженера A: 3..6 или 0. Задаётся ggml_metal_pa_naxa_force (замер ядра), иначе
+// GGML_METAL_NAX из окружения (читается на каждом умножении).
+void ggml_metal_pa_naxa_force(int mode);
+int  ggml_metal_pa_naxa_mode(void);
+// Счёт умножений в режимах 3..6 с прошлого сброса (строка для журнала), как ggml_metal_pa_nax_stats.
+void ggml_metal_pa_naxa_stats(char * buf, size_t len, int reset);
+
 void ggml_metal_device_get_memory(ggml_metal_device_t dev, size_t * free, size_t * total);
 bool ggml_metal_device_supports_op(ggml_metal_device_t dev, const struct ggml_tensor * op);
 
--- a/src/ggml-metal/ggml-metal-device.m
+++ b/src/ggml-metal/ggml-metal-device.m
@@ -280,6 +280,125 @@
     return res;
 }
 
+// PocketAgent, патч 12 (инженер A): своя библиотека для режимов GGML_METAL_NAX=3..6 и постоянный
+// буфер под half-активации / half-веса. Отдельно от основной библиотеки и от библиотеки патча 7:
+// если компилятор телефона новые ядра не примет, остальное работает как раньше (умножение уходит
+// старым путём, в журнале строка «PA NAXA: … не собралась»).
+static ggml_metal_library_t g_pa_naxa_lib   = NULL;
+static int                  g_pa_naxa_state = 0;   // 0 — не собирали, 1 — есть, -1 — не собралась
+static id<MTLBuffer>        g_pa_scr        = nil;
+static size_t               g_pa_scr_size   = 0;
+
+static bool pa_naxa_emu_env(void) {
+    const char * e = getenv("GGML_METAL_PA_NAX_EMU");
+    return e != NULL && e[0] == '1';
+}
+
+bool ggml_metal_device_pa_naxa_possible(ggml_metal_device_t dev) {
+    return ggml_metal_device_get_props(dev)->has_tensor || pa_naxa_emu_env();
+}
+
+ggml_metal_library_t ggml_metal_device_get_library_naxa(ggml_metal_device_t dev) {
+    if (!ggml_metal_device_pa_naxa_possible(dev)) {
+        return NULL;
+    }
+    id<MTLDevice> device = (id<MTLDevice>) ggml_metal_device_get_obj(dev);
+    @synchronized (device) {
+        if (g_pa_naxa_state != 0) {
+            return g_pa_naxa_lib;
+        }
+        g_pa_naxa_state = -1;
+#if GGML_METAL_EMBED_LIBRARY
+        const int64_t t_start = ggml_time_us();
+        const struct ggml_metal_device_props * props = ggml_metal_device_get_props(dev);
+        const bool emu = !props->has_tensor;
+
+        extern const char ggml_metallib_start[];
+        extern const char ggml_metallib_end[];
+        NSString * src = [[NSString alloc] initWithBytes:ggml_metallib_start
+                                                  length:(ggml_metallib_end - ggml_metallib_start)
+                                                encoding:NSUTF8StringEncoding];
+        id<MTLLibrary> library = nil;
+        @autoreleasepool {
+            NSMutableDictionary * prep = [NSMutableDictionary dictionary];
+            if (props->has_bfloat) {
+                [prep setObject:@"1" forKey:@"GGML_METAL_HAS_BF16"];
+            }
+            if (props->has_tensor) {
+                [prep setObject:@"1" forKey:@"GGML_METAL_HAS_TENSOR"];
+            } else {
+                [prep setObject:@"1" forKey:@"GGML_METAL_PA_NAX_EMU"];
+            }
+            [prep setObject:@"1" forKey:@"GGML_METAL_PA_NAXA"];
+            [prep setObject:@"1" forKey:@"GGML_METAL_EMBED_LIBRARY"];
+
+            MTLCompileOptions * options = [MTLCompileOptions new];
+            options.preprocessorMacros = prep;
+            // Версия языка: по умолчанию — как у основной библиотеки (самая новая, что знает ОС).
+            // GGML_METAL_NAXA_LANG=4.0 / 4.1 — задать явно.
+            const char * lang = getenv("GGML_METAL_NAXA_LANG");
+            if (lang && strcmp(lang, "4.0") == 0) {
+                options.languageVersion = (MTLLanguageVersion) (4 << 16);
+            } else if (lang && strcmp(lang, "4.1") == 0) {
+                options.languageVersion = (MTLLanguageVersion) ((4 << 16) + 1);
+            }
+            const unsigned lv = (unsigned) options.languageVersion;
+
+            NSError * error = nil;
+            library = [device newLibraryWithSource:src options:options error:&error];
+            if (library == nil) {
+                GGML_LOG_ERROR("%s: PA NAXA: библиотека не собралась: %s\n", __func__,
+                               error ? [[error description] UTF8String] : "?");
+            } else {
+                GGML_LOG_INFO("%s: PA NAXA: библиотека собрана за %.3f с, язык %u.%u%s\n", __func__,
+                              (ggml_time_us() - t_start) / 1e6, lv >> 16, lv & 0xFFFF,
+                              emu ? ", ЭМУЛЯЦИЯ блоков (проверка на Маке)" : "");
+            }
+            [options release];
+        }
+        [src release];
+
+        if (library != nil) {
+            ggml_metal_library_t res = calloc(1, sizeof(struct ggml_metal_library));
+            if (res) {
+                res->obj       = library;
+                res->dev       = dev;
+                res->pipelines = ggml_metal_pipelines_init();
+                res->lock      = [NSLock new];
+                g_pa_naxa_lib   = res;
+                g_pa_naxa_state = 1;
+            }
+        }
+#else
+        GGML_LOG_WARN("%s: PA NAXA: нужны вшитые шейдеры (GGML_METAL_EMBED_LIBRARY) — режимы 3..6 недоступны\n", __func__);
+#endif
+        return g_pa_naxa_lib;
+    }
+}
+
+struct ggml_metal_buffer_id ggml_metal_device_pa_scratch(ggml_metal_device_t dev, size_t nbytes) {
+    struct ggml_metal_buffer_id res = { NULL, 0 };
+    id<MTLDevice> device = (id<MTLDevice>) ggml_metal_device_get_obj(dev);
+    @synchronized (device) {
+        if (g_pa_scr == nil || g_pa_scr_size < nbytes) {
+            const size_t sz = ((nbytes + (1u << 20) - 1) >> 20) << 20;
+            id<MTLBuffer> b = [device newBufferWithLength:sz options:MTLResourceStorageModePrivate];
+            if (b == nil) {
+                GGML_LOG_ERROR("%s: PA NAXA: не выделился буфер %.1f МБ\n", __func__, sz / 1048576.0);
+                return res;
+            }
+            // Старый буфер не отпускаем: его ещё могут читать командные буферы в полёте
+            // (ggml кодирует их без удержания ссылок). Рост — редкость: до самого большого слоя.
+            g_pa_scr      = b;
+            g_pa_scr_size = sz;
+            GGML_LOG_INFO("%s: PA NAXA: буфер видеочипа %.1f МБ\n", __func__, sz / 1048576.0);
+        }
+        res.metal = (__bridge void *) g_pa_scr;
+        res.offs  = 0;
+    }
+    return res;
+}
+
 ggml_metal_library_t ggml_metal_library_init_from_source(ggml_metal_device_t dev, const char * source, bool verbose) {
     if (source == NULL) {
         GGML_LOG_ERROR("%s: source is NULL\n", __func__);
--- a/src/ggml-metal/ggml-metal-impl.h
+++ b/src/ggml-metal/ggml-metal-impl.h
@@ -1302,6 +1302,22 @@
     int64_t  np;
 } ggml_metal_kargs_opt_step_adamw;
 
+// PocketAgent, патч 12 (инженер A): умножение для матричных блоков A19 — режимы
+// GGML_METAL_NAX=3..6 (ядра kernel_mul_mm_naxd*/naxs*, своя библиотека шейдеров).
+// Только плоские умножения: веса [M][K], активации [N][K], выход [N][M] подряд.
+// Сначала 8-байтные поля — раскладка совпадает в C и в Metal без выравнивающих дыр.
+#define FC_PA_NAXA 1900
+typedef struct {
+    uint64_t nb01;   // шаг строки весов, байт (у развёрнутых в half — K*2)
+    uint64_t nb11;   // шаг строки активаций, байт (буфер half — K*2, исходные float — nb[1])
+    int32_t  ne00;   // K
+    int32_t  ne0;    // M — строки весов = столбцы выхода
+    int32_t  ne1;    // N — токены
+    int32_t  n_tt;   // плиток по токенам в раздаче
+    int32_t  n_wt;   // плиток по весам
+    int32_t  swz;    // ширина полосы обхода плиток по весам (1 — построчно)
+} ggml_metal_kargs_pa_naxa;
+
 typedef struct {
     int64_t  np;
 } ggml_metal_kargs_opt_step_sgd;
--- a/src/ggml-metal/ggml-metal-ops.cpp
+++ b/src/ggml-metal/ggml-metal-ops.cpp
@@ -2347,9 +2347,16 @@
     return 1;
 }
 
+// PocketAgent, патч 12 (инженер A): режимы GGML_METAL_NAX=3..6, см. ниже pa_naxa_encode.
+static bool pa_naxa_encode(ggml_metal_op_t ctx, ggml_tensor * op);
+
 int ggml_metal_op_mul_mat(ggml_metal_op_t ctx, int idx) {
     ggml_tensor * op = ctx->node(idx);
 
+    if (pa_naxa_encode(ctx, op)) {
+        return 1;
+    }
+
     ggml_metal_library_t lib = ctx->lib;
     ggml_metal_encoder_t enc = ctx->enc;
 
@@ -2591,6 +2598,278 @@
     return 1;
 }
 
+//
+// PocketAgent, патч 12 (инженер A): умножение на матричных блоках A19, режимы GGML_METAL_NAX=3..6.
+// Ядра — kernel_mul_mm_naxa* в ggml-metal.metal (там же, почему именно так). Здесь — выбор и раздача:
+//   • активации float → half один раз на умножение в постоянный буфер (GGML_METAL_NAXA_ACT=f32 — нет);
+//   • режим 4 — ещё и веса слоя → half в тот же буфер, затем плотное прямое ядро;
+//   • обход плиток полосами по GGML_METAL_NAXA_SWZ плиток весов (по умолчанию 8; 1 — построчно).
+// Буфер общий для всех умножений: перед его записью — барьер (все прежние раздачи закончены),
+// между записью и чтением — ещё один. Не подходит умножение — false, и работает прежний путь
+// (патч 7 / штатное ядро) ровно как без этой правки.
+//
+#include <atomic>
+#include <cstdio>
+#include <cstdlib>
+#include <cstring>
+#include <map>
+#include <mutex>
+#include <string>
+#include <unordered_set>
+
+static std::atomic<int> g_pa_naxa_forced{-1};
+
+void ggml_metal_pa_naxa_force(int mode) {
+    g_pa_naxa_forced.store(mode);
+}
+
+int ggml_metal_pa_naxa_mode(void) {
+    const int f = g_pa_naxa_forced.load();
+    if (f >= 0) {
+        return (f >= 3 && f <= 6) ? f : 0;
+    }
+    // На каждом умножении, как GGML_METAL_NAX у патча 7: режим меняется со следующей картинки.
+    const char * e = getenv("GGML_METAL_NAX");
+    if (e == nullptr || e[0] == '\0') {
+        return 0;
+    }
+    const int v = atoi(e);
+    return (v >= 3 && v <= 6) ? v : 0;
+}
+
+static std::mutex                  g_pa_naxa_mu;
+static std::map<std::string, long> g_pa_naxa_stat;
+
+// Счёт «тип весов → что взято»; каждое новое сочетание — строкой в журнал (один раз).
+static void pa_naxa_note(const ggml_tensor * op, const char * what) {
+    char key[160];
+    snprintf(key, sizeof(key), "%s → %s", ggml_type_name(op->src[0]->type), what);
+    std::lock_guard<std::mutex> lk(g_pa_naxa_mu);
+    long & c = g_pa_naxa_stat[key];
+    if (c++ == 0) {
+        GGML_LOG_INFO("PA NAXA: умножение %s [%lldx%lld x %lld]\n", key,
+                      (long long) op->src[0]->ne[1], (long long) op->src[0]->ne[0], (long long) op->src[1]->ne[1]);
+    }
+}
+
+void ggml_metal_pa_naxa_stats(char * buf, size_t len, int reset) {
+    std::string out = "PA NAXA: режим " + std::to_string(ggml_metal_pa_naxa_mode()) + "; умножений:";
+    std::lock_guard<std::mutex> lk(g_pa_naxa_mu);
+    for (const auto & kv : g_pa_naxa_stat) {
+        out += " " + kv.first + " ×" + std::to_string(kv.second) + ";";
+    }
+    if (g_pa_naxa_stat.empty()) {
+        out += " не было";
+    }
+    if (reset) {
+        g_pa_naxa_stat.clear();
+    }
+    if (buf && len) {
+        snprintf(buf, len, "%s", out.c_str());
+    }
+}
+
+static int pa_naxa_env_int(const char * name, int def) {
+    const char * e = getenv(name);
+    return (e && e[0]) ? atoi(e) : def;
+}
+
+// Конвейер по имени; несобравшийся не пробуем снова на каждом умножении.
+static ggml_metal_pipeline_with_params pa_naxa_pipeline(ggml_metal_library_t lib, const char * base, int ah) {
+    static std::mutex                      mu;
+    static std::unordered_set<std::string> failed;
+
+    char name[256];
+    if (ah >= 0) {
+        snprintf(name, sizeof(name), "%s_ah=%d", base, ah);
+    } else {
+        snprintf(name, sizeof(name), "%s", base);
+    }
+    {
+        std::lock_guard<std::mutex> lk(mu);
+        if (failed.count(name)) {
+            ggml_metal_pipeline_with_params none = {};
+            return none;
+        }
+    }
+    ggml_metal_pipeline_with_params p = ggml_metal_library_get_pipeline(lib, name);
+    if (!p.pipeline) {
+        ggml_metal_cv_t cv = nullptr;
+        if (ah >= 0) {
+            cv = ggml_metal_cv_init();
+            ggml_metal_cv_set_bool(cv, ah != 0, FC_PA_NAXA + 0);
+        }
+        p = ggml_metal_library_compile_pipeline(lib, base, name, cv);
+        if (cv) {
+            ggml_metal_cv_free(cv);
+        }
+    }
+    if (!p.pipeline) {
+        std::lock_guard<std::mutex> lk(mu);
+        if (failed.insert(name).second) {
+            GGML_LOG_WARN("%s: PA NAXA: конвейер %s не собрался — умножение прежним путём\n", __func__, name);
+        }
+    }
+    return p;
+}
+
+static bool pa_naxa_encode(ggml_metal_op_t ctx, ggml_tensor * op) {
+    const int mode = ggml_metal_pa_naxa_mode();
+    if (mode == 0) {
+        return false;
+    }
+
+    const ggml_tensor * s0 = op->src[0];
+    const ggml_tensor * s1 = op->src[1];
+
+    const int64_t K = s0->ne[0];
+    const int64_t M = s0->ne[1];
+    const int64_t N = s1->ne[1];
+
+    const char * why = nullptr;
+    const bool type_ok = s0->type == GGML_TYPE_F16  || s0->type == GGML_TYPE_Q4_0 || s0->type == GGML_TYPE_Q8_0 ||
+                         s0->type == GGML_TYPE_Q4_K || s0->type == GGML_TYPE_Q5_K || s0->type == GGML_TYPE_Q6_K;
+    if (!ggml_metal_device_pa_naxa_possible(ctx->dev)) {
+        why = "прежнее (нет матричных блоков)";
+    } else if (ggml_get_op_params_i32(op, 1) == GGML_HINT_SRC0_IS_HADAMARD) {
+        why = "прежнее (Адамар)";
+    } else if (!type_ok || s1->type != GGML_TYPE_F32 || op->type != GGML_TYPE_F32) {
+        why = "прежнее (тип весов/активаций)";
+    } else if (s0->ne[2] != 1 || s0->ne[3] != 1 || s1->ne[2] != 1 || s1->ne[3] != 1) {
+        why = "прежнее (не плоское)";
+    } else if (K % 32 != 0 || K > INT32_MAX / 2 || M > INT32_MAX || N > INT32_MAX) {
+        why = "прежнее (K не кратно 32)";
+    } else if (s0->nb[0] != ggml_type_size(s0->type) || s0->nb[1] % 4 != 0) {
+        why = "прежнее (веса не подряд)";
+    } else if (s1->nb[0] != sizeof(float) || s1->nb[1] % 16 != 0) {
+        why = "прежнее (активации не подряд)";
+    } else if (!ggml_is_contiguous(op)) {
+        why = "прежнее (выход не подряд)";
+    } else if (N <= 8) {
+        why = "прежнее (мало токенов)";
+    }
+    if (why) {
+        pa_naxa_note(op, why);
+        return false;
+    }
+
+    ggml_metal_library_t nlib = ggml_metal_device_get_library_naxa(ctx->dev);
+    if (nlib == nullptr) {
+        pa_naxa_note(op, "прежнее (библиотека NAXA не собралась)");
+        return false;
+    }
+
+    // Плитка: токены × строки весов, SIMD-групп, общая память (только режим 6).
+    int bt = 128, bw = 128, nsg = 16;
+    size_t smem = 0;
+    switch (mode) {
+        case 3: case 4: bt = 128; bw = 128; nsg = 16; break;
+        case 5:         bt = 64;  bw = 128; nsg = 4;  break;
+        case 6:         bt = 64;  bw = 128; nsg = 4;  smem = 2 * 128 * (32 + 8) * sizeof(ggml_fp16_t); break;
+    }
+
+    const char * act_env = getenv("GGML_METAL_NAXA_ACT");
+    const int ah = (act_env && strcmp(act_env, "f32") == 0) ? 0 : 1;
+    const int swz = std::max(1, pa_naxa_env_int("GGML_METAL_NAXA_SWZ", 8));
+
+    char base[128];
+    // режим 4: второй проход — то же прямое ядро 128 x 128 (режим 3) на развёрнутых half-весах
+    snprintf(base, sizeof(base), "kernel_mul_mm_naxa%d_%s", mode == 4 ? 3 : mode, mode == 4 ? "f16" : ggml_type_name(s0->type));
+    ggml_metal_pipeline_with_params pm = pa_naxa_pipeline(nlib, base, ah);
+    ggml_metal_pipeline_with_params pc = {};
+    ggml_metal_pipeline_with_params pd = {};
+    if (ah) {
+        pc = pa_naxa_pipeline(nlib, "kernel_pa_naxa_cvt", -1);
+    }
+    if (mode == 4) {
+        char dname[128];
+        snprintf(dname, sizeof(dname), "kernel_pa_naxa_deq_%s", ggml_type_name(s0->type));
+        pd = pa_naxa_pipeline(nlib, dname, -1);
+    }
+    if (!pm.pipeline || (ah && !pc.pipeline) || (mode == 4 && !pd.pipeline)) {
+        pa_naxa_note(op, "прежнее (конвейер NAXA не собрался)");
+        return false;
+    }
+    if (ggml_metal_pipeline_max_theads_per_threadgroup(pm) < 32 * nsg) {
+        char w[96];
+        snprintf(w, sizeof(w), "прежнее (режим %d: мало нитей на группу, %d < %d)", mode,
+                 ggml_metal_pipeline_max_theads_per_threadgroup(pm), 32 * nsg);
+        pa_naxa_note(op, w);
+        return false;
+    }
+
+    // Буфер: [активации half N×K][веса half M×K — только режим 4].
+    const size_t act_bytes = ah ? GGML_PAD((size_t) N * K * sizeof(ggml_fp16_t), 256) : 0;
+    const size_t w_bytes   = mode == 4 ? (size_t) M * K * sizeof(ggml_fp16_t) : 0;
+    ggml_metal_buffer_id bid_scr = {};
+    if (act_bytes + w_bytes > 0) {
+        bid_scr = ggml_metal_device_pa_scratch(ctx->dev, act_bytes + w_bytes);
+        if (bid_scr.metal == nullptr) {
+            pa_naxa_note(op, "прежнее (буфер NAXA не выделился)");
+            return false;
+        }
+    }
+    ggml_metal_buffer_id bid_act = bid_scr;
+    ggml_metal_buffer_id bid_w   = bid_scr;
+    bid_w.offs += act_bytes;
+
+    ggml_metal_encoder_t enc = ctx->enc;
+
+    ggml_metal_kargs_pa_naxa args = {};
+    args.nb01 = s0->nb[1];
+    args.nb11 = s1->nb[1];
+    args.ne00 = (int32_t) K;
+    args.ne0  = (int32_t) M;
+    args.ne1  = (int32_t) N;
+    args.n_tt = (int32_t) ((N + bt - 1) / bt);
+    args.n_wt = (int32_t) ((M + bw - 1) / bw);
+    args.swz  = swz;
+
+    if (act_bytes + w_bytes > 0) {
+        // буфер общий: прежние умножения, читавшие его, должны закончиться
+        ggml_metal_op_concurrency_reset(ctx);
+        if (ah) {
+            ggml_metal_encoder_set_pipeline(enc, pc);
+            ggml_metal_encoder_set_bytes   (enc, &args, sizeof(args), 0);
+            ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(s1), 1);
+            ggml_metal_encoder_set_buffer  (enc, bid_act, 2);
+            const int nth = (int) std::min<int64_t>(256, K / 4);
+            ggml_metal_encoder_dispatch_threadgroups(enc, (int) N, 1, 1, nth, 1, 1);
+        }
+        if (mode == 4) {
+            ggml_metal_encoder_set_pipeline(enc, pd);
+            ggml_metal_encoder_set_bytes   (enc, &args, sizeof(args), 0);
+            ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(s0), 1);
+            ggml_metal_encoder_set_buffer  (enc, bid_w, 2);
+            const int nth = (int) std::min<int64_t>(256, K / 16);
+            ggml_metal_encoder_dispatch_threadgroups(enc, (int) M, 1, 1, nth, 1, 1);
+        }
+        ggml_metal_op_concurrency_reset(ctx);
+    }
+
+    if (ah) {
+        args.nb11 = (uint64_t) K * sizeof(ggml_fp16_t);
+    }
+    if (mode == 4) {
+        args.nb01 = (uint64_t) K * sizeof(ggml_fp16_t);
+    }
+
+    ggml_metal_encoder_set_pipeline(enc, pm);
+    ggml_metal_encoder_set_bytes   (enc, &args, sizeof(args), 0);
+    ggml_metal_encoder_set_buffer  (enc, mode == 4 ? bid_w : ggml_metal_get_buffer_id(s0), 1);
+    ggml_metal_encoder_set_buffer  (enc, ah ? bid_act : ggml_metal_get_buffer_id(s1), 2);
+    ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op), 3);
+    if (smem) {
+        ggml_metal_encoder_set_threadgroup_memory_size(enc, smem, 0);
+    }
+    ggml_metal_encoder_dispatch_threadgroups(enc, args.n_tt, args.n_wt, 1, 32, nsg, 1);
+
+    char what[64];
+    snprintf(what, sizeof(what), "NAXA %d%s", mode, ah ? "" : " (f32)");
+    pa_naxa_note(op, what);
+    return true;
+}
+
 size_t ggml_metal_op_mul_mat_id_extra_tpe(const ggml_tensor * op) {
     assert(op->op == GGML_OP_MUL_MAT_ID);
 
--- a/src/ggml-metal/ggml-metal.metal
+++ b/src/ggml-metal/ggml-metal.metal
@@ -12168,3 +12168,607 @@
         *(device float *) (dst + i0*args.nb_d0 + idst*args.nb_d1 + it*args.nb_d2) = result[idst];
     }
 }
+
+#if defined(GGML_METAL_PA_NAXA) && (defined(GGML_METAL_HAS_TENSOR) || defined(GGML_METAL_PA_NAX_EMU))
+
+//
+// PocketAgent, патч 12 (инженер A): умножение для матричных блоков A19 — режимы GGML_METAL_NAX=3..6.
+//
+// Зачем ещё одно ядро. Ядро патча 7 (схема MLX qmm_t_nax) и штатное тензорное ядро на телефоне
+// идут на одной скорости (~3,3 трлн оп/с, ≈45 % пика блоков): оба разворачивают веса в общую
+// память группы с барьером на каждом шаге K и читают float-активации. По журналу v9 все три
+// формы умножения тянут активации из памяти на ~95–107 ГБ/с (1054 токена × K × 4 байта,
+// перечитанные для каждой плитки весов в 64 строки) — похоже на потолок памяти, а не блоков.
+// Здесь четыре варианта, выбор — GGML_METAL_NAX:
+//   3 — «прямой»: каждая SIMD-группа сама грузит фрагменты весов из памяти устройства и
+//       разворачивает их прямо в регистрах (q4_K/q4_0/q8_0 — своим кодом, остальные — через
+//       штатную развёртку), без общей памяти и без барьеров с памятью (как fp16-ядро MLX и
+//       W4A8 у Cider). Плитка группы 128 токенов × 128 весов, 16 групп по 32×32;
+//   4 — «два прохода»: веса слоя разворачиваются в half-буфер (одно простое ядро), затем то же
+//       прямое ядро на плотных half-весах. Проверка потолка без цены K-квантов;
+//   5 — «прямой», плитка 64 × 128, 4 группы по 32×64 (больше счёта на одну загрузку);
+//   6 — через общую память, но с двойным буфером весов и ОДНИМ барьером на шаг K=32,
+//       плитка 64 × 128, 4 группы по 32×64 — «починенная» схема патча 7.
+// Во всех: активации переводятся в half ОДИН раз на умножение отдельным ядром в буфер
+// (вдвое меньше байт на каждое перечитывание; GGML_METAL_NAXA_ACT=f32 — читать float, как раньше),
+// плитки обходятся полосами по GGML_METAL_NAXA_SWZ плиток весов (по умолчанию 8), чтобы
+// перечитывания попадали в кэш. Точность та же, что у патча 7: half × half → float.
+// Раскладка фрагмента 16×16 — как у MLX (steel/gemm/nax.h, MIT), та же, что в патче 7.
+//
+// GGML_METAL_PA_NAX_EMU — только для проверки на Мак-мини (M1, блоков нет): умножение 16×32×16
+// считается обычным кодом через общую память с той же раскладкой. На телефоне не включается.
+//
+
+constant bool FC_pa_naxa_ah [[function_constant(FC_PA_NAXA + 0)]];   // активации — half-буфер
+
+namespace pa_naxa {
+
+typedef vec<half,  8> frag_h;   // кусок 16x16: 32 нити x 8 значений
+typedef vec<float, 8> frag_f;
+
+// Нить lane владеет строками fm и fm+8, столбцами fn..fn+3 куска 16x16 (как у MLX).
+static inline short2 frag_coord(ushort lane) {
+    const short qid = lane >> 2;
+    const short fm  = ((qid & 4) | ((lane >> 1) & 3));
+    const short fn  = ((qid & 2) | (lane & 1)) * 4;
+    return short2(fn, fm);
+}
+
+#if defined(GGML_METAL_PA_NAX_EMU)
+// Эмуляция для M1: фрагменты (раскладка MLX) выкладываются в общую память этой SIMD-группы
+// (es — 1024 half = 2 КБ: A 16x16 и B 32x16 half, потом C 16x32 float на том же месте),
+// умножаются обычными simdgroup-матрицами 8x8 M1 и возвращаются в раскладку фрагментов.
+// Проверяет всё, кроме самого блока: индексы плиток, развёртку весов, края, запись.
+static inline void mma(thread frag_f & c0, thread frag_f & c1,
+                       thread const frag_h & a, thread const frag_h & b0, thread const frag_h & b1,
+                       ushort lane, threadgroup half * es) {
+    const short2 fc = frag_coord(lane);
+    FOR_UNROLL (short r = 0; r < 2; r++) {
+        FOR_UNROLL (short j = 0; j < 4; j++) {
+            const short row = fc.y + r * 8, col = fc.x + j;
+            es[row * 16 + col]              = a[r * 4 + j];
+            es[256 + row * 16 + col]        = b0[r * 4 + j];
+            es[256 + (16 + row) * 16 + col] = b1[r * 4 + j];
+        }
+    }
+    simdgroup_barrier(mem_flags::mem_threadgroup);
+
+    simdgroup_half8x8  ma[2][2];   // [m][k]
+    simdgroup_half8x8  mb[4][2];   // [n][k], загружены транспонированными: k x n
+    simdgroup_float8x8 mc[2][4];
+    FOR_UNROLL (short mi = 0; mi < 2; mi++) {
+        FOR_UNROLL (short ki = 0; ki < 2; ki++) {
+            simdgroup_load(ma[mi][ki], es, 16, ulong2(ki * 8, mi * 8));
+        }
+    }
+    FOR_UNROLL (short ni = 0; ni < 4; ni++) {
+        FOR_UNROLL (short ki = 0; ki < 2; ki++) {
+            simdgroup_load(mb[ni][ki], es + 256, 16, ulong2(ki * 8, ni * 8), true);
+        }
+    }
+    FOR_UNROLL (short mi = 0; mi < 2; mi++) {
+        FOR_UNROLL (short ni = 0; ni < 4; ni++) {
+            mc[mi][ni] = make_filled_simdgroup_matrix<float, 8>(0.0f);
+            FOR_UNROLL (short ki = 0; ki < 2; ki++) {
+                simdgroup_multiply_accumulate(mc[mi][ni], ma[mi][ki], mb[ni][ki], mc[mi][ni]);
+            }
+        }
+    }
+    simdgroup_barrier(mem_flags::mem_threadgroup);
+
+    threadgroup float * ec = (threadgroup float *) es;   // C [16][32]
+    FOR_UNROLL (short mi = 0; mi < 2; mi++) {
+        FOR_UNROLL (short ni = 0; ni < 4; ni++) {
+            simdgroup_store(mc[mi][ni], ec, 32, ulong2(ni * 8, mi * 8));
+        }
+    }
+    simdgroup_barrier(mem_flags::mem_threadgroup);
+    FOR_UNROLL (short r = 0; r < 2; r++) {
+        FOR_UNROLL (short j = 0; j < 4; j++) {
+            const short row = fc.y + r * 8, col = fc.x + j;
+            c0[r * 4 + j] += ec[row * 32 + col];
+            c1[r * 4 + j] += ec[row * 32 + 16 + col];
+        }
+    }
+    simdgroup_barrier(mem_flags::mem_threadgroup);
+}
+#define PA_NAXA_MMA(c0, c1, a, b0, b1) pa_naxa::mma(c0, c1, a, b0, b1, lane, pa_es)
+// float4 — чтобы место было выровнено под float-чтение C и simdgroup_store
+#define PA_NAXA_EMU_DECL(nsg) threadgroup float4 pa_emu_mem[(nsg) * 128]; threadgroup half * pa_es = (threadgroup half *) (pa_emu_mem + sgitg * 128);
+#else
+// C(16x32) += A(16x16) * B^T, B — два куска 16x16 в виде [строка весов][k]; блок считает half x half.
+static inline void mma(thread frag_f & c0, thread frag_f & c1,
+                       thread const frag_h & a, thread const frag_h & b0, thread const frag_h & b1) {
+    constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
+        16, 32, 16, false, true, true,
+        mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
+    mpp::tensor_ops::matmul2d<desc, execution_simdgroup> op;
+
+    auto ca = op.template get_left_input_cooperative_tensor<half, half, float>();
+    auto cb = op.template get_right_input_cooperative_tensor<half, half, float>();
+    auto cc = op.template get_destination_cooperative_tensor<decltype(ca), decltype(cb), float>();
+
+    FOR_UNROLL (short i = 0; i < 8; i++) {
+        ca[i]     = a[i];
+        cb[i]     = b0[i];
+        cb[8 + i] = b1[i];
+        cc[i]     = c0[i];
+        cc[8 + i] = c1[i];
+    }
+
+    op.run(ca, cb, cc);
+
+    FOR_UNROLL (short i = 0; i < 8; i++) {
+        c0[i] = cc[i];
+        c1[i] = cc[8 + i];
+    }
+}
+#define PA_NAXA_MMA(c0, c1, a, b0, b1) pa_naxa::mma(c0, c1, a, b0, b1)
+#define PA_NAXA_EMU_DECL(nsg)
+#endif
+
+// Какую плитку считает группа: полосами по swz плиток весов — все плитки токенов проходят
+// полосу, пока её веса лежат в кэше, и активации перечитываются на полосу, а не на плитку.
+static inline int2 tile_of(constant ggml_metal_kargs_pa_naxa & args, uint3 tgpig) {
+    int tt = tgpig.x;
+    int wt = tgpig.y;
+    if (args.swz > 1 && args.n_wt > 1) {
+        const int lin     = (int) tgpig.y * args.n_tt + (int) tgpig.x;
+        const int band_sz = args.swz * args.n_tt;
+        const int band    = lin / band_sz;
+        const int r       = lin - band * band_sz;
+        const int wib     = min(args.swz, args.n_wt - band * args.swz);
+        wt = band * args.swz + r % wib;
+        tt = r / wib;
+    }
+    return int2(tt, wt);
+}
+
+// Активации: 4+4 значения строки (k и k+16) в half; буфер half или исходные float.
+static inline void load_x(device const char * row, int k, thread half4 & v0, thread half4 & v1) {
+    if (FC_pa_naxa_ah) {
+        device const half * p = (device const half *) row + k;
+        v0 = *((device const half4 *) p);
+        v1 = *((device const half4 *) (p + 16));
+    } else {
+        device const float * p = (device const float *) row + k;
+        v0 = half4(*((device const float4 *) p));
+        v1 = half4(*((device const float4 *) (p + 16)));
+    }
+}
+
+// Загрузчики весов для прямых ядер: строка row, проход K = k0..k0+31 (k0 кратно 32),
+// нить берёт k0+o..+3 (v0) и k0+16+o..+3 (v1), o = fc.x ∈ {0,4,8,12}. Арифметика — та же,
+// что у штатных dequantize_*, чтобы веса выходили те же, что у старых ядер.
+struct wl_f16 {
+    static inline void load(device const char * row, int k0, short o, thread half4 & v0, thread half4 & v1) {
+        device const half * p = (device const half *) row + k0 + o;
+        v0 = *((device const half4 *) p);
+        v1 = *((device const half4 *) (p + 16));
+    }
+};
+
+struct wl_q4_0 {
+    static inline void load(device const char * row, int k0, short o, thread half4 & v0, thread half4 & v1) {
+        device const block_q4_0 * xb = (device const block_q4_0 *) row + k0 / 32;
+        dequantize_q4_0_t4(xb, (short) (o / 4), v0);
+        dequantize_q4_0_t4(xb, (short) (4 + o / 4), v1);
+    }
+};
+
+struct wl_q8_0 {
+    static inline void load(device const char * row, int k0, short o, thread half4 & v0, thread half4 & v1) {
+        device const block_q8_0 * xb = (device const block_q8_0 *) row + k0 / 32;
+        dequantize_q8_0_t4(xb, (short) (o / 4), v0);
+        dequantize_q8_0_t4(xb, (short) (4 + o / 4), v1);
+    }
+};
+
+// q4_K: 32 значения прохода лежат в одном подблоке — масштаб распаковывается один раз.
+struct wl_q4_K {
+    static inline void load(device const char * row, int k0, short o, thread half4 & v0, thread half4 & v1) {
+        device const block_q4_K * xb = (device const block_q4_K *) row + k0 / QK_K;
+        const short kk = k0 % QK_K;
+        const short j  = kk / 64;          // пара подблоков
+        const short hi = (kk / 32) & 1;    // младшие или старшие полубайты
+        const uchar2 sc = get_scale_min_k4_just2(2 * j, hi, xb->scales);
+        const float d   = hi ? xb->d / 16.h : xb->d;
+        const float dl  = d * sc[0];
+        const float ml  = (float) xb->dmin * sc[1];
+        const uint mask = hi ? 0xF0 : 0x0F;
+        device const uchar * q = xb->qs + 32 * j + o;
+        const uint q0 = *((device const uint *) q);
+        const uint q1 = *((device const uint *) (q + 16));
+        FOR_UNROLL (short i = 0; i < 4; i++) {
+            v0[i] = dl * ((q0 >> (8 * i)) & mask) - ml;
+            v1[i] = dl * ((q1 >> (8 * i)) & mask) - ml;
+        }
+    }
+};
+
+// Прочие типы (q5_K, q6_K) — через штатную развёртку куска 16: берётся 4 из 16 (дороже,
+// но у рисующей части таких умножений единицы).
+template<typename block_q, short nl, void (*dequantize_func)(device const block_q *, short, thread half4x4 &)>
+struct wl_gen {
+    static inline half4 pick(thread const half4x4 & t, short o) {
+        half4 v = t[0];
+        if (o == 4)  v = t[1];
+        if (o == 8)  v = t[2];
+        if (o == 12) v = t[3];
+        return v;
+    }
+    static inline void load(device const char * row, int k0, short o, thread half4 & v0, thread half4 & v1) {
+        device const block_q * xb = (device const block_q *) row;
+        half4x4 t;
+        const int c0 = k0 / 16;
+        dequantize_func(xb + c0 / nl, (short) (c0 % nl), t);
+        v0 = pick(t, o);
+        const int c1 = c0 + 1;
+        dequantize_func(xb + c1 / nl, (short) (c1 % nl), t);
+        v1 = pick(t, o);
+    }
+};
+
+} // namespace pa_naxa
+
+// Перевод активаций float → half один раз на умножение: [N][K] с шагом nb11 → подряд [N][K].
+kernel void kernel_pa_naxa_cvt(
+        constant ggml_metal_kargs_pa_naxa & args,
+        device const char * src,
+        device       char * dst,
+        uint3  tgpig [[threadgroup_position_in_grid]],
+        ushort tiitg [[thread_index_in_threadgroup]],
+        ushort3 ntg  [[threads_per_threadgroup]]) {
+    const int row = tgpig.x;
+    device const float4 * s = (device const float4 *) (src + (uint64_t) row * args.nb11);
+    device       half4  * d = (device       half4  *) (dst + (uint64_t) row * args.ne00 * sizeof(half));
+    for (int i = tiitg; i < args.ne00 / 4; i += ntg.x) {
+        d[i] = half4(s[i]);
+    }
+}
+
+// Режим 4, первый проход: веса [M][K] → half [M][K] той же штатной развёрткой.
+template<typename block_q, short nl, void (*dequantize_func)(device const block_q *, short, thread half4x4 &)>
+kernel void kernel_pa_naxa_deq(
+        constant ggml_metal_kargs_pa_naxa & args,
+        device const char * src,
+        device       char * dst,
+        uint3  tgpig [[threadgroup_position_in_grid]],
+        ushort tiitg [[thread_index_in_threadgroup]],
+        ushort3 ntg  [[threads_per_threadgroup]]) {
+    const int row = tgpig.x;
+    device const block_q * xb = (device const block_q *) (src + (uint64_t) row * args.nb01);
+    device half4 * d = (device half4 *) (dst + (uint64_t) row * args.ne00 * sizeof(half));
+    for (int c = tiitg; c < args.ne00 / 16; c += ntg.x) {
+        half4x4 t;
+        dequantize_func(xb + c / nl, (short) (c % nl), t);
+        d[4 * c + 0] = t[0];
+        d[4 * c + 1] = t[1];
+        d[4 * c + 2] = t[2];
+        d[4 * c + 3] = t[3];
+    }
+}
+
+// Выход: фрагменты D → dst[токен][строка весов], float; по четыре подряд, где можно.
+template<short TT, short TW>
+static inline void pa_naxa_store(constant ggml_metal_kargs_pa_naxa & args, device char * dst,
+                                 thread pa_naxa::frag_f (&D)[TT][TW], int t, int w, short n_t, short n_w, short2 fc) {
+    const int M = args.ne0;
+    device float * dp = (device float *) dst + (int64_t) t * M + w;
+    FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+        FOR_UNROLL (short tw = 0; tw < TW; tw++) {
+            FOR_UNROLL (short r = 0; r < 2; r++) {
+                const short row = tt * 16 + fc.y + r * 8;
+                const short col = tw * 16 + fc.x;
+                if (row < n_t) {
+                    device float * p = dp + (int64_t) row * M + col;
+                    if (col + 4 <= n_w && (M % 4) == 0) {
+                        *((device float4 *) p) = float4(D[tt][tw][r * 4 + 0], D[tt][tw][r * 4 + 1],
+                                                        D[tt][tw][r * 4 + 2], D[tt][tw][r * 4 + 3]);
+                    } else {
+                        FOR_UNROLL (short j = 0; j < 4; j++) {
+                            if (col + j < n_w) {
+                                p[j] = D[tt][tw][r * 4 + j];
+                            }
+                        }
+                    }
+                }
+            }
+        }
+    }
+}
+
+// Режимы 3, 4, 5: прямое ядро — фрагменты весов и активаций грузит каждая SIMD-группа сама,
+// из памяти устройства в регистры; общей памяти и барьеров с памятью нет. Барьер mem_none раз
+// в 256 K — только чтобы группы шли по K вместе и делили кэш (как gemm_nax у MLX).
+template<typename WL, short BT, short BW, short WT, short WW>
+[[kernel, max_total_threads_per_threadgroup(WT * WW * 32)]]
+void kernel_mul_mm_naxd(
+        constant ggml_metal_kargs_pa_naxa & args,
+        device const char * srcW,
+        device const char * srcX,
+        device       char * dst,
+        uint3  tgpig [[threadgroup_position_in_grid]],
+        ushort sgitg [[simdgroup_index_in_threadgroup]],
+        ushort lane  [[thread_index_in_simdgroup]]) {
+    using namespace pa_naxa;
+
+    constexpr short ST = BT / WT;   // подплитка SIMD-группы: токены
+    constexpr short SW = BW / WW;   //                        строки весов
+    constexpr short TT = ST / 16;
+    constexpr short TW = SW / 16;
+    constexpr int   BKG = 256;
+    static_assert(TW % 2 == 0, "подплитка по весам должна быть кратна 32");
+
+    PA_NAXA_EMU_DECL(WT * WW)
+
+    const int K = args.ne00;
+    const int M = args.ne0;
+    const int N = args.ne1;
+
+    const int2 tile = tile_of(args, tgpig);
+    const int t_sg = tile.x * BT + ST * (sgitg / WW);
+    const int w_sg = tile.y * BW + SW * (sgitg % WW);
+
+    const short n_t = (short) clamp(N - t_sg, 0, (int) ST);
+    const short n_w = (short) clamp(M - w_sg, 0, (int) SW);
+    const bool active = n_t > 0 && n_w > 0;
+
+    const short2 fc = frag_coord(lane);
+
+    // Строки за краем не читаем мимо: берём последнюю живую, результат по ним не пишется.
+    device const char * xr[TT][2];
+    device const char * wr[TW][2];
+    FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+        FOR_UNROLL (short r = 0; r < 2; r++) {
+            const int row = min((int) (tt * 16 + fc.y + r * 8), max((int) n_t - 1, 0));
+            xr[tt][r] = srcX + (uint64_t) (t_sg + row) * args.nb11;
+        }
+    }
+    FOR_UNROLL (short tw = 0; tw < TW; tw++) {
+        FOR_UNROLL (short r = 0; r < 2; r++) {
+            const int row = min((int) (tw * 16 + fc.y + r * 8), max((int) n_w - 1, 0));
+            wr[tw][r] = srcW + (uint64_t) (w_sg + row) * args.nb01;
+        }
+    }
+
+    frag_f D[TT][TW];
+    FOR_UNROLL (short i = 0; i < TT; i++) {
+        FOR_UNROLL (short j = 0; j < TW; j++) {
+            D[i][j] = frag_f(0.0f);
+        }
+    }
+
+    _Pragma("clang loop unroll(disable)")
+    for (int kb = 0; kb < K; kb += BKG) {
+        threadgroup_barrier(mem_flags::mem_none);
+        if (active) {
+            const int ke = min(K, kb + BKG);
+            _Pragma("clang loop unroll(disable)")
+            for (int k0 = kb; k0 < ke; k0 += 32) {
+                // как у MLX (gemm_nax.h) и Cider: не даёт компилятору поднять загрузки всех
+                // шагов над всеми run и вылить регистры в память
+                volatile int compiler_barrier;
+
+                frag_h A[TT][2];
+                frag_h B[TW][2];
+
+                FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+                    FOR_UNROLL (short r = 0; r < 2; r++) {
+                        half4 v0, v1;
+                        load_x(xr[tt][r], k0 + fc.x, v0, v1);
+                        FOR_UNROLL (short j = 0; j < 4; j++) {
+                            A[tt][0][r * 4 + j] = v0[j];
+                            A[tt][1][r * 4 + j] = v1[j];
+                        }
+                    }
+                }
+                FOR_UNROLL (short tw = 0; tw < TW; tw++) {
+                    FOR_UNROLL (short r = 0; r < 2; r++) {
+                        half4 v0, v1;
+                        WL::load(wr[tw][r], k0, fc.x, v0, v1);
+                        FOR_UNROLL (short j = 0; j < 4; j++) {
+                            B[tw][0][r * 4 + j] = v0[j];
+                            B[tw][1][r * 4 + j] = v1[j];
+                        }
+                    }
+                }
+                FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+                    FOR_UNROLL (short tw = 0; tw < TW; tw += 2) {
+                        FOR_UNROLL (short tk = 0; tk < 2; tk++) {
+                            PA_NAXA_MMA(D[tt][tw], D[tt][tw + 1], A[tt][tk], B[tw][tk], B[tw + 1][tk]);
+                        }
+                    }
+                }
+
+                (void) compiler_barrier;
+            }
+        }
+    }
+
+    if (active) {
+        pa_naxa_store<TT, TW>(args, dst, D, t_sg, w_sg, n_t, n_w, fc);
+    }
+}
+
+// Режим 6: разворот BW x 32 весов шага k0 в плитку ws ([BW][BKP] half).
+template<typename block_q, short nl, void (*dequantize_func)(device const block_q *, short, thread half4x4 &),
+         short BW, short BKP, int NTH>
+static inline void pa_naxs_load_w(threadgroup half * ws, device const char * srcW, uint64_t nb01,
+                                  int w0, int M, int k0, ushort tiitg) {
+    constexpr int ITEMS = BW * 2;   // куски по 16 значений: 2 на строку за шаг 32
+    for (int work = tiitg; work < ITEMS; work += NTH) {
+        const short row = work / 2;
+        const short kc  = work % 2;
+        const int   kp  = k0 + kc * 16;
+        half4x4 tmp;
+        if (w0 + row < M) {
+            device const block_q * rp = (device const block_q *) (srcW + (uint64_t) (w0 + row) * nb01);
+            dequantize_func(rp + kp / (16 * nl), (short) ((kp / 16) % nl), tmp);
+        } else {
+            tmp = half4x4(0.0h);
+        }
+        threadgroup half4 * d4 = (threadgroup half4 *) (ws + row * BKP + kc * 16);
+        d4[0] = tmp[0];
+        d4[1] = tmp[1];
+        d4[2] = tmp[2];
+        d4[3] = tmp[3];
+    }
+}
+
+// Режим 6: веса через общую память, но с двойным буфером и одним барьером на шаг K=32:
+// пока SIMD-группы умножают плитку шага k, нити уже разворачивают плитку шага k+1 в другой буфер.
+template<typename block_q, short nl, void (*dequantize_func)(device const block_q *, short, thread half4x4 &),
+         short BT, short BW, short WT, short WW>
+[[kernel, max_total_threads_per_threadgroup(WT * WW * 32)]]
+void kernel_mul_mm_naxs(
+        constant ggml_metal_kargs_pa_naxa & args,
+        device const char * srcW,
+        device const char * srcX,
+        device       char * dst,
+        threadgroup  char * shmem [[threadgroup(0)]],
+        uint3  tgpig [[threadgroup_position_in_grid]],
+        ushort tiitg [[thread_index_in_threadgroup]],
+        ushort sgitg [[simdgroup_index_in_threadgroup]],
+        ushort lane  [[thread_index_in_simdgroup]]) {
+    using namespace pa_naxa;
+
+    constexpr short BK  = 32;
+    constexpr short BKP = BK + 8;        // строка плитки весов со сдвигом против конфликтов банков
+    constexpr short ST  = BT / WT;
+    constexpr short SW  = BW / WW;
+    constexpr short TT  = ST / 16;
+    constexpr short TW  = SW / 16;
+    constexpr int   NTH = WT * WW * 32;
+    constexpr int   W_TILE  = BW * BKP;
+    static_assert(TW % 2 == 0, "подплитка по весам должна быть кратна 32");
+
+    PA_NAXA_EMU_DECL(WT * WW)
+
+    const int K = args.ne00;
+    const int M = args.ne0;
+    const int N = args.ne1;
+
+    const int2 tile = tile_of(args, tgpig);
+    const int t0 = tile.x * BT;
+    const int w0 = tile.y * BW;
+    const short sg_t = ST * (sgitg / WW);
+    const short sg_w = SW * (sgitg % WW);
+    const short n_t = (short) clamp(N - (t0 + sg_t), 0, (int) ST);
+    const short n_w = (short) clamp(M - (w0 + sg_w), 0, (int) SW);
+    const bool active = n_t > 0 && n_w > 0;
+
+    threadgroup half * ws = (threadgroup half *) shmem;   // [2][BW][BKP]
+
+    const short2 fc = frag_coord(lane);
+
+    device const char * xr[TT][2];
+    FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+        FOR_UNROLL (short r = 0; r < 2; r++) {
+            const int row = min((int) (tt * 16 + fc.y + r * 8), max((int) n_t - 1, 0));
+            xr[tt][r] = srcX + (uint64_t) (t0 + sg_t + row) * args.nb11;
+        }
+    }
+
+    frag_f D[TT][TW];
+    FOR_UNROLL (short i = 0; i < TT; i++) {
+        FOR_UNROLL (short j = 0; j < TW; j++) {
+            D[i][j] = frag_f(0.0f);
+        }
+    }
+
+    pa_naxs_load_w<block_q, nl, dequantize_func, BW, BKP, NTH>(ws, srcW, args.nb01, w0, M, 0, tiitg);
+    threadgroup_barrier(mem_flags::mem_threadgroup);
+
+    short cur = 0;
+    for (int k0 = 0; k0 < K; k0 += BK, cur ^= 1) {
+        // Следующая плитка — в другой буфер. Его последним читали на прошлом шаге, а тот
+        // закончился барьером: писать безопасно, второго барьера не нужно.
+        if (k0 + BK < K) {
+            pa_naxs_load_w<block_q, nl, dequantize_func, BW, BKP, NTH>(ws + (cur ^ 1) * W_TILE, srcW, args.nb01,
+                                                                      w0, M, k0 + BK, tiitg);
+        }
+
+        if (active) {
+            threadgroup const half * wc = ws + cur * W_TILE;
+            frag_h A[TT][2];
+            frag_h B[TW][2];
+            FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+                FOR_UNROLL (short r = 0; r < 2; r++) {
+                    half4 v0, v1;
+                    load_x(xr[tt][r], k0 + fc.x, v0, v1);
+                    FOR_UNROLL (short j = 0; j < 4; j++) {
+                        A[tt][0][r * 4 + j] = v0[j];
+                        A[tt][1][r * 4 + j] = v1[j];
+                    }
+                }
+            }
+            FOR_UNROLL (short tw = 0; tw < TW; tw++) {
+                FOR_UNROLL (short r = 0; r < 2; r++) {
+                    threadgroup const half * p = wc + (sg_w + tw * 16 + fc.y + r * 8) * BKP + fc.x;
+                    const half4 v0 = *((threadgroup const half4 *) p);
+                    const half4 v1 = *((threadgroup const half4 *) (p + 16));
+                    FOR_UNROLL (short j = 0; j < 4; j++) {
+                        B[tw][0][r * 4 + j] = v0[j];
+                        B[tw][1][r * 4 + j] = v1[j];
+                    }
+                }
+            }
+            FOR_UNROLL (short tt = 0; tt < TT; tt++) {
+                FOR_UNROLL (short tw = 0; tw < TW; tw += 2) {
+                    FOR_UNROLL (short tk = 0; tk < 2; tk++) {
+                        PA_NAXA_MMA(D[tt][tw], D[tt][tw + 1], A[tt][tk], B[tw][tk], B[tw + 1][tk]);
+                    }
+                }
+            }
+        }
+
+        threadgroup_barrier(mem_flags::mem_threadgroup);
+    }
+
+    if (active) {
+        pa_naxa_store<TT, TW>(args, dst, D, t0 + sg_t, w0 + sg_w, n_t, n_w, fc);
+    }
+}
+
+// Имена: kernel_mul_mm_naxa<режим>_<тип> (режим 4 берёт kernel_mul_mm_naxa3_f16),
+// kernel_pa_naxa_deq_<тип> (первый проход режима 4), kernel_pa_naxa_cvt.
+#define PA_NAXD_INST(cfg, tname, WL, BT, BW, WT, WW) \
+template [[host_name("kernel_mul_mm_naxa" #cfg "_" #tname)]] [[kernel]] \
+decltype(kernel_mul_mm_naxd<WL, BT, BW, WT, WW>) kernel_mul_mm_naxd<WL, BT, BW, WT, WW>;
+
+#define PA_NAXS_INST(cfg, tname, bq, nl, dq, BT, BW, WT, WW) \
+template [[host_name("kernel_mul_mm_naxa" #cfg "_" #tname)]] [[kernel]] \
+decltype(kernel_mul_mm_naxs<bq, nl, dq, BT, BW, WT, WW>) kernel_mul_mm_naxs<bq, nl, dq, BT, BW, WT, WW>;
+
+#define PA_NAXA_DEQ_INST(tname, bq, nl, dq) \
+template [[host_name("kernel_pa_naxa_deq_" #tname)]] [[kernel]] \
+decltype(kernel_pa_naxa_deq<bq, nl, dq>) kernel_pa_naxa_deq<bq, nl, dq>;
+
+typedef pa_naxa::wl_gen<block_q5_K, QK_NL, dequantize_q5_K> pa_naxa_wl_q5_K;
+typedef pa_naxa::wl_gen<block_q6_K, QK_NL, dequantize_q6_K> pa_naxa_wl_q6_K;
+
+// cfg 3: прямое, 128 токенов x 128 весов, 16 групп по 32x32
+// cfg 5: прямое,  64 x 128, 4 группы по 32x64
+// cfg 6: общая память с двойным буфером, 64 x 128, 4 группы по 32x64
+#define PA_NAXA_INST_TYPE(tname, bq, nl, dq, WL) \
+    PA_NAXD_INST(3, tname, WL, 128, 128, 4, 4) \
+    PA_NAXD_INST(5, tname, WL,  64, 128, 2, 2) \
+    PA_NAXS_INST(6, tname, bq, nl, dq, 64, 128, 2, 2) \
+    PA_NAXA_DEQ_INST(tname, bq, nl, dq)
+
+PA_NAXA_INST_TYPE(f16,  half4x4,    1,     dequantize_f16,  pa_naxa::wl_f16)
+PA_NAXA_INST_TYPE(q4_0, block_q4_0, 2,     dequantize_q4_0, pa_naxa::wl_q4_0)
+PA_NAXA_INST_TYPE(q8_0, block_q8_0, 2,     dequantize_q8_0, pa_naxa::wl_q8_0)
+PA_NAXA_INST_TYPE(q4_K, block_q4_K, QK_NL, dequantize_q4_K, pa_naxa::wl_q4_K)
+PA_NAXA_INST_TYPE(q5_K, block_q5_K, QK_NL, dequantize_q5_K, pa_naxa_wl_q5_K)
+PA_NAXA_INST_TYPE(q6_K, block_q6_K, QK_NL, dequantize_q6_K, pa_naxa_wl_q6_K)
+
+// Режим 4, второй проход — это kernel_mul_mm_naxa3_f16 (прямое ядро 128 x 128 на half-весах).
+
+#undef PA_NAXA_INST_TYPE
+#undef PA_NAXA_DEQ_INST
+#undef PA_NAXS_INST
+#undef PA_NAXD_INST
+
+#endif // GGML_METAL_PA_NAXA
PA_GGML_V12A_PATCH
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V12A_PATCH' \
    || { echo "❌ правка sd.cpp v12a (замер режимов 3–6) не легла — см. $log" >&2; return 1; }
--- a/src/pa_kernel_bench.cpp
+++ b/src/pa_kernel_bench.cpp
@@ -54,9 +54,18 @@
 int  ggml_metal_pa_get_nax(void);
 int  ggml_metal_pa_nax_compiled(void);
 void ggml_metal_pa_nax_stats(char * buf, size_t len, int reset);
+// патч 12 (инженер A): режимы 3..6
+void ggml_metal_pa_naxa_force(int mode);
+int  ggml_metal_pa_naxa_mode(void);
+void ggml_metal_pa_naxa_stats(char * buf, size_t len, int reset);
 }
 #endif
 
+// Патч 12 (инженер A): режимы ядра в замере — 0 старое, 1/2 MLX (патч 7), 3..6 NAXA.
+// Всего режимов до 8 (массивы ниже), PA_KERNEL_BENCH_MODES="0,1,3,5" — свой список,
+// PA_KERNEL_BENCH_TYPES="q4_K,q8_0" — только эти типы весов в замере скорости.
+#define PA_KB_MODES 8
+
 namespace {
 
 std::string g_pa_report;
@@ -92,6 +101,10 @@
         case 0: return "старое";
         case 1: return "MLX 64x64";
         case 2: return "MLX 128x128";
+        case 3: return "NAXA прямое 128";
+        case 4: return "NAXA 2 прохода";
+        case 5: return "NAXA прямое 64x128";
+        case 6: return "NAXA 2 буфера";
         default: return "?";
     }
 }
@@ -101,10 +114,30 @@
         case 0: return "old";
         case 1: return "nax64";
         case 2: return "nax128";
+        case 3: return "naxa3";
+        case 4: return "naxa4";
+        case 5: return "naxa5";
+        case 6: return "naxa6";
         default: return "m?";
     }
 }
 
+// Включить режим замера: 0..2 — патч 7 (NAXA выкл), 3..6 — NAXA (а если умножение ей не
+// подходит — MLX 64, как при GGML_METAL_NAX=3..6 в приложении).
+void set_mode(int mode) {
+#if defined(__APPLE__)
+    if (mode >= 3) {
+        ggml_metal_pa_set_nax(1);
+        ggml_metal_pa_naxa_force(mode);
+    } else {
+        ggml_metal_pa_set_nax(mode);
+        ggml_metal_pa_naxa_force(0);
+    }
+#else
+    (void) mode;
+#endif
+}
+
 // Какое ядро реально взяли за прогон — по счёту ggml-metal (сброс перед прогоном).
 std::string kernel_taken() {
 #if defined(__APPLE__)
@@ -112,12 +145,23 @@
     ggml_metal_pa_nax_stats(buf, sizeof(buf), 1);
     const char* tail = strstr(buf, "умножений:");
     const std::string s = tail ? tail : buf;
+    char bufa[2048];
+    ggml_metal_pa_naxa_stats(bufa, sizeof(bufa), 1);
+    const char* taila = strstr(bufa, "умножений:");
+    const std::string sa = taila ? taila : bufa;
     const bool k128 = s.find("MLX 128") != std::string::npos;
     const bool k64  = s.find("MLX 64") != std::string::npos;
     const bool kold = s.find("старое") != std::string::npos;
-    const int n = (int) k128 + (int) k64 + (int) kold;
+    int n = (int) k128 + (int) k64 + (int) kold;
+    int ka = 0;
+    for (int m = 3; m <= 6; m++) {
+        char pat[32];
+        snprintf(pat, sizeof(pat), "NAXA %d", m);
+        if (sa.find(pat) != std::string::npos) { ka = m; n++; }
+    }
     if (n == 0) return "none";
     if (n > 1) return "mix";
+    if (ka) return std::string("naxa") + std::to_string(ka);
     return k128 ? "nax128" : (k64 ? "nax64" : "old");
 #else
     return "none";
@@ -299,6 +343,31 @@
         modes.push_back(1);
         modes.push_back(2);
     }
+    // Патч 12: режимы NAXA — там же, где есть матричные блоки (и на M1 с эмуляцией).
+    const bool naxa_emu = getenv("GGML_METAL_PA_NAX_EMU") != nullptr;
+    if (compiled_at_start != 0 || naxa_emu) {
+        for (int m = 3; m <= 6; m++) modes.push_back(m);
+    }
+    if (const char* ml = getenv("PA_KERNEL_BENCH_MODES")) {
+        std::vector<int> want;
+        for (const char* p = ml; *p;) {
+            char* end = nullptr;
+            const long v = strtol(p, &end, 10);
+            if (end == p) { p++; continue; }
+            if (v >= 0 && v < PA_KB_MODES && std::find(want.begin(), want.end(), (int) v) == want.end()) want.push_back((int) v);
+            p = end;
+        }
+        // старое (0) — всегда первым: от него считаются «×» и допуск точности
+        want.erase(std::remove(want.begin(), want.end(), 0), want.end());
+        want.insert(want.begin(), 0);
+        modes = want;
+    }
+    const char* type_filter = getenv("PA_KERNEL_BENCH_TYPES");
+    auto type_wanted = [&](ggml_type t) {
+        if (!type_filter || !type_filter[0]) return true;
+        const std::string f = std::string(",") + type_filter + ",";
+        return f.find(std::string(",") + ggml_type_name(t) + ",") != std::string::npos;
+    };
 
     std::string head, body, summary;
     appendf(head, "Проверка ядра умножения (ROADMAP §24), видеочип %s\n", ggml_backend_dev_description(dev));
@@ -312,7 +381,8 @@
     bool any_error = false;
     // Сбой видеочипа переводит контекст в «ошибку» до пересоздания: пересоздаём, а режим,
     // на котором упало, дальше не гоняем — иначе каждый следующий прогон тоже «упадёт».
-    bool mode_dead[3] = { false, false, false };
+    bool mode_dead[PA_KB_MODES] = {};
+    bool mode_bad[PA_KB_MODES]  = {};  // патч 12: какой режим посчитал неверно
     auto gpu_failed = [&](int mode) {
         any_error       = true;
         mode_dead[mode] = true;
@@ -361,7 +431,7 @@
             for (int mode : modes) {
                 if (!be) break;
                 if (mode_dead[mode]) { appendf(body, " · %s пропущено", mode_name(mode)); continue; }
-                ggml_metal_pa_set_nax(mode);
+                set_mode(mode);
                 kernel_taken();  // сброс счёта
                 std::vector<float> out((size_t) M * N, NAN);
                 if (ggml_backend_graph_compute(be, pc.gf[0]) != GGML_STATUS_SUCCESS) {
@@ -383,7 +453,7 @@
                 if (mode == 0) err_old = rel;
                 // Годно, если не хуже штатного втрое и в пределах половинной точности.
                 const bool ok = !bad && (mode == 0 || rel <= std::max(3.0 * err_old, 0.02));
-                if (!ok && mode != 0) any_fail = true;
+                if (!ok && mode != 0) { any_fail = true; mode_bad[mode] = true; }
                 if (bad) appendf(body, " · %s: НЕ ЧИСЛА", mode_name(mode));
                 else appendf(body, " · %s %.4f%s", mode_name(mode), rel, ok ? "" : " ОШИБКА");
                 appendf(kb, " %s_err=%.5f %s_ok=%d %s_k=%s", mode_key(mode), bad ? -1.0 : rel,
@@ -406,7 +476,7 @@
 
     appendf(body, "\nСкорость (лучший из 3 прогонов, мс; в скобках трлн операций/с), выход x вход x токены:\n");
     // время блока: [тип][N][режим]
-    struct BlockAcc { double ms[3] = {0, 0, 0}; bool ok[3] = {true, true, true}; int parts = 0; };
+    struct BlockAcc { double ms[PA_KB_MODES] = {}; bool ok[PA_KB_MODES] = {true, true, true, true, true, true, true, true}; int parts = 0; };
     std::vector<std::vector<BlockAcc>> block(sizeof(types) / sizeof(types[0]), std::vector<BlockAcc>(n_list.size()));
     double best_gain = 0;
     std::string best_gain_what;
@@ -448,7 +518,7 @@
                 if (acc) acc->ok[mode] = false;
                 continue;
             }
-            ggml_metal_pa_set_nax(mode);
+            set_mode(mode);
             kernel_taken();  // сброс счёта
             const double t = run_timed(be, pc.gf[ni], 3);
             if (t < 0) {
@@ -470,7 +540,7 @@
             const double rel = maxe / std::max(1e-12, mean_abs);
             if (mode == 0) { t_old = t; err_old = rel; }
             const bool ok = !bad && (mode == 0 || rel <= std::max(3.0 * err_old, 0.02));
-            if (!ok) any_fail = true;
+            if (!ok) { any_fail = true; mode_bad[mode] = true; }
             const double tf = flop / (t * 1e-3) / 1e12;
             appendf(body, " · %s %.2f (%.2f)%s", mode_name(mode), t, tf,
                     bad ? " НЕ ЧИСЛА" : (ok ? "" : " ОШИБКА"));
@@ -497,6 +567,7 @@
 
     for (size_t ti = 0; ti < sizeof(types) / sizeof(types[0]); ti++) {
         const ggml_type type = types[ti];
+        if (!type_wanted(type)) continue;
         for (const Sz& s : shapes) {
             if (!be) break;
             if (quick && !(ti == 0 && &s == &shapes[0])) break;
@@ -505,7 +576,7 @@
                 appendf(body, "  %-6s %s %dx%d: не выделилась память\n", s.op, ggml_type_name(type), s.M, s.K);
                 appendf(body, "KB op=%s type=%s M=%d K=%d alloc=fail\n", s.op, ggml_type_name(type), s.M, s.K);
                 any_error = true;
-                for (auto& acc : block[ti]) for (int m = 0; m < 3; m++) acc.ok[m] = false;
+                for (auto& acc : block[ti]) for (int m = 0; m < PA_KB_MODES; m++) acc.ok[m] = false;
                 continue;
             }
             mem_peak = std::max(mem_peak, ggml_backend_buffer_get_size(pc.buf));
@@ -561,8 +632,15 @@
                         else snprintf(p, sizeof(p), "—");
                         return std::string(p);
                     };
-                    snprintf(b, sizeof(b), "блок q4_K: старое %.0f мс, MLX 64 — %s, MLX 128 — %s",
-                             acc.ms[0], part(1).c_str(), part(2).c_str());
+                    // патч 12: и лучший из режимов NAXA (3..6), если они были в замере
+                    int best_a = 0;
+                    for (int m : modes) {
+                        if (m >= 3 && acc.ok[m] && acc.ms[m] > 0 && (best_a == 0 || acc.ms[m] < acc.ms[best_a])) best_a = m;
+                    }
+                    char pa[96] = "";
+                    if (best_a) snprintf(pa, sizeof(pa), ", лучший NAXA %d — %s", best_a, part(best_a).c_str());
+                    snprintf(b, sizeof(b), "блок q4_K: старое %.0f мс, MLX 64 — %s, MLX 128 — %s%s",
+                             acc.ms[0], part(1).c_str(), part(2).c_str(), pa);
                 } else {
                     snprintf(b, sizeof(b), "блок q4_K: старое %.0f мс", acc.ms[0]);
                 }
@@ -572,6 +650,7 @@
     }
 
     ggml_metal_pa_set_nax(-1);  // обратно к тому, что задаёт приложение (GGML_METAL_NAX)
+    ggml_metal_pa_naxa_force(-1);
     if (be) ggml_backend_free(be);
     ggml_log_set(nullptr, nullptr);
 
@@ -580,11 +659,19 @@
     appendf(head, "ядра MLX после замера: %s\n", compiled == 1 ? "собраны" : (compiled == 0 ? "НЕ собрались — считало старое" : "не понадобились"));
     appendf(head, "KBINFO compiled=%d mode_before=%d quick=%d seconds=%.1f buf_peak_mb=%.0f\n", compiled, mode_before,
             quick ? 1 : 0, (ggml_time_us() - t_start) / 1e6, mem_peak / 1048576.0);
-    if (any_fail) {
+    bool naxa_dead = false;
+    for (int m = 3; m < PA_KB_MODES; m++) naxa_dead = naxa_dead || mode_dead[m];
+    bool mlx_bad = mode_bad[1] || mode_bad[2];
+    int naxa_bad = 0;
+    for (int m = 3; m < PA_KB_MODES; m++) if (mode_bad[m] && !naxa_bad) naxa_bad = m;
+    if (any_fail && !mlx_bad && naxa_bad) {
+        summary = "Ядро NAXA (режим " + std::to_string(naxa_bad) + ") считает НЕВЕРНО — этот режим не включать";
+    } else if (any_fail) {
         summary = "Ядро MLX считает НЕВЕРНО — выключите «Ядро MLX»";
     } else if (any_error) {
         summary = mode_dead[1] || mode_dead[2] ? "Ядро MLX уронило видеочип — выключите «Ядро MLX»"
-                                               : "Сбой видеочипа при замере — см. журнал";
+                  : (naxa_dead ? "Ядро NAXA (режимы 3–6) уронило видеочип — см. журнал"
+                               : "Сбой видеочипа при замере — см. журнал");
     } else if (!summary_block.empty()) {
         summary = (compiled == 1 ? "Верно · " : "Ядро MLX не собрано · ") + summary_block;
     } else if (compiled != 1) {
@@ -608,6 +695,12 @@
     static char buf[4096];
 #if defined(__APPLE__)
     ggml_metal_pa_nax_stats(buf, sizeof(buf), reset);
+    // патч 12: и счёт режимов NAXA (3..6) — строкой ниже
+    const size_t used = strlen(buf);
+    if (used + 2 < sizeof(buf)) {
+        buf[used] = '\n';
+        ggml_metal_pa_naxa_stats(buf + used + 1, sizeof(buf) - used - 1, reset);
+    }
 #else
     (void) reset;
     snprintf(buf, sizeof(buf), "PA NAX: не Apple");
PA_SD_V12A_PATCH
  grep -q kernel_mul_mm_naxd "$src/ggml/src/ggml-metal/ggml-metal.metal" \
    && grep -q pa_naxa_encode "$src/ggml/src/ggml-metal/ggml-metal-ops.cpp" \
    && grep -q ggml_metal_device_get_library_naxa "$src/ggml/src/ggml-metal/ggml-metal-device.m" \
    && grep -q ggml_metal_kargs_pa_naxa "$src/ggml/src/ggml-metal/ggml-metal-impl.h" \
    && grep -q ggml_metal_pa_naxa_force "$src/src/pa_kernel_bench.cpp" \
    || { echo "❌ правка v12a (ядра NAXA) не на месте" >&2; return 1; }
  # <<< патч 12 (инженер A)
  # >>> патч 13 (инженер B)
  # 13) переупаковка весов q4_K «плитками» при загрузке + ядро режима 7 (в v10b — 4), описание — п.13 выше.
  #     Накладывается ПОСЛЕ п.12: правки в ggml-metal-ops.cpp и pa_kernel_bench.cpp сделаны поверх него.
  #     Новые файлы правки убираем заранее: checkout их не трогает, и повторное наложение упало бы.
  rm -f "$src/src/pa_repack.h" "$src/src/pa_kernel_bench_b.cpp"
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V13B_PATCH' \
    || { echo "❌ правка sd.cpp п.13 (переупаковка весов, режим 7) не легла — см. $log" >&2; return 1; }
diff --git a/src/model_loader.cpp b/src/model_loader.cpp
index 0d4f7a7..4c924c7 100644
--- a/src/model_loader.cpp
+++ b/src/model_loader.cpp
@@ -32,6 +32,54 @@
 #include "zip.h"
 
 #include "name_conversion.h"
+#include "pa_repack.h"
+
+// PocketAgent п.13: режим GGML_METAL_NAX=7 (до слияния с п.12 — 4) — веса слоёв рисующей части
+// q4_K переупаковываются при загрузке «плитками» (src/pa_repack.h, тип GGML_TYPE_PA_Q4_K_T) под ядро
+// умножения на матричных блоках, которое грузит веса прямо в регистры без общей памяти.
+// Ядро живёт в ggml-metal; слабая ссылка — чтобы сборка без Metal не ломалась.
+#if defined(__APPLE__)
+extern "C" int ggml_backend_metal_pa4_prepare(void) __attribute__((weak));
+#endif
+
+static bool pa4_mode_on() {
+    const char* e = std::getenv("GGML_METAL_NAX");
+    // 7, а не 4: режим 4 занят «двумя проходами» инженера A (п.12), режимы 3..6 — его ядра.
+    return e != nullptr && e[0] == '7' && e[1] == '\0';
+}
+
+// Можно ли ядру режима 7 доверять: собрано ли на этом устройстве. Спрашиваем один раз.
+static bool pa4_kernel_ready() {
+#if defined(__APPLE__)
+    static std::once_flag once;
+    static bool ready = false;
+    std::call_once(once, []() {
+        ready = ggml_backend_metal_pa4_prepare != nullptr && ggml_backend_metal_pa4_prepare() == 1;
+        LOG_INFO("PA NAX4: режим 7 — %s", ready ? "веса слоёв рисующей части переупаковываются под матричные блоки"
+                                                : "ядро недоступно (нет блоков или не собралось), веса как есть");
+    });
+    return ready;
+#else
+    return false;
+#endif
+}
+
+// Годится ли тензор под переупаковку: только веса линейных слоёв блоков (transformer_blocks.*.weight)
+// q4_K с K кратным 256 и строками кратными 16. Больше ничего — эти веса ни в какие операции,
+// кроме умножения, не идут, и штатные ядра их больше не увидят.
+static bool pa4_eligible(const TensorStorage& ts, const ggml_tensor* dst) {
+    if (ts.type != GGML_TYPE_Q4_K || (dst->type != GGML_TYPE_Q4_K && dst->type != GGML_TYPE_PA_Q4_K_T)) {
+        return false;
+    }
+    if (dst->ne[2] != 1 || dst->ne[3] != 1 || !pa4::shape_ok(dst->ne[0], dst->ne[1]) || !ggml_is_contiguous(dst)) {
+        return false;
+    }
+    const std::string& n = ts.name;
+    if (n.find("transformer_blocks.") == std::string::npos || n.size() < 7 || n.compare(n.size() - 7, 7, ".weight") != 0) {
+        return false;
+    }
+    return pa4_mode_on() && pa4_kernel_ready();
+}
 
 /*================================================= Preprocess ==================================================*/
 
@@ -1033,6 +1081,7 @@ bool ModelLoader::load_tensors(on_new_tensor_cb_t on_new_tensor_cb,
     std::atomic<int64_t> copy_to_backend_time_ms(0);
     std::atomic<int64_t> convert_time_ms(0);
     std::atomic<uint64_t> bytes_processed(0);
+    std::atomic<int> pa4_tensors(0);  // PocketAgent п.13: сколько тензоров переупаковано
 
     int num_threads_to_use = n_threads_;
 
@@ -1127,6 +1176,7 @@ bool ModelLoader::load_tensors(on_new_tensor_cb_t on_new_tensor_cb,
                 std::vector<uint8_t> read_buffer;
                 std::vector<uint8_t> convert_buffer;
                 std::vector<uint8_t> zip_entry_buffer;
+                std::vector<uint8_t> pa4_tmp;  // PocketAgent п.13: рабочий буфер переупаковки (16 строк)
 
                 while (true) {
                     int64_t t0, t1;
@@ -1168,6 +1218,16 @@ bool ModelLoader::load_tensors(on_new_tensor_cb_t on_new_tensor_cb,
                         continue;
                     }
 
+                    // PocketAgent п.13: режим 7 — тензор станет «плитками» (тот же размер, другой порядок
+                    // байтов). Режим выключили, а тензор с прошлой загрузки ещё помечен — вернуть q4_K.
+                    const bool pa4 = pa4_eligible(tensor_storage, dst_tensor);
+                    if (pa4) {
+                        dst_tensor->type = GGML_TYPE_PA_Q4_K_T;
+                    } else if (dst_tensor->type == GGML_TYPE_PA_Q4_K_T && tensor_storage.type == GGML_TYPE_Q4_K) {
+                        dst_tensor->type = GGML_TYPE_Q4_K;
+                    }
+                    const bool same_type = pa4 || tensor_storage.type == dst_tensor->type;
+
                     size_t nbytes_to_read = tensor_storage.nbytes_to_read();
 
                     auto read_data = [&](char* buf, size_t n) -> bool {
@@ -1230,7 +1290,7 @@ bool ModelLoader::load_tensors(on_new_tensor_cb_t on_new_tensor_cb,
                     char* target_buf  = nullptr;
                     char* convert_buf = nullptr;
                     if (dst_tensor->buffer == nullptr || ggml_backend_buffer_is_host(dst_tensor->buffer)) {
-                        if (tensor_storage.type == dst_tensor->type) {
+                        if (same_type) {
                             GGML_ASSERT(ggml_nbytes(dst_tensor) == tensor_storage.nbytes());
                             if (tensor_storage.is_f64 || tensor_storage.is_i64) {
                                 read_buffer.resize(tensor_storage.nbytes_to_read());
@@ -1250,7 +1310,7 @@ bool ModelLoader::load_tensors(on_new_tensor_cb_t on_new_tensor_cb,
                         read_buf   = (char*)read_buffer.data();
                         target_buf = read_buf;
 
-                        if (tensor_storage.type != dst_tensor->type) {
+                        if (!same_type) {
                             convert_buffer.resize(ggml_nbytes(dst_tensor));
                             convert_buf = (char*)convert_buffer.data();
                         }
@@ -1276,7 +1336,12 @@ bool ModelLoader::load_tensors(on_new_tensor_cb_t on_new_tensor_cb,
                         f8_e5m2_to_f16_vec((uint8_t*)read_buf, (uint16_t*)target_buf, tensor_storage.nelements());
 #endif
                     }
-                    if (tensor_storage.type != dst_tensor->type) {
+                    if (pa4) {
+                        // переупаковка на месте — там, куда только что прочли (память тензора или буфер чтения)
+                        pa4::repack_q4k((uint8_t*)target_buf, dst_tensor->ne[1], dst_tensor->ne[0], pa4_tmp);
+                        pa4_tensors.fetch_add(1);
+                    }
+                    if (!same_type) {
                         if (convert_buf == nullptr) {
                             LOG_ERROR("read tensor data failed: too less memory for conversion");
                             failed = true;
@@ -1370,6 +1435,10 @@ bool ModelLoader::load_tensors(on_new_tensor_cb_t on_new_tensor_cb,
                  (convert_time_ms.load() / (float)last_n_threads) / 1000.f,
                  (copy_to_backend_time_ms.load() / (float)last_n_threads) / 1000.f);
     }
+    if (pa4_tensors.load() > 0) {
+        // время переупаковки входит в «convert» строкой выше
+        LOG_INFO("PA NAX4: переупаковано тензоров: %d", pa4_tensors.load());
+    }
     return success && validate_sources(target_tensor_names);
 }
 
diff --git a/src/pa_kernel_bench.cpp b/src/pa_kernel_bench.cpp
index e164914..87ddb9a 100644
--- a/src/pa_kernel_bench.cpp
+++ b/src/pa_kernel_bench.cpp
@@ -58,14 +58,20 @@ void ggml_metal_pa_nax_stats(char * buf, size_t len, int reset);
 void ggml_metal_pa_naxa_force(int mode);
 int  ggml_metal_pa_naxa_mode(void);
 void ggml_metal_pa_naxa_stats(char * buf, size_t len, int reset);
+void ggml_metal_pa4_stats(char * buf, size_t len, int reset);  // PocketAgent п.13 (режим 7)
 }
 #endif
 
 // Патч 12 (инженер A): режимы ядра в замере — 0 старое, 1/2 MLX (патч 7), 3..6 NAXA.
 // Всего режимов до 8 (массивы ниже), PA_KERNEL_BENCH_MODES="0,1,3,5" — свой список,
 // PA_KERNEL_BENCH_TYPES="q4_K,q8_0" — только эти типы весов в замере скорости.
+// Режим 7 (п.13, переупаковка весов плитками) — отдельным разделом из src/pa_kernel_bench_b.cpp.
 #define PA_KB_MODES 8
 
+// PocketAgent п.13: раздел «Режим 7» (переупаковка весов плитками) — src/pa_kernel_bench_b.cpp
+std::string sd_pa4_bench_section(ggml_backend_t& be, ggml_backend_dev_t dev, const float* wpool, size_t nw,
+                                 const float* xpool, size_t nx, bool quick, std::string& body, bool& fail);
+
 namespace {
 
 std::string g_pa_report;
@@ -348,6 +354,9 @@ const char* sd_pa_kernel_bench(void) {
     if (compiled_at_start != 0 || naxa_emu) {
         for (int m = 3; m <= 6; m++) modes.push_back(m);
     }
+    // Режим 7 (п.13, переупакованные веса) считается своим разделом ниже, а не в общем цикле:
+    // по умолчанию — всегда, при своём списке PA_KERNEL_BENCH_MODES — только если в нём есть 7.
+    bool pa_run7 = true;
     if (const char* ml = getenv("PA_KERNEL_BENCH_MODES")) {
         std::vector<int> want;
         for (const char* p = ml; *p;) {
@@ -357,6 +366,8 @@ const char* sd_pa_kernel_bench(void) {
             if (v >= 0 && v < PA_KB_MODES && std::find(want.begin(), want.end(), (int) v) == want.end()) want.push_back((int) v);
             p = end;
         }
+        pa_run7 = std::find(want.begin(), want.end(), 7) != want.end();
+        want.erase(std::remove(want.begin(), want.end(), 7), want.end());
         // старое (0) — всегда первым: от него считаются «×» и допуск точности
         want.erase(std::remove(want.begin(), want.end(), 0), want.end());
         want.insert(want.begin(), 0);
@@ -649,6 +660,16 @@ const char* sd_pa_kernel_bench(void) {
         }
     }
 
+    // PocketAgent п.13: раздел «Режим 7» (переупаковка весов плитками, веса прямо в регистры).
+    // Режимы A (3..6) на время раздела выключены: иначе после цикла выше в силе остался бы
+    // последний режим A, и его крючок забрал бы умножения q4_K, с которыми раздел сравнивает
+    // (колонка «MLX 64» показала бы скорость NAXA — поймано на мини 25.09.2026).
+    ggml_metal_pa_naxa_force(0);
+    bool pa4_fail = false;
+    const std::string pa4_sum = (be && pa_run7) ? sd_pa4_bench_section(be, dev, pool.w.data(), pool.w.size(), pool.x.data(),
+                                                          pool.x.size(), quick, body, pa4_fail)
+                                   : std::string();
+
     ggml_metal_pa_set_nax(-1);  // обратно к тому, что задаёт приложение (GGML_METAL_NAX)
     ggml_metal_pa_naxa_force(-1);
     if (be) ggml_backend_free(be);
@@ -680,6 +701,7 @@ const char* sd_pa_kernel_bench(void) {
         summary = "Замер не дал чисел — см. журнал";
     }
 
+    if (!pa4_sum.empty()) summary += " · " + pa4_sum;  // PocketAgent п.13
     R = summary + "\n" + head + body;
     if (!best_gain_what.empty()) {
         appendf(R, "\nЛучше всего: ×%.2f (%s)\n", best_gain, best_gain_what.c_str());
@@ -695,6 +717,15 @@ const char* sd_pa_kernel_stats(int reset) {
     static char buf[4096];
 #if defined(__APPLE__)
     ggml_metal_pa_nax_stats(buf, sizeof(buf), reset);
+    {
+        // PocketAgent п.13: умножения режима 7 (переупакованные веса) — хвостом строки патча 7
+        char b4[1024];
+        ggml_metal_pa4_stats(b4, sizeof(b4), reset);
+        if (b4[0]) {
+            const size_t n = strlen(buf);
+            snprintf(buf + n, sizeof(buf) - n, " режим 7:%s", b4);
+        }
+    }
     // патч 12: и счёт режимов NAXA (3..6) — строкой ниже
     const size_t used = strlen(buf);
     if (used + 2 < sizeof(buf)) {
diff --git a/src/pa_kernel_bench_b.cpp b/src/pa_kernel_bench_b.cpp
new file mode 100644
index 0000000..a1eec8e
--- /dev/null
+++ b/src/pa_kernel_bench_b.cpp
@@ -0,0 +1,413 @@
+// PocketAgent п.13: раздел «Режим 7» в «Проверить ядро».
+//
+// Что меряет: умножения размеров Qwen-Image 2.1 (A 4096→4096, B 4096→12288, C 12288→4096, 1037 и
+// 1024 токена) на весах q4_K, переупакованных «плитками» (src/pa_repack.h), ядром режима 7 —
+// во всех пяти плитках (GGML_METAL_NAX7_TILE a/b/c/d/e), с float-активациями и, для плитки «b»
+// (по умолчанию), с half-активациями. Рядом, в том же тепловом окне, — ядро MLX 64 (режим 1) на тех же q4_K,
+// чтобы сравнение было честным. Блок = 4·A + 2·B + C, шаг = ×32.
+//
+// Точность: полное сравнение с эталоном на процессоре (float/double) на неровном случае
+// 208×512 × 100 токенов, и выборочное (256 точек) на больших. Эталон — из ИСХОДНЫХ байтов q4_K
+// до переупаковки, так что проверяется и переупаковка, и развёртка в ядре.
+//
+// Строки для разбора: «KB4ACC …», «KB4 …», «KB4BLOCK …» (ключ=значение). Итог — одна строка,
+// её основной отчёт дописывает к первой строке экрана.
+
+#include "ggml-alloc.h"
+#include "ggml-backend.h"
+#include "ggml.h"
+#include "pa_repack.h"
+
+#include <algorithm>
+#include <cmath>
+#include <cstdarg>
+#include <cstdio>
+#include <cstdlib>
+#include <cstring>
+#include <random>
+#include <string>
+#include <thread>
+#include <vector>
+
+#if defined(__APPLE__)
+extern "C" {
+void ggml_metal_pa_set_nax(int mode);
+int  ggml_backend_metal_pa4_prepare(void);
+void ggml_metal_pa4_stats(char* buf, size_t len, int reset);
+}
+#endif
+
+namespace {
+
+void b_appendf(std::string& s, const char* fmt, ...) {
+    char buf[1024];
+    va_list ap;
+    va_start(ap, fmt);
+    vsnprintf(buf, sizeof(buf), fmt, ap);
+    va_end(ap);
+    s += buf;
+}
+
+void b_quantize(const float* src, uint8_t* dst, int nrows, int K) {
+    const size_t row = ggml_row_size(GGML_TYPE_Q4_K, K);
+    int nt           = (int) std::thread::hardware_concurrency();
+    nt               = std::max(1, std::min(nt, 6));
+    if (nrows < 64) nt = 1;
+    std::vector<std::thread> th;
+    const int per = (nrows + nt - 1) / nt;
+    for (int t = 0; t < nt; t++) {
+        const int r0 = t * per, r1 = std::min(nrows, r0 + per);
+        if (r0 >= r1) break;
+        th.emplace_back([=]() {
+            ggml_quantize_chunk(GGML_TYPE_Q4_K, src + (size_t) r0 * K, dst + (size_t) r0 * row, 0, r1 - r0, K, nullptr);
+        });
+    }
+    for (auto& t : th) t.join();
+}
+
+// Одно умножение: веса [M x K] — в двух видах: q4_K (для режима 1) и переупакованные (режим 7),
+// активации float [Nmax x K] и их half-копия; графы на каждое N и вид.
+struct BCase {
+    ggml_context* ctx         = nullptr;
+    ggml_backend_buffer_t buf = nullptr;
+    ggml_tensor* wq           = nullptr;  // q4_K
+    ggml_tensor* wt           = nullptr;  // pa_q4_K_t
+    ggml_tensor* x            = nullptr;  // f32
+    ggml_tensor* xh           = nullptr;  // f16
+    std::vector<int> ns;
+    // [ni][0] — q4_K×f32, [ni][1] — плитки×f32, [ni][2] — плитки×f16
+    std::vector<std::vector<ggml_tensor*>> c;
+    std::vector<std::vector<ggml_cgraph*>> gf;
+    std::vector<uint8_t> host_q;  // исходные q4_K (эталон)
+    int M = 0, K = 0;
+
+    ~BCase() {
+        if (buf) ggml_backend_buffer_free(buf);
+        if (ctx) ggml_free(ctx);
+    }
+
+    bool init(ggml_backend_t be, int M_, int K_, const std::vector<int>& n_list, const float* wpool, size_t nw,
+              const float* xpool, size_t nx, bool keep_host) {
+        M = M_; K = K_; ns = n_list;
+        const int Nmax = *std::max_element(ns.begin(), ns.end());
+        if ((size_t) M * K > nw || (size_t) Nmax * K > nx) return false;
+        ggml_init_params ip = {};
+        ip.mem_size   = ggml_tensor_overhead() * (8 + 8 * ns.size()) + ggml_graph_overhead() * 3 * ns.size();
+        ip.no_alloc   = true;
+        ctx           = ggml_init(ip);
+        if (!ctx) return false;
+        wq = ggml_new_tensor_2d(ctx, GGML_TYPE_Q4_K, K, M);
+        wt = ggml_new_tensor_2d(ctx, GGML_TYPE_PA_Q4_K_T, K, M);
+        x  = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, Nmax);
+        xh = ggml_new_tensor_2d(ctx, GGML_TYPE_F16, K, Nmax);
+        for (int n : ns) {
+            ggml_tensor* xn  = n == Nmax ? x : ggml_view_2d(ctx, x, K, n, x->nb[1], 0);
+            ggml_tensor* xhn = n == Nmax ? xh : ggml_view_2d(ctx, xh, K, n, xh->nb[1], 0);
+            std::vector<ggml_tensor*> cc = { ggml_mul_mat(ctx, wq, xn), ggml_mul_mat(ctx, wt, xn), ggml_mul_mat(ctx, wt, xhn) };
+            std::vector<ggml_cgraph*> gg;
+            for (auto* t : cc) {
+                ggml_cgraph* g = ggml_new_graph(ctx);
+                ggml_build_forward_expand(g, t);
+                gg.push_back(g);
+            }
+            c.push_back(cc);
+            gf.push_back(gg);
+        }
+        buf = ggml_backend_alloc_ctx_tensors(ctx, be);
+        if (!buf) return false;
+
+        const size_t rowb = ggml_row_size(GGML_TYPE_Q4_K, K);
+        std::vector<uint8_t> q((size_t) M * rowb);
+        b_quantize(wpool, q.data(), M, K);
+        ggml_backend_tensor_set(wq, q.data(), 0, q.size());
+        if (keep_host) host_q = q;
+        std::vector<uint8_t> tmp;
+        pa4::repack_q4k(q.data(), M, K, tmp);
+        ggml_backend_tensor_set(wt, q.data(), 0, q.size());
+        ggml_backend_tensor_set(x, xpool, 0, (size_t) Nmax * K * sizeof(float));
+        std::vector<ggml_fp16_t> h((size_t) Nmax * K);
+        ggml_fp32_to_fp16_row(xpool, h.data(), (int64_t) h.size());
+        ggml_backend_tensor_set(xh, h.data(), 0, h.size() * sizeof(ggml_fp16_t));
+        return true;
+    }
+
+    void weight_row(int m, std::vector<float>& out) const {
+        const size_t rowb = ggml_row_size(GGML_TYPE_Q4_K, K);
+        std::vector<uint8_t> raw(rowb);
+        if (!host_q.empty()) {
+            memcpy(raw.data(), host_q.data() + (size_t) m * rowb, rowb);
+        } else {
+            ggml_backend_tensor_get(wq, raw.data(), (size_t) m * rowb, rowb);
+        }
+        out.resize(K);
+        ggml_get_type_traits(GGML_TYPE_Q4_K)->to_float(raw.data(), out.data(), K);
+    }
+};
+
+double b_run(ggml_backend_t be, ggml_cgraph* g, int reps) {
+    if (ggml_backend_graph_compute(be, g) != GGML_STATUS_SUCCESS) return -1.0;
+    ggml_backend_synchronize(be);
+    double best = 1e30;
+    for (int i = 0; i < reps; i++) {
+        const int64_t t0 = ggml_time_us();
+        if (ggml_backend_graph_compute(be, g) != GGML_STATUS_SUCCESS) return -1.0;
+        ggml_backend_synchronize(be);
+        best = std::min(best, (ggml_time_us() - t0) / 1000.0);
+    }
+    return best;
+}
+
+std::string b_stats() {
+#if defined(__APPLE__)
+    char buf[1024];
+    ggml_metal_pa4_stats(buf, sizeof(buf), 1);
+    return buf;
+#else
+    return "";
+#endif
+}
+
+struct Variant {
+    const char* key;   // для разбора
+    int graph;         // 0 — q4_K режим 1, 1 — плитки f32, 2 — плитки f16
+    char tile;
+};
+
+}  // namespace
+
+// Раздел «Режим 7». be — открытый бэкенд Metal. Пишет строки в body, возвращает короткий итог
+// для первой строки экрана («» — раздел не выполнялся). fail = true — ядро считает неверно/упало.
+std::string sd_pa4_bench_section(ggml_backend_t& be, ggml_backend_dev_t dev, const float* wpool, size_t nw,
+                                 const float* xpool, size_t nx, bool quick, std::string& body, bool& fail) {
+    fail = false;
+#if !defined(__APPLE__)
+    (void) be; (void) dev; (void) wpool; (void) nw; (void) xpool; (void) nx; (void) quick; (void) body;
+    return "";
+#else
+    if (!be) return "";
+    body += "\nРежим 7 (переупаковка весов плитками, веса прямо в регистры, ROADMAP §24.6):\n";
+    if (ggml_backend_metal_pa4_prepare() != 1) {
+        body += "  недоступен: нет матричных блоков или ядро не собралось — см. журнал\n";
+        body += "KB4INFO ready=0\n";
+        return "режим 7 недоступен";
+    }
+    body += "KB4INFO ready=1\n";
+
+    const char* tile_env_before = getenv("GGML_METAL_NAX7_TILE");
+    const std::string tile_before = tile_env_before ? tile_env_before : "";
+    auto set_tile = [](char t) {
+        char v[2] = { t, 0 };
+        setenv("GGML_METAL_NAX7_TILE", v, 1);
+    };
+    auto recreate = [&]() {
+        ggml_backend_free(be);
+        be = ggml_backend_dev_init(dev, nullptr);
+    };
+
+    const Variant variants_full[] = {
+        { "nax64", 0, 'b' }, { "b4a", 1, 'a' }, { "b4b", 1, 'b' }, { "b4c", 1, 'c' },
+        { "b4d", 1, 'd' },   { "b4e", 1, 'e' }, { "b4b_h", 2, 'b' },
+    };
+    const Variant variants_quick[] = { { "nax64", 0, 'b' }, { "b4a", 1, 'a' }, { "b4b", 1, 'b' } };
+    const Variant* variants = quick ? variants_quick : variants_full;
+    const int nv            = quick ? 3 : 7;
+    std::vector<bool> dead(nv, false);
+
+    // --- точность: неровный случай, полное сравнение ---
+    {
+        const int M = 208, K = 512, N = 100;
+        BCase bc;
+        if (!bc.init(be, M, K, { N }, wpool, nw, xpool, nx, true)) {
+            body += "  точность: не выделилась память\n";
+            fail = true;
+        } else {
+            std::vector<double> ref((size_t) M * N);
+            std::vector<std::vector<float>> W(M);
+            for (int m = 0; m < M; m++) bc.weight_row(m, W[m]);
+            double mean_abs = 0;
+            for (int n = 0; n < N; n++) {
+                const float* xr = xpool + (size_t) n * K;
+                for (int m = 0; m < M; m++) {
+                    double s = 0;
+                    for (int k = 0; k < K; k++) s += (double) W[m][k] * xr[k];
+                    ref[(size_t) n * M + m] = s;
+                    mean_abs += std::fabs(s);
+                }
+            }
+            mean_abs /= (double) M * N;
+            std::string kb;
+            b_appendf(kb, "KB4ACC M=%d K=%d N=%d", M, K, N);
+            b_appendf(body, "  точность %dx%d x %d, макс. ошибка / сред. модуль:", M, K, N);
+            // плитки b и c на всех видах — края по токенам и весам у каждой свои
+            const Variant acc_v[] = { { "nax64", 0, 'b' }, { "b4a", 1, 'a' }, { "b4b", 1, 'b' }, { "b4c", 1, 'c' },
+                                      { "b4d", 1, 'd' },   { "b4e", 1, 'e' }, { "b4b_h", 2, 'b' }, { "b4c_h", 2, 'c' } };
+            for (const Variant& v : acc_v) {
+                if (!be) break;
+                ggml_metal_pa_set_nax(v.graph == 0 ? 1 : 0);
+                set_tile(v.tile);
+                b_stats();
+                std::vector<float> out((size_t) M * N, NAN);
+                if (ggml_backend_graph_compute(be, bc.gf[0][v.graph]) != GGML_STATUS_SUCCESS) {
+                    b_appendf(body, " · %s СБОЙ", v.key);
+                    b_appendf(kb, " %s_ok=0 %s_gpu=fail", v.key, v.key);
+                    if (v.graph != 0) fail = true;
+                    recreate();
+                    continue;
+                }
+                ggml_backend_synchronize(be);
+                const std::string st = b_stats();
+                ggml_backend_tensor_get(bc.c[0][v.graph], out.data(), 0, out.size() * sizeof(float));
+                double maxe = 0;
+                bool bad    = false;
+                for (size_t i = 0; i < out.size(); i++) {
+                    if (!std::isfinite(out[i])) { bad = true; break; }
+                    maxe = std::max(maxe, std::fabs(out[i] - ref[i]));
+                }
+                const double rel = maxe / std::max(1e-12, mean_abs);
+                const bool took  = v.graph == 0 || st.find("B4") != std::string::npos;
+                // режим 1 — для сравнения, не судим: у штатной развёртки q4_K на мелких масштабах своя
+                // ошибка (d/16 в half уходит в субнормальные числа), см. отчёт п.13
+                const bool ok    = v.graph == 0 ? !bad : (!bad && rel <= 0.02 && took);
+                if (!ok && v.graph != 0) fail = true;
+                b_appendf(body, " · %s %s", v.key, bad ? "НЕ ЧИСЛА" : "");
+                if (!bad) b_appendf(body, "%.4f%s", rel, ok ? "" : " ОШИБКА");
+                if (!took) body += " [ядро режима 7 не взято]";
+                b_appendf(kb, " %s_err=%.5f %s_ok=%d", v.key, bad ? -1.0 : rel, v.key, ok ? 1 : 0);
+            }
+            body += "\n" + kb + "\n";
+        }
+    }
+
+    // --- скорость на размерах рисующей части ---
+    struct Sz { const char* op; int M, K; int per_block; };
+    const Sz shapes[] = { { "A_attn", 4096, 4096, 4 }, { "B_up", 12288, 4096, 2 }, { "C_down", 4096, 12288, 1 } };
+    const std::vector<int> n_list = quick ? std::vector<int>{ 1037 } : std::vector<int>{ 1037, 1024 };
+    std::vector<std::vector<double>> block(n_list.size(), std::vector<double>(nv, 0.0));
+    std::vector<std::vector<bool>> block_ok(n_list.size(), std::vector<bool>(nv, true));
+    std::vector<int> parts(n_list.size(), 0);
+    body += "  скорость (лучший из 3, мс; в скобках трлн оп/с):\n";
+    for (const Sz& s : shapes) {
+        if (!be) break;
+        if (quick && &s != &shapes[0]) break;
+        BCase bc;
+        if (!bc.init(be, s.M, s.K, n_list, wpool, nw, xpool, nx, false)) {
+            b_appendf(body, "  %s: не выделилась память\nKB4 op=%s alloc=fail\n", s.op, s.op);
+            for (auto& v : block_ok) std::fill(v.begin(), v.end(), false);
+            continue;
+        }
+        for (size_t ni = 0; ni < n_list.size(); ni++) {
+            const int N       = n_list[ni];
+            const double flop = 2.0 * s.M * s.K * (double) N;
+            // эталон: 256 точек
+            std::mt19937 rng(11);
+            std::vector<std::pair<int, int>> pts;
+            for (int i = 0; i < 256; i++) pts.push_back({ (int) (rng() % N), (int) (rng() % s.M) });
+            std::vector<double> ref(pts.size());
+            double mean_abs = 0;
+            {
+                std::vector<float> w;
+                for (size_t i = 0; i < pts.size(); i++) {
+                    bc.weight_row(pts[i].second, w);
+                    const float* xr = xpool + (size_t) pts[i].first * s.K;
+                    double acc = 0;
+                    for (int k = 0; k < s.K; k++) acc += (double) w[k] * xr[k];
+                    ref[i] = acc;
+                    mean_abs += std::fabs(acc);
+                }
+                mean_abs /= pts.size();
+            }
+            b_appendf(body, "  %-6s %5dx%5dx%4d:", s.op, s.M, s.K, N);
+            std::string kb;
+            b_appendf(kb, "KB4 op=%s M=%d K=%d N=%d per_block=%d", s.op, s.M, s.K, N, s.per_block);
+            double t_ref = -1;
+            for (int vi = 0; vi < nv; vi++) {
+                const Variant& v = variants[vi];
+                if (!be) break;
+                if (dead[vi]) {
+                    b_appendf(kb, " %s_ok=0", v.key);
+                    block_ok[ni][vi] = false;
+                    continue;
+                }
+                ggml_metal_pa_set_nax(v.graph == 0 ? 1 : 0);
+                set_tile(v.tile);
+                b_stats();
+                const double t = b_run(be, bc.gf[ni][v.graph], 3);
+                if (t < 0) {
+                    b_appendf(body, " · %s СБОЙ", v.key);
+                    b_appendf(kb, " %s_ok=0 %s_gpu=fail", v.key, v.key);
+                    if (v.graph != 0) fail = true;
+                    dead[vi]          = true;
+                    block_ok[ni][vi]  = false;
+                    recreate();
+                    continue;
+                }
+                const std::string st = b_stats();
+                double maxe = 0;
+                bool bad    = false;
+                for (size_t i = 0; i < pts.size(); i++) {
+                    float val = NAN;
+                    ggml_backend_tensor_get(bc.c[ni][v.graph], &val, ((size_t) pts[i].first * s.M + pts[i].second) * sizeof(float),
+                                            sizeof(float));
+                    if (!std::isfinite(val)) { bad = true; break; }
+                    maxe = std::max(maxe, std::fabs(val - ref[i]));
+                }
+                const double rel = maxe / std::max(1e-12, mean_abs);
+                const bool took  = v.graph == 0 || st.find("B4") != std::string::npos;
+                // режим 1 — для сравнения, не судим: у штатной развёртки q4_K на мелких масштабах своя
+                // ошибка (d/16 в half уходит в субнормальные числа), см. отчёт п.13
+                const bool ok    = v.graph == 0 ? !bad : (!bad && rel <= 0.02 && took);
+                if (!ok && v.graph != 0) fail = true;
+                if (vi == 0) t_ref = t;
+                const double tf = flop / (t * 1e-3) / 1e12;
+                b_appendf(body, " · %s %.2f (%.2f)%s", v.key, t, tf, bad ? " НЕ ЧИСЛА" : (ok ? "" : " ОШИБКА"));
+                if (vi > 0 && t_ref > 0) b_appendf(body, " ×%.2f", t_ref / t);
+                b_appendf(kb, " %s_ms=%.3f %s_tf=%.3f %s_err=%.5f %s_ok=%d", v.key, t, v.key, tf, v.key, bad ? -1.0 : rel, v.key,
+                          ok ? 1 : 0);
+                block[ni][vi] += t * s.per_block;
+                if (!ok) block_ok[ni][vi] = false;
+            }
+            body += "\n" + kb + "\n";
+            parts[ni]++;
+        }
+    }
+
+    // --- блок ---
+    std::string summary;
+    body += "  блок (4·A + 2·B + C, мс) и шаг (×32):\n";
+    for (size_t ni = 0; ni < n_list.size(); ni++) {
+        if (parts[ni] != 3) continue;
+        const int N       = n_list[ni];
+        const double flop = 2.0 * N * (4.0 * 4096 * 4096 + 2.0 * 12288 * 4096 + 1.0 * 4096 * 12288);
+        std::string kb;
+        b_appendf(kb, "KB4BLOCK N=%d gflop=%.1f", N, flop / 1e9);
+        b_appendf(body, "  N=%4d:", N);
+        int best = -1;
+        for (int vi = 0; vi < nv; vi++) {
+            const Variant& v = variants[vi];
+            if (!block_ok[ni][vi] || block[ni][vi] <= 0) {
+                b_appendf(kb, " %s_ok=0", v.key);
+                b_appendf(body, " · %s —", v.key);
+                continue;
+            }
+            const double tf = flop / (block[ni][vi] * 1e-3) / 1e12;
+            b_appendf(kb, " %s_ms=%.2f %s_tf=%.3f %s_step_s=%.3f %s_ok=1", v.key, block[ni][vi], v.key, tf, v.key,
+                      block[ni][vi] * 32 / 1000.0, v.key);
+            b_appendf(body, " · %s %.1f (%.2f)", v.key, block[ni][vi], tf);
+            if (vi > 0 && (best < 0 || block[ni][vi] < block[ni][best])) best = vi;
+        }
+        body += "\n" + kb + "\n";
+        if (N == 1037 && best > 0 && block_ok[ni][0] && block[ni][0] > 0) {
+            char b[160];
+            snprintf(b, sizeof(b), "режим 7: блок %.0f мс (%s) против MLX 64 %.0f (×%.2f)", block[ni][best], variants[best].key,
+                     block[ni][0], block[ni][0] / block[ni][best]);
+            summary = b;
+        }
+    }
+
+    // вернуть как было
+    if (tile_before.empty()) unsetenv("GGML_METAL_NAX7_TILE");
+    else setenv("GGML_METAL_NAX7_TILE", tile_before.c_str(), 1);
+    if (fail) return "режим 7 считает НЕВЕРНО";
+    return summary.empty() ? std::string("режим 7 верен, блок не посчитан") : summary;
+#endif
+}
diff --git a/src/pa_repack.h b/src/pa_repack.h
new file mode 100644
index 0000000..c7b46ed
--- /dev/null
+++ b/src/pa_repack.h
@@ -0,0 +1,121 @@
+// PocketAgent п.13: переупаковка весов q4_K при загрузке в раскладку
+// «плитками» (GGML_TYPE_PA_Q4_K_T) под ядро умножения на матричных блоках A19/M5.
+//
+// Зачем. Штатные ядра и ядро по схеме MLX (п.7) разворачивают q4_K в общую память группы и
+// ставят два барьера на каждый шаг по K — блоки простаивают, пока группа распаковывает веса
+//. Все, у кого блоки реально разгоняются (MLX fp16, Cider, tessl),
+// грузят операнд ПРЯМО из памяти устройства в регистры. Для этого каждой нити нужен свой
+// кусочек весов подряд — в обычном q4_K он размазан по 2 строкам и 4 полубайтам в разных
+// местах блока. Поэтому раскладываем байты заново, один раз при загрузке.
+//
+// Раскладка ТОЧНАЯ и того же размера: это перестановка тех же байтов q4_K (144 байта на 256
+// весов). Ни одно число не меняется, память не растёт (0 %), картинка — побитово та же
+// арифметика, что у штатной развёртки (масштаб d·sc, сдвиг dmin·m, как в dequantize_q4_K).
+//
+// Устройство. Строки весов группами по 16 (M кратно 16), в строке K/256 суперблоков. Группа из
+// 16 строк занимает ровно те же 16·rowbytes байт, что и раньше (переупаковка на месте, по
+// группам). Внутри группы — «сверхплитки» по одному суперблоку на 16 строк, 2304 байта:
+//   [0, 256)     заголовки 16 строк: для строки r — 16 байт {half d, half dmin, scales[12]}
+//                (ровно заголовок её block_q4_K, без изменений);
+//   [256, 2304)  полубайты: 4 куска по 64 значения K, кусок c — 512 байт = 32 нити × uint4.
+//                Нить lane берёт uint4 по адресу 256 + c·512 + lane·16; компонента p (0..3) —
+//                кусок K 16 значений (64c + 16p .. +15); в uint полубайт e (биты 4e..4e+3):
+//                e = 0..3 — строка fm, k = fn + e; e = 4..7 — строка fm + 8, k = fn + e − 4,
+//                где (fn, fm) — раскладка регистрового фрагмента 16×16 MLX (steel/gemm/nax.h):
+//                qid = lane >> 2; fm = (qid & 4) | ((lane >> 1) & 3); fn = ((qid & 2) | (lane & 1)) · 4.
+// Так одна загрузка uint4 даёт нити ровно её 4 куска правого операнда matmul2d 16×32×16.
+#pragma once
+
+#include <cstdint>
+#include <cstring>
+#include <vector>
+
+namespace pa4 {
+
+// Сверхплитка: 16 строк × 256 значений K.
+constexpr int kRows       = 16;
+constexpr int kSuper      = 256;
+constexpr int kBlockBytes = 144;                    // sizeof(block_q4_K)
+constexpr int kTileBytes  = kRows * kBlockBytes;    // 2304
+
+inline void frag_coord(int lane, int& fn, int& fm) {
+    const int qid = lane >> 2;
+    fm            = (qid & 4) | ((lane >> 1) & 3);
+    fn            = ((qid & 2) | (lane & 1)) * 4;
+}
+
+// Годится ли матрица [K x M] (ne0 = K, ne1 = M) под раскладку.
+inline bool shape_ok(int64_t K, int64_t M) {
+    return K > 0 && M > 0 && K % kSuper == 0 && M % kRows == 0;
+}
+
+// 4 подряд идущих значения K (k кратно 4) одной строки из блока q4_K → 4 полубайта в 16 битах.
+// В q4_K байт qs[32i + t] хранит значение k = 64i + t в младшем полубайте и k = 64i + 32 + t —
+// в старшем; 4 подряд идущих k лежат в 4 подряд идущих байтах, все в одной половине.
+inline uint32_t nib4(const uint8_t* qs, int k) {
+    const int i = k >> 6;
+    const int t = k & 63;
+    uint32_t x;
+    std::memcpy(&x, qs + 32 * i + (t & 31), 4);
+    if (t >= 32) {
+        x >>= 4;
+    }
+    x &= 0x0F0F0F0Fu;
+    return (x & 0xFu) | ((x >> 4) & 0xF0u) | ((x >> 8) & 0xF00u) | ((x >> 12) & 0xF000u);
+}
+
+// Переупаковка на месте: data — nrows строк q4_K по K значений (как в файле), nrows кратно 16.
+// tmp — рабочий буфер вызывающего (16 строк, до ~110 КБ), чтобы не выделять память на каждый тензор.
+inline void repack_q4k(uint8_t* data, int64_t nrows, int64_t K, std::vector<uint8_t>& tmp) {
+    const int64_t nsb    = K / kSuper;
+    const size_t rowb    = (size_t) nsb * kBlockBytes;
+    const size_t grp     = (size_t) kRows * rowb;
+    tmp.resize(grp);
+    for (int64_t g = 0; g < nrows / kRows; g++) {
+        uint8_t* dst = data + (size_t) g * grp;
+        std::memcpy(tmp.data(), dst, grp);
+        for (int64_t s = 0; s < nsb; s++) {
+            uint8_t* st = dst + (size_t) s * kTileBytes;
+            for (int r = 0; r < kRows; r++) {
+                std::memcpy(st + r * 16, tmp.data() + r * rowb + (size_t) s * kBlockBytes, 16);
+            }
+            uint8_t* q = st + 256;
+            for (int c = 0; c < 4; c++) {
+                for (int lane = 0; lane < 32; lane++) {
+                    int fn, fm;
+                    frag_coord(lane, fn, fm);
+                    const uint8_t* qs0 = tmp.data() + fm * rowb + (size_t) s * kBlockBytes + 16;
+                    const uint8_t* qs1 = tmp.data() + (fm + 8) * rowb + (size_t) s * kBlockBytes + 16;
+                    for (int p = 0; p < 4; p++) {
+                        const int k      = c * 64 + p * 16 + fn;
+                        const uint32_t u = nib4(qs0, k) | (nib4(qs1, k) << 16);
+                        std::memcpy(q + c * 512 + lane * 16 + p * 4, &u, 4);
+                    }
+                }
+            }
+        }
+    }
+}
+
+// Обратно (только для проверки на процессоре): значение (строка m, столбец k) из раскладки.
+inline uint8_t tiled_q(const uint8_t* data, int64_t K, int64_t m, int64_t k) {
+    const size_t rowb = (size_t) (K / kSuper) * kBlockBytes;
+    const uint8_t* st = data + (size_t) (m / kRows) * kRows * rowb + (size_t) (k / kSuper) * kTileBytes;
+    const int r = (int) (m % kRows), kk = (int) (k % kSuper);
+    const int c = kk / 64, p = (kk % 64) / 16, col = kk % 16;
+    for (int lane = 0; lane < 32; lane++) {
+        int fn, fm;
+        frag_coord(lane, fn, fm);
+        if (col < fn || col >= fn + 4) continue;
+        int e;
+        if (r == fm) e = col - fn;
+        else if (r == fm + 8) e = 4 + col - fn;
+        else continue;
+        uint32_t u;
+        std::memcpy(&u, st + 256 + c * 512 + lane * 16 + p * 4, 4);
+        return (uint8_t) ((u >> (4 * e)) & 0xF);
+    }
+    return 0xFF;
+}
+
+}  // namespace pa4
PA_SD_V13B_PATCH
  git -C "$src/ggml" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_GGML_V13B_PATCH' \
    || { echo "❌ правка ggml п.13 (тип pa_q4_K_t, ядро режима 7) не легла — см. $log" >&2; return 1; }
diff --git a/include/ggml.h b/include/ggml.h
index e720d00..513b688 100644
--- a/include/ggml.h
+++ b/include/ggml.h
@@ -434,7 +434,11 @@ extern "C" {
         GGML_TYPE_Q2_0    = 42,
         GGML_TYPE_F8_E4M3 = 43,
         GGML_TYPE_F8_E5M2 = 44,
-        GGML_TYPE_COUNT   = 45,
+        // PocketAgent п.13: q4_K, переупакованный при загрузке «плитками» под ядро умножения на
+        // матричных блоках A19/M5 (sd.cpp src/pa_repack.h). Те же 144 байта на 256 весов, другой
+        // порядок; считает только Metal-ядро режима GGML_METAL_NAX=7, на процессоре его нет.
+        GGML_TYPE_PA_Q4_K_T = 45,
+        GGML_TYPE_COUNT   = 46,
     };
 
     // precision
diff --git a/src/ggml-metal/ggml-metal-ops.cpp b/src/ggml-metal/ggml-metal-ops.cpp
index 4f489f7..2f3ebdb 100644
--- a/src/ggml-metal/ggml-metal-ops.cpp
+++ b/src/ggml-metal/ggml-metal-ops.cpp
@@ -2350,6 +2350,497 @@ int ggml_metal_op_pool_2d(ggml_metal_op_t ctx, int idx) {
 // PocketAgent, патч 12 (инженер A): режимы GGML_METAL_NAX=3..6, см. ниже pa_naxa_encode.
 static bool pa_naxa_encode(ggml_metal_op_t ctx, ggml_tensor * op);
 
+// PocketAgent п.13: зависимости блока режима 7 (ниже)
+#include "ggml-metal.h"
+
+#include <cstdio>
+#include <cstdlib>
+#include <mutex>
+#include <string>
+#include <unordered_map>
+
+//
+// PocketAgent п.13: умножение на весах, переупакованных при загрузке
+// (GGML_TYPE_PA_Q4_K_T, раскладка — src/pa_repack.h в sd.cpp). Режим GGML_METAL_NAX=7 (до слияния с п.12 — 4).
+//
+// Чем отличается от ядра п.7 (схема MLX qmm_t_nax): там веса разворачиваются в общую память
+// группы и на каждый шаг K=64 стоят два барьера — блоки ждут, пока группа распакует q4_K.
+// Здесь каждая SIMD-группа сама грузит свой кусок весов ОДНИМ uint4 на нить прямо из памяти
+// устройства (раскладка уже совпадает с регистровым фрагментом matmul2d), разворачивает в
+// регистрах (масштаб и сдвиг на 32 значения — как в dequantize_q4_K) и отдаёт в блок.
+// Общей памяти и барьеров нет вовсе; шаг K = 256 (суперблок). Так же устроены быстрые пути
+// MLX fp16 и Cider.
+//
+// Ядра — в СВОЕЙ маленькой библиотеке шейдеров, собранной из строки ниже: основная библиотека
+// и библиотека ядер MLX (п.7) не меняются, и если компилятор телефона это ядро не примет, это
+// коснётся только режима 7 — веса тогда просто не переупаковываются (см. ggml_backend_metal_pa4_prepare).
+//
+// Плитки (GGML_METAL_NAX7_TILE, старое имя GGML_METAL_NAX4_TILE тоже понимается; читается на каждом
+// умножении; нет — «b»):
+//   a — 64 токена × 128 строк весов, 4 SIMD-группы 2×2, у каждой 32×64;
+//   b — 64 × 64, 4 группы 2×2, у каждой 32×32 (как MLX qmm_t_nax; по умолчанию — меньше регистров);
+//   c — 128 × 128, 8 групп 4×2, у каждой 32×64;
+//   d — 64 × 128, 4 группы 1×4, у каждой 64×32;
+//   e — 128 × 128, 16 групп 4×4, у каждой 32×32 (как Cider).
+// Активации float или half (что придёт из графа) — сужаются в half в регистрах.
+//
+// GGML_METAL_PA4_EMU=1 (или общий с п.12 GGML_METAL_PA_NAX_EMU=1) — только для проверки на машине БЕЗ матричных блоков (M1): блок 16×32×16
+// считается обычными simdgroup_matrix через общую память. Правильность раскладки, развёртки и
+// краёв — та же; скорость — нет.
+//
+static const char * pa4_metal_src = R"PA4SRC(
+#include <metal_stdlib>
+#if !defined(PA4_EMU)
+#include <metal_tensor>
+#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
+#endif
+using namespace metal;
+
+#define PA4_UNROLL _Pragma("clang loop unroll(full)")
+
+struct pa4_args {
+    ulong nb01, nb02, nb03, nb11, nb12, nb13;
+    int   K, M, N, ne12, r2, r3;
+};
+
+typedef vec<half, 8>  pa4_fh;   // кусок 16x16: 32 нити x 8 значений
+typedef vec<float, 8> pa4_ff;
+
+// нить владеет строками fm и fm+8, столбцами fn..fn+3 куска 16x16 (раскладка MLX nax.h)
+static inline short2 pa4_coord(ushort lane) {
+    const short qid = lane >> 2;
+    const short fm  = (qid & 4) | ((lane >> 1) & 3);
+    const short fn  = ((qid & 2) | (lane & 1)) * 4;
+    return short2(fn, fm);
+}
+
+#if !defined(PA4_EMU)
+// C(16x32) += A(16x16) * B^T, B — два куска 16x16 [строка весов][k]; одна SIMD-группа
+static inline void pa4_mma(thread pa4_ff & c0, thread pa4_ff & c1,
+                           thread const pa4_fh & a, thread const pa4_fh & b0, thread const pa4_fh & b1) {
+    constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
+        16, 32, 16, false, true, true,
+        mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
+    mpp::tensor_ops::matmul2d<desc, execution_simdgroup> op;
+
+    auto ca = op.template get_left_input_cooperative_tensor<half, half, float>();
+    auto cb = op.template get_right_input_cooperative_tensor<half, half, float>();
+    auto cc = op.template get_destination_cooperative_tensor<decltype(ca), decltype(cb), float>();
+
+    PA4_UNROLL for (short i = 0; i < 8; i++) {
+        ca[i]     = a[i];
+        cb[i]     = b0[i];
+        cb[8 + i] = b1[i];
+        cc[i]     = c0[i];
+        cc[8 + i] = c1[i];
+    }
+    op.run(ca, cb, cc);
+    PA4_UNROLL for (short i = 0; i < 8; i++) {
+        c0[i] = cc[i];
+        c1[i] = cc[8 + i];
+    }
+}
+#define PA4_MMA(c0, c1, a, b0, b1) pa4_mma(c0, c1, a, b0, b1)
+#else
+// Проверка без блоков: тот же 16x32x16 обычными 8x8 через общую память SIMD-группы.
+static inline void pa4_mma_emu(thread pa4_ff & c0, thread pa4_ff & c1,
+                               thread const pa4_fh & a, thread const pa4_fh & b0, thread const pa4_fh & b1,
+                               threadgroup half * sh, threadgroup float * sf, ushort lane) {
+    const short2 fc = pa4_coord(lane);
+    for (short e = 0; e < 8; e++) {
+        const short r = fc.y + 8 * (e >> 2);
+        const short c = fc.x + (e & 3);
+        sh[r * 16 + c]              = a[e];
+        sh[256 + r * 16 + c]        = b0[e];
+        sh[256 + (16 + r) * 16 + c] = b1[e];
+        sf[r * 32 + c]              = c0[e];
+        sf[r * 32 + 16 + c]         = c1[e];
+    }
+    simdgroup_barrier(mem_flags::mem_threadgroup);
+    simdgroup_half8x8  ma[2][2];
+    simdgroup_half8x8  mb[4][2];
+    simdgroup_float8x8 mc[2][4];
+    for (short i = 0; i < 2; i++) for (short k = 0; k < 2; k++) simdgroup_load(ma[i][k], sh + i * 128 + k * 8, 16);
+    for (short j = 0; j < 4; j++) for (short k = 0; k < 2; k++) simdgroup_load(mb[j][k], sh + 256 + j * 128 + k * 8, 16, ulong2(0, 0), true);
+    for (short i = 0; i < 2; i++) for (short j = 0; j < 4; j++) simdgroup_load(mc[i][j], sf + i * 256 + j * 8, 32);
+    for (short i = 0; i < 2; i++) for (short j = 0; j < 4; j++) for (short k = 0; k < 2; k++)
+        simdgroup_multiply_accumulate(mc[i][j], ma[i][k], mb[j][k], mc[i][j]);
+    for (short i = 0; i < 2; i++) for (short j = 0; j < 4; j++) simdgroup_store(mc[i][j], sf + i * 256 + j * 8, 32);
+    simdgroup_barrier(mem_flags::mem_threadgroup);
+    for (short e = 0; e < 8; e++) {
+        const short r = fc.y + 8 * (e >> 2);
+        const short c = fc.x + (e & 3);
+        c0[e] = sf[r * 32 + c];
+        c1[e] = sf[r * 32 + 16 + c];
+    }
+    simdgroup_barrier(mem_flags::mem_threadgroup);
+}
+#define PA4_MMA(c0, c1, a, b0, b1) pa4_mma_emu(c0, c1, a, b0, b1, sh, sf, lane)
+#endif
+
+static inline half4 pa4_ld(device const float * p) { return half4(float4(*((device const packed_float4 *) p))); }
+static inline half4 pa4_ld(device const half  * p) { return half4(*((device const packed_half4  *) p)); }
+
+template<typename TA, short BT, short BW, short WT, short WW>
+[[kernel, max_total_threads_per_threadgroup(WT * WW * 32)]]
+void kernel_mul_mm_pa4(
+        constant pa4_args   & args [[buffer(0)]],
+        device const char   * srcA [[buffer(1)]],
+        device const char   * srcB [[buffer(2)]],
+        device       char   * dst  [[buffer(3)]],
+#if defined(PA4_EMU)
+        threadgroup  char   * shmem [[threadgroup(0)]],
+#endif
+        uint3  tgpig [[threadgroup_position_in_grid]],
+        ushort sgitg [[simdgroup_index_in_threadgroup]],
+        ushort lane  [[thread_index_in_simdgroup]]) {
+    constexpr short ST = BT / WT;   // подплитка SIMD-группы: токены
+    constexpr short SW = BW / WW;   //                        строки весов
+    constexpr short TT = ST / 16;
+    constexpr short TW = SW / 16;
+    static_assert(TW % 2 == 0, "подплитка по весам должна быть кратна 32");
+
+    const int im  = tgpig.z;
+    const int i12 = im % args.ne12;
+    const int i13 = im / args.ne12;
+
+    const int t0  = tgpig.x * BT + ST * (sgitg / WW);
+    const int w0  = tgpig.y * BW + SW * (sgitg % WW);
+    const int n_t = min(args.N - t0, (int) ST);   // живые токены подплитки
+    const int n_w = min(args.M - w0, (int) SW);   // живые строки весов (кратно 16)
+    // Барьеров в ядре нет — пустая SIMD-группа может уйти сразу.
+    if (n_t <= 0 || n_w <= 0) {
+        return;
+    }
+
+#if defined(PA4_EMU)
+    threadgroup half  * sh = (threadgroup half  *)(shmem + sgitg * 3584);
+    threadgroup float * sf = (threadgroup float *)(shmem + sgitg * 3584 + 1536);
+#endif
+
+    const short2 fc  = pa4_coord(lane);
+    const int    nsb = args.K / 256;
+
+    // группа из 16 строк весов tw: wa + tw*16*nb01; сверхплитка суперблока s: + s*2304
+    device const uchar * wa = (device const uchar *) srcA
+                            + (ulong)(i12 / args.r2) * args.nb02 + (ulong)(i13 / args.r3) * args.nb03
+                            + (ulong) w0 * args.nb01;
+    device const char  * xa = srcB + args.nb12 * i12 + args.nb13 * i13 + (ulong) t0 * args.nb11;
+
+    pa4_ff D[TT][TW];
+    PA4_UNROLL for (short i = 0; i < TT; i++) {
+        PA4_UNROLL for (short j = 0; j < TW; j++) {
+            D[i][j] = pa4_ff(0.0f);
+        }
+    }
+
+    for (int s = 0; s < nsb; s++) {
+        PA4_UNROLL for (short c = 0; c < 4; c++) {
+            // MLX/Cider: иначе компилятор поднимает все загрузки над всеми run и выливает регистры
+            volatile int compiler_barrier;
+
+            // кусок K 64: веса — один uint4 на нить и группу строк; заголовки строк fm и fm+8
+            // (d, dmin, 12 байт масштабов) — тут же, чтобы не держать их в регистрах весь суперблок
+            uint4 wq[TW];
+            uint4 hd[TW][2];
+            PA4_UNROLL for (short tw = 0; tw < TW; tw++) {
+                device const uchar * st = wa + (ulong)(tw * 16) * args.nb01 + (ulong) s * 2304;
+                const bool live = tw * 16 < n_w;
+                wq[tw]    = live ? *((device const uint4 *)(st + 256 + c * 512 + lane * 16)) : uint4(0);
+                hd[tw][0] = live ? *((device const uint4 *)(st + fc.y * 16))                 : uint4(0);
+                hd[tw][1] = live ? *((device const uint4 *)(st + (fc.y + 8) * 16))           : uint4(0);
+            }
+
+            PA4_UNROLL for (short u = 0; u < 2; u++) {
+                // подблок 32 значений j = 2c + u: масштаб d*sc и сдвиг dmin*m (get_scale_min_k4),
+                // в float — как в dequantize_q4_K, но без d/16 в half (у мелких d это субнормальные числа)
+                const short j = 2 * c + u;
+                float sc[TW][2];
+                float mn[TW][2];
+                PA4_UNROLL for (short tw = 0; tw < TW; tw++) {
+                    PA4_UNROLL for (short r = 0; r < 2; r++) {
+                        const half2  dd = as_type<half2>(hd[tw][r].x);
+                        const uchar4 q0 = as_type<uchar4>(hd[tw][r].y);   // scales[0..3]
+                        const uchar4 q1 = as_type<uchar4>(hd[tw][r].z);   // scales[4..7]
+                        const uchar4 q2 = as_type<uchar4>(hd[tw][r].w);   // scales[8..11]
+                        uchar scv, mv;
+                        if (j < 4) {
+                            scv = q0[j] & 63;
+                            mv  = q1[j] & 63;
+                        } else {
+                            scv = (q2[j - 4] & 0xF) | ((q0[j - 4] >> 6) << 4);
+                            mv  = (q2[j - 4] >> 4)  | ((q1[j - 4] >> 6) << 4);
+                        }
+                        sc[tw][r] = (float) dd.x * (float) scv;
+                        mn[tw][r] = (float) dd.y * (float) mv;
+                    }
+                }
+
+                PA4_UNROLL for (short pp = 0; pp < 2; pp++) {
+                    const short p  = 2 * u + pp;                        // кусок 16 значений K
+                    const int   k0 = s * 256 + c * 64 + p * 16 + fc.x;
+
+                    pa4_fh A[TT];
+                    PA4_UNROLL for (short tt = 0; tt < TT; tt++) {
+                        PA4_UNROLL for (short r = 0; r < 2; r++) {
+                            const short row = tt * 16 + fc.y + 8 * r;
+                            half4 v = half4(0.0h);
+                            if (row < n_t) {
+                                v = pa4_ld((device const TA *)(xa + (ulong) row * args.nb11) + k0);
+                            }
+                            A[tt][r * 4 + 0] = v[0];
+                            A[tt][r * 4 + 1] = v[1];
+                            A[tt][r * 4 + 2] = v[2];
+                            A[tt][r * 4 + 3] = v[3];
+                        }
+                    }
+
+                    pa4_fh B[TW];
+                    PA4_UNROLL for (short tw = 0; tw < TW; tw++) {
+                        const uint q = wq[tw][p];
+                        PA4_UNROLL for (short e = 0; e < 8; e++) {
+                            const short r = e >> 2;
+                            B[tw][e] = (half) fma(sc[tw][r], (float)((q >> (4 * e)) & 0xFu), -mn[tw][r]);
+                        }
+                    }
+
+                    PA4_UNROLL for (short tt = 0; tt < TT; tt++) {
+                        PA4_UNROLL for (short tw = 0; tw < TW; tw += 2) {
+                            PA4_MMA(D[tt][tw], D[tt][tw + 1], A[tt], B[tw], B[tw + 1]);
+                        }
+                    }
+                }
+            }
+        }
+    }
+
+    // результат: dst[токен][строка весов], float
+    device float * dp = (device float *) dst + ((ulong) im * args.N + t0) * args.M + w0;
+    PA4_UNROLL for (short tt = 0; tt < TT; tt++) {
+        PA4_UNROLL for (short tw = 0; tw < TW; tw++) {
+            PA4_UNROLL for (short r = 0; r < 2; r++) {
+                const short row = tt * 16 + fc.y + 8 * r;
+                if (row < n_t && tw * 16 < n_w) {
+                    device float * p = dp + (ulong) row * args.M + tw * 16 + fc.x;
+                    p[0] = D[tt][tw][r * 4 + 0];
+                    p[1] = D[tt][tw][r * 4 + 1];
+                    p[2] = D[tt][tw][r * 4 + 2];
+                    p[3] = D[tt][tw][r * 4 + 3];
+                }
+            }
+        }
+    }
+}
+
+#define PA4_INST(tile, tname, TA, BT, BW, WT, WW) \
+template [[host_name("kernel_mul_mm_pa4_" #tile "_" #tname)]] [[kernel]] \
+decltype(kernel_mul_mm_pa4<TA, BT, BW, WT, WW>) kernel_mul_mm_pa4<TA, BT, BW, WT, WW>;
+
+PA4_INST(a, f32, float,  64, 128, 2, 2)
+PA4_INST(b, f32, float,  64,  64, 2, 2)
+PA4_INST(c, f32, float, 128, 128, 4, 2)
+PA4_INST(d, f32, float,  64, 128, 1, 4)
+PA4_INST(e, f32, float, 128, 128, 4, 4)
+PA4_INST(a, f16, half,   64, 128, 2, 2)
+PA4_INST(b, f16, half,   64,  64, 2, 2)
+PA4_INST(c, f16, half,  128, 128, 4, 2)
+PA4_INST(d, f16, half,   64, 128, 1, 4)
+PA4_INST(e, f16, half,  128, 128, 4, 4)
+)PA4SRC";
+
+struct pa4_args_host {
+    uint64_t nb01, nb02, nb03, nb11, nb12, nb13;
+    int32_t  K, M, N, ne12, r2, r3;
+};
+
+struct pa4_tile {
+    char tile;
+    int  bt, bw, nsg;
+};
+
+static pa4_tile pa4_tile_cfg(char t) {
+    switch (t) {
+        case 'a': return { 'a',  64, 128, 4 };
+        case 'c': return { 'c', 128, 128, 8 };
+        case 'd': return { 'd',  64, 128, 4 };
+        case 'e': return { 'e', 128, 128, 16 };
+        default:  return { 'b',  64,  64, 4 };
+    }
+}
+
+static char pa4_tile_env(void) {
+    // Режим теперь 7 (4 занят п.12): новое имя переменной главнее, старое понимается.
+    const char * e = getenv("GGML_METAL_NAX7_TILE");
+    if (!(e && e[0])) {
+        e = getenv("GGML_METAL_NAX4_TILE");
+    }
+    if (e && e[0] >= 'a' && e[0] <= 'e' && e[1] == '\0') {
+        return e[0];
+    }
+    return 'b';
+}
+
+static bool pa4_emu_allowed(void) {
+    const char * e = getenv("GGML_METAL_PA4_EMU");
+    const char * a = getenv("GGML_METAL_PA_NAX_EMU");  // общий переключатель эмуляции с п.12
+    return (e != nullptr && e[0] == '1') || (a != nullptr && a[0] == '1');
+}
+
+static std::mutex                                            g_pa4_mu;
+static std::unordered_map<ggml_metal_device_t, ggml_metal_library_t> g_pa4_lib;   // nullptr — не собралась
+static std::unordered_map<std::string, long>                 g_pa4_stat;
+
+// Своя библиотека с ядрами режима 7 — один раз на устройство. NULL — нельзя (нет блоков) или не собралась.
+static ggml_metal_library_t pa4_library(ggml_metal_device_t dev) {
+    std::lock_guard<std::mutex> lk(g_pa4_mu);
+    auto it = g_pa4_lib.find(dev);
+    if (it != g_pa4_lib.end()) {
+        return it->second;
+    }
+    const ggml_metal_device_props * props = ggml_metal_device_get_props(dev);
+    const bool emu = !props->has_tensor && pa4_emu_allowed() && props->has_simdgroup_mm;
+    ggml_metal_library_t lib = nullptr;
+    if (props->has_tensor || emu) {
+        std::string src = emu ? std::string("#define PA4_EMU 1\n") + pa4_metal_src : std::string(pa4_metal_src);
+        const int64_t t0 = ggml_time_us();
+        lib = ggml_metal_library_init_from_source(dev, src.c_str(), true);
+        GGML_LOG_INFO("PA NAX4: ядра режима 7%s %s за %.2f с\n", emu ? " (эмуляция блока, только проверка)" : "",
+                      lib ? "собраны" : "НЕ собрались", (ggml_time_us() - t0) / 1e6);
+    } else {
+        GGML_LOG_INFO("PA NAX4: матричных блоков нет — режим 7 недоступен\n");
+    }
+    g_pa4_lib[dev] = lib;
+    return lib;
+}
+
+static ggml_metal_pipeline_with_params pa4_pipeline(ggml_metal_device_t dev, char tile, ggml_type t1, pa4_tile * cfg) {
+    ggml_metal_pipeline_with_params res = {};
+    res.pipeline = nullptr;
+    ggml_metal_library_t lib = pa4_library(dev);
+    if (lib == nullptr) {
+        return res;
+    }
+    *cfg = pa4_tile_cfg(tile);
+    char name[64];
+    snprintf(name, sizeof(name), "kernel_mul_mm_pa4_%c_%s", cfg->tile, t1 == GGML_TYPE_F16 ? "f16" : "f32");
+    res = ggml_metal_library_get_pipeline(lib, name);
+    if (!res.pipeline) {
+        res = ggml_metal_library_compile_pipeline(lib, name, name, nullptr);
+    }
+    if (res.pipeline && ggml_metal_pipeline_max_theads_per_threadgroup(res) < 32 * cfg->nsg) {
+        GGML_LOG_WARN("PA NAX4: %s — мало нитей на группу\n", name);
+        res.pipeline = nullptr;
+    }
+    return res;
+}
+
+// Можно ли переупаковывать веса: ядро режима 7 собрано на этом устройстве (плитка «b» и текущая).
+// Зовётся загрузчиком sd.cpp ДО переупаковки — нет ядра, нет и переупаковки.
+extern "C" int ggml_metal_pa4_prepare_dev(ggml_metal_device_t dev) {
+    if (dev == nullptr) {
+        return 0;
+    }
+    pa4_tile cfg;
+    if (!pa4_pipeline(dev, 'b', GGML_TYPE_F32, &cfg).pipeline) {
+        return 0;
+    }
+    pa4_pipeline(dev, pa4_tile_env(), GGML_TYPE_F32, &cfg);
+    return 1;
+}
+
+extern "C" int ggml_backend_metal_pa4_prepare(void) {
+    ggml_backend_reg_t reg = ggml_backend_metal_reg();
+    if (reg == nullptr || ggml_backend_reg_dev_count(reg) == 0) {
+        return 0;
+    }
+    ggml_backend_dev_t d = ggml_backend_reg_dev_get(reg, 0);
+    return d ? ggml_metal_pa4_prepare_dev((ggml_metal_device_t) d->context) : 0;
+}
+
+// Счёт умножений режима 7 с прошлого сброса — дописывается к строке sd_pa_kernel_stats.
+extern "C" void ggml_metal_pa4_stats(char * buf, size_t len, int reset) {
+    std::string out;
+    {
+        std::lock_guard<std::mutex> lk(g_pa4_mu);
+        for (const auto & kv : g_pa4_stat) {
+            out += " " + kv.first + " ×" + std::to_string(kv.second) + ";";
+        }
+        if (reset) {
+            g_pa4_stat.clear();
+        }
+    }
+    if (buf && len) {
+        snprintf(buf, len, "%s", out.c_str());
+    }
+}
+
+static int ggml_metal_pa4_op_mul_mat(ggml_metal_op_t ctx, int idx) {
+    ggml_tensor * op = ctx->node(idx);
+    const ggml_tensor * s0 = op->src[0];
+    const ggml_tensor * s1 = op->src[1];
+
+    // Переупакованные веса понимает только это ядро — отказать здесь нечем, поэтому условия
+    // проверены заранее (загрузчик: форма; граф DiT: активации подряд) и тут — утверждения.
+    GGML_ASSERT(s1->type == GGML_TYPE_F32 || s1->type == GGML_TYPE_F16);
+    GGML_ASSERT(op->type == GGML_TYPE_F32);
+    GGML_ASSERT(s1->nb[0] == ggml_type_size(s1->type));
+    GGML_ASSERT(op->nb[0] == sizeof(float) && op->nb[1] == (size_t) op->ne[0] * sizeof(float));
+    GGML_ASSERT(s0->ne[0] % 256 == 0 && s0->ne[1] % 16 == 0);
+    GGML_ASSERT(s1->ne[2] % s0->ne[2] == 0 && s1->ne[3] % s0->ne[3] == 0);
+
+    pa4_tile cfg;
+    char tile = pa4_tile_env();
+    ggml_metal_pipeline_with_params p = pa4_pipeline(ctx->dev, tile, s1->type, &cfg);
+    if (!p.pipeline && tile != 'b') {
+        tile = 'b';
+        p    = pa4_pipeline(ctx->dev, tile, s1->type, &cfg);
+    }
+    if (p.pipeline && !ggml_metal_device_get_props(ctx->dev)->has_tensor && cfg.nsg * 3584 > 32768) {
+        p = pa4_pipeline(ctx->dev, 'b', s1->type, &cfg);   // эмуляция: 16 групп не влезают в общую память
+    }
+    if (!p.pipeline) {
+        GGML_ABORT("PA NAX4: веса переупакованы, а ядра режима 7 нет (%s)", s1->type == GGML_TYPE_F16 ? "f16" : "f32");
+    }
+
+    pa4_args_host args = {
+        /*.nb01 =*/ s0->nb[1],
+        /*.nb02 =*/ s0->nb[2],
+        /*.nb03 =*/ s0->nb[3],
+        /*.nb11 =*/ s1->nb[1],
+        /*.nb12 =*/ s1->nb[2],
+        /*.nb13 =*/ s1->nb[3],
+        /*.K    =*/ (int32_t) s0->ne[0],
+        /*.M    =*/ (int32_t) s0->ne[1],
+        /*.N    =*/ (int32_t) s1->ne[1],
+        /*.ne12 =*/ (int32_t) s1->ne[2],
+        /*.r2   =*/ (int32_t) (s1->ne[2] / s0->ne[2]),
+        /*.r3   =*/ (int32_t) (s1->ne[3] / s0->ne[3]),
+    };
+
+    ggml_metal_encoder_t enc = ctx->enc;
+    ggml_metal_encoder_set_pipeline(enc, p);
+    ggml_metal_encoder_set_bytes   (enc, &args, sizeof(args), 0);
+    ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(s0), 1);
+    ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(s1), 2);
+    ggml_metal_encoder_set_buffer  (enc, ggml_metal_get_buffer_id(op), 3);
+    if (!ggml_metal_device_get_props(ctx->dev)->has_tensor) {
+        ggml_metal_encoder_set_threadgroup_memory_size(enc, (size_t) cfg.nsg * 3584, 0);   // только эмуляция
+    }
+    ggml_metal_encoder_dispatch_threadgroups(enc, (s1->ne[1] + cfg.bt - 1) / cfg.bt, (s0->ne[1] + cfg.bw - 1) / cfg.bw,
+                                             s1->ne[2] * s1->ne[3], 32, cfg.nsg, 1);
+
+    {
+        char key[96];
+        snprintf(key, sizeof(key), "%s → B4 %c (%s)", ggml_type_name(s0->type), cfg.tile, ggml_type_name(s1->type));
+        std::lock_guard<std::mutex> lk(g_pa4_mu);
+        if (g_pa4_stat[key]++ == 0) {
+            GGML_LOG_INFO("PA NAX4: умножение %s [%lldx%lld x %lld]\n", key, (long long) s0->ne[1], (long long) s0->ne[0],
+                          (long long) s1->ne[1]);
+        }
+    }
+    return 1;
+}
+
 int ggml_metal_op_mul_mat(ggml_metal_op_t ctx, int idx) {
     ggml_tensor * op = ctx->node(idx);
 
@@ -2372,6 +2863,12 @@ int ggml_metal_op_mul_mat(ggml_metal_op_t ctx, int idx) {
             return ggml_metal_op_fwht(ctx, idx);
         }
     }
+    // PocketAgent п.13: веса, переупакованные при загрузке (режим GGML_METAL_NAX=7), понимает
+    // только ядро режима 7 — при любом числе токенов, иначе штатные ядра прочли бы мусор.
+    // (Крючок п.12 выше такие веса не берёт: GGML_TYPE_PA_Q4_K_T нет в его списке типов.)
+    if (op->src[0]->type == GGML_TYPE_PA_Q4_K_T) {
+        return ggml_metal_pa4_op_mul_mat(ctx, idx);
+    }
     const ggml_metal_device_props * props_dev = ggml_metal_device_get_props(ctx->dev);
 
     GGML_TENSOR_LOCALS( int32_t, ne0, op->src[0], ne);
diff --git a/src/ggml.c b/src/ggml.c
index b148c30..536f1bb 100644
--- a/src/ggml.c
+++ b/src/ggml.c
@@ -687,6 +687,14 @@ static const struct ggml_type_traits type_traits[GGML_TYPE_COUNT] = {
         .is_quantized             = false,
         .to_float                 = (ggml_to_float_t) dequantize_row_f8_e5m2,
     },
+    [GGML_TYPE_PA_Q4_K_T] = {
+        // PocketAgent п.13: только для Metal-ядра режима 7 — to_float нет намеренно: процессор
+        // не должен молча читать переставленные байты как обычный q4_K
+        .type_name                = "pa_q4_K_t",
+        .blck_size                = QK_K,
+        .type_size                = sizeof(block_q4_K),
+        .is_quantized             = true,
+    },
     [GGML_TYPE_Q1_0] = {
         .type_name                = "q1_0",
         .blck_size                = QK1_0,
PA_GGML_V13B_PATCH
  grep -q GGML_TYPE_PA_Q4_K_T "$src/ggml/include/ggml.h" \
    && grep -q kernel_mul_mm_pa4 "$src/ggml/src/ggml-metal/ggml-metal-ops.cpp" \
    && grep -q GGML_METAL_NAX7_TILE "$src/ggml/src/ggml-metal/ggml-metal-ops.cpp" \
    && grep -q pa4_eligible "$src/src/model_loader.cpp" \
    && grep -q sd_pa4_bench_section "$src/src/pa_kernel_bench.cpp" \
    && grep -q pa_run7 "$src/src/pa_kernel_bench.cpp" \
    && [ -f "$src/src/pa_repack.h" ] && [ -f "$src/src/pa_kernel_bench_b.cpp" ] \
    || { echo "❌ правка п.13 (режим 7) не на месте" >&2; return 1; }
  # <<< патч 13 (инженер B)
  # >>> патч 14
  # 14) Поддержка FLUX.3 Image Klein (и Klein Base) — ПЕРЕНОС одного коммита апстрима
  #     8cd731e7b4 «feat: add FLUX.3 Image Klein and Klein Base support (#2143)», 15.10.2026.
  #     Почему перенос, а не подъём версии: между нашим 88411ef и этим коммитом 60 правок
  #     апстрима (обновление ggml, переделка RoPE и кэшей, новый батч CFG) — наши п.1–13
  #     (~6 500 строк, ядра нейроблоков, выселение весов) пришлось бы переналагать заново
  #     и перемеривать Qwen-Image на телефоне. Сам FLUX.3 — 9 файлов, ~330 строк, и всё,
  #     на что он опирается (flux.hpp, dit.hpp, rope.hpp, ggml_block.hpp, соглашение
  #     «знак шага = промежуточный вызов» в семплерах), на 88411ef совпадает с апстримом
  #     (сверено по исходникам обоих коммитов 16.10.2026).
  #     Что делает: новая версия VERSION_FLUX3 (узнаётся по весам emb_in.image + txt_mode_blocks),
  #     рисующая часть flux3.hpp, энкодер — Qwen3-VL (4B) со слоями 4..32 и позициями mrope,
  #     VAE от FLUX.2, своё расписание шума (сдвиг 6,93), «целевой шаг» для дистиллированной.
  #     Ветки Qwen-Image 2.1 и FLUX.2 klein не тронуты: все правки — новые ветки «if flux3».
  #     Новый файл убираем заранее: checkout его не трогает, и повторное наложение упало бы.
  rm -f "$src/src/model/diffusion/flux3.hpp"
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V14_FLUX3_PATCH' \
    || { echo "❌ правка sd.cpp п.14 (FLUX.3) не легла — см. $log" >&2; return 1; }
diff --git a/src/model.h b/src/model.h
--- a/src/model.h
+++ b/src/model.h
@@ -62,6 +62,7 @@
     VERSION_SENSENOVA_U1_5,
     VERSION_LLADA_IMAGE,
     VERSION_ESRGAN,
+    VERSION_FLUX3,
     VERSION_COUNT,
 };
 
@@ -114,6 +115,10 @@
     return false;
 }
 
+static inline bool sd_version_is_flux3(SDVersion version) {
+    return version == VERSION_FLUX3;
+}
+
 static inline bool sd_version_is_flux2(SDVersion version) {
     if (version == VERSION_FLUX2 || version == VERSION_FLUX2_KLEIN) {
         return true;
@@ -268,7 +273,13 @@
 }
 
 static inline bool sd_version_uses_flux2_vae(SDVersion version) {
-    if (sd_version_is_flux2(version) || sd_version_is_ernie_image(version) || sd_version_is_lens(version) || sd_version_is_ideogram4(version) || sd_version_is_sefi_image(version) || sd_version_is_llada_image(version)) {
+    if (sd_version_is_flux2(version) ||
+        sd_version_is_flux3(version) ||
+        sd_version_is_ernie_image(version) ||
+        sd_version_is_lens(version) ||
+        sd_version_is_ideogram4(version) ||
+        sd_version_is_sefi_image(version) ||
+        sd_version_is_llada_image(version)) {
         return true;
     }
     return false;
@@ -299,6 +310,7 @@
 static inline bool sd_version_is_dit(SDVersion version) {
     if (sd_version_is_flux(version) ||
         sd_version_is_flux2(version) ||
+        sd_version_is_flux3(version) ||
         sd_version_is_ltxav(version) ||
         sd_version_is_minimax_h3(version) ||
         sd_version_is_sd3(version) ||
diff --git a/src/model_loader.cpp b/src/model_loader.cpp
--- a/src/model_loader.cpp
+++ b/src/model_loader.cpp
@@ -431,6 +431,11 @@
 
 SDVersion ModelLoader::get_sd_version() const {
     TensorStorage token_embedding_weight, input_block_weight, context_ebedding_weight;
+
+    if (tensor_storage_map.find("model.diffusion_model.emb_in.image.weight") != tensor_storage_map.end() &&
+        tensor_storage_map.find("model.diffusion_model.txt_mode_blocks.0.q_proj.weight") != tensor_storage_map.end()) {
+        return VERSION_FLUX3;
+    }
 
     bool has_multiple_encoders = false;
     bool is_unet               = false;
diff --git a/src/runtime/denoiser.hpp b/src/runtime/denoiser.hpp
--- a/src/runtime/denoiser.hpp
+++ b/src/runtime/denoiser.hpp
@@ -1400,6 +1400,29 @@
     }
 };
 
+struct Flux3FlowDenoiser : public FluxFlowDenoiser {
+    float t_to_sigma(float t) override {
+        float u = (t + 1.f) / TIMESTEPS;
+        return shift * u / (1.f + (shift - 1.f) * u);
+    }
+
+    std::vector<float> get_sigmas(uint32_t n, int image_seq_len, scheduler_t scheduler_type, SDVersion version, const char* extra_sample_args = nullptr) override {
+        if (scheduler_type != DISCRETE_SCHEDULER) {
+            return Denoiser::get_sigmas(n, image_seq_len, scheduler_type, version, extra_sample_args);
+        }
+        if (n == 0) {
+            return {};
+        }
+        std::vector<float> sigmas;
+        sigmas.reserve(n + 1);
+        for (uint32_t i = 0; i <= n; ++i) {
+            float u = 1.f - static_cast<float>(i) / n;
+            sigmas.push_back(shift * u / (1.f + (shift - 1.f) * u));
+        }
+        return sigmas;
+    }
+};
+
 struct SefiFlowDenoiser;
 
 struct SefiFlowDenoiser : public FluxFlowDenoiser {
diff --git a/src/pipeline/diffusion_engine.cpp b/src/pipeline/diffusion_engine.cpp
--- a/src/pipeline/diffusion_engine.cpp
+++ b/src/pipeline/diffusion_engine.cpp
@@ -105,6 +105,7 @@
     "SenseNova U1.5",
     "LLaDA-Image",
     "ESRGAN",
+    "Flux.3 Image Klein",
 };
 
 static_assert(VERSION_COUNT == sizeof(model_version_to_str) / sizeof(model_version_to_str[0]),
@@ -1379,6 +1380,9 @@
             } else {
                 default_flow_shift = 3.f;
             }
+        } else if (sd_version_is_flux3(version)) {
+            pred_type          = FLUX_FLOW_PRED;
+            default_flow_shift = 6.93f;
         } else if (sd_version_is_flux(version) ||
                    sd_version_is_flux2(version) ||
                    sd_version_is_longcat(version) ||
@@ -1442,7 +1446,11 @@
         }
         case FLUX_FLOW_PRED: {
             LOG_INFO("running in Flux FLOW mode");
-            denoiser = std::make_shared<FluxFlowDenoiser>();
+            if (sd_version_is_flux3(version)) {
+                denoiser = std::make_shared<Flux3FlowDenoiser>();
+            } else {
+                denoiser = std::make_shared<FluxFlowDenoiser>();
+            }
             break;
         }
         case SEFI_FLOW_PRED: {
@@ -2399,6 +2407,13 @@
         if (sd_version_is_hunyuan_video(version) && step + 1 < sigmas.size()) {
             hunyuan_timestep_r_tensor = sd::Tensor<float>::from_vector({sigmas[step + 1]});
         }
+        sd::Tensor<float> flux3_target_timestep;
+        if (version == VERSION_FLUX3) {
+            // The sign marks intermediate evaluations; the magnitude is the one-based step.
+            const size_t target_index = static_cast<size_t>(std::abs(step));
+            GGML_ASSERT(target_index > 0 && target_index < sigmas.size());
+            flux3_target_timestep = sd::Tensor<float>::from_vector({sigmas[target_index]});
+        }
         sd::Tensor<float> noised_input = x * c_in;
         if (apply_denoise_mask && (version == VERSION_WAN2_2_TI2V || sd_version_is_ltxav(version) || sd_version_is_lingbot_video(version))) {
             noised_input = noised_input * denoise_mask + sampling_init_latent * (1.0f - denoise_mask);
@@ -2474,6 +2489,8 @@
             } else if (sd_version_is_flux(version) || sd_version_is_flux2(version) || sd_version_is_longcat(version) || sd_version_is_sefi_image(version)) {
                 diffusion_params.extra = FluxDiffusionExtra{&guidance_tensor,
                                                             local_skip_layers};
+            } else if (sd_version_is_flux3(version)) {
+                diffusion_params.extra = Flux3DiffusionExtra{flux3_target_timestep.empty() ? nullptr : &flux3_target_timestep};
             } else if (version == VERSION_QWEN_IMAGE_2_1) {
                 diffusion_params.extra = QwenImage21DiffusionExtra{&condition.c_token_types};
             } else if (sd_version_is_anima(version)) {
@@ -2881,6 +2898,8 @@
         return "longcat";
     } else if (sd_version_is_flux(version)) {
         return "flux_kontext";
+    } else if (sd_version_is_flux3(version)) {
+        return "flux2";
     } else if (sd_version_is_flux2(version) || sd_version_is_sefi_image(version)) {
         return "flux2";
     } else if (version == VERSION_QWEN_IMAGE_LAYERED) {
diff --git a/src/pipeline/model_builders.cpp b/src/pipeline/model_builders.cpp
--- a/src/pipeline/model_builders.cpp
+++ b/src/pipeline/model_builders.cpp
@@ -14,6 +14,7 @@
 #include "model/diffusion/control.hpp"
 #include "model/diffusion/ernie_image.hpp"
 #include "model/diffusion/flux.hpp"
+#include "model/diffusion/flux3.hpp"
 #include "model/diffusion/hidream_o1.hpp"
 #include "model/diffusion/hunyuan.hpp"
 #include "model/diffusion/ideogram4.hpp"
@@ -168,6 +169,11 @@
                                                                   version,
                                                                   weight_manager,
                                                                   sd_ctx_params->model_args);
+        } else if (sd_version_is_flux3(version)) {
+            result.conditioner = std::make_shared<LLMEmbedder>(ctx.backends.runtime_backend(SDBackendModule::TE),
+                                                               tensor_storage_map, version, "", false, weight_manager, tokenizers);
+            result.diffusion   = std::make_shared<Flux3::Flux3Runner>(ctx.backends.runtime_backend(SDBackendModule::DIFFUSION),
+                                                                    tensor_storage_map, "model.diffusion_model", weight_manager);
         } else if (sd_version_is_flux2(version) || sd_version_is_sefi_image(version)) {
             bool is_chroma     = false;
             result.conditioner = std::make_shared<LLMEmbedder>(ctx.backends.runtime_backend(SDBackendModule::TE),
diff --git a/src/conditioning/conditioner.hpp b/src/conditioning/conditioner.hpp
--- a/src/conditioning/conditioner.hpp
+++ b/src/conditioning/conditioner.hpp
@@ -1980,6 +1980,7 @@
         } else if (sd_version_is_pid(version)) {
             arch = LLM::LLMArch::GEMMA2_2B;
         } else if (version == VERSION_QWEN_IMAGE_2_1 ||
+                   sd_version_is_flux3(version) ||
                    sd_version_is_lingbot_video(version) ||
                    sd_version_is_ideogram4(version) ||
                    sd_version_is_boogu_image(version) ||
@@ -2159,6 +2160,9 @@
             weights.insert(weights.end(), curr_tokens.size(), curr_weight);
         }
 
+        if (sd_version_is_flux3(version)) {
+            min_length = std::min(max_length, ((tokens.size() + 79) / 80) * 80);
+        }
         std::vector<float> mask;
         tokenizer->pad_tokens(tokens, &weights, &mask, min_length, max_length);
 
@@ -2210,6 +2214,15 @@
             }
         }
 
+        sd::Tensor<int32_t> position_ids;
+        if (sd_version_is_flux3(version)) {
+            position_ids = sd::Tensor<int32_t>::zeros({static_cast<int64_t>(tokens.size() * 4)});
+            for (size_t axis = 0; axis < 4; ++axis) {
+                for (size_t i = 0; i < tokens.size(); ++i) {
+                    position_ids[axis * tokens.size() + i] = mask[i] == 0.f ? 1 : static_cast<int32_t>(i);
+                }
+            }
+        }
         auto hidden_states = llm->compute(n_threads,
                                           input_ids,
                                           attention_mask,
@@ -2218,7 +2231,8 @@
                                           false,
                                           false,
                                           deepstack_image_embeds,
-                                          image_grids);
+                                          image_grids,
+                                          position_ids);
         if (hidden_states.empty()) {
             LOG_ERROR("LLM prompt encoding failed");
             return {};
@@ -2973,6 +2987,15 @@
 
                 prompt += "<|im_end|>\n<|im_start|>assistant\n";
             }
+        } else if (sd_version_is_flux3(version)) {
+            prompt_template_encode_start_idx = 0;
+            max_length                       = 4096;
+            out_layers                       = {4, 8, 12, 16, 20, 24, 28, 32};
+            prompt                           = "<|im_start|>user\n";
+            prompt_attn_range.first          = static_cast<int>(prompt.size());
+            prompt += conditioner_params.text;
+            prompt_attn_range.second = static_cast<int>(prompt.size());
+            prompt += "<|im_end|>\n<|im_start|>assistant\n";
         } else if (version == VERSION_FLUX2_KLEIN) {
             prompt_template_encode_start_idx = 0;
             min_length                       = 512;
diff --git a/src/model/diffusion/flux3.hpp b/src/model/diffusion/flux3.hpp
new file mode 100644
--- /dev/null
+++ b/src/model/diffusion/flux3.hpp
@@ -0,0 +1,260 @@
+// PocketAgent п.14: FLUX.3 Image Klein. Файл перенесён ДОСЛОВНО из апстрима
+// leejet/stable-diffusion.cpp 8cd731e7b4 (#2143, 15.10.2026) — всё, на что он опирается
+// (flux.hpp, dit.hpp, rope.hpp, ggml_block), на нашем 88411ef совпадает с апстримом. Не правим,
+// чтобы следующий подъём версии лёг без конфликтов.
+#ifndef __SD_MODEL_DIFFUSION_FLUX3_HPP__
+#define __SD_MODEL_DIFFUSION_FLUX3_HPP__
+
+#include "model/diffusion/flux.hpp"
+
+namespace Flux3 {
+
+    struct Flux3Config {
+        int64_t hidden_size = 3072;
+        int64_t context_dim = 20480;
+        int64_t channels    = 128;
+        int64_t mlp_dim     = 9216;
+        int heads           = 24;
+        int depth           = 5;
+        int single_depth    = 28;
+        bool flow_map       = false;
+
+        static Flux3Config detect_from_weights(const String2TensorStorage& tensors, const std::string& prefix) {
+            Flux3Config config;
+            int depth = 0, single_depth = 0;
+            bool detected = false;
+            for (const auto& [name, tensor] : tensors) {
+                if (!starts_with(name, prefix + ".")) {
+                    continue;
+                }
+                std::string key = name.substr(prefix.size() + 1);
+                if (key == "txt_in.weight") {
+                    detected           = true;
+                    config.context_dim = tensor.ne[0];
+                    config.hidden_size = tensor.ne[1];
+                } else if (key == "emb_in.image.weight") {
+                    config.channels = tensor.ne[0];
+                } else if (key == "single_blocks.0.mlp_out.weight") {
+                    config.mlp_dim = tensor.ne[0];
+                } else if (key == "ref_time_in.in_layer.weight") {
+                    config.flow_map = true;
+                }
+                if (starts_with(key, "txt_mode_blocks.")) {
+                    depth = std::max(depth, atoi(key.substr(16).c_str()) + 1);
+                }
+                if (starts_with(key, "single_blocks.")) {
+                    single_depth = std::max(single_depth, atoi(key.substr(14).c_str()) + 1);
+                }
+            }
+            if (depth > 0)
+                config.depth = depth;
+            if (single_depth > 0)
+                config.single_depth = single_depth;
+            config.heads = static_cast<int>(config.hidden_size / 128);
+            if (detected) {
+                LOG_VERBOSE("flux3: hidden_size = %" PRId64 ", context_dim = %" PRId64 ", depth = %d, single_depth = %d, flow_map = %s",
+                            config.hidden_size, config.context_dim, config.depth, config.single_depth, config.flow_map ? "true" : "false");
+            }
+            return config;
+        }
+    };
+
+    static ggml_tensor* token_slice(ggml_context* ctx, ggml_tensor* x, int64_t start, int64_t length) {
+        return ggml_view_3d(ctx, x, x->ne[0], length, x->ne[2], x->nb[1], x->nb[2], start * x->nb[1]);
+    }
+
+    struct Block : public GGMLBlock {
+        int heads;
+
+        Block(const Flux3Config& config)
+            : heads(config.heads) {
+            for (const auto* name : {"q_proj", "k_proj", "v_proj", "attn_out"}) {
+                blocks[name] = std::make_shared<Linear>(config.hidden_size, config.hidden_size, false);
+            }
+            blocks["mlp_in"]  = std::make_shared<Linear>(config.hidden_size, 2 * config.mlp_dim, false);
+            blocks["mlp_out"] = std::make_shared<Linear>(config.mlp_dim, config.hidden_size, false);
+            blocks["norm"]    = std::make_shared<Flux::QKNorm>(config.hidden_size / heads);
+        }
+
+        ggml_tensor* linear(GGMLRunnerContext* ctx, const std::string& name, ggml_tensor* x) {
+            return std::dynamic_pointer_cast<Linear>(blocks[name])->forward(ctx, x);
+        }
+
+        ggml_tensor* forward(GGMLRunnerContext* ctx, ggml_tensor* x, ggml_tensor* pe, const std::vector<Flux::ModulationOut>& mods, const std::vector<int64_t>& lengths) {
+            auto gc            = ctx->ggml_ctx;
+            ggml_tensor* x_mod = nullptr;
+            int64_t offset     = 0;
+            for (size_t i = 0; i < lengths.size(); ++i) {
+                auto part = token_slice(gc, x, offset, lengths[i]);
+                part      = Flux::modulate(gc, ggml_norm(gc, part, 1e-6f), mods[i].shift, mods[i].scale);
+                x_mod     = x_mod ? ggml_concat(gc, x_mod, part, 1) : part;
+                offset += lengths[i];
+            }
+            auto split = [&](ggml_tensor* v) {
+                return ggml_reshape_4d(gc, v, x->ne[0] / heads, heads, x->ne[1], x->ne[2]);
+            };
+            auto norm        = std::dynamic_pointer_cast<Flux::QKNorm>(blocks["norm"]);
+            auto q           = norm->query_norm(ctx, split(linear(ctx, "q_proj", x_mod)));
+            auto k           = norm->key_norm(ctx, split(linear(ctx, "k_proj", x_mod)));
+            auto v           = split(linear(ctx, "v_proj", x_mod));
+            auto attn        = Rope::attention(ctx, q, k, v, pe, nullptr);
+            auto mlp         = ggml_ext_silu_act(gc, linear(ctx, "mlp_in", x_mod));
+            auto update      = ggml_add(gc, linear(ctx, "attn_out", attn), linear(ctx, "mlp_out", mlp));
+            ggml_tensor* out = nullptr;
+            offset           = 0;
+            for (size_t i = 0; i < lengths.size(); ++i) {
+                auto part = ggml_mul(gc, token_slice(gc, update, offset, lengths[i]), mods[i].gate);
+                part      = ggml_add(gc, token_slice(gc, x, offset, lengths[i]), part);
+                out       = out ? ggml_concat(gc, out, part, 1) : part;
+                offset += lengths[i];
+            }
+            return out;
+        }
+    };
+
+    struct Model : public GGMLBlock {
+        Flux3Config config;
+
+        Model(const Flux3Config& config)
+            : config(config) {
+            blocks["txt_in"]  = std::make_shared<Linear>(config.context_dim, config.hidden_size, false);
+            blocks["time_in"] = std::make_shared<Flux::MLPEmbedder>(256, config.hidden_size, false);
+            if (config.flow_map) {
+                blocks["ref_time_in"] = std::make_shared<Flux::MLPEmbedder>(256, config.hidden_size, false);
+            }
+            for (const std::string mode : {"image", "image_cond", "txt"}) {
+                blocks["early_stream_modulations." + mode]  = std::make_shared<Flux::Modulation>(config.hidden_size, false, false);
+                blocks["single_stream_modulations." + mode] = std::make_shared<Flux::Modulation>(config.hidden_size, false, false);
+                const std::string base                      = mode == "txt" ? "txt_mode_blocks." : "content_mode_blocks." + mode + ".";
+                for (int i = 0; i < config.depth; ++i) {
+                    blocks[base + std::to_string(i)] = std::make_shared<Block>(config);
+                }
+                if (mode != "txt") {
+                    blocks["emb_in." + mode] = std::make_shared<Linear>(config.channels, config.hidden_size, false);
+                }
+            }
+            for (int i = 0; i < config.single_depth; ++i) {
+                blocks["single_blocks." + std::to_string(i)] = std::make_shared<Block>(config);
+            }
+            blocks["final_layer.image"] = std::make_shared<Flux::LastLayer>(config.hidden_size, 1, config.channels, false, false);
+        }
+
+        ggml_tensor* forward(GGMLRunnerContext* ctx, ggml_tensor* image, ggml_tensor* text, ggml_tensor* reference, ggml_tensor* timestep, ggml_tensor* zero, ggml_tensor* target, ggml_tensor* pe) {
+            auto gc             = ctx->ggml_ctx;
+            const int64_t width = image->ne[0], height = image->ne[1];
+            auto time_in   = std::dynamic_pointer_cast<Flux::MLPEmbedder>(blocks["time_in"]);
+            auto image_vec = time_in->forward(ctx, ggml_ext_timestep_embedding(gc, timestep, 256, 10000, 1000.f));
+            auto clean_vec = time_in->forward(ctx, ggml_ext_timestep_embedding(gc, zero, 256, 10000, 1000.f));
+            if (config.flow_map) {
+                auto ref_time = std::dynamic_pointer_cast<Flux::MLPEmbedder>(blocks["ref_time_in"]);
+                auto ref_vec  = ref_time->forward(ctx, ggml_ext_timestep_embedding(gc, target, 256, 10000, 1000.f));
+                image_vec     = ggml_add(gc, image_vec, ref_vec);
+                clean_vec     = ggml_add(gc, clean_vec, ref_vec);
+            }
+            std::vector<std::string> modes{"image"};
+            std::vector<ggml_tensor*> inputs{DiT::patchify(gc, image, 1, 1)};
+            if (reference) {
+                modes.push_back("image_cond");
+                inputs.push_back(reference);
+            }
+            modes.push_back("txt");
+            inputs.push_back(text);
+            std::vector<Flux::ModulationOut> single_mods;
+            std::vector<int64_t> lengths;
+            ggml_tensor* joint = nullptr;
+            int64_t offset     = 0;
+            for (size_t m = 0; m < modes.size(); ++m) {
+                const auto& mode = modes[m];
+                auto vec         = m == 0 ? image_vec : clean_vec;
+                auto early       = std::dynamic_pointer_cast<Flux::Modulation>(blocks["early_stream_modulations." + mode])->forward(ctx, vec)[0];
+                single_mods.push_back(std::dynamic_pointer_cast<Flux::Modulation>(blocks["single_stream_modulations." + mode])->forward(ctx, vec)[0]);
+                lengths.push_back(inputs[m]->ne[1]);
+                auto h                 = std::dynamic_pointer_cast<Linear>(blocks[mode == "txt" ? "txt_in" : "emb_in." + mode])->forward(ctx, inputs[m]);
+                auto mode_pe           = ggml_view_4d(gc, pe, 2, 2, 64, lengths.back(), pe->nb[1], pe->nb[2], pe->nb[3], offset * pe->nb[3]);
+                const std::string base = mode == "txt" ? "txt_mode_blocks." : "content_mode_blocks." + mode + ".";
+                for (int i = 0; i < config.depth; ++i) {
+                    h = std::dynamic_pointer_cast<Block>(blocks[base + std::to_string(i)])->forward(ctx, h, mode_pe, {early}, {lengths.back()});
+                }
+                joint = joint ? ggml_concat(gc, joint, h, 1) : h;
+                offset += lengths.back();
+            }
+            for (int i = 0; i < config.single_depth; ++i) {
+                joint = std::dynamic_pointer_cast<Block>(blocks["single_blocks." + std::to_string(i)])->forward(ctx, joint, pe, single_mods, lengths);
+            }
+            auto out = std::dynamic_pointer_cast<Flux::LastLayer>(blocks["final_layer.image"])->forward(ctx, token_slice(gc, joint, 0, lengths[0]), image_vec);
+            return DiT::unpatchify(gc, out, height, width, 1, 1);
+        }
+    };
+
+    struct Flux3Runner : public DiffusionModelRunner {
+        Flux3Config config;
+        Model model;
+        std::vector<float> pe_values;
+        sd::Tensor<float> zero = sd::Tensor<float>::zeros({1});
+
+        Flux3Runner(ggml_backend_t backend, const String2TensorStorage& tensors, const std::string& prefix, std::shared_ptr<RunnerWeightManager> weight_manager = nullptr)
+            : DiffusionModelRunner(backend, prefix, weight_manager),
+              config(Flux3Config::detect_from_weights(tensors, prefix)),
+              model(config) {
+            model.init(params_ctx, tensors, prefix);
+        }
+
+        std::string get_desc() override { return "flux3"; }
+        void get_param_tensors(std::map<std::string, ggml_tensor*>& tensors, const std::string& prefix) override {
+            model.get_param_tensors(tensors, prefix);
+        }
+
+        sd::Tensor<float> compute(int n_threads, const DiffusionParams& params) override {
+            if (params.ref_latents && params.ref_image_params.pass_to_dit && params.ref_latents->size() > 10) {
+                LOG_ERROR("FLUX.3 supports at most 10 reference images");
+                return {};
+            }
+            const auto* extra = diffusion_extra_as<Flux3DiffusionExtra>(params);
+            GGML_ASSERT(params.x && params.context && params.timesteps);
+            GGML_ASSERT(!config.flow_map || extra->target_timestep);
+            auto get_graph = [&]() {
+                auto gf   = new_graph_custom(FLUX_GRAPH_SIZE);
+                auto x    = make_input(*params.x);
+                auto text = make_input(*params.context);
+                GGML_ASSERT(x->ne[3] == 1 && text->ne[2] == 1);
+                Rope::Embedding embedding;
+                auto append_image = [&](int64_t w, int64_t h, float index) {
+                    embedding.positions.append_image(static_cast<int>(h), static_cast<int>(w), 1, 0.5f, 0.5f);
+                    for (int64_t y = 0; y < h; ++y) {
+                        for (int64_t x = 0; x < w; ++x) {
+                            embedding.ids.push_back({0.f, y * 0.5f, x * 0.5f, index});
+                        }
+                    }
+                };
+                append_image(x->ne[0], x->ne[1], 0.f);
+                ggml_tensor* references = nullptr;
+                if (params.ref_latents && params.ref_image_params.pass_to_dit) {
+                    int index = 0;
+                    for (const auto& ref : *params.ref_latents) {
+                        auto r = make_input(ref);
+                        append_image(r->ne[0], r->ne[1], -float(++index));
+                        r          = DiT::patchify(compute_ctx, r, 1, 1);
+                        references = references ? ggml_concat(compute_ctx, references, r, 1) : r;
+                    }
+                }
+                for (int64_t i = 0; i < text->ne[1]; ++i) {
+                    embedding.ids.push_back({0.f, 0.f, 0.f, static_cast<float>(i)});
+                }
+                embedding.positions.append_tokens(text->ne[1]);
+                embedding.values = Rope::embed_nd(embedding.ids, 1, 10000.f, {32, 32, 32, 32}, embedding.layout, &embedding.frequencies);
+                pe_values        = finish_rope_pe(std::move(embedding));
+                auto pe          = ggml_new_tensor_4d(compute_ctx, GGML_TYPE_F32, 2, 2, 64, pe_values.size() / 256);
+                set_backend_tensor_data(pe, pe_values.data());
+                auto runner_ctx = get_context();
+                auto out        = model.forward(&runner_ctx, x, text, references, make_input(*params.timesteps), make_input(zero),
+                                         config.flow_map ? make_input(*extra->target_timestep) : nullptr, pe);
+                ggml_build_forward_expand(gf, out);
+                return gf;
+            };
+            return restore_trailing_singleton_dims(GGMLRunner::compute(get_graph, n_threads, false), params.x->dim());
+        }
+    };
+
+}  // namespace Flux3
+
+#endif  // __SD_MODEL_DIFFUSION_FLUX3_HPP__
diff --git a/src/model/diffusion/model.hpp b/src/model/diffusion/model.hpp
--- a/src/model/diffusion/model.hpp
+++ b/src/model/diffusion/model.hpp
@@ -64,6 +64,10 @@
     float pulid_id_weight               = 1.0f;
 };
 
+struct Flux3DiffusionExtra {
+    const sd::Tensor<float>* target_timestep = nullptr;
+};
+
 struct AnimaDiffusionExtra {
     const sd::Tensor<int32_t>* t5_ids   = nullptr;
     const sd::Tensor<float>* t5_weights = nullptr;
@@ -145,6 +149,7 @@
                                           UNetDiffusionExtra,
                                           SkipLayerDiffusionExtra,
                                           FluxDiffusionExtra,
+                                          Flux3DiffusionExtra,
                                           AnimaDiffusionExtra,
                                           QwenImage21DiffusionExtra,
                                           WanDiffusionExtra,
diff --git a/src/model/te/llm.hpp b/src/model/te/llm.hpp
--- a/src/model/te/llm.hpp
+++ b/src/model/te/llm.hpp
@@ -2269,7 +2269,8 @@
                                  const DeepStackImageEmbeds& deepstack_image_embeds_tensor,
                                  const std::vector<ImageGrid>& image_grids,
                                  std::set<int> out_layers,
-                                 bool return_all_hidden_states = false) {
+                                 bool return_all_hidden_states           = false,
+                                 const sd::Tensor<int32_t>& position_ids = {}) {
             ggml_cgraph* gf        = new_graph_custom(LLM_GRAPH_SIZE);
             ggml_tensor* input_ids = make_input(input_ids_tensor);
             std::vector<std::pair<int, ggml_tensor*>> image_embeds;
@@ -2333,6 +2334,10 @@
                 }
             }
 
+            if (!position_ids.empty()) {
+                GGML_ASSERT(position_ids.numel() == static_cast<int64_t>(input_pos_vec.size()));
+                input_pos_vec = position_ids.values();
+            }
             auto input_pos = ggml_new_tensor_1d(compute_ctx,
                                                 GGML_TYPE_I32,
                                                 input_pos_vec.size());
@@ -2406,7 +2411,8 @@
                                   bool return_all_hidden_states                      = false,
                                   bool auto_runner_end                               = true,
                                   const DeepStackImageEmbeds& deepstack_image_embeds = {},
-                                  const std::vector<ImageGrid>& image_grids          = {}) {
+                                  const std::vector<ImageGrid>& image_grids          = {},
+                                  const sd::Tensor<int32_t>& position_ids            = {}) {
             auto get_graph = [&]() -> ggml_cgraph* {
                 return build_graph(input_ids,
                                    attention_mask,
@@ -2414,7 +2420,8 @@
                                    deepstack_image_embeds,
                                    image_grids,
                                    out_layers,
-                                   return_all_hidden_states);
+                                   return_all_hidden_states,
+                                   position_ids);
             };
             return restore_trailing_singleton_dims(GGMLRunner::compute(get_graph, n_threads, auto_runner_end),
                                                    input_ids.dim() + 1);
PA_SD_V14_FLUX3_PATCH
  grep -q VERSION_FLUX3 "$src/src/model.h" \
    && grep -q Flux3FlowDenoiser "$src/src/runtime/denoiser.hpp" \
    && grep -q "Flux3::Flux3Runner" "$src/src/pipeline/model_builders.cpp" \
    && [ -f "$src/src/model/diffusion/flux3.hpp" ] \
    || { echo "❌ правка п.14 (FLUX.3) не на месте" >&2; return 1; }
  # <<< патч 14
  # >>> патч 15
  # 15) v13: шаг FLUX.3 режется на куски по блокам. Первый запуск на телефоне 16.10.2026 (512²,
  #     «Быстро») упал через 14,9 с: «flux3 segment 1/1 (graph) failed during execution»,
  #     «Discarded (victim of GPU error/recovery)». Причина — в перенесённом flux3.hpp апстрима
  #     нет ни одного mark_graph_cut, план разреза пуст (has_cuts=false), и наш
  #     SD_FORCE_SEGMENTED_COMPUTE (п.2) без точек разреза ничего не режет: весь шаг рисования
  #     (5+5 блоков режимов и 28 общих) уходит в видеочип одним командным буфером, а iOS обрывает
  #     такие как зависшие — ровно то, что п.2 когда-то починил для Qwen-Image. Точки ставим как
  #     у Qwen-Image и FLUX.2: пролог (векторы времени), каждый блок режима, каждый общий блок;
  #     хвост (последний слой) — штатный «ggml_runner.final». Отдельной правкой, а не внутри п.14:
  #     п.14 — дословный апстрим, а это наше отступление от него, видно и откатывается само по себе.
  #     Qwen-Image 2.1 и FLUX.2 klein не задеты — меняется только flux3.hpp.
  git -C "$src" apply --whitespace=nowarn - >>"$log" 2>&1 <<'PA_SD_V15_FLUX3_CUTS_PATCH' \
    || { echo "❌ правка sd.cpp п.15 (разрез FLUX.3) не легла — см. $log" >&2; return 1; }
diff --git a/src/model/diffusion/flux3.hpp b/src/model/diffusion/flux3.hpp
--- a/src/model/diffusion/flux3.hpp
+++ b/src/model/diffusion/flux3.hpp
@@ -151,6 +151,13 @@
                 image_vec     = ggml_add(gc, image_vec, ref_vec);
                 clean_vec     = ggml_add(gc, clean_vec, ref_vec);
             }
+            // PocketAgent п.15: точки разреза шага (как flux.prelude у FLUX.2). Без них план разреза
+            // пуст и SD_FORCE_SEGMENTED_COMPUTE молча считает весь шаг одним командным буфером Metal —
+            // iOS обрывает его как зависший (телефон 16.10: «flux3 segment 1/1 (graph) failed»).
+            // Векторы времени — выход «пролога»: модуляции блоков считаются из них заново в каждом
+            // куске (1 токен, копейки), как у FLUX.2 с его общим vec.
+            sd::ggml_graph_cut::mark_graph_cut(image_vec, "flux3.prelude", "image_vec");
+            sd::ggml_graph_cut::mark_graph_cut(clean_vec, "flux3.prelude", "clean_vec");
             std::vector<std::string> modes{"image"};
             std::vector<ggml_tensor*> inputs{DiT::patchify(gc, image, 1, 1)};
             if (reference) {
@@ -174,12 +181,16 @@
                 const std::string base = mode == "txt" ? "txt_mode_blocks." : "content_mode_blocks." + mode + ".";
                 for (int i = 0; i < config.depth; ++i) {
                     h = std::dynamic_pointer_cast<Block>(blocks[base + std::to_string(i)])->forward(ctx, h, mode_pe, {early}, {lengths.back()});
+                    // Кусок = один блок, как у Qwen-Image (transformer_blocks.i) и FLUX.2 (double_blocks.i).
+                    // Имя группы своё у каждого режима: «image» и «image_cond» идут по одним номерам.
+                    sd::ggml_graph_cut::mark_graph_cut(h, "flux3." + base + std::to_string(i), "h");
                 }
                 joint = joint ? ggml_concat(gc, joint, h, 1) : h;
                 offset += lengths.back();
             }
             for (int i = 0; i < config.single_depth; ++i) {
                 joint = std::dynamic_pointer_cast<Block>(blocks["single_blocks." + std::to_string(i)])->forward(ctx, joint, pe, single_mods, lengths);
+                sd::ggml_graph_cut::mark_graph_cut(joint, "flux3.single_blocks." + std::to_string(i), "joint");
             }
             auto out = std::dynamic_pointer_cast<Flux::LastLayer>(blocks["final_layer.image"])->forward(ctx, token_slice(gc, joint, 0, lengths[0]), image_vec);
             return DiT::unpatchify(gc, out, height, width, 1, 1);
PA_SD_V15_FLUX3_CUTS_PATCH
  grep -q '"flux3.single_blocks."' "$src/src/model/diffusion/flux3.hpp" \
    || { echo "❌ правка п.15 (разрез FLUX.3) не на месте" >&2; return 1; }
  # <<< патч 15
  grep -q SD_FORCE_SEGMENTED_COMPUTE "$src/src/core/ggml_runner.cpp" \
    && grep -q SD_SEGMENT_TIMING "$src/src/core/ggml_runner.cpp" \
    && grep -q "run order" "$src/ggml/src/ggml-metal/ggml-metal-context.m" \
    && grep -q GGML_METAL_TENSOR_F16B "$src/ggml/src/ggml-metal/ggml-metal.metal" \
    && grep -q GGML_METAL_TENSOR_F16B "$src/ggml/src/ggml-metal/ggml-metal-device.m" \
    && grep -q tensor_f16b "$src/ggml/src/ggml-metal/ggml-metal-device.cpp" \
    && grep -q kernel_mul_mm_nax "$src/ggml/src/ggml-metal/ggml-metal.metal" \
    && grep -q pa_nax_pipeline "$src/ggml/src/ggml-metal/ggml-metal-device.cpp" \
    && grep -q sd_pa_kernel_stats "$src/include/stable-diffusion.h" \
    && grep -q ggml_metal_device_ensure_library "$src/ggml/src/ggml-metal/ggml-metal-context.m" \
    && [ -f "$src/src/pa_kernel_bench.cpp" ] \
    && grep -q SD_VAE_SEGMENTS "$src/src/model/vae/wan_vae.hpp" \
    && grep -q SD_KEEP_WEIGHTS "$src/src/core/ggml_runner.cpp" \
    && grep -q kernel_im2col_flat "$src/ggml/src/ggml-metal/ggml-metal.metal" \
    && grep -q kernel_pa_transpose_f32 "$src/ggml/src/ggml-metal/ggml-metal-ops.cpp" \
    && grep -q SD_PROFILE_BLOCK "$src/src/core/ggml_runner.cpp" \
    && grep -q SD_KEEP_ENCODER "$src/src/core/ggml_runner.cpp" \
    && grep -q pa_keep_rank "$src/src/model_manager.cpp" \
    && grep -q KBBLOCK "$src/src/pa_kernel_bench.cpp" \
    && grep -q pa_apply_rope "$src/src/model/diffusion/qwen_image_2_1.hpp" \
    && grep -q kernel_rope_pa_table_f32 "$src/ggml/src/ggml-metal/ggml-metal.metal" \
    && grep -q GGML_ROPE_TYPE_PA_TABLE "$src/ggml/src/ggml-cpu/ops.cpp" \
    && grep -q pa_total_weight_bytes "$src/src/model_manager.cpp" \
    || { echo "❌ правки движка не на месте" >&2; return 1; }
  echo "  правки движка наложены"
}

# Сборка sdcpp.xcframework. Итог — $1/sdcpp.xcframework + метка версии.
# Журнал целиком — $1/sd-build/build.log (там и искать причину, если упало).
pa_build_sd_framework() {  # pa_build_sd_framework <папка-кэша>
  out="${1:?}"
  work="$out/sd-build"
  log="$work/build.log"
  mkdir -p "$work" || return 1
  : > "$log"
  echo "  журнал сборки: $log"

  # cmake: на машинах его нет, а Homebrew ставить не хотим. Берём переносную
  # сборку Kitware. ⚠️ Из CMake.app вынимаем Contents в папку БЕЗ «.app»:
  # из папки с «.app» через наш фоновый ssh-вход ничего не запускается —
  # процесс молча висит.
  cm="$out/cmake-$PA_CMAKE_VERSION/bin/cmake"
  if [ ! -x "$cm" ]; then
    echo "  качаю cmake $PA_CMAKE_VERSION"
    t="$(mktemp -d /tmp/pa-cmake.XXXXXXXX)" || return 1
    if ! curl -sL --retry 3 -o "$t/c.tgz" \
        "https://github.com/Kitware/CMake/releases/download/v$PA_CMAKE_VERSION/cmake-$PA_CMAKE_VERSION-macos-universal.tar.gz" \
       || ! tar xzf "$t/c.tgz" -C "$t"; then
      echo "❌ Не скачался cmake." >&2; rm -rf "$t"; return 1
    fi
    rm -rf "$out/cmake-$PA_CMAKE_VERSION"
    mv "$t/cmake-$PA_CMAKE_VERSION-macos-universal/CMake.app/Contents" "$out/cmake-$PA_CMAKE_VERSION" \
      || { rm -rf "$t"; return 1; }
    rm -rf "$t"
    [ -x "$cm" ] || { echo "❌ cmake распаковался без бинарника." >&2; return 1; }
  fi

  src="$work/src"
  if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$PA_SD_COMMIT" ]; then
    echo "  качаю stable-diffusion.cpp @ $PA_SD_COMMIT"
    rm -rf "$src"
    { git init -q "$src" \
      && git -C "$src" remote add origin https://github.com/leejet/stable-diffusion.cpp \
      && git -C "$src" fetch -q --depth 1 origin "$PA_SD_COMMIT" \
      && git -C "$src" checkout -q FETCH_HEAD \
      && git -C "$src" submodule update -q --init --depth 1 ggml; } >>"$log" 2>&1 \
      || { echo "❌ Не скачались исходники stable-diffusion.cpp — см. $log" >&2; return 1; }
  fi

  pa_sd_apply_patches "$src" "$log" || return 1

  bld="$work/build-ios"
  rm -rf "$bld"
  # ⚠️ nice: на мини за машиной сидит человек, сборка не должна вешать ему экран.
  echo "  cmake: настройка"
  nice -n 10 "$cm" -S "$src" -B "$bld" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_OSX_SYSROOT=iphoneos \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_OBJC_FLAGS="-DGGMLMetalClass=PASDGGMLMetalClass" \
      -DCMAKE_OBJCXX_FLAGS="-DGGMLMetalClass=PASDGGMLMetalClass" \
      -DSD_METAL=ON -DSD_BUILD_EXAMPLES=OFF -DSD_WEBP=OFF -DSD_WEBM=OFF \
      -DSD_BUILD_SHARED_LIBS=OFF -DBUILD_SHARED_LIBS=OFF \
      -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
      -DGGML_BUILD_TESTS=OFF -DGGML_BUILD_EXAMPLES=OFF \
      >>"$log" 2>&1 || { echo "❌ cmake не настроился — см. $log" >&2; tail -20 "$log" >&2; return 1; }

  echo "  cmake: сборка (долго)"
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  nice -n 10 "$cm" --build "$bld" --config Release -j "$jobs" >>"$log" 2>&1 \
    || { echo "❌ stable-diffusion.cpp не собрался — см. $log" >&2; grep -E 'error:' "$log" | head -5 >&2; return 1; }

  # Склейка в динамический фреймворк. Наружу — только функции sd.cpp.
  fw="$work/fw/sdcpp.framework"
  rm -rf "$work/fw"
  mkdir -p "$fw/Headers" "$fw/Modules" || return 1
  cp "$src/include/stable-diffusion.h" "$fw/Headers/" || return 1
  printf '%s\n' 'framework module sdcpp {' '  umbrella header "stable-diffusion.h"' \
    '  export *' '  module * { export * }' '}' > "$fw/Modules/module.modulemap"
  printf '%s\n' '_sd_*' '_new_sd_ctx' '_free_sd_ctx' '_generate_image' \
    '_free_sd_images' '_free_sd_audio' '_str_to_*' \
    '_sample_method_to_str' '_scheduler_to_str' > "$work/exports.txt"
  libs="$(find "$bld" -name '*.a' | tr '\n' ' ')"
  [ -n "$libs" ] || { echo "❌ после сборки нет ни одной библиотеки .a" >&2; return 1; }
  sdk="$(xcrun --sdk iphoneos --show-sdk-path)" || return 1
  # shellcheck disable=SC2086
  xcrun --sdk iphoneos clang++ -dynamiclib -arch arm64 \
      -target arm64-apple-ios17.0 -isysroot "$sdk" \
      -install_name @rpath/sdcpp.framework/sdcpp \
      -Wl,-all_load $libs \
      -Wl,-exported_symbols_list,"$work/exports.txt" \
      -Wl,-dead_strip \
      -framework Foundation -framework Metal -framework MetalKit \
      -framework Accelerate -lc++ \
      -o "$fw/sdcpp" >>"$log" 2>&1 \
    || { echo "❌ не склеился фреймворк — см. $log" >&2; tail -15 "$log" >&2; return 1; }
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleExecutable</key><string>sdcpp</string>' \
    '<key>CFBundleIdentifier</key><string>com.example.sdcpp</string>' \
    '<key>CFBundleName</key><string>sdcpp</string>' \
    '<key>CFBundlePackageType</key><string>FMWK</string>' \
    '<key>CFBundleShortVersionString</key><string>1.0</string>' \
    '<key>CFBundleVersion</key><string>1</string>' \
    '<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>' \
    '<key>MinimumOSVersion</key><string>17.0</string>' \
    '</dict></plist>' > "$fw/Info.plist"

  # Доказательство фактом, а не верой: ни одного ggml_* наружу, API на месте,
  # класс ObjC переименован. Любое нарушение — сборку не принимаем.
  leaked="$(nm -gU "$fw/sdcpp" | grep -c ' _ggml_' || true)"
  api="$(nm -gU "$fw/sdcpp" | grep -c ' _generate_image$' || true)"
  oldcls="$(nm "$fw/sdcpp" | grep -c 'OBJC_CLASS_\$_GGMLMetalClass$' || true)"
  echo "  проверка символов: наружу ggml_* — $leaked, generate_image — $api, старый класс ObjC — $oldcls" | tee -a "$log"
  if [ "$leaked" != "0" ] || [ "$api" != "1" ] || [ "$oldcls" != "0" ]; then
    echo "❌ фреймворк не прошёл проверку символов — не принимаю" >&2
    return 1
  fi

  rm -rf "$work/sdcpp.xcframework"
  xcodebuild -create-xcframework -framework "$fw" -output "$work/sdcpp.xcframework" >>"$log" 2>&1 \
    || { echo "❌ не собрался xcframework — см. $log" >&2; return 1; }
  rm -rf "$out/sdcpp.xcframework"
  mv "$work/sdcpp.xcframework" "$out/sdcpp.xcframework" || return 1
  printf '%s\n' "$PA_SD_VERSION" > "$out/.pa-sd-version"
  echo "  движок картинок собран: $(du -sh "$out/sdcpp.xcframework" | cut -f1)"
}
