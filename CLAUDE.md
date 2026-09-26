# CLAUDE.md — handlive-apple

macOS and iOS/iPadOS apps of HandLive (Swift 6, macOS 13+ / iOS 16+; XcodeGen `project.yml`, packages `HLProtocol`, `HLCrypto`, `HLTransport`, `HLDesignSystem`, `HLLocalization`, `HLAppCore`, `HLMacUI`). The apps receive data from Android and send data back. One part of the HandLive **workspace**: the hub repository `handlive` is this directory's parent, holds the specification that all code implements, and its `CLAUDE.md` applies here in full.

## Workspace layout (mandatory)

```
<workspace>/        hub repo "handlive": CLAUDE.md (read first), docs/, plans/, tools/docs/, tools/workspace.sh
  apple/            this repo (handlive-apple)
  shared/           repo "handlive-shared": test-vectors/, schemas/, design-tokens/, tools/
```

Package tests resolve the workspace root from `#filePath` (six levels up) and read `../shared/test-vectors`, `../shared/schemas`; `HLDesignSystem` tests also read `../shared/design-tokens/tokens.json`, `../docs/design-system/1-foundations/03-kieu-chu.md` and use `../shared/tools/.venv/bin/python` when present. Outside this layout the tests fail. From the hub, `tools/workspace.sh clone <group-url>` checks the parts out.

## Working here

- Read in this order: `../CLAUDE.md` → `../docs/detailed-design/README.md` → `../docs/detailed-design/00-common-specs.md` → the phase file in `../plans/20260925-implementation/` → the leaf specs it names → `../docs/code-standards.md`. UI work also reads `../docs/design-system/README.md`, `../docs/design-system/3-platforms/01-macos.md` or `02-ios-ipados.md` and the component READMEs.
- Contracts (wire format, error codes, settings keys, UI strings) come from the hub docs; change them there first, never in code. Test vectors, schemas and tokens change only in `../shared` (repo handlive-shared) as their own commits — say so in the report so the Android and relay agents re-run their tests.
- Build and test: with Xcode, `cd Packages/<Pkg> && xcodebuild test -scheme <Pkg> -destination 'platform=macOS'`; with Command Line Tools only, `HL_SWIFT_TESTING_PACKAGE=1 swift test` in the package (always set it under Command Line Tools: it also switches the String Catalogs to their `.lproj` fallback; SwiftUI packages need `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk` when a newer SDK is installed). The app target builds only with Xcode, so keep its sources thin and put logic in `HLMacUI`. `xcodegen generate` makes `HandLive.xcodeproj` (git-ignored); `swiftlint lint --strict` (`TOOLCHAIN_DIR=/Library/Developer/CommandLineTools` without Xcode). Source files are named in PascalCase after their main type (`../docs/code-standards.md`).
- Branches: `feat/phase-0N-<slug>` per phase. Commit early and small — one commit per logical step (scaffold, module, tests, docs), conventional commits (`feat(apple): …`, `test(apple): …`), no AI references. A commit never spans repositories. Commit before writing the report and list the hashes with the repository name in `../plans/20260925-implementation/reports/`.
- CI (`.github/workflows/ci-apple.yml`) reproduces the layout: hub at the workspace root, this repo into `apple/`, handlive-shared into `shared/`. It does not run when only shared or docs change — start it by hand (workflow_dispatch).
