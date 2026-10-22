# Third-party notices

Pocket Agent itself is MIT-licensed (see `LICENSE`). It uses or bundles the
components below under their own licenses. Versions are taken from the repo
files (`Vendor/*`, `project.yml`, `PlaygroundLib/manifest.json`); license
names are as declared there or in the upstream projects and should be
re-verified before a release.

## Models (NOT included in this repository)

| Model | Used for | License |
|---|---|---|
| Gemma 4 E2B (`litert-community/gemma-4-E2B-it-litert-lm`) | default on-device model | Declared in the app catalog as Apache 2.0. **Verify on the model card before you redistribute.** Earlier Gemma generations (e.g. Gemma 3n) were under the Gemma Terms of Use (https://ai.google.dev/gemma/terms) with its Prohibited Use Policy; if you use such a model, those terms apply to you. |

The model is never bundled: it is downloaded on first launch (or with
`scripts/download-model.sh`) from Hugging Face. You are responsible for
complying with the model's license.

## Code

| Component | Where | License |
|---|---|---|
| LiteRT-LM Swift wrapper (Google, v0.15.0) | `Vendor/LiteRTLM` (copy of `swift/`) | Apache-2.0 (`Vendor/LiteRTLM/LICENSE`) |
| mlx-swift-lm 3.31.4 (Apple) | SwiftPM dependency | MIT |
| swift-transformers 1.3.3 (Hugging Face) | SwiftPM dependency | Apache-2.0 |
| llama.cpp (PrismML fork) | downloaded by `tools/mac/pa-vendor.sh` | MIT |
| stable-diffusion.cpp | built by `tools/mac/pa-vendor.sh` | MIT |

## Bundled JavaScript/CSS libraries (`PocketAgent/Resources/PlaygroundLib`)

Used by the in-app web "playground" so generated pages work offline. Each
library directory contains its own license file.

| Library | License |
|---|---|
| **Phaser** 3.90.0 | MIT |
| **p5.js** 1.11.10 | **LGPL-2.1** (full text in `p5/license.txt`; the minified file is shipped unmodified) |
| three.js, PixiJS, Matter.js, cannon-es, cannon.js, Tone.js, howler.js, Chart.js, Bootstrap, Pico CSS, Water.css, Tailwind (browser build), Alpine.js, jQuery, anime.js, Motion One, Lodash, Day.js, marked, QRCode.js, node-qrcode, lil-gui, stats.js | MIT |
| D3, canvas-confetti | ISC |

Exact versions: `PocketAgent/Resources/PlaygroundLib/manifest.json`.
Re-fetch with `tools/fetch-playground-libs.py`.
