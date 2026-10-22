//
//  PlaygroundBackdrop.swift
//  PocketAgent
//
//  Цветной фон площадки.
//
//  ⚠️ ЗАЧЕМ ЦВЕТ ИМЕННО ЗДЕСЬ И БОЛЬШЕ НИГДЕ. Всё приложение намеренно чёрное:
//  на чёрном читается стекло, и рабочие экраны не должны отвлекать. Но площадка —
//  это место для игр и «приколов», правка владельца дословно: «хочу чтоб плейграунд
//  был в разноцветном стиле айос 27 стеклянном». Цвет здесь несёт смысл: человек
//  по одному взгляду понимает, что попал в другую часть приложения.
//
//  ⚠️ И ПОЧЕМУ ЦВЕТ — В ФОНЕ, А НЕ В КАРТОЧКАХ. Правило дизайна
//  жёсткое: стекло только на плавающем слое, никогда на карточках и списках. Ровно так
//  же советует и Apple: цвет живёт в фоне, а стеклянные элементы над ним его
//  подхватывают. HIG «Color» дословно: «use color sparingly on Liquid Glass… reserve
//  color for elements that truly benefit from emphasis». Красить сами карточки
//  стеклом было бы браком и по нашему правилу, и по их указаниям.
//
//  ⚠️⚠️ ПРО БАТАРЕЮ, И ЭТО ЗДЕСЬ НЕ МЕЛОЧЬ. Рядом на видеочипе крутится модель,
//  и фон не имеет права соперничать с ней за кадры. Поэтому:
//   • сетчатый градиент ОДИН на весь экран, а не по одному на карточку — на большом
//     экране такой градиент стоит примерно как небольшой трёхмерный проход, один
//     потянет любой телефон, десяток — нет;
//   • анимируем ТОЧКИ через `withAnimation(...).repeatForever()`, а не пересчитываем
//     кадр за кадром через `TimelineView(.animation)`: во втором случае тело вьюхи
//     считается 60–120 раз в секунду просто чтобы фон дышал;
//   • размер сетки задан один раз и не меняется: смена размера пересобирает шейдер
//     и даёт рывок;
//   • при включённом «Уменьшении движения» фон стоит неподвижно.
//

import SwiftUI

/// Цветная подложка площадки.
struct PlaygroundBackdrop: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Фаза волны 0…1. Двигается сама, если движение разрешено.
    @State private var phase: CGFloat = 0

    /// Палитра. Тёплое и холодное вперемешку — так пятна видно как отдельные,
    /// а не как одно размазанное свечение.
    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.24, blue: 0.94),   // фиолетовый
        Color(red: 0.09, green: 0.52, blue: 0.96),   // синий
        Color(red: 0.14, green: 0.78, blue: 0.72),   // бирюзовый
        Color(red: 0.98, green: 0.40, blue: 0.28),   // коралловый
        Color(red: 0.96, green: 0.68, blue: 0.18),   // янтарный
        Color(red: 0.85, green: 0.24, blue: 0.62),   // малиновый
        Color(red: 0.45, green: 0.30, blue: 0.98),
        Color(red: 0.20, green: 0.62, blue: 0.98),
        Color(red: 0.10, green: 0.70, blue: 0.60)
    ]

    var body: some View {
        ZStack {
            // Под цветом — настоящий чёрный: на нём цвет читается как свечение,
            // а не как грязь, и белый текст поверх остаётся контрастным.
            Color.black
            colorLayer
            // ⚠️ Затемнение сверху обязательно: без него белый текст на янтарном
            // пятне становится нечитаемым. Проверяется глазами, а не рассуждением.
            LinearGradient(colors: [Color.black.opacity(0.52), Color.black.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .onAppear(perform: startDrifting)
    }

    @ViewBuilder
    private var colorLayer: some View {
        if #available(iOS 18.0, *) {
            // ⚠️ Пространство цвета — `perceptual`, а не обычное. В обычном красный
            // с синим смешиваются в грязно-серый вместо пурпурного, и весь фон
            // выглядит выцветшим.
            MeshGradient(width: 3,
                         height: 3,
                         points: meshPoints(),
                         colors: Self.palette,
                         colorSpace: .perceptual)
                .opacity(0.85)
        } else {
            // На старых iOS сетчатого градиента нет — берём угловой. Он статичный,
            // зато не стоит почти ничего и выглядит тем же семейством цветов.
            AngularGradient(colors: Self.palette + [Self.palette[0]],
                            center: .center)
                .blur(radius: 60)
                .opacity(0.7)
        }
    }

    /// Точки сетки. Двигаются только внутренние: углы держат картинку на месте,
    /// иначе на краях экрана вылезает пустота.
    @available(iOS 18.0, *)
    private func meshPoints() -> [SIMD2<Float>] {
        let p = Float(phase)
        return [
            SIMD2(0, 0),                       SIMD2(0.5, 0),                       SIMD2(1, 0),
            SIMD2(0, 0.45 + p * 0.12),         SIMD2(0.5 - p * 0.16, 0.5 + p * 0.1), SIMD2(1, 0.55 - p * 0.12),
            SIMD2(0, 1),                       SIMD2(0.5 + p * 0.1, 1),              SIMD2(1, 1)
        ]
    }

    private func startDrifting() {
        guard !reduceMotion else { return }
        // Туда-обратно, а не по кругу: у волны нет «шва», на котором картинка
        // дёргается, возвращаясь в начало.
        withAnimation(.smooth(duration: 9).repeatForever(autoreverses: true)) {
            phase = 1
        }
    }
}

#Preview {
    PlaygroundBackdrop()
}
