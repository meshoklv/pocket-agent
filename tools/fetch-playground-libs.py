#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Сборщик «полки библиотек» для площадки Pocket Agent.

Качает выпуски (не мастер-ветку) с jsDelivr/esm.sh, проверяет каждый файл
(не html, не пустой, модуль без внешних импортов), кладёт рядом лицензию
и пишет опись manifest.json.
"""
import concurrent.futures
import datetime
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "PocketAgent", "Resources", "PlaygroundLib")
UA = {"User-Agent": "curl/8.5.0"}
# Дата сборки полки. Её видит чужой код в manifest.json.
GEN_DATE = os.environ.get("SHELF_DATE") or datetime.date.today().isoformat()


def get(url, timeout=180):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def jsd(pkg, ver, path):
    return f"https://cdn.jsdelivr.net/npm/{pkg}@{ver}/{path.lstrip('/')}"


# ── описание полки ────────────────────────────────────────────────────────────
# files: (локальное имя, форма, глобальная переменная|None, откуда)
#   откуда: ("npm", "путь/в/пакете") | ("url", "полный адрес")
LIBS = [
    dict(
        id="three", pkg="three", version="0.147.0", name="three.js", kind="3d",
        hint="трёхмерная графика на видеокарте (WebGL)",
        bare=["three", "three/addons/", "three/examples/jsm/"],
        cdn=["cdn.jsdelivr.net/npm/three", "unpkg.com/three",
             "cdnjs.cloudflare.com/ajax/libs/three.js", "esm.sh/three",
             "cdn.skypack.dev/three"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("three.min.js", "umd", "THREE", ("npm", "build/three.min.js")),
            ("three.module.min.js", "module", None, ("npm", "build/three.module.min.js")),
            ("examples/jsm/controls/OrbitControls.js", "module", None,
             ("npm", "examples/jsm/controls/OrbitControls.js")),
            ("examples/js/controls/OrbitControls.js", "umd", "THREE.OrbitControls",
             ("npm", "examples/js/controls/OrbitControls.js")),
        ],
    ),
    dict(
        id="phaser", pkg="phaser", version="3.90.0", name="Phaser", kind="game",
        hint="движок двумерных игр: сцены, спрайты, физика, ввод",
        bare=["phaser"],
        cdn=["cdn.jsdelivr.net/npm/phaser", "unpkg.com/phaser",
             "cdnjs.cloudflare.com/ajax/libs/phaser", "esm.sh/phaser",
             "cdn.skypack.dev/phaser"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("phaser.min.js", "umd", "Phaser", ("npm", "dist/phaser.min.js")),
            ("phaser.esm.min.js", "module", None, ("npm", "dist/phaser.esm.min.js")),
        ],
    ),
    dict(
        id="pixi.js", pkg="pixi.js", version="8.20.1", name="PixiJS", kind="game",
        hint="быстрая двумерная графика на видеокарте (внимание: в 8-й версии сначала await app.init())",
        bare=["pixi.js"],
        cdn=["cdn.jsdelivr.net/npm/pixi.js", "unpkg.com/pixi.js",
             "cdnjs.cloudflare.com/ajax/libs/pixi.js", "esm.sh/pixi.js",
             "cdn.skypack.dev/pixi.js"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("pixi.min.js", "umd", "PIXI", ("npm", "dist/pixi.min.js")),
            ("pixi.min.mjs", "module", None, ("npm", "dist/pixi.min.mjs")),
        ],
    ),
    dict(
        id="matter-js", pkg="matter-js", version="0.20.0", name="Matter.js", kind="physics",
        hint="плоская физика: тела, столкновения, пружины",
        bare=["matter-js"],
        cdn=["cdn.jsdelivr.net/npm/matter-js", "unpkg.com/matter-js",
             "cdnjs.cloudflare.com/ajax/libs/matter-js", "esm.sh/matter-js",
             "cdn.skypack.dev/matter-js"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("matter.min.js", "umd", "Matter", ("npm", "build/matter.min.js")),
            ("matter.module.js", "module", None,
             ("url", "https://cdn.jsdelivr.net/npm/matter-js@0.20.0/+esm")),
        ],
    ),
    dict(
        id="cannon-es", pkg="cannon-es", version="0.20.0", name="cannon-es", kind="physics",
        hint="объёмная физика (продолжение cannon.js), только в виде модуля",
        bare=["cannon-es"],
        cdn=["cdn.jsdelivr.net/npm/cannon-es", "unpkg.com/cannon-es",
             "esm.sh/cannon-es", "cdn.skypack.dev/cannon-es",
             "cdnjs.cloudflare.com/ajax/libs/cannon-es"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("cannon-es.js", "module", None, ("npm", "dist/cannon-es.js")),
        ],
    ),
    dict(
        id="cannon", pkg="cannon", version="0.6.2", name="cannon.js", kind="physics",
        hint="объёмная физика по-старому, через глобальную переменную CANNON",
        bare=["cannon"],
        cdn=["cdn.jsdelivr.net/npm/cannon", "unpkg.com/cannon",
             "cdnjs.cloudflare.com/ajax/libs/cannon.js", "esm.sh/cannon",
             "cdn.skypack.dev/cannon"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("cannon.min.js", "umd", "CANNON", ("npm", "build/cannon.min.js")),
        ],
    ),
    dict(
        id="p5", pkg="p5", version="1.11.10", name="p5.js", kind="creative",
        hint="рисование и творческое программирование (setup/draw)",
        bare=["p5"],
        cdn=["cdn.jsdelivr.net/npm/p5", "unpkg.com/p5",
             "cdnjs.cloudflare.com/ajax/libs/p5.js", "esm.sh/p5",
             "cdn.skypack.dev/p5"],
        license="LGPL-2.1", license_src=("npm", "license.txt"),
        files=[
            ("p5.min.js", "umd", "p5", ("npm", "lib/p5.min.js")),
            ("addons/p5.sound.min.js", "umd", "p5.sound", ("npm", "lib/addons/p5.sound.min.js")),
        ],
    ),
    dict(
        id="tone", pkg="tone", version="15.1.22", name="Tone.js", kind="audio",
        hint="музыка и синтезаторы: ноты, темп, эффекты",
        bare=["tone"],
        cdn=["cdn.jsdelivr.net/npm/tone", "unpkg.com/tone",
             "cdnjs.cloudflare.com/ajax/libs/tone", "esm.sh/tone",
             "cdn.skypack.dev/tone"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("Tone.js", "umd", "Tone", ("npm", "build/Tone.js")),
            ("tone.module.js", "module", None,
             ("url", "https://esm.sh/tone@15.1.22/es2022/tone.bundle.mjs")),
        ],
    ),
    dict(
        id="howler", pkg="howler", version="2.2.4", name="howler.js", kind="audio",
        hint="проигрывание звуков и музыки простыми командами",
        bare=["howler"],
        cdn=["cdn.jsdelivr.net/npm/howler", "unpkg.com/howler",
             "cdnjs.cloudflare.com/ajax/libs/howler", "esm.sh/howler",
             "cdn.skypack.dev/howler"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("howler.min.js", "umd", "Howler", ("npm", "dist/howler.min.js")),
            ("howler.module.js", "module", None,
             ("url", "https://cdn.jsdelivr.net/npm/howler@2.2.4/+esm")),
        ],
    ),
    dict(
        id="chart.js", pkg="chart.js", version="4.5.1", name="Chart.js", kind="chart",
        hint="графики и диаграммы: линии, столбцы, круговые",
        bare=["chart.js", "chart.js/auto"],
        cdn=["cdn.jsdelivr.net/npm/chart.js", "unpkg.com/chart.js",
             "cdnjs.cloudflare.com/ajax/libs/Chart.js", "esm.sh/chart.js",
             "cdn.skypack.dev/chart.js"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("chart.umd.js", "umd", "Chart", ("npm", "dist/chart.umd.js")),
            ("chart.js", "module", None, ("npm", "dist/chart.js")),
        ],
    ),
    dict(
        id="d3", pkg="d3", version="7.9.0", name="D3", kind="chart",
        hint="данные в картинку: оси, шкалы, свои диаграммы на SVG",
        bare=["d3"],
        cdn=["cdn.jsdelivr.net/npm/d3", "unpkg.com/d3",
             "cdnjs.cloudflare.com/ajax/libs/d3", "esm.sh/d3",
             "cdn.skypack.dev/d3"],
        license="ISC", license_src=("npm", "LICENSE"),
        files=[
            ("d3.min.js", "umd", "d3", ("npm", "dist/d3.min.js")),
            ("d3.module.js", "module", None,
             ("url", "https://esm.sh/d3@7.9.0/es2022/d3.bundle.mjs")),
        ],
    ),
    dict(
        id="bootstrap", pkg="bootstrap", version="5.3.8", name="Bootstrap", kind="style",
        hint="готовое оформление страницы и элементы: сетка, кнопки, окна",
        bare=["bootstrap"],
        # ⚠️ ДВА АДРЕСА BOOTSTRAPCDN — НЕ ЛИШНИЕ. Пока Bootstrap жил на своём
        # собственном CDN, в учебниках и статьях писали именно stackpath/maxcdn,
        # и маленькая модель повторяет их чаще, чем нынешний jsdelivr. Не узнаем
        # этот адрес — страница уйдёт в интернет, которого нет, и останется голой.
        cdn=["cdn.jsdelivr.net/npm/bootstrap", "unpkg.com/bootstrap",
             "cdnjs.cloudflare.com/ajax/libs/bootstrap", "esm.sh/bootstrap",
             "cdn.skypack.dev/bootstrap",
             "stackpath.bootstrapcdn.com/bootstrap",
             "maxcdn.bootstrapcdn.com/bootstrap",
             "netdna.bootstrapcdn.com/bootstrap"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("bootstrap.min.css", "css", None, ("npm", "dist/css/bootstrap.min.css")),
            ("bootstrap.bundle.min.js", "umd", "bootstrap", ("npm", "dist/js/bootstrap.bundle.min.js")),
        ],
    ),
    dict(
        id="pico", pkg="@picocss/pico", version="2.1.1", name="Pico CSS", kind="style",
        hint="крошечное «сразу красиво» без классов — оформляет обычную разметку",
        bare=["@picocss/pico"],
        cdn=["cdn.jsdelivr.net/npm/@picocss/pico", "unpkg.com/@picocss/pico",
             "cdnjs.cloudflare.com/ajax/libs/picocss", "esm.sh/@picocss/pico",
             "cdn.skypack.dev/@picocss/pico"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("pico.min.css", "css", None, ("npm", "css/pico.min.css")),
        ],
    ),
    dict(
        id="water.css", pkg="water.css", version="2.1.1", name="Water.css", kind="style",
        hint="самое лёгкое оформление без классов, 23 КБ",
        bare=["water.css"],
        cdn=["cdn.jsdelivr.net/npm/water.css", "unpkg.com/water.css",
             "cdnjs.cloudflare.com/ajax/libs/water.css", "esm.sh/water.css",
             "cdn.skypack.dev/water.css"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("water.min.css", "css", None, ("npm", "out/water.min.css")),
        ],
    ),
    dict(
        id="tailwindcss", pkg="@tailwindcss/browser", version="4.3.3", name="Tailwind CSS (браузерная сборка)",
        kind="style",
        hint="оформление классами прямо в разметке (class=\"flex gap-4\"), собирается в браузере",
        bare=["@tailwindcss/browser", "tailwindcss"],
        cdn=["cdn.tailwindcss.com", "cdn.jsdelivr.net/npm/@tailwindcss/browser",
             "unpkg.com/@tailwindcss/browser", "esm.sh/@tailwindcss/browser",
             "cdn.skypack.dev/@tailwindcss/browser"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("tailwind.browser.js", "umd", None, ("npm", "dist/index.global.js")),
        ],
    ),
    dict(
        id="alpinejs", pkg="alpinejs", version="3.17.2", name="Alpine.js", kind="ui",
        hint="оживить разметку прямо в HTML: x-data, x-show, x-on",
        bare=["alpinejs"],
        cdn=["cdn.jsdelivr.net/npm/alpinejs", "unpkg.com/alpinejs",
             "cdnjs.cloudflare.com/ajax/libs/alpinejs", "esm.sh/alpinejs",
             "cdn.skypack.dev/alpinejs"],
        license="MIT",
        license_src=("url", "https://raw.githubusercontent.com/alpinejs/alpine/main/LICENSE.md"),
        files=[
            ("alpine.min.js", "umd", "Alpine", ("npm", "dist/cdn.min.js")),
            ("alpine.module.esm.js", "module", None, ("npm", "dist/module.esm.js")),
        ],
    ),
    # ⚠️ jQuery КЛАДЁМ, ХОТЯ ОН И «УСТАРЕЛ». Дело не в моде, а в том, чем обучена
    # маленькая модель: половина примеров работы с разметкой в её данных — это
    # `$('#кнопка').on('click', …)` и `<script src="https://code.jquery.com/jquery-3.6.0.min.js">`.
    # Без файла на полке такая страница молча мертва, а виноватой выглядит модель.
    #
    # ⚠️ ВЕРСИЯ 3.7.1, А НЕ 4.x — ОСОЗНАННО. В четвёртой выкинута часть старых
    # приёмов, которыми модель как раз и пишет. Третья ветка понимает и старый код,
    # и новый; ради совместимости берём её.
    #
    # ⚠️ МОДУЛЬНОЙ СБОРКИ ИЗДАТЕЛЬ В 3.x НЕ ВЫПУСКАЕТ (dist-module появился только
    # в 4.0), поэтому модуль берём собранный jsDelivr (`+esm`) — тем же способом,
    # что и у matter-js/stats.js. Проверено: внешних импортов внутри нет.
    dict(
        id="jquery", pkg="jquery", version="3.7.1", name="jQuery", kind="ui",
        hint="старый добрый $: найти элемент, повесить обработчик, поменять разметку",
        bare=["jquery"],
        cdn=["code.jquery.com/jquery", "ajax.googleapis.com/ajax/libs/jquery",
             "cdn.jsdelivr.net/npm/jquery", "unpkg.com/jquery",
             "cdnjs.cloudflare.com/ajax/libs/jquery", "esm.sh/jquery",
             "cdn.skypack.dev/jquery"],
        license="MIT", license_src=("npm", "LICENSE.txt"),
        files=[
            ("jquery.min.js", "umd", "jQuery", ("npm", "dist/jquery.min.js")),
            ("jquery.module.js", "module", None,
             ("url", "https://cdn.jsdelivr.net/npm/jquery@3.7.1/+esm")),
        ],
    ),
    dict(
        id="animejs", pkg="animejs", version="3.2.2", name="anime.js", kind="motion",
        hint="плавные движения и переходы для любых элементов",
        bare=["animejs"],
        cdn=["cdn.jsdelivr.net/npm/animejs", "unpkg.com/animejs",
             "cdnjs.cloudflare.com/ajax/libs/animejs", "esm.sh/animejs",
             "cdn.skypack.dev/animejs"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("anime.min.js", "umd", "anime", ("npm", "lib/anime.min.js")),
            ("anime.es.js", "module", None, ("npm", "lib/anime.es.js")),
        ],
    ),
    dict(
        id="motion", pkg="motion", version="13.2.0", name="Motion One", kind="motion",
        hint="движение на родном движке браузера: animate(), scroll(), spring",
        bare=["motion"],
        cdn=["cdn.jsdelivr.net/npm/motion", "unpkg.com/motion",
             "cdnjs.cloudflare.com/ajax/libs/motion", "esm.sh/motion",
             "cdn.skypack.dev/motion"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("motion.js", "umd", "Motion", ("npm", "dist/motion.js")),
            ("motion.module.js", "module", None,
             ("url", "https://esm.sh/motion@13.2.0/es2022/motion.bundle.mjs")),
        ],
    ),
    dict(
        id="lodash", pkg="lodash", version="4.17.21", name="Lodash", kind="util",
        hint="набор мелких помощников для массивов, объектов и строк",
        bare=["lodash", "lodash-es"],
        cdn=["cdn.jsdelivr.net/npm/lodash", "unpkg.com/lodash",
             "cdnjs.cloudflare.com/ajax/libs/lodash.js", "esm.sh/lodash",
             "cdn.skypack.dev/lodash"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("lodash.min.js", "umd", "_", ("npm", "lodash.min.js")),
            ("lodash.module.js", "module", None,
             ("url", "https://cdn.jsdelivr.net/npm/lodash@4.17.21/+esm")),
        ],
    ),
    dict(
        id="dayjs", pkg="dayjs", version="1.11.23", name="Day.js", kind="util",
        hint="даты и время: разбор, сложение, красивый вывод",
        bare=["dayjs"],
        cdn=["cdn.jsdelivr.net/npm/dayjs", "unpkg.com/dayjs",
             "cdnjs.cloudflare.com/ajax/libs/dayjs", "esm.sh/dayjs",
             "cdn.skypack.dev/dayjs"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("dayjs.min.js", "umd", "dayjs", ("npm", "dayjs.min.js")),
            ("dayjs.module.js", "module", None,
             ("url", "https://cdn.jsdelivr.net/npm/dayjs@1.11.23/+esm")),
        ],
    ),
    dict(
        id="marked", pkg="marked", version="18.0.12", name="marked", kind="util",
        hint="превращает разметку Markdown в HTML",
        bare=["marked"],
        cdn=["cdn.jsdelivr.net/npm/marked", "unpkg.com/marked",
             "cdnjs.cloudflare.com/ajax/libs/marked", "esm.sh/marked",
             "cdn.skypack.dev/marked"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("marked.umd.js", "umd", "marked", ("npm", "lib/marked.umd.js")),
            ("marked.esm.js", "module", None, ("npm", "lib/marked.esm.js")),
        ],
    ),
    dict(
        id="canvas-confetti", pkg="canvas-confetti", version="1.9.4", name="canvas-confetti",
        kind="util", hint="салют из конфетти на экране одной командой",
        bare=["canvas-confetti"],
        cdn=["cdn.jsdelivr.net/npm/canvas-confetti", "unpkg.com/canvas-confetti",
             "cdnjs.cloudflare.com/ajax/libs/canvas-confetti", "esm.sh/canvas-confetti",
             "cdn.skypack.dev/canvas-confetti"],
        license="ISC", license_src=("npm", "LICENSE"),
        files=[
            ("confetti.browser.js", "umd", "confetti", ("npm", "dist/confetti.browser.js")),
            ("confetti.module.mjs", "module", None, ("npm", "dist/confetti.module.mjs")),
        ],
    ),
    dict(
        id="qrcodejs", pkg="qrcodejs", version="1.0.0", name="QRCode.js", kind="util",
        hint="рисует QR-код в элементе страницы: new QRCode(el, «текст»)",
        bare=["qrcodejs"],
        cdn=["cdn.jsdelivr.net/npm/qrcodejs", "unpkg.com/qrcodejs",
             "cdnjs.cloudflare.com/ajax/libs/qrcodejs", "esm.sh/qrcodejs",
             "cdn.skypack.dev/qrcodejs"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("qrcode.min.js", "umd", "QRCode", ("npm", "qrcode.min.js")),
        ],
    ),
    dict(
        id="qrcode", pkg="qrcode", version="1.5.4", name="node-qrcode", kind="util",
        hint="QR-код в картинку или на холст, в виде модуля",
        bare=["qrcode"],
        cdn=["cdn.jsdelivr.net/npm/qrcode", "unpkg.com/qrcode",
             "cdnjs.cloudflare.com/ajax/libs/qrcode", "esm.sh/qrcode",
             "cdn.skypack.dev/qrcode"],
        license="MIT", license_src=("npm", "license"),
        files=[
            ("qrcode.module.js", "module", None,
             ("url", "https://esm.sh/qrcode@1.5.4/es2022/qrcode.bundle.mjs")),
        ],
    ),
    dict(
        id="lil-gui", pkg="lil-gui", version="0.21.0", name="lil-gui", kind="util",
        hint="панелька с ползунками для настройки прямо на странице",
        bare=["lil-gui"],
        cdn=["cdn.jsdelivr.net/npm/lil-gui", "unpkg.com/lil-gui",
             "cdnjs.cloudflare.com/ajax/libs/lil-gui", "esm.sh/lil-gui",
             "cdn.skypack.dev/lil-gui"],
        license="MIT", license_src=("npm", "LICENSE.md"),
        files=[
            ("lil-gui.umd.min.js", "umd", "lil", ("npm", "dist/lil-gui.umd.min.js")),
            ("lil-gui.esm.min.js", "module", None, ("npm", "dist/lil-gui.esm.min.js")),
        ],
    ),
    dict(
        id="stats.js", pkg="stats.js", version="0.17.0", name="stats.js", kind="util",
        hint="счётчик кадров в углу экрана",
        bare=["stats.js"],
        cdn=["cdn.jsdelivr.net/npm/stats.js", "unpkg.com/stats.js",
             "cdnjs.cloudflare.com/ajax/libs/stats.js", "esm.sh/stats.js",
             "cdn.skypack.dev/stats.js"],
        license="MIT", license_src=("npm", "LICENSE"),
        files=[
            ("stats.min.js", "umd", "Stats", ("npm", "build/stats.min.js")),
            ("stats.module.js", "module", None,
             ("url", "https://cdn.jsdelivr.net/npm/stats.js@0.17.0/+esm")),
        ],
    ),
]

HTML_MARKERS = (b"<!doctype", b"<html", b"<!DOCTYPE", b"<?xml")
EXT_IMPORT = re.compile(r'(?:^|[\s;}])(?:import|export)[^;\n]{0,400}?from\s*["\']([^"\']+)["\']')
BARE_IMPORT = re.compile(r'(?:^|[\s;}])import\s*["\']([^"\']+)["\']')


def check(data, form, path, lib_id):
    problems = []
    if len(data) < 500:
        problems.append(f"подозрительно мал: {len(data)} Б")
    low = data[:200].lstrip()[:20]
    if any(low.startswith(m) for m in HTML_MARKERS):
        problems.append("похоже на HTML-страницу, а не на код")
    if form == "module":
        txt = data.decode("utf-8", "replace")
        refs = set(EXT_IMPORT.findall(txt)) | set(BARE_IMPORT.findall(txt))
        outside = [r for r in refs if r.startswith(("/", "http://", "https://", "//"))]
        # относительные импорты допустимы только внутри three (жёсткая структура папок)
        rel = [r for r in refs if r.startswith((".", ".."))]
        if outside:
            problems.append(f"тянет из сети: {sorted(outside)[:3]}")
        if rel and lib_id != "three":
            problems.append(f"относительные импорты: {sorted(rel)[:3]}")
    return problems


def fetch_one(job):
    lib, fname, form, glob, src = job
    if src[0] == "npm":
        url = jsd(lib["pkg"], lib["version"], src[1])
    else:
        url = src[1]
    data = get(url)
    return (lib["id"], fname, form, glob, url, data)


def main():
    os.makedirs(ROOT, exist_ok=True)
    jobs = []
    for lib in LIBS:
        for fname, form, glob, src in lib["files"]:
            jobs.append((lib, fname, form, glob, src))

    results = {}
    errors = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(fetch_one, j): j for j in jobs}
        for f in concurrent.futures.as_completed(futs):
            j = futs[f]
            try:
                results[(j[0]["id"], j[1])] = f.result()
            except Exception as e:
                errors.append(f"{j[0]['id']}/{j[1]}: {e}")

    if errors:
        print("!!! НЕ СКАЧАЛОСЬ:")
        for e in errors:
            print("   ", e)

    # лицензии
    lic_data = {}
    lic_err = []
    def fetch_lic(lib):
        kind, val = lib["license_src"]
        url = jsd(lib["pkg"], lib["version"], val) if kind == "npm" else val
        return lib["id"], get(url, 60), url
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {ex.submit(fetch_lic, lib): lib for lib in LIBS}
        for f in concurrent.futures.as_completed(futs):
            lib = futs[f]
            try:
                lid, data, url = f.result()
                lic_data[lid] = (data, url)
            except Exception as e:
                lic_err.append(f"{lib['id']}: {e}")
    if lic_err:
        print("!!! ЛИЦЕНЗИИ НЕ СКАЧАЛИСЬ:")
        for e in lic_err:
            print("   ", e)

    manifest = {"generatedAt": GEN_DATE, "libraries": []}
    report = []
    total = 0
    nfiles = 0
    for lib in LIBS:
        entry_files = []
        lbytes = 0
        for fname, form, glob, src in lib["files"]:
            key = (lib["id"], fname)
            if key not in results:
                continue
            _, _, _, _, url, data = results[key]
            probs = check(data, form, fname, lib["id"])
            dest = os.path.join(ROOT, lib["id"], fname)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(data)
            rec = {"path": f"{lib['id']}/{fname}", "form": form}
            if glob:
                rec["global"] = glob
            entry_files.append(rec)
            lbytes += len(data)
            nfiles += 1
            report.append((lib["id"], fname, len(data), url, probs))

        lic_path = None
        if lib["id"] in lic_data:
            data, url = lic_data[lib["id"]]
            name = os.path.basename(lib["license_src"][1])
            dest = os.path.join(ROOT, lib["id"], name)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(data)
            lic_path = f"{lib['id']}/{name}"
            lbytes += len(data)
            nfiles += 1

        total += lbytes
        manifest["libraries"].append({
            "id": lib["id"],
            "name": lib["name"],
            "version": lib["version"],
            "kind": lib["kind"],
            "files": entry_files,
            "bare": lib["bare"],
            "cdn": lib["cdn"],
            "license": lib["license"],
            "licenseFile": lic_path or "",
            "bytes": lbytes,
            "hint": lib["hint"],
        })

    with open(os.path.join(ROOT, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    print("\n=== ОТЧЁТ ===")
    for lid, fname, size, url, probs in sorted(report):
        flag = "  ⚠️ " + "; ".join(probs) if probs else ""
        print(f"{size:>9}  {lid}/{fname}{flag}")
    print(f"\nвсего файлов (с лицензиями): {nfiles}")
    print(f"всего байт: {total}  ({total/1048576:.2f} МБ)")
    bad = [r for r in report if r[4]]
    print(f"проблемных файлов: {len(bad)}")
    return 1 if (errors or lic_err or bad) else 0


if __name__ == "__main__":
    sys.exit(main())
