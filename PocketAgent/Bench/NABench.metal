//
//  NABench.metal
//  PocketAgent / Bench
//
//  МИКРОЗАМЕР МАТРИЧНЫХ БЛОКОВ A19 (Neural Accelerators) — ядра видеочипа.
//  ROADMAP §24.6, ТЗ — docs/research/na-spec.md §4 (ядра K0–K6). Хозяин замера —
//  NABench.swift: там как запускать, что значат числа и какие ядра к какому K относятся.
//
//  ⚠️ ЭТОТ ФАЙЛ НЕ КОМПИЛИРУЕТСЯ ОБЫЧНЫМ ПРАВИЛОМ XCODE. Он исключён из исходников
//  в project.yml и собирается отдельным шагом сборки в NABench.metallib с ключами
//  `-std=metal4.0 -mios-version-min=26.0`; тот же текст кладётся в приложение, чтобы
//  замер мог собрать его ещё и на самом телефоне с языком 4.1 (ТЗ §4). Причина:
//  приложение целится в iOS 17, а тензоры (`<metal_tensor>`) и Metal Performance
//  Primitives есть только в языке Metal 4 (iOS 26+). Обычное правило Xcode собирает
//  шейдеры под цель приложения — там `__HAVE_TENSOR__` не определён и заголовок MPP
//  пустой (проверено на мини 24.09.2026: «no template named 'execution_simdgroups'»).
//  Поднимать всему приложению минимальную систему до 26 ради замера нельзя.
//
//  Раскладка данных — как в рисующей части Qwen-Image у нас (ggml):
//    W — веса,      M строк × K, K подряд (строка = выходной признак);
//    X — активации, N строк × K, K подряд (строка = токен);
//    Y — результат, N строк × M, M подряд: Y[n][m] = Σ_k X[n][k]·W[m][k].
//  В терминах MPP: левый операнд — плитка X (extents (K, BT)), правый — плитка W
//  с transpose_right (extents (K, BW)), результат — extents (BW, BT). Ровно так же
//  зовёт matmul2d штатный ggml (`mm.run(mB, mA, cT)`), то есть путь проверен.
//
//  Проверок краёв в ядрах НЕТ намеренно: M и K кратны 128, а число токенов N хост
//  добивает до кратного 128 пустыми строками (буферы X и Y больше на хвост). Так
//  «1054 токена» считаются честно: хвостовая плитка работает вхолостую, как в жизни,
//  а скорость хост считает по настоящему N.
//
//  Имена ядер собираются ОДИНАКОВО здесь (макросы внизу) и в NABench.swift
//  (NABenchKernels). Расходятся — хост пишет «нет в библиотеке», а не падает.
//

#include <metal_stdlib>
// Тензоры и MPP — только в языке Metal 4. Без него (сборка под macOS 15 для проверки
// хост-кода на офисном мини) остаются заполнение и классические ядра (K0); всё с MPP
// исчезает, и хост честно пишет «нет в библиотеке». Метка na_has_tensor — чтобы на
// телефоне это было видно одной строкой, а не по сотне пропусков.
#if defined(__HAVE_TENSOR__)
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
#endif

using namespace metal;

#define NA_UNROLL _Pragma("clang loop unroll(full)")

// Совпадает с NABenchArgs в NABench.swift (восемь int32 подряд).
struct NAArgs {
    int M;      // строки весов
    int N;      // токены (с добивкой до кратного 128)
    int K;      // глубина
    int ldx;    // шаг строки X в элементах
    int ldw;    // шаг строки W в элементах (для half/bf16/int8 весов)
    int ldy;    // шаг строки Y в элементах
    int wrow;   // шаг строки W в БАЙТАХ (для блочных форматов весов)
    int iters;  // повторов в пиковых ядрах
};

// ─────────────────────────────────────────────────────────────────────────────
// Заполнение входов. Случайные числа считаются на видеочипе по номеру элемента —
// 16 млн элементов процессор в отладочной сборке заполнял бы секундами. Эталон на
// процессоре читает уже заполненные буферы (общая память), повторять формулу не надо.
// ─────────────────────────────────────────────────────────────────────────────

static inline uint na_hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

// Равномерно в [-1, 1).
static inline float na_rand(uint i, uint seed) {
    return float(na_hash(i ^ (seed * 0x9E3779B9u)) >> 8) * (2.0f / 16777216.0f) - 1.0f;
}

static inline uchar na_byte(uint i, uint seed) {
    return uchar(na_hash(i * 2654435761u ^ (seed * 0x85EBCA6Bu)) & 0xFF);
}

kernel void na_fill_half(device half * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                         uint i [[thread_position_in_grid]]) {
    p[i] = half(na_rand(i, seed));
}

kernel void na_fill_float(device float * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    p[i] = na_rand(i, seed);
}

kernel void na_fill_bf16(device bfloat * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                         uint i [[thread_position_in_grid]]) {
    p[i] = bfloat(na_rand(i, seed));
}

// int8 в [-64, 64]: сумма 12288 произведений до 64² заведомо влезает в int32.
kernel void na_fill_i8(device int8_t * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                       uint i [[thread_position_in_grid]]) {
    p[i] = int8_t(clamp(int(rint(na_rand(i, seed) * 64.0f)), -64, 64));
}

// ── Блочные форматы весов (поток = один блок). Масштабы подобраны так, чтобы веса
// были порядка ±0,5–1, как у half-входов: ошибки разных путей на одной шкале.
//   q4a — схема MLX affine: {half s; half b; uchar qs[32]} на 64 веса, w = s·q + b;
//   q40 — ggml Q4_0: {half d; uchar qs[16]} на 32, w = d·(q − 8), младшие 4 бита — первые 16;
//   q80 — ggml Q8_0: {half d; int8 qs[32]} на 32, w = d·q;
//   q4k — ggml Q4_K: {half d; half dmin; uchar scales[12]; uchar qs[128]} на 256.

kernel void na_fill_q4a(device uchar * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    device uchar * b = p + (long)i * 36;
    *((device half *)b)       = half((2.0f + na_rand(i, seed)) / 64.0f);
    *((device half *)(b + 2)) = half(0.5f * na_rand(i, seed + 7u));
    for (int j = 4; j < 36; j++) b[j] = na_byte(i * 36 + j, seed);
}

kernel void na_fill_q40(device uchar * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    device uchar * b = p + (long)i * 18;
    *((device half *)b) = half((1.0f + 0.5f * na_rand(i, seed)) / 16.0f);
    for (int j = 2; j < 18; j++) b[j] = na_byte(i * 18 + j, seed);
}

kernel void na_fill_q80(device uchar * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    device uchar * b = p + (long)i * 34;
    *((device half *)b) = half((1.0f + 0.5f * na_rand(i, seed)) / 256.0f);
    for (int j = 2; j < 34; j++) b[j] = na_byte(i * 34 + j, seed);
}

kernel void na_fill_q4k(device uchar * p [[buffer(0)]], constant uint & seed [[buffer(1)]],
                        uint i [[thread_position_in_grid]]) {
    device uchar * b = p + (long)i * 144;
    *((device half *)b)       = half((1.0f + 0.5f * na_rand(i, seed)) / 1024.0f);
    *((device half *)(b + 2)) = half((1.0f + 0.5f * na_rand(i, seed + 3u)) / 256.0f);
    for (int j = 4; j < 144; j++) b[j] = na_byte(i * 144 + j, seed);
}

// ─────────────────────────────────────────────────────────────────────────────
// K0 — потолок обычного пути: simdgroup_matrix 8×8 half→float, всё в регистрах.
// Восемь независимых цепочек накопления (чтобы не упираться в задержку одной), операнды
// читаются из памяти один раз (иначе компилятор посчитал бы всё заранее). Четыре
// SIMD-группы на группу потоков. Работа: группы × 4 × iters × 8 × 1024 оп.
// ─────────────────────────────────────────────────────────────────────────────

[[kernel, max_total_threads_per_threadgroup(128)]]
void na_k0_simd(device const half * A [[buffer(0)]],
                device float * out    [[buffer(2)]],
                constant NAArgs & a   [[buffer(3)]],
                uint   tg [[threadgroup_position_in_grid]],
                ushort sg [[simdgroup_index_in_threadgroup]]) {
    simdgroup_half8x8 x[4], y[2];
    NA_UNROLL for (int i = 0; i < 4; i++) simdgroup_load(x[i], A + i * 64, 8);
    NA_UNROLL for (int i = 0; i < 2; i++) simdgroup_load(y[i], A + 256 + i * 64, 8);
    simdgroup_float8x8 c[8];
    NA_UNROLL for (int j = 0; j < 8; j++) c[j] = make_filled_simdgroup_matrix<float, 8>(0.0f);
    for (int it = 0; it < a.iters; it++) {
        NA_UNROLL for (int j = 0; j < 8; j++)
            simdgroup_multiply_accumulate(c[j], x[j & 3], y[j >> 2], c[j]);
    }
    device float * o = out + ((long)tg * 4 + sg) * 512;
    NA_UNROLL for (int j = 0; j < 8; j++) simdgroup_store(c[j], o + j * 64, 8);
}

// ─────────────────────────────────────────────────────────────────────────────
// Развёртка блочных весов в half: 16 значений за вызов (кусок `c` внутри блока).
// Формат WF: 0 — f16 (без развёртки, «блок» = 16 half), 1 — q4a, 2 — q40, 3 — q80,
// 4 — q4k. Порядок значений внутри блоков совпадает с эталоном на процессоре
// (NABench.swift, NABenchWeights.dequantRow) — менять только парой.
// Не зависит от MPP — живёт вне охраны __HAVE_TENSOR__.
// ─────────────────────────────────────────────────────────────────────────────

template <int WF> struct na_wf        { enum { QK = 16,  BS = 32  }; };
template <>       struct na_wf<1>     { enum { QK = 64,  BS = 36  }; };
template <>       struct na_wf<2>     { enum { QK = 32,  BS = 18  }; };
template <>       struct na_wf<3>     { enum { QK = 32,  BS = 34  }; };
template <>       struct na_wf<4>     { enum { QK = 256, BS = 144 }; };

template <int WF>
static inline void na_deq16(device const uchar * blk, int c, thread half * o) {
    if constexpr (WF == 0) {
        device const half4 * p = (device const half4 *)blk;
        NA_UNROLL for (int j = 0; j < 4; j++) {
            const half4 v = p[j];
            o[4 * j] = v[0]; o[4 * j + 1] = v[1]; o[4 * j + 2] = v[2]; o[4 * j + 3] = v[3];
        }
    } else if constexpr (WF == 1) {
        const half s = *((device const half *)blk);
        const half b = *((device const half *)(blk + 2));
        device const uchar * qs = blk + 4 + c * 8;
        NA_UNROLL for (int j = 0; j < 8; j++) {
            const uchar q = qs[j];
            o[2 * j]     = s * half(q & 0xF) + b;
            o[2 * j + 1] = s * half(q >> 4) + b;
        }
    } else if constexpr (WF == 2) {
        const half d = *((device const half *)blk);
        device const uchar * qs = blk + 2;
        const int sh = c * 4;
        NA_UNROLL for (int j = 0; j < 16; j++) o[j] = d * half(int((qs[j] >> sh) & 0xF) - 8);
    } else if constexpr (WF == 3) {
        const half d = *((device const half *)blk);
        device const char * qs = (device const char *)(blk + 2) + 16 * c;
        NA_UNROLL for (int j = 0; j < 16; j++) o[j] = d * half(qs[j]);
    } else {
        // Q4_K: 4 группы по 64; в группе первые 32 — младшие 4 бита q[0..31] с масштабом
        // is, следующие 32 — старшие биты тех же байтов с масштабом is+1 (ggml
        // dequantize_row_q4_K). Кусок c: группа c/4, половина битов (c/2)&1, байты c&1.
        const half d    = *((device const half *)blk);
        const half dmin = *((device const half *)(blk + 2));
        device const uchar * sc = blk + 4;
        const int j64 = c >> 2, sub = (c >> 1) & 1, hf = c & 1;
        const int is = 2 * j64 + sub;
        uchar sv, mv;
        if (is < 4) {
            sv = sc[is] & 63;
            mv = sc[is + 4] & 63;
        } else {
            sv = (sc[is + 4] & 0xF) | ((sc[is - 4] >> 6) << 4);
            mv = (sc[is + 4] >> 4)  | ((sc[is]     >> 6) << 4);
        }
        const half dl = d * half(sv), ml = dmin * half(mv);
        device const uchar * q = blk + 16 + 32 * j64 + 16 * hf;
        const int sh = sub * 4;
        NA_UNROLL for (int j = 0; j < 16; j++) o[j] = dl * half((q[j] >> sh) & 0xF) - ml;
    }
}

// Развернуть плитку весов BW × BK (от столбца k0) в общую память со строкой STRIDE.
template <int WF, int BW, int BK, int STRIDE, int NTH>
static inline void na_load_w(threadgroup half * dst, device const uchar * W, int wrow,
                             int w0, int k0, ushort tid) {
    constexpr int CH = BK / 16;
    for (int i = tid; i < BW * CH; i += NTH) {
        const int r = i / CH, cc = i % CH, k = k0 + cc * 16;
        device const uchar * blk = W + (long)(w0 + r) * wrow + (k / na_wf<WF>::QK) * na_wf<WF>::BS;
        half o[16];
        na_deq16<WF>(blk, (k % na_wf<WF>::QK) / 16, o);
        threadgroup half4 * d = (threadgroup half4 *)(dst + r * STRIDE + cc * 16);
        d[0] = half4(o[0],  o[1],  o[2],  o[3]);
        d[1] = half4(o[4],  o[5],  o[6],  o[7]);
        d[2] = half4(o[8],  o[9],  o[10], o[11]);
        d[3] = half4(o[12], o[13], o[14], o[15]);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// K0-GEMM — классический GEMM на simdgroup_matrix (так считает обычный путь ggml).
// Плитка группы BT×BW, WT×WW SIMD-групп, у каждой подплитка 32×32 (4×4 куска 8×8),
// шаг K 32 через общую память группы. WF = -1 — веса half; WF ≥ 0 — блочный формат,
// развёртка в общую память (= штатный ggml без тензоров, GGML_METAL_TENSOR_DISABLE).
// Не зависит от MPP: на мини (M1, macOS 15) по этим ядрам проверяется хост-код и
// эталонная развёртка всех форматов.
// ─────────────────────────────────────────────────────────────────────────────

template <int BT, int BW, int WT, int WW, int WF>
[[kernel, max_total_threads_per_threadgroup(WT * WW * 32)]]
void na_simd(device const half * X   [[buffer(0)]],
             device const uchar * Wb [[buffer(1)]],
             device float * Y        [[buffer(2)]],
             constant NAArgs & a   [[buffer(3)]],
             uint2  tg  [[threadgroup_position_in_grid]],
             ushort tid [[thread_index_in_threadgroup]],
             ushort sg  [[simdgroup_index_in_threadgroup]]) {
    constexpr int BK  = 32;
    constexpr int BKP = BK + 8;          // сдвиг строки против конфликтов банков
    constexpr int NTH = WT * WW * 32;
    constexpr int ST  = BT / WT;         // подплитка SIMD-группы: токены
    constexpr int SW  = BW / WW;         //                        строки весов
    static_assert(ST == 32 && SW == 32, "подплитка SIMD-группы — 32×32");

    threadgroup half sX[BT * BKP];
    threadgroup half sW[BW * BKP];

    const int t0 = tg.x * BT;
    const int w0 = tg.y * BW;
    const int st = (sg / WW) * ST;
    const int sw = (sg % WW) * SW;

    simdgroup_float8x8 c[4][4];
    NA_UNROLL for (int i = 0; i < 4; i++)
        NA_UNROLL for (int j = 0; j < 4; j++)
            c[i][j] = make_filled_simdgroup_matrix<float, 8>(0.0f);

    for (int k0 = 0; k0 < a.K; k0 += BK) {
        for (int i = tid; i < BT * (BK / 4); i += NTH) {
            const int r = i / (BK / 4), c4 = (i % (BK / 4)) * 4;
            *((threadgroup half4 *)(sX + r * BKP + c4)) =
                *((device const half4 *)(X + (long)(t0 + r) * a.ldx + k0 + c4));
        }
        if constexpr (WF < 0) {
            device const half * W = (device const half *)Wb;
            for (int i = tid; i < BW * (BK / 4); i += NTH) {
                const int r = i / (BK / 4), c4 = (i % (BK / 4)) * 4;
                *((threadgroup half4 *)(sW + r * BKP + c4)) =
                    *((device const half4 *)(W + (long)(w0 + r) * a.ldw + k0 + c4));
            }
        } else {
            na_load_w<(WF < 0 ? 0 : WF), BW, BK, BKP, NTH>(sW, Wb, a.wrow, w0, k0, tid);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        NA_UNROLL for (int kk = 0; kk < BK; kk += 8) {
            simdgroup_half8x8 ax[4], bw[4];
            NA_UNROLL for (int i = 0; i < 4; i++)
                simdgroup_load(ax[i], sX + (st + i * 8) * BKP + kk, BKP);
            // W лежит [строка весов][k] — грузим транспонированным, получаем [k][строка]
            NA_UNROLL for (int j = 0; j < 4; j++)
                simdgroup_load(bw[j], sW + (sw + j * 8) * BKP + kk, BKP, ulong2(0, 0), true);
            NA_UNROLL for (int i = 0; i < 4; i++)
                NA_UNROLL for (int j = 0; j < 4; j++)
                    simdgroup_multiply_accumulate(c[i][j], ax[i], bw[j], c[i][j]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    NA_UNROLL for (int i = 0; i < 4; i++)
        NA_UNROLL for (int j = 0; j < 4; j++)
            simdgroup_store(c[i][j], Y + (long)(t0 + st + i * 8) * a.ldy + (w0 + sw + j * 8), a.ldy);
}

#define NA_SIMD(BT, BW, WT, WW) \
template [[host_name("na_simd_" #BT "x" #BW)]] [[kernel]] \
decltype(na_simd<BT, BW, WT, WW, -1>) na_simd<BT, BW, WT, WW, -1>;
#define NA_SIMDQ(tn, BT, BW, WT, WW, WF) \
template [[host_name("na_simd_" #tn "_" #BT "x" #BW)]] [[kernel]] \
decltype(na_simd<BT, BW, WT, WW, WF>) na_simd<BT, BW, WT, WW, WF>;

NA_SIMD(64, 64, 2, 2)
NA_SIMD(128, 64, 4, 2)
NA_SIMD(128, 128, 4, 4)
NA_SIMDQ(q4a, 64, 64, 2, 2, 1)
NA_SIMDQ(q40, 64, 64, 2, 2, 2)
NA_SIMDQ(q80, 64, 64, 2, 2, 3)
NA_SIMDQ(q4k, 64, 64, 2, 2, 4)

#if defined(__HAVE_TENSOR__)

// Метка «тензоры в этой библиотеке есть». Ничего полезного не считает.
kernel void na_has_tensor(device int * p [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    p[i] = 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Metal 4 MPP: tensor_ops::matmul2d. Область исполнения: NSG = 0 — одна SIMD-группа
// (execution_simdgroup), NSG ≥ 1 — execution_simdgroups<NSG>. Замер tzakharko на A19:
// одна группа лучше; у Cider/tessl на M5 крупные плитки на много групп лучше. Кто прав
// на НАШИХ размерах — ради этого замер.
// ⚠️ Указатели device передаются в tensor() НЕконстантными: const «отравляет» подбор
// типов MPP (tessl, na-spec §1.6).
// ─────────────────────────────────────────────────────────────────────────────

template <int NSG> struct na_scope { using type = execution_simdgroups<NSG>; };
template <>        struct na_scope<0> { using type = execution_simdgroup; };

constexpr int na_threads(int nsg) { return nsg == 0 ? 32 : nsg * 32; }

// Обнулить накопитель. Раскладка cooperative tensor не документирована — трогаем только
// свои живые элементы. В примере заголовка MPP написано get_mask — в SDK 26.2 такого
// метода нет, есть is_valid_element (проверено компиляцией 24.09.2026).
template <typename CT, typename TA>
static inline void na_zero(thread CT & cT) {
    NA_UNROLL for (uint16_t i = 0; i < cT.get_capacity(); ++i) {
        if (cT.is_valid_element(i)) cT[i] = TA(0);
    }
}

// ── K1/K2/K3 — пик блоков по tzakharko (na-spec §2.1): одни и те же маленькие тензоры
// устройства (лежат в кэше), результат — кооперативный, iters одинаковых run подряд.
// Это потолок СЧЁТА без памяти; настоящий GEMM его не достигнет.
// Работа: группы × iters × 2·MT·NT·KT (iters кратно 4).
template <typename TL, typename TR, typename TA, int MT, int NT, int KT, int NSG>
[[kernel, max_total_threads_per_threadgroup(na_threads(NSG))]]
void na_peak(device const TL * A [[buffer(0)]],
             device const TR * B [[buffer(1)]],
             device TA * out     [[buffer(2)]],
             constant NAArgs & a [[buffer(3)]],
             uint tg [[threadgroup_position_in_grid]]) {
    using namespace mpp::tensor_ops;
    auto tA = tensor((device TL *)A, extents<int32_t, KT, MT>());
    auto tB = tensor((device TR *)B, extents<int32_t, KT, NT>());
    constexpr auto desc = matmul2d_descriptor(MT, NT, KT, false, true, true,
                                              matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, typename na_scope<NSG>::type> mm;
    auto cT = mm.template get_destination_cooperative_tensor<decltype(tA), decltype(tB), TA>();
    na_zero<decltype(cT), TA>(cT);
    for (int it = 0; it < a.iters; it += 4) {
        mm.run(tA, tB, cT);
        mm.run(tA, tB, cT);
        mm.run(tA, tB, cT);
        mm.run(tA, tB, cT);
    }
    auto tO = tensor(out + (long)tg * MT * NT, extents<int32_t, NT, MT>());
    cT.store(tO);
}

// ── GEMM, операнды прямо из памяти устройства. BK = 0 — K целиком одним вызовом
// (dynamic_extent: MPP сам крутит K, как у tessl §2.4), иначе цикл по K шагом BK
// с плитками постоянного размера (без проверок краёв внутри MPP).
template <typename TI, typename TA, int BT, int BW, int BK, int NSG, bool RELAX>
[[kernel, max_total_threads_per_threadgroup(na_threads(NSG))]]
void na_mpp_dev(device const TI * X [[buffer(0)]],
                device const TI * W [[buffer(1)]],
                device TA * Y       [[buffer(2)]],
                constant NAArgs & a [[buffer(3)]],
                uint2 tg [[threadgroup_position_in_grid]]) {
    using namespace mpp::tensor_ops;
    const int t0 = tg.x * BT;
    const int w0 = tg.y * BW;
    device TI * xp = (device TI *)(X + (long)t0 * a.ldx);
    device TI * wp = (device TI *)(W + (long)w0 * a.ldw);

    constexpr int KD = BK > 0 ? BK : int(dynamic_extent);
    constexpr auto desc = matmul2d_descriptor(BT, BW, KD, false, true, RELAX,
                                              matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, typename na_scope<NSG>::type> mm;
    auto tY = tensor(Y + (long)t0 * a.ldy + w0, extents<int32_t, BW, BT>(), array<int, 2>({1, a.ldy}));

    if constexpr (BK == 0) {
        auto tX = tensor(xp, dextents<int32_t, 2>(a.K, BT), array<int, 2>({1, a.ldx}));
        auto tW = tensor(wp, dextents<int32_t, 2>(a.K, BW), array<int, 2>({1, a.ldw}));
        auto cT = mm.template get_destination_cooperative_tensor<decltype(tX), decltype(tW), TA>();
        na_zero<decltype(cT), TA>(cT);
        mm.run(tX, tW, cT);
        cT.store(tY);
    } else {
        auto tX0 = tensor(xp, extents<int32_t, BK, BT>(), array<int, 2>({1, a.ldx}));
        auto tW0 = tensor(wp, extents<int32_t, BK, BW>(), array<int, 2>({1, a.ldw}));
        auto cT = mm.template get_destination_cooperative_tensor<decltype(tX0), decltype(tW0), TA>();
        na_zero<decltype(cT), TA>(cT);
        for (int k = 0; k < a.K; k += BK) {
            // Сдвиг — указателем, а не slice(): у tensor_inline срезы на части
            // компиляторов молча читают плитку (0,0) (Rigel, arXiv:2606.12765).
            auto mX = tensor(xp + k, extents<int32_t, BK, BT>(), array<int, 2>({1, a.ldx}));
            auto mW = tensor(wp + k, extents<int32_t, BK, BW>(), array<int, 2>({1, a.ldw}));
            mm.run(mX, mW, cT);
        }
        cT.store(tY);
    }
}

// Копия плитки ROWS × BK элементов в общую память (плотно) кусками по 16 байт —
// тип элемента не важен: half, bfloat, int8.
template <typename TI, int ROWS, int BK, int NTH>
static inline void na_copy_tile(threadgroup TI * dst, device const TI * src, int ld, ushort tid) {
    constexpr int CH = BK * (int)sizeof(TI) / 16;
    static_assert(CH >= 1 && (BK * (int)sizeof(TI)) % 16 == 0, "строка плитки — целые 16 байт");
    for (int i = tid; i < ROWS * CH; i += NTH) {
        const int r = i / CH, c = i % CH;
        ((threadgroup uint4 *)(dst + r * BK))[c] = ((device const uint4 *)(src + (long)r * ld))[c];
    }
}

// ── GEMM, операнды из общей памяти группы (обе плитки), двойной буфер — один барьер
// на шаг K (схема нашего ggml-ядра T, na-spec §3). WF ≥ 1 (только TI = half) — веса
// блочного формата разворачиваются в half при загрузке в общую память: (в) «наш» путь.
template <typename TI, typename TA, int BT, int BW, int BK, int NSG, int WF>
[[kernel, max_total_threads_per_threadgroup(na_threads(NSG))]]
void na_mpp_tg(device const TI * X     [[buffer(0)]],
               device const uchar * Wb [[buffer(1)]],
               device TA * Y           [[buffer(2)]],
               constant NAArgs & a     [[buffer(3)]],
               uint2  tg  [[threadgroup_position_in_grid]],
               ushort tid [[thread_index_in_threadgroup]]) {
    using namespace mpp::tensor_ops;
    constexpr int NTH = na_threads(NSG);
    threadgroup TI sX[2][BT * BK];
    threadgroup TI sW[2][BW * BK];

    const int t0 = tg.x * BT;
    const int w0 = tg.y * BW;
    device const TI * xp = X + (long)t0 * a.ldx;

    constexpr auto desc = matmul2d_descriptor(BT, BW, BK, false, true, true,
                                              matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, typename na_scope<NSG>::type> mm;

    auto tX0 = tensor((threadgroup TI *)sX[0], extents<int32_t, BK, BT>());
    auto tW0 = tensor((threadgroup TI *)sW[0], extents<int32_t, BK, BW>());
    auto cT = mm.template get_destination_cooperative_tensor<decltype(tX0), decltype(tW0), TA>();
    na_zero<decltype(cT), TA>(cT);

    short buf = 0;
    for (int k0 = 0; k0 < a.K; k0 += BK, buf ^= 1) {
        na_copy_tile<TI, BT, BK, NTH>(sX[buf], xp + k0, a.ldx, tid);
        if constexpr (WF == 0) {
            device const TI * wp = (device const TI *)Wb + (long)w0 * a.ldw;
            na_copy_tile<TI, BW, BK, NTH>(sW[buf], wp + k0, a.ldw, tid);
        } else {
            na_load_w<WF, BW, BK, BK, NTH>((threadgroup half *)sW[buf], Wb, a.wrow, w0, k0, tid);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        auto mX = tensor((threadgroup TI *)sX[buf], extents<int32_t, BK, BT>());
        auto mW = tensor((threadgroup TI *)sW[buf], extents<int32_t, BK, BW>());
        mm.run(mX, mW, cT);
        // Второго барьера нет: следующий шаг пишет в другой буфер, а в этот — только
        // после следующего барьера, которого все достигнут, закончив это умножение.
    }

    auto tY = tensor(Y + (long)t0 * a.ldy + w0, extents<int32_t, BW, BT>(), array<int, 2>({1, a.ldy}));
    cT.store(tY);
}

// ─────────────────────────────────────────────────────────────────────────────
// Схема MLX (steel/gemm/nax.h, quantized_nax.h; © 2025 Apple, MIT) — то, что стоит в
// нашем ggml-ядре N (kernel_mul_mm_nax): каждая SIMD-группа считает СВОЮ подплитку
// 32×32 кусками matmul2d<16,32,16, execution_simdgroup>, операнды — кооперативные
// тензоры в регистрах, раскладка элементов — как у MLX (Apple её не документирует,
// na-spec §1.5). Внутри K-цикла — `volatile int compiler_barrier`, как у MLX и Cider:
// иначе компилятор поднимает все загрузки над всеми run и выливает регистры (§1.6).
// ─────────────────────────────────────────────────────────────────────────────

namespace na_reg_detail {

// Нить lane владеет строками fm и fm+8, столбцами fn..fn+3 куска 16×16 (как у MLX).
static inline short2 frag_coord(ushort lane) {
    const short qid = lane >> 2;
    const short fm  = ((qid & 4) | ((lane >> 1) & 3));
    const short fn  = ((qid & 2) | (lane & 1)) * 4;
    return short2(fn, fm);
}

// C(16×32) += A(16×16) · Bᵀ, где B — два куска 16×16 в виде [строка весов][k].
// TI — тип входов (half или int8_t), TA — накопитель (float или int32_t).
template <typename TI, typename TA>
static inline void mma(thread vec<TA, 8> & c0, thread vec<TA, 8> & c1,
                       thread const vec<TI, 8> & a, thread const vec<TI, 8> & b0,
                       thread const vec<TI, 8> & b1) {
    constexpr auto desc = mpp::tensor_ops::matmul2d_descriptor(
        16, 32, 16, false, true, true,
        mpp::tensor_ops::matmul2d_descriptor::mode::multiply_accumulate);
    mpp::tensor_ops::matmul2d<desc, execution_simdgroup> op;

    auto ca = op.template get_left_input_cooperative_tensor<TI, TI, TA>();
    auto cb = op.template get_right_input_cooperative_tensor<TI, TI, TA>();
    auto cc = op.template get_destination_cooperative_tensor<decltype(ca), decltype(cb), TA>();

    NA_UNROLL for (short i = 0; i < 8; i++) {
        ca[i]     = a[i];
        cb[i]     = b0[i];
        cb[8 + i] = b1[i];
        cc[i]     = c0[i];
        cc[8 + i] = c1[i];
    }
    op.run(ca, cb, cc);
    NA_UNROLL for (short i = 0; i < 8; i++) {
        c0[i] = cc[i];
        c1[i] = cc[8 + i];
    }
}

// Прочитать 4 подряд (из памяти устройства или общей) в четыре слота фрагмента.
template <typename TI, typename P>
static inline void load4(thread vec<TI, 8> & f, int slot, P p) {
    const vec<TI, 4> v = *p;
    f[slot] = v[0]; f[slot + 1] = v[1]; f[slot + 2] = v[2]; f[slot + 3] = v[3];
}

} // namespace na_reg_detail

// ── K4 — кооперативная mma MLX в цикле, операнды в регистрах (путь нашего N без
// памяти). Каждая SIMD-группа: фрагменты читаются один раз (из A: 32×32 «токенов»
// и 32×32 «весов»), дальше iters × 4 mma 16×32×16.
// Работа: группы × 4 SIMD-группы × iters × 4 × 16384 оп.
template <typename TI, typename TA>
[[kernel, max_total_threads_per_threadgroup(128)]]
void na_k4(device const TI * A [[buffer(0)]],
           device TA * out     [[buffer(2)]],
           constant NAArgs & a [[buffer(3)]],
           uint   tg   [[threadgroup_position_in_grid]],
           ushort sg   [[simdgroup_index_in_threadgroup]],
           ushort lane [[thread_index_in_simdgroup]]) {
    using namespace na_reg_detail;
    const short2 fc = frag_coord(lane);
    vec<TI, 8> x[2][2], w[2][2];
    NA_UNROLL for (int i = 0; i < 2; i++)
        NA_UNROLL for (int k = 0; k < 2; k++)
            NA_UNROLL for (int r = 0; r < 2; r++) {
                const int row = i * 16 + fc.y + r * 8;
                load4<TI>(x[i][k], r * 4, (device const vec<TI, 4> *)(A + row * 32 + k * 16 + fc.x));
                load4<TI>(w[i][k], r * 4, (device const vec<TI, 4> *)(A + 1024 + row * 32 + k * 16 + fc.x));
            }
    vec<TA, 8> D[2][2];
    NA_UNROLL for (int i = 0; i < 2; i++)
        NA_UNROLL for (int j = 0; j < 2; j++)
            D[i][j] = vec<TA, 8>(0);
    for (int it = 0; it < a.iters; it++) {
        NA_UNROLL for (int i = 0; i < 2; i++)
            NA_UNROLL for (int k = 0; k < 2; k++)
                mma<TI, TA>(D[i][0], D[i][1], x[i][k], w[0][k], w[1][k]);
    }
    device TA * o = out + ((long)tg * 4 + sg) * 32 * 32;
    NA_UNROLL for (int i = 0; i < 2; i++)
        NA_UNROLL for (int j = 0; j < 2; j++)
            NA_UNROLL for (int r = 0; r < 2; r++) {
                const int row = i * 16 + fc.y + r * 8;
                const int col = j * 16 + fc.x;
                NA_UNROLL for (int q = 0; q < 4; q++) o[row * 32 + col + q] = D[i][j][r * 4 + q];
            }
}

// ── GEMM по схеме MLX. X (half или int8) — прямо из памяти устройства в регистры.
//   WF = -1 — веса тоже прямо из памяти в регистры, без общей памяти (fp16-путь MLX,
//             Cider «шаг 2», na-spec §2.2–2.3);
//   WF ≥  0 — веса через общую память группы: 0 — f16 копией, 1..4 — развёртка блочного
//             формата (q4a/q40/q80/q4k) = наше ядро N; шаг K 64, два барьера на шаг.
template <typename TI, typename TA, int BT, int BW, int WT, int WW, int WF>
[[kernel, max_total_threads_per_threadgroup(WT * WW * 32)]]
void na_reg(device const TI * X      [[buffer(0)]],
            device const uchar * Wb  [[buffer(1)]],
            device TA * Y            [[buffer(2)]],
            constant NAArgs & a      [[buffer(3)]],
            uint2  tg   [[threadgroup_position_in_grid]],
            ushort tid  [[thread_index_in_threadgroup]],
            ushort sg   [[simdgroup_index_in_threadgroup]],
            ushort lane [[thread_index_in_simdgroup]]) {
    using namespace na_reg_detail;
    constexpr int BK  = 64;          // шаг по K на одну загрузку плитки весов
    constexpr int BKP = BK + 8;      // строка плитки весов со сдвигом (как у MLX)
    constexpr int SK  = 32;          // K за один проход по регистрам
    constexpr int TK  = SK / 16;
    constexpr int ST  = BT / WT;
    constexpr int SW  = BW / WW;
    constexpr int TT  = ST / 16;
    constexpr int TW  = SW / 16;
    constexpr int NTH = WT * WW * 32;
    static_assert(TW % 2 == 0, "подплитка по весам должна быть кратна 32");
    static_assert(WF < 0 || is_same<TI, half>::value, "общая память — только для half-весов");

    // Общая память нужна только при WF ≥ 0; иначе массив в один элемент (не используется).
    threadgroup half ws[WF < 0 ? 1 : BW * BKP];

    const int t0 = tg.x * BT;
    const int w0 = tg.y * BW;
    const int sg_t = ST * (sg / WW);
    const int sg_w = SW * (sg % WW);

    device const TI * xb = X + (long)(t0 + sg_t) * a.ldx;
    device const TI * wb = (device const TI *)Wb + (long)(w0 + sg_w) * a.ldw;
    const short2 fc = frag_coord(lane);

    vec<TA, 8> D[TT][TW];
    NA_UNROLL for (int i = 0; i < TT; i++)
        NA_UNROLL for (int j = 0; j < TW; j++)
            D[i][j] = vec<TA, 8>(0);

    for (int k0 = 0; k0 < a.K; k0 += BK) {
        if constexpr (WF >= 0) {
            threadgroup_barrier(mem_flags::mem_threadgroup);
            na_load_w<(WF < 0 ? 0 : WF), BW, BK, BKP, NTH>(ws, Wb, a.wrow, w0, k0, tid);
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        NA_UNROLL for (int kk = 0; kk < BK; kk += SK) {
            vec<TI, 8> A[TT][TK];
            vec<TI, 8> B[TW][TK];
            volatile int compiler_barrier;
            (void) compiler_barrier;
            NA_UNROLL for (int tt = 0; tt < TT; tt++)
                NA_UNROLL for (int tk = 0; tk < TK; tk++)
                    NA_UNROLL for (int r = 0; r < 2; r++) {
                        const int row = tt * 16 + fc.y + r * 8;
                        load4<TI>(A[tt][tk], r * 4,
                                  (device const vec<TI, 4> *)(xb + (long)row * a.ldx + k0 + kk + tk * 16 + fc.x));
                    }
            NA_UNROLL for (int tw = 0; tw < TW; tw++)
                NA_UNROLL for (int tk = 0; tk < TK; tk++)
                    NA_UNROLL for (int r = 0; r < 2; r++) {
                        const int row = tw * 16 + fc.y + r * 8;
                        if constexpr (WF < 0) {
                            load4<TI>(B[tw][tk], r * 4,
                                      (device const vec<TI, 4> *)(wb + (long)row * a.ldw + k0 + kk + tk * 16 + fc.x));
                        } else {
                            load4<TI>(B[tw][tk], r * 4,
                                      (threadgroup const vec<TI, 4> *)(ws + (sg_w + row) * BKP + kk + tk * 16 + fc.x));
                        }
                    }
            NA_UNROLL for (int tt = 0; tt < TT; tt++)
                NA_UNROLL for (int tw = 0; tw < TW; tw += 2)
                    NA_UNROLL for (int tk = 0; tk < TK; tk++)
                        mma<TI, TA>(D[tt][tw], D[tt][tw + 1], A[tt][tk], B[tw][tk], B[tw + 1][tk]);
        }
    }

    device TA * dp = Y + (long)(t0 + sg_t) * a.ldy + (w0 + sg_w);
    NA_UNROLL for (int tt = 0; tt < TT; tt++)
        NA_UNROLL for (int tw = 0; tw < TW; tw++)
            NA_UNROLL for (int r = 0; r < 2; r++) {
                const int row = tt * 16 + fc.y + r * 8;
                const int col = tw * 16 + fc.x;
                device TA * p = dp + (long)row * a.ldy + col;
                NA_UNROLL for (int q = 0; q < 4; q++) p[q] = D[tt][tw][r * 4 + q];
            }
}

// ─────────────────────────────────────────────────────────────────────────────
// Экземпляры. Имена ⇄ NABenchKernels в NABench.swift — менять парой.
//   na_peak_<тип>_<MTxNTxKT>_s<NSG>          K1 (hf), K2 (i8), K3 (bf, hF, ff, hh, s4)
//   na_k4_<тип>                              K4
//   na_dev_<тип>_<BTxBWxBK>_s<NSG>[_x]       GEMM, операнды из памяти (BK 0 = K целиком; _x — без relaxed)
//   na_tg_<тип>_<BTxBWxBK>_s<NSG>            GEMM, операнды через общую память
//   na_reg_<веса>_<BT>x<BW>                  GEMM по схеме MLX
// Типы: hf — half×half→float, hh — half×half→half, bf — bfloat×bfloat→float,
//       hF — half×float→float, ff — float×float→float, i8 — int8×int8→int32;
//       веса блочных форматов (× half-активации → float): q4a, q40, q80, q4k, f16;
//       у na_reg: hd — half-веса прямо из памяти, i8 — int8×int8 прямо из памяти.
// ─────────────────────────────────────────────────────────────────────────────

#define NA_PEAK(tn, TL, TR, TA, MT, NT, KT, NSG) \
template [[host_name("na_peak_" #tn "_" #MT "x" #NT "x" #KT "_s" #NSG)]] [[kernel]] \
decltype(na_peak<TL, TR, TA, MT, NT, KT, NSG>) na_peak<TL, TR, TA, MT, NT, KT, NSG>;

NA_PEAK(hf, half, half, float, 16, 32, 16, 0)
NA_PEAK(hf, half, half, float, 32, 32, 16, 1)
NA_PEAK(hf, half, half, float, 32, 32, 32, 1)
NA_PEAK(hf, half, half, float, 32, 32, 64, 1)
NA_PEAK(hf, half, half, float, 32, 32, 32, 0)
NA_PEAK(i8, int8_t, int8_t, int32_t, 32, 32, 32, 1)
NA_PEAK(i8, int8_t, int8_t, int32_t, 32, 32, 64, 1)
NA_PEAK(i8, int8_t, int8_t, int32_t, 32, 32, 32, 0)
NA_PEAK(bf, bfloat, bfloat, float, 32, 32, 32, 1)
NA_PEAK(hF, half, float, float, 32, 32, 32, 1)
NA_PEAK(ff, float, float, float, 32, 32, 32, 1)
NA_PEAK(hh, half, half, half, 32, 32, 32, 1)
NA_PEAK(hf, half, half, float, 64, 64, 32, 4)

template [[host_name("na_k4_hf")]] [[kernel]] decltype(na_k4<half, float>) na_k4<half, float>;
template [[host_name("na_k4_i8")]] [[kernel]] decltype(na_k4<int8_t, int32_t>) na_k4<int8_t, int32_t>;

#define NA_DEV(tn, TI, TA, BT, BW, BK, NSG, RELAX, sfx) \
template [[host_name("na_dev_" #tn "_" #BT "x" #BW "x" #BK "_s" #NSG sfx)]] [[kernel]] \
decltype(na_mpp_dev<TI, TA, BT, BW, BK, NSG, RELAX>) na_mpp_dev<TI, TA, BT, BW, BK, NSG, RELAX>;

// half × half → float: сетка плиток и областей исполнения
NA_DEV(hf, half, float,  16,  32, 16, 0, true, "")
NA_DEV(hf, half, float,  32,  32, 32, 0, true, "")
NA_DEV(hf, half, float,  32,  32, 32, 1, true, "")
NA_DEV(hf, half, float,  32,  64, 32, 0, true, "")
NA_DEV(hf, half, float,  64,  32,  0, 4, true, "")
NA_DEV(hf, half, float,  64,  64, 32, 1, true, "")
NA_DEV(hf, half, float,  64,  64, 32, 2, true, "")
NA_DEV(hf, half, float,  64,  64, 32, 4, true, "")
NA_DEV(hf, half, float,  64,  64, 64, 4, true, "")
NA_DEV(hf, half, float,  64,  64,  0, 4, true, "")
NA_DEV(hf, half, float, 128,  64, 32, 4, true, "")
NA_DEV(hf, half, float, 128,  64,  0, 4, true, "")
NA_DEV(hf, half, float,  64, 128,  0, 4, true, "")
NA_DEV(hf, half, float, 256,  64,  0, 8, true, "")
NA_DEV(hf, half, float,  64, 256,  0, 8, true, "")
NA_DEV(hf, half, float, 128, 128, 32, 4, true, "")
NA_DEV(hf, half, float, 128, 128,  0, 4, true, "")
NA_DEV(hf, half, float, 128, 128, 32, 8, true, "")
NA_DEV(hf, half, float, 128, 128, 64, 16, true, "")
NA_DEV(hf, half, float,  64,  64, 32, 4, false, "_x")
// half × half → half
NA_DEV(hh, half, half,   32,  32, 32, 0, true, "")
NA_DEV(hh, half, half,   64,  64, 32, 4, true, "")
NA_DEV(hh, half, half,  128, 128, 32, 4, true, "")
// bfloat × bfloat → float (блоки первого поколения его могут не ускорять — узнаем)
NA_DEV(bf, bfloat, float, 32,  32, 32, 0, true, "")
NA_DEV(bf, bfloat, float, 64,  64, 32, 4, true, "")
NA_DEV(bf, bfloat, float, 128, 128, 32, 4, true, "")
// int8 × int8 → int32
NA_DEV(i8, int8_t, int32_t, 32,  32, 32, 0, true, "")
NA_DEV(i8, int8_t, int32_t, 32,  32, 64, 0, true, "")
NA_DEV(i8, int8_t, int32_t, 64,  64, 64, 1, true, "")
NA_DEV(i8, int8_t, int32_t, 64,  64, 64, 4, true, "")
NA_DEV(i8, int8_t, int32_t, 128, 128, 64, 4, true, "")
NA_DEV(i8, int8_t, int32_t, 128, 128,  0, 4, true, "")
NA_DEV(i8, int8_t, int32_t, 128, 128, 64, 16, true, "")

#define NA_TG(tn, TI, TA, BT, BW, BK, NSG, WF) \
template [[host_name("na_tg_" #tn "_" #BT "x" #BW "x" #BK "_s" #NSG)]] [[kernel]] \
decltype(na_mpp_tg<TI, TA, BT, BW, BK, NSG, WF>) na_mpp_tg<TI, TA, BT, BW, BK, NSG, WF>;

// Общая память группы — 32 КБ: 2 буфера × (BT + BW) × BK × размер элемента.
NA_TG(hf, half, float,  32,  32, 32, 0, 0)
NA_TG(hf, half, float,  64,  64, 32, 1, 0)
NA_TG(hf, half, float,  64,  64, 32, 4, 0)
NA_TG(hf, half, float,  64,  64, 64, 4, 0)
NA_TG(hf, half, float, 128,  64, 32, 4, 0)
NA_TG(hf, half, float, 128, 128, 32, 4, 0)
NA_TG(hf, half, float, 128, 128, 32, 16, 0)
NA_TG(bf, bfloat, float, 64, 64, 32, 4, 0)
NA_TG(i8, int8_t, int32_t, 64,  64, 64, 4, 0)
NA_TG(i8, int8_t, int32_t, 128, 128, 64, 4, 0)
NA_TG(i8, int8_t, int32_t, 128, 128, 64, 16, 0)
// «наш» путь (в): развёртка блочных весов в общую память + matmul2d
NA_TG(q4a, half, float,  64,  64, 64, 4, 1)
NA_TG(q4a, half, float, 128, 128, 32, 4, 1)
NA_TG(q4a, half, float, 128, 128, 32, 16, 1)
NA_TG(q4a, half, float,  32,  32, 64, 0, 1)
NA_TG(q40, half, float, 128, 128, 32, 4, 2)
NA_TG(q80, half, float, 128, 128, 32, 4, 3)
NA_TG(q4k, half, float, 128, 128, 32, 4, 4)
NA_TG(q4k, half, float,  64,  64, 64, 4, 4)

#define NA_REG(tn, TI, TA, BT, BW, WT, WW, WF) \
template [[host_name("na_reg_" #tn "_" #BT "x" #BW)]] [[kernel]] \
decltype(na_reg<TI, TA, BT, BW, WT, WW, WF>) na_reg<TI, TA, BT, BW, WT, WW, WF>;

NA_REG(hd,  half, float,  64,  64, 2, 2, -1)
NA_REG(hd,  half, float, 128, 128, 4, 4, -1)
NA_REG(hd,  half, float,  64, 128, 2, 4, -1)
NA_REG(i8,  int8_t, int32_t,  64,  64, 2, 2, -1)
NA_REG(i8,  int8_t, int32_t, 128, 128, 4, 4, -1)
NA_REG(f16, half, float,  64,  64, 2, 2, 0)
NA_REG(f16, half, float, 128, 128, 4, 4, 0)
NA_REG(q4a, half, float,  64,  64, 2, 2, 1)
NA_REG(q4a, half, float, 128, 128, 4, 4, 1)
NA_REG(q40, half, float,  64,  64, 2, 2, 2)
NA_REG(q40, half, float, 128, 128, 4, 4, 2)
NA_REG(q80, half, float,  64,  64, 2, 2, 3)
NA_REG(q80, half, float, 128, 128, 4, 4, 3)
NA_REG(q4k, half, float,  64,  64, 2, 2, 4)
NA_REG(q4k, half, float, 128, 128, 4, 4, 4)

#endif // __HAVE_TENSOR__
