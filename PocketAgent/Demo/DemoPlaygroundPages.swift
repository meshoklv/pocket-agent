//
//  DemoPlaygroundPages.swift
//  PocketAgent / Demo
//
//  Витрина площадки: четыре страницы-примера, которые демонстрация кладёт
//  во временную папку приложения и открывает так, как их увидит человек.
//
//  ⚠️ ЗАЧЕМ ЭТО ВООБЩЕ ЕСТЬ. Площадку (ROADMAP §18) нельзя показать на снимке
//  теми же средствами, что и остальные экраны: у неё нет «поддельного источника
//  данных», она показывает НАСТОЯЩИЕ файлы из папки проекта настоящим движком
//  WebKit. Поддельная папка `DemoScenario.folder` ведёт в никуда — на ней
//  площадка честно скажет «страниц не нашёл». Поэтому здесь мы делаем ровно
//  одно: пишем несколько примеров в СВОЮ временную папку и подставляем её как
//  папку проекта. Дальше работает боевой код без единой подмены — тот же обход,
//  тот же просмотрщик, та же проверка страницы перед показом.
//
//  ⚠️ ПОЧЕМУ ССЫЛКА НА БИБЛИОТЕКУ ОБЫЧНАЯ, А НЕ «НАША». В трёхмерной сцене
//  стоит самый обычный адрес `https://cdn.jsdelivr.net/npm/three@0.147.0/...`
//  — именно такой, какой напишет модель. Приложение молча подменяет его файлом
//  с полки (PocketAgent/Resources/PlaygroundLib), и снимок нужен как раз затем,
//  чтобы это было видно глазами: интернета нет, а сцена крутится.
//  Полка приезжает отдельной веткой; пока её нет, страница честно скажет на
//  своём же экране, что библиотека не подключилась, — пустого чёрного кадра
//  не будет ни в одном из двух случаев.
//
//  ⚠️ ФАЙЛЫ — ВО ВРЕМЕННУЮ ПАПКУ ПРИЛОЖЕНИЯ, и это важно. Ни к какой папке
//  человека демонстрация не прикасается: писать примеры в чужой проект значит
//  насорить в нём. Временную папку система вычищает сама.
//

// ⚠️ ВЕСЬ ФАЙЛ — ТОЛЬКО ОТЛАДОЧНАЯ СБОРКА.
// Демонстрационный режим нужен ради снимков экранов на симуляторе, и в сборку
// для магазина ему попадать незачем: там это мёртвый код и выдуманные тексты.
#if DEBUG

import Foundation

// MARK: - Какие страницы лежат на витрине

/// Одна страница-пример.
///
/// ⚠️ Порядок случаев ЗНАЧИМ: он задаёт время изменения файлов, а площадка
/// сортирует карточки по свежести. Первый случай — самая свежая карточка,
/// то есть первая на экране.
enum DemoPlaygroundPage: String, CaseIterable {

    /// Трёхмерная сцена на three.js — та самая, ради которой существует полка.
    case scene = "сцена-кристалл.html"
    /// Игра на холсте: управление пальцем, всё внутри одного файла.
    case game = "игра-звездопад.html"
    /// Обычная страничка-сайт с оформлением.
    case site = "сайт-кофейня.html"
    /// Заведомо сломанная страница — на ней видно разбор поломки и починку.
    case broken = "сломанная-страница.html"

    var fileName: String { rawValue }
}

// MARK: - Готовая витрина

/// Папка с примерами и опознанные площадкой файлы в ней.
struct DemoPlaygroundContent {
    /// Папка проекта, которую видит демонстрация.
    let folder: ProjectFolder
    /// Файлы по страницам — чтобы открыть нужную сразу, без нажатий.
    let items: [DemoPlaygroundPage: PlaygroundItem]
}

enum DemoPlayground {

    /// Витрина готовится ОДИН раз за запуск: файлы пишутся при первом обращении,
    /// дальше все экраны демонстрации пользуются той же папкой.
    static let prepared: DemoPlaygroundContent = build()

    /// Найти файл нужной страницы. Файла нет (запись не удалась) — вернём nil,
    /// и экран честно скажет об этом словами, а не покажет пустоту.
    static func item(_ page: DemoPlaygroundPage) -> PlaygroundItem? {
        prepared.items[page]
    }

    // MARK: - Сборка папки

    private static func build() -> DemoPlaygroundContent {
        // ⚠️ Приводим к каноническому виду СРАЗУ. Временная папка живёт по адресу
        // `/var/folders/…`, а на самом деле это `/private/var/folders/…`. Площадка
        // сравнивает границы папки по каноническому пути, и несовпадение здесь
        // означало бы «страниц не нашёл» на папке, где страницы лежат.
        let root = SafePath.canonical(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("Витрина площадки", isDirectory: true))

        let manager = FileManager.default
        // Папку пересоздаём: прошлый запуск мог оставить в ней недописанное.
        try? manager.removeItem(at: root)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        var items: [DemoPlaygroundPage: PlaygroundItem] = [:]
        let pages = DemoPlaygroundPage.allCases

        for (index, page) in pages.enumerated() {
            let url = root.appendingPathComponent(page.fileName)
            let html = source(for: page)
            guard let data = html.data(using: .utf8) else { continue }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                continue
            }

            // ⚠️ Время изменения выставляем сами. Площадка показывает свежее сверху,
            // а все четыре файла пишутся в одну и ту же секунду — без этого порядок
            // карточек на снимке скакал бы от запуска к запуску.
            let modified = Date(timeIntervalSinceNow: -Double(index) * 600)
            try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

            items[page] = PlaygroundItem(url: url,
                                         relativePath: page.fileName,
                                         name: page.fileName,
                                         sizeInBytes: data.count,
                                         modifiedAt: modified)
        }

        let folder = ProjectFolder(url: root,
                                   bookmark: Data(),
                                   displayName: "витрина",
                                   adoptedAt: Date(timeIntervalSinceNow: -3600))
        return DemoPlaygroundContent(folder: folder, items: items)
    }

    // MARK: - Сами страницы

    private static func source(for page: DemoPlaygroundPage) -> String {
        switch page {
        case .scene:  return sceneHTML
        case .game:   return gameHTML
        case .site:   return siteHTML
        case .broken: return brokenHTML
        }
    }

    /// Трёхмерная сцена. Библиотека берётся ОБЫЧНОЙ ссылкой на чужой адрес —
    /// подменять её файлом с полки должно само приложение.
    ///
    /// ⚠️ Строка «сырая» (`#"""`): внутри и кавычки, и обратные слэши CSS/JS
    /// попадаются как есть, а в обычной строке Swift принял бы их за свои
    /// управляющие последовательности.
    private static let sceneHTML = #"""
    <!doctype html>
    <html lang="ru">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Кристалл</title>
    <style>
      html, body { margin: 0; height: 100%; background: #05070f; overflow: hidden; }
      canvas { display: block; }
      .подпись {
        position: fixed; left: 20px; right: 20px; bottom: 34px;
        font: 16px/1.4 -apple-system, system-ui, sans-serif; color: #eef2ff;
        text-shadow: 0 2px 12px rgba(0,0,0,.8); pointer-events: none;
      }
      .подпись h1 { margin: 0 0 6px; font-size: 26px; letter-spacing: .2px; }
      .подпись p { margin: 0; opacity: .75; }
      .беда {
        position: fixed; inset: 24px; display: none; align-items: center; justify-content: center;
        text-align: center; color: #ffd9d9; font: 17px/1.5 -apple-system, system-ui, sans-serif;
        border: 1px solid rgba(255,120,120,.4); border-radius: 20px; background: rgba(60,10,10,.5);
        padding: 24px;
      }
    </style>
    </head>
    <body>
      <div class="подпись">
        <h1>Кристалл</h1>
        <p>Трёхмерная сцена на three.js. Ведите пальцем — она поворачивается.</p>
      </div>
      <div class="беда" id="беда">
        Сцена не запустилась: библиотека three.js не подключилась.<br>
        Интернета здесь нет — её должно подставить само приложение.
      </div>

      <!-- Обычный адрес библиотеки: ровно такой пишет модель.
           Приложение молча подменяет его файлом со своей полки. -->
      <script src="https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js"></script>
      <script>
        if (!window.THREE) {
          document.getElementById('беда').style.display = 'flex';
        } else {
          var сцена = new THREE.Scene();
          сцена.fog = new THREE.Fog(0x05070f, 6, 16);

          var камера = new THREE.PerspectiveCamera(52, window.innerWidth / window.innerHeight, 0.1, 100);
          камера.position.set(0, 0.6, 6);

          var рисователь = new THREE.WebGLRenderer({ antialias: true, alpha: false });
          рисователь.setPixelRatio(Math.min(window.devicePixelRatio, 2));
          рисователь.setSize(window.innerWidth, window.innerHeight);
          document.body.appendChild(рисователь.domElement);

          var кристалл = new THREE.Mesh(
            new THREE.IcosahedronGeometry(1.9, 0),
            new THREE.MeshStandardMaterial({ color: 0x7aa2ff, metalness: 0.65, roughness: 0.18, flatShading: true })
          );
          сцена.add(кристалл);

          var сетка = new THREE.Mesh(
            new THREE.IcosahedronGeometry(2.35, 0),
            new THREE.MeshBasicMaterial({ color: 0x9ad7ff, wireframe: true, transparent: true, opacity: 0.28 })
          );
          сцена.add(сетка);

          var звёзды = new THREE.BufferGeometry();
          var точки = [];
          for (var i = 0; i < 500; i++) {
            точки.push((Math.random() - 0.5) * 34, (Math.random() - 0.5) * 34, (Math.random() - 0.5) * 34);
          }
          звёзды.setAttribute('position', new THREE.Float32BufferAttribute(точки, 3));
          сцена.add(new THREE.Points(звёзды, new THREE.PointsMaterial({ color: 0x8fb6ff, size: 0.06 })));

          сцена.add(new THREE.AmbientLight(0x3b4a7a, 1.1));
          var свет = new THREE.DirectionalLight(0xfff2d0, 2.2);
          свет.position.set(4, 6, 5);
          сцена.add(свет);
          var подсветка = new THREE.PointLight(0xff7ad9, 2.4, 22);
          подсветка.position.set(-5, -3, 3);
          сцена.add(подсветка);

          var поворотX = 0.15, поворотY = 0.0, палец = null;
          document.addEventListener('touchstart', function (e) { палец = e.touches[0]; }, { passive: true });
          document.addEventListener('touchmove', function (e) {
            if (!палец) { return; }
            var т = e.touches[0];
            поворотY += (т.clientX - палец.clientX) * 0.006;
            поворотX += (т.clientY - палец.clientY) * 0.006;
            палец = т;
          }, { passive: true });
          document.addEventListener('touchend', function () { палец = null; }, { passive: true });

          window.addEventListener('resize', function () {
            камера.aspect = window.innerWidth / window.innerHeight;
            камера.updateProjectionMatrix();
            рисователь.setSize(window.innerWidth, window.innerHeight);
          });

          (function кадр(время) {
            var t = (время || 0) / 1000;
            кристалл.rotation.x = поворотX + Math.sin(t * 0.4) * 0.18;
            кристалл.rotation.y = поворотY + t * 0.32;
            сетка.rotation.x = кристалл.rotation.x * -0.6;
            сетка.rotation.y = кристалл.rotation.y * 0.7;
            рисователь.render(сцена, камера);
            requestAnimationFrame(кадр);
          })(0);
        }
      </script>
    </body>
    </html>
    """#

    /// Игра на холсте: ловим падающие звёзды. Ни одной чужой ссылки — всё внутри.
    private static let gameHTML = #"""
    <!doctype html>
    <html lang="ru">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Звездопад</title>
    <style>
      html, body { margin: 0; height: 100%; overflow: hidden;
                   background: radial-gradient(120% 80% at 50% 0%, #1b2450 0%, #070a18 60%, #05060f 100%); }
      canvas { display: block; touch-action: none; }
      .счёт {
        position: fixed; top: 78px; left: 0; right: 0; text-align: center;
        font: 600 42px/1 -apple-system, system-ui, sans-serif; color: #ffd873;
        text-shadow: 0 4px 18px rgba(0,0,0,.7); pointer-events: none;
      }
      .подсказка {
        position: fixed; bottom: 46px; left: 0; right: 0; text-align: center;
        font: 15px/1.4 -apple-system, system-ui, sans-serif; color: rgba(255,255,255,.7);
        pointer-events: none;
      }
    </style>
    </head>
    <body>
      <div class="счёт" id="счёт">0</div>
      <div class="подсказка">Ведите пальцем — корзинка едет за ним</div>
      <canvas id="холст"></canvas>
      <script>
        var холст = document.getElementById('холст');
        var к = холст.getContext('2d');
        var Ш = 0, В = 0, масштаб = Math.min(window.devicePixelRatio || 1, 2);

        function размер() {
          Ш = window.innerWidth; В = window.innerHeight;
          холст.width = Ш * масштаб; холст.height = В * масштаб;
          холст.style.width = Ш + 'px'; холст.style.height = В + 'px';
          к.setTransform(масштаб, 0, 0, масштаб, 0, 0);
        }
        размер();
        window.addEventListener('resize', размер);

        var корзинка = { x: window.innerWidth / 2, y: 0, ширина: 96 };
        var звёзды = [], счёт = 0, время = 0;

        function новаяЗвезда(сверху) {
          звёзды.push({
            x: 30 + Math.random() * (Ш - 60),
            y: сверху ? -30 : Math.random() * В * 0.6,
            скорость: 2.2 + Math.random() * 2.4,
            размер: 10 + Math.random() * 8,
            угол: Math.random() * Math.PI
          });
        }
        for (var i = 0; i < 5; i++) { новаяЗвезда(false); }

        document.addEventListener('touchmove', function (e) {
          корзинка.x = e.touches[0].clientX;
        }, { passive: true });
        document.addEventListener('touchstart', function (e) {
          корзинка.x = e.touches[0].clientX;
        }, { passive: true });

        function звезда(x, y, r, угол, цвет) {
          к.save(); к.translate(x, y); к.rotate(угол); к.beginPath();
          for (var i = 0; i < 10; i++) {
            var рад = (i % 2 === 0) ? r : r * 0.44;
            var а = Math.PI / 5 * i - Math.PI / 2;
            к.lineTo(Math.cos(а) * рад, Math.sin(а) * рад);
          }
          к.closePath(); к.fillStyle = цвет; к.fill(); к.restore();
        }

        function прямоугольник(x, y, ш, в, r) {
          к.beginPath();
          к.moveTo(x + r, y);
          к.arcTo(x + ш, y, x + ш, y + в, r);
          к.arcTo(x + ш, y + в, x, y + в, r);
          к.arcTo(x, y + в, x, y, r);
          к.arcTo(x, y, x + ш, y, r);
          к.closePath();
        }

        (function кадр() {
          время += 1;
          корзинка.y = В - 130;
          к.clearRect(0, 0, Ш, В);

          if (время % 34 === 0) { новаяЗвезда(true); }

          for (var i = звёзды.length - 1; i >= 0; i--) {
            var з = звёзды[i];
            з.y += з.скорость; з.угол += 0.02;
            звезда(з.x, з.y, з.размер, з.угол, '#ffd873');

            var поймал = Math.abs(з.x - корзинка.x) < корзинка.ширина / 2 &&
                         Math.abs(з.y - корзинка.y) < 34;
            if (поймал) {
              счёт += 1; звёзды.splice(i, 1);
              document.getElementById('счёт').textContent = счёт;
            } else if (з.y > В + 40) {
              звёзды.splice(i, 1);
            }
          }

          к.fillStyle = '#7aa2ff';
          прямоугольник(корзинка.x - корзинка.ширина / 2, корзинка.y - 16, корзинка.ширина, 32, 16);
          к.fill();
          к.fillStyle = 'rgba(255,255,255,.35)';
          прямоугольник(корзинка.x - корзинка.ширина / 2 + 8, корзинка.y - 12, корзинка.ширина - 16, 8, 4);
          к.fill();

          requestAnimationFrame(кадр);
        })();
      </script>
    </body>
    </html>
    """#

    /// Обычная страничка-сайт. Всё оформление внутри файла: интернета тут нет,
    /// и чужие шрифты со стилями всё равно не загрузились бы.
    private static let siteHTML = #"""
    <!doctype html>
    <html lang="ru">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Кофейня «Полка»</title>
    <style>
      :root { --кофе: #3b2418; --молоко: #f6efe7; --акцент: #c8763c; }
      * { box-sizing: border-box; }
      body { margin: 0; background: var(--молоко); color: var(--кофе);
             font: 17px/1.55 -apple-system, system-ui, "Helvetica Neue", sans-serif; }
      header { padding: 72px 24px 40px; text-align: center;
               background: linear-gradient(160deg, #4a2c1c 0%, #7a4526 100%); color: #fff2e6; }
      header .знак { font-size: 40px; }
      header h1 { margin: 12px 0 6px; font-size: 34px; letter-spacing: .3px; }
      header p { margin: 0; opacity: .8; }
      main { padding: 28px 20px 56px; max-width: 620px; margin: 0 auto; }
      h2 { font-size: 22px; margin: 30px 0 14px; }
      .карточки { display: grid; gap: 14px; }
      .карточка { background: #fff; border-radius: 18px; padding: 18px 20px;
                  box-shadow: 0 8px 26px rgba(59,36,24,.09); display: flex; gap: 14px; align-items: center; }
      .карточка .значок { font-size: 30px; }
      .карточка h3 { margin: 0 0 2px; font-size: 18px; }
      .карточка p { margin: 0; font-size: 15px; opacity: .72; }
      .цена { margin-left: auto; font-weight: 600; color: var(--акцент); white-space: nowrap; }
      .кнопка { display: block; margin: 30px auto 0; padding: 15px 30px; border: 0; border-radius: 999px;
                background: var(--акцент); color: #fff; font-size: 17px; font-weight: 600; }
      footer { text-align: center; padding: 26px; font-size: 14px; opacity: .6; }
    </style>
    </head>
    <body>
      <header>
        <div class="знак">☕️</div>
        <h1>Кофейня «Полка»</h1>
        <p>Тихое место с книгами — Малая Бронная, 14</p>
      </header>
      <main>
        <h2>Что наливаем</h2>
        <div class="карточки">
          <div class="карточка">
            <div class="значок">🫘</div>
            <div><h3>Фильтр дня</h3><p>Кения, ягодная кислинка</p></div>
            <div class="цена">240 ₽</div>
          </div>
          <div class="карточка">
            <div class="значок">🥛</div>
            <div><h3>Флэт уайт</h3><p>Двойной эспрессо и плотное молоко</p></div>
            <div class="цена">290 ₽</div>
          </div>
          <div class="карточка">
            <div class="значок">🍫</div>
            <div><h3>Какао на овсяном</h3><p>Тёмный шоколад, без сахара</p></div>
            <div class="цена">260 ₽</div>
          </div>
        </div>
        <h2>Когда открыто</h2>
        <div class="карточки">
          <div class="карточка">
            <div class="значок">🕗</div>
            <div><h3>Каждый день</h3><p>с 8:00 до 22:00, кухня до 21:30</p></div>
          </div>
        </div>
        <button class="кнопка" onclick="this.textContent='Столик забронирован ✓'">Забронировать столик</button>
      </main>
      <footer>Сделано помощником прямо на телефоне, без интернета</footer>
    </body>
    </html>
    """#

    /// Заведомо сломанная страница: и ошибка в коде, и пропавший соседний файл.
    /// На ней видно, как выглядит разбор поломки и предложение починить.
    private static let brokenHTML = #"""
    <!doctype html>
    <html lang="ru">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Часы</title>
    <style>
      body { margin: 0; height: 100vh; background: #0b0f1c; color: #e8ecff;
             font: 17px/1.5 -apple-system, system-ui, sans-serif;
             display: flex; align-items: center; justify-content: center; }
    </style>
    </head>
    <body>
      <h1 id="часы">--:--</h1>
      <img src="фон-часов.png" alt="фон">
      <script>
        // Холста с таким именем на странице нет — страница падает на первой же строке.
        var к = document.getElementById('циферблат').getContext('2d');
        setInterval(function () {
          document.getElementById('часы').textContent = new Date().toLocaleTimeString('ru-RU');
        }, 1000);
      </script>
    </body>
    </html>
    """#
}

#endif
