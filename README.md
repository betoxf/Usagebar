# Just A Usage Bar

<p align="center">
  <img src="images/image3.png" alt="JustaUsageBar screenshot" width="600">
</p>

A lightweight macOS menu bar app that shows your **Claude** and **Codex** (OpenAI) usage at a glance -- 5-hour rolling window and 7-day limits, right in your menu bar.

<p align="center">
  <img src="images/demo.gif" alt="JustaUsageBar demo" width="600">
</p>

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Install

```bash
brew install betoxf/tap/justausagebar
```

That's it. If you have Claude CLI or Codex CLI logged in, the app auto-detects your credentials -- zero config.

## Update

If you already have the app installed, update it with:

```bash
brew update
brew upgrade --cask justausagebar
```

If you installed manually, download the latest `JustaUsageBar.app` from Releases and replace the copy in `/Applications`.

> **No Homebrew?** Run this instead:
> ```bash
> /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/betoxf/JustaUsageBar/main/install.sh)"
> ```

---

## Quick Start

1. **Install** -- `brew install betoxf/tap/justausagebar`
2. **Launch** -- open JustaUsageBar from Applications (or `open -a JustaUsageBar`)
3. **Done** -- if you use Claude CLI or Codex CLI, credentials are detected automatically

If you don't use the CLIs, click the menu bar item > **Setup Usage Tracking** > **Sign in with Browser**.

---

## Features

- Shows 5-hour and 7-day usage percentages for **Claude** and **Codex**
- Auto-detects Claude CLI and Codex CLI credentials (OAuth) -- zero setup
- Smooth dissolve animation alternating between providers in the menu bar
- Configurable switch interval (5s / 8s / 10s / 15s / 30s)
- Display modes: Both percentages, 5h only, or Weekly only
- Toggle providers: show Claude, Codex, or both
- Temporary Codex `2x` promo badge with compact dropdown countdown/date display while the promo is active
- Claude peak-hours indicator with animated downward badge during faster-consumption windows
- Auto-refreshes OAuth tokens when expired
- Falls back to browser session login for Claude if CLI not available
- Launch at Login support
- Minimal resource usage (~0% CPU when idle)

## Menu Bar

| Provider | Label | Style |
|----------|-------|-------|
| Claude | `✳︎ Claude` | Anthropic orange accents |
| Codex | `> Codex` | Terminal icon, subtle blue accents |

When both providers are active, the menu bar alternates between them with a smooth dissolve animation. Left-click to switch manually, or use "Switch Every > Manual" for click-only mode.

When OpenAI is running a temporary Codex limit boost, the menu bar can show a compact `2x` badge before the Codex 5h value. In the dropdown, the Codex row alternates between time remaining and the end date, and the badge disappears automatically after the promo expires.

During Anthropic weekday peak hours, Claude can show an animated downward indicator before the Claude 5h value. In the dropdown, the Claude section adds a compact `↓ Peak hour` note, and hovering the menu bar item shows a `faster consumption` tooltip.

**Click the menu bar item** to see:

| Option | What it does |
|--------|-------------|
| Usage details | Current % and time until reset for each provider |
| Refresh (Cmd+R) | Manually refresh usage data |
| Display > Show Both / 5h Only / Weekly Only | Change what numbers are shown |
| Display > Show Promo Visibility | Show or hide the temporary Codex `2x` promo badge when available |
| Display > Show Claude / Show Codex | Toggle which providers appear |
| Display > Switch Every | Animation interval (Manual / 5s / 8s / 10s / 15s / 30s) |
| Show Icon | Toggle the provider label above the numbers |
| Launch at Login | Start automatically on macOS login |
| Sign Out | Sign out of Claude or Codex independently |

## Setup Details

### Automatic (Recommended)

The app auto-detects credentials on launch:

**Claude CLI** -- reads Claude OAuth credentials from the macOS Keychain item `Claude Code-credentials`, with `~/.claude/.credentials.json` as a fallback on setups that still write the file
```bash
# If you haven't already:
npm install -g @anthropic-ai/claude-code
claude login
```

To verify Claude is logged in and the Keychain item exists:
```bash
security find-generic-password -s "Claude Code-credentials"
```

**Codex CLI** -- reads `~/.codex/auth.json`
```bash
# If you haven't already:
npm install -g @openai/codex
codex login
```

### Manual (Claude only)

1. Click menu bar > **Setup Usage Tracking** > **Sign in with Browser**
2. Log in to claude.ai normally -- credentials are extracted automatically
3. If auto-extraction fails, use **Manual Entry** with session key + org ID from DevTools

## Common Commands

| Action | Command |
|--------|---------|
| Install | `brew install betoxf/tap/justausagebar` |
| Update | `brew update && brew upgrade --cask justausagebar` |
| Uninstall | `brew uninstall justausagebar` |
| Check version | `brew info betoxf/tap/justausagebar` |
| Check auto-start | Menu bar > look for checkmark on "Launch at Login" |
| Launch manually | `open -a JustaUsageBar` |

## How It Works

### Authentication Priority

| Priority | Method | Source | Auto-refresh |
|----------|--------|--------|-------------|
| 1 | Claude OAuth | Keychain `Claude Code-credentials` or `~/.claude/.credentials.json` | Yes |
| 2 | Claude Web Session | Browser cookie extraction | No |
| 3 | Codex OAuth | `~/.codex/auth.json` | Yes |

### API Endpoints

| Provider | Endpoint |
|----------|----------|
| Claude (OAuth) | `GET api.anthropic.com/api/oauth/usage` |
| Claude (Web) | `GET claude.ai/api/organizations/{orgId}/usage` |
| Codex | `GET chatgpt.com/backend-api/wham/usage` |

Usage refreshes every 60 seconds. OAuth tokens refresh automatically when expired.

### Temporary Indicators

| Provider | Indicator | Behavior |
|----------|-----------|----------|
| Codex | `2x` badge | Shows while the temporary OpenAI limit boost is active, alternates compact dropdown text between time left and end date, and auto-hides after expiry |
| Claude | Downward peak-hours badge | Shows during Anthropic weekday peak hours when limits are consumed faster, adds `↓ Peak hour` in the dropdown, and exposes a hover tooltip |

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Session expired" (Claude) | Run `claude login`, then verify `security find-generic-password -s "Claude Code-credentials"` returns an item; if not, sign out and authenticate again |
| Codex not showing | Run `codex login`, verify `~/.codex/auth.json` exists |
| Claude shows `0%` or `--` after restart | Click Refresh (Cmd+R). If it stays stale, run `claude login` again and confirm the `Claude Code-credentials` Keychain item exists |
| Usage shows 0% | Click Refresh (Cmd+R) or wait for next auto-refresh. Very low usage can legitimately show `0%` for the weekly window |
| Not starting at login | Toggle "Launch at Login" in menu, or check System Settings > Login Items |

## Build from Source

```bash
git clone https://github.com/betoxf/JustaUsageBar.git
cd JustaUsageBar
make release
# App at build/DerivedData/Build/Products/Release/JustaUsageBar.app -- drag to /Applications
```

## Privacy & Security

- All credentials stored locally (AES-256-GCM encrypted, machine-locked)
- OAuth credentials read locally from CLI-managed auth stores (Claude Keychain or CLI files, not copied to a server)
- No telemetry, no analytics, no third-party services
- Not affiliated with Anthropic or OpenAI
- Open source (MIT)

## License

MIT

## Acknowledgments

- **[CodexBar](https://github.com/steipete/CodexBar)** -- Authentication flow and browser session extraction inspired by this excellent Codex usage bar
- **Anthropic** -- Claude API and Claude Code CLI
- **OpenAI** -- Codex API and usage tracking
