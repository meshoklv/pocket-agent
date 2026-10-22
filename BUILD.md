# Building

> **Not verified by the author for this release copy**: no Xcode was available when the repo was prepared,
> so the steps below come from the project's own configuration and have not been re-run.

Requirements: macOS with Xcode 26.2, [XcodeGen](https://github.com/yonaskolb/XcodeGen), a physical iPhone
(the simulator cannot run the on-device GPU engine), an Apple developer account for signing.

1. Set your identity in `project.yml`: `bundleIdPrefix`, `PRODUCT_BUNDLE_IDENTIFIER`
   (default `com.example.pocketagent`) and `DEVELOPMENT_TEAM: YOUR_TEAM_ID` (or pick the team in Xcode).
2. Put the optional native engines in place (they are git-ignored, too big for git):
   ```bash
   . tools/mac/pa-vendor.sh
   ensure_llama_framework "$PWD"   # Bonsai/llama.cpp engine, downloaded
   ensure_sd_framework "$PWD"      # image engine, built from a pinned commit
   ```
   `Vendor/LiteRTLM/Package.swift` downloads the LiteRT-LM binary by URL + checksum.
3. `xcodegen generate && open PocketAgent.xcodeproj`, select your iPhone, press Run.
4. Get the model: the app downloads it on first launch, or run `scripts/download-model.sh`
   and copy the file to the phone via the Files app.

`.github/workflows/build.yml` is an unsigned compile check on a macOS runner; it needs no secrets.

