# Contributing to Usagebar

Thank you for helping improve Usagebar. The project favors small, reviewable changes that preserve a fast, private, native macOS experience.

## Before you start

- Search existing issues and pull requests before opening a duplicate.
- Use the bug or feature issue form for changes that need discussion.
- Keep provider credentials, session cookies, account identifiers, and raw API responses out of issues, commits, screenshots, and logs.
- Follow [SECURITY.md](SECURITY.md) for security-sensitive reports.

## Development setup

Requirements: Xcode 26+, the bundled macOS SDK, and Git. The app targets macOS 14+.

```bash
git clone https://github.com/betoxf/Usagebar.git
cd Usagebar
./script/build_and_run.sh --verify
```

The script stops an existing Usagebar process, builds a Debug app into `build/CodexDerivedData`, launches the fresh bundle, and verifies the process. It also supports `--debug`, `--logs`, and `--telemetry`.

Use `make build` for a compile-only build.

Run `./script/test_performance.sh` for deterministic scheduling, cancellation, credential-snapshot, timer-lifetime, menu, and image-cache regression tests. Scheduling tests use fake providers; rendering tests compile the real AppKit renderers with fixture state. Both use an isolated preferences domain and never read provider credentials or contact provider APIs. Set `USAGEBAR_RENDER_OUTPUT=/absolute/path/preview.png` to save light/dark rendering previews.

For local performance measurements, use a Release build:

```bash
USAGEBAR_BUILD_CONFIGURATION=Release USAGEBAR_DISABLE_AUTO_UPDATE=1 ./script/build_and_run.sh --verify
```

`USAGEBAR_DERIVED_DATA` can place build output outside a synced folder. `USAGEBAR_DISABLE_AUTO_UPDATE=1` applies only to the launched process and keeps local test builds from starting an automatic Homebrew update. Compare the same provider settings after initial credential discovery and requests have settled.

## Project structure

- `JustaUsageBar/Models`: usage-domain data types
- `JustaUsageBar/Services`: credential discovery and provider clients
- `JustaUsageBar/ViewModels`: refresh orchestration and preferences
- `JustaUsageBar/Views`: AppKit and SwiftUI presentation
- `JustaUsageBar/Assets.xcassets`: app and menu assets
- `Casks`: Homebrew distribution definitions
- `docs`: architecture and maintainer documentation

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing authentication, networking, storage, or refresh behavior.

## Change standards

1. Create a focused branch from an up-to-date `main`.
2. Match the existing Swift style and keep changes narrowly scoped.
3. Preserve main-actor isolation for UI state and avoid unnecessary timers or polling.
4. Treat provider payloads as untrusted and handle missing or changed fields defensively.
5. Never add telemetry, a proxy backend, or new credential persistence without explicit design review.
6. Update documentation when behavior, authentication, requirements, or release steps change.

## Validation

Every pull request should include evidence matching its blast radius:

- Build the `JustaUsageBar` scheme.
- Launch the freshly built app for runtime changes.
- Check light and dark menu-bar appearances for UI changes.
- Verify Claude-only, Codex-only, and dual-provider states when provider display logic changes.
- Confirm no secrets or account data appear in logs.
- Include screenshots for visible changes when practical.

Use an imperative commit subject, keep unrelated cleanup separate, and call out credential, network, storage, signing, or Homebrew impact explicitly. Maintainers should follow [docs/RELEASING.md](docs/RELEASING.md).
