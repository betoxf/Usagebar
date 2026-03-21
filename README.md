# Just A Usage Bar

A lightweight macOS menu bar app that shows your **Claude** and **Codex** (OpenAI) usage at a glance -- 5-hour rolling window and 7-day limits, right in your menu bar.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- Shows 5-hour and 7-day usage percentages for **Claude** and **Codex**
- Auto-detects Claude CLI and Codex CLI credentials (OAuth) -- zero setup if you use the CLIs
- Smooth dissolve animation alternating between providers in the menu bar
- Configurable switch interval (5s / 8s / 10s / 15s / 30s)
- Display modes: Both percentages, 5h only, or Weekly only
- Toggle providers: show Claude, Codex, or both
- Auto-refreshes OAuth tokens when expired
- Falls back to browser session login for Claude if CLI not available
- Launch at Login support
- Minimal resource usage (~0% CPU when idle)

## Installation

### Quick Install (one command)

```bash
brew install betoxf/tap/justausagebar
```

That's it. Homebrew handles the tap automatically.

### Update

```bash
brew upgrade betoxf/tap/justausagebar
```

### Uninstall

```bash
brew uninstall justausagebar
brew untap betoxf/tap  # optional: remove the tap
```

### Install Script (alternative)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/betoxf/JustaUsageBar/main/install.sh)"
```

### Build from Source

```bash
git clone https://github.com/betoxf/JustaUsageBar.git
cd JustaUsageBar
make release
# Built app is at build/Release/JustaUsageBar.app — drag to /Applications
```

Or open `JustaUsageBar.xcodeproj` in Xcode and press Cmd+R.

## Setup

### Automatic (Recommended)

The app auto-detects credentials from your CLI tools on launch. No manual configuration needed if you already use:

**Claude CLI** -- credentials read from `~/.claude/.credentials.json` (written by Claude Code / `claude` CLI)

```bash
# If you haven't already:
npm install -g @anthropic-ai/claude-code
claude login
```

**Codex CLI** -- credentials read from `~/.codex/auth.json`

```bash
# If you haven't already:
npm install -g @openai/codex
codex login
```

Once detected, you'll see green checkmarks in the setup window. Click **"Use Detected Credentials"** and you're done.

### Manual (Claude only)

If you don't use the CLI, you can sign in via browser:

1. Click the menu bar icon > **"Setup Usage Tracking"**
2. Click **"Sign in with Browser"** -- this opens claude.ai in an embedded browser
3. Log in normally. Credentials are extracted automatically
4. If auto-extraction fails, use **"Manual Entry"** with your session key and org ID from browser DevTools

## Usage

### Menu Bar Display

| Provider | Label | Style |
|----------|-------|-------|
| Claude | `✳︎ Claude` | Anthropic orange accents |
| Codex | **CODEX** | Heavy font, OpenAI green accents |

When both providers are active, the menu bar alternates between them with a smooth dissolve animation.

### Menu Options

Click the menu bar item to see:

- **Usage details** -- current percentages and time until reset for each provider
- **Refresh** (Cmd+R) -- manually refresh usage data
- **Display** -- submenu with:
  - Show Both / 5h Only / Weekly Only
  - Show Claude / Show Codex toggles
  - Switch Every -- animation interval (5s to 30s)
- **Show Icon** -- toggle the provider label above the numbers
- **Launch at Login** -- start automatically on macOS login
- **Sign Out** -- sign out of Claude or Codex independently

### Auto-Refresh

Usage data refreshes automatically every 60 seconds (configurable 30s to 10 min). OAuth tokens are refreshed automatically when they expire.

### Launch at Login

Toggle via the menu: click your usage bar > **Launch at Login**. Uses macOS `SMAppService` (no login items clutter).

To check if it's enabled:
- Open the app menu > look for the checkmark next to "Launch at Login"
- Or check System Settings > General > Login Items

## How It Works

### Authentication

The app uses a priority-based auth system:

| Priority | Method | Source | Auto-refresh |
|----------|--------|--------|-------------|
| 1 | Claude OAuth | `~/.claude/.credentials.json` or Keychain | Yes |
| 2 | Claude Web Session | Browser cookie extraction | No |
| 3 | Codex OAuth | `~/.codex/auth.json` | Yes |

OAuth tokens are refreshed automatically:
- **Claude**: via `platform.claude.com/v1/oauth/token`
- **Codex**: via `auth.openai.com/oauth/token`

### API Endpoints

| Provider | Endpoint |
|----------|----------|
| Claude (OAuth) | `GET api.anthropic.com/api/oauth/usage` |
| Claude (Web) | `GET claude.ai/api/organizations/{orgId}/usage` |
| Codex | `GET chatgpt.com/backend-api/wham/usage` |

## Troubleshooting

### "Session expired" error (Claude)
Your web session cookie expired. Either:
- Install Claude CLI and run `claude login` (recommended -- OAuth tokens auto-refresh)
- Click Sign Out > set up again via browser

### Codex not showing up
Make sure you've run `codex login` and `~/.codex/auth.json` exists. The app auto-detects this file on launch.

### Usage shows 0% for everything
The API might be temporarily unavailable. Click Refresh (Cmd+R) or wait for the next auto-refresh cycle.

### App not starting at login
Check System Settings > General > Login Items > ensure JustaUsageBar is listed. You can also toggle it from the app menu.

### Check current version
```bash
brew info betoxf/tap/justausagebar
```

## Privacy & Security

- All credentials stored locally (AES-256-GCM encrypted, machine-locked)
- OAuth credentials read directly from CLI config files (not copied)
- No telemetry, no analytics, no third-party services
- Network requests only to `claude.ai`, `api.anthropic.com`, `chatgpt.com`, `auth.openai.com`, and `platform.claude.com`
- Not affiliated with Anthropic or OpenAI
- Open source (MIT)

## Contributing

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Build and test: `make build`
5. Open a PR

## License

MIT
