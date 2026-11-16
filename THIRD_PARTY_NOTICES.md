# Third-party components

## Playwright Core

Microsoft Playwright Core 1.62.1, Apache-2.0. Used only by the independent Mac Chrome account tool. The pinned package is stored in `tools/chrome/vendor/`; its upstream LICENSE and NOTICE are retained inside the package and distributed runtime.

Source: https://github.com/microsoft/playwright

## Node.js

The Mac Chrome helper embeds an official standalone Node.js runtime. Its complete upstream license and notices are distributed as `ChromeRuntime/runtime/NODE-LICENSE`. The helper does not implement workspace or photo business logic.

Source: https://github.com/nodejs/node

## Sparkle

Sparkle 2.9.6 provides in-app updates for the macOS version. The upstream license is bundled as `Sparkle-LICENSE.txt`.

Source: https://github.com/sparkle-project/Sparkle/tree/2.9.6

## SQLite

The native applications use the operating system's SQLite3 library. SQLite is in the public domain. No bundled Rust SQLite library is distributed.

Source: https://sqlite.org/copyright.html

## Platform marks and application artwork

The platform logos identify the user's own account platforms and remain the property of their respective owners. Their original source metadata is retained in `apple/Packages/WorkBenchKit/Sources/WorkBenchKit/Resources/platform-sources.json`.

The approved ZHH application artwork and its source image are retained in `assets/branding/`.
