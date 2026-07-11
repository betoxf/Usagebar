# Security policy

Usagebar reads local provider credentials and sends authenticated requests to provider endpoints. Security reports are handled privately to reduce the risk of exposing tokens or user data.

## Supported versions

| Version | Support |
| --- | --- |
| Latest release | Security fixes and investigation |
| Older releases | Best effort; upgrade may be required |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting flow from the repository **Security** tab. If that option is unavailable, contact the repository owner privately through their GitHub profile before sharing technical details.

Include the affected app and macOS versions, installation method, impacted provider flow, reproduction steps, expected security boundary, observed behavior, and a minimal sanitized proof of concept.

Never send access tokens, refresh tokens, session keys, cookies, complete credential files, hardware identifiers, or unredacted API responses.

## Security boundaries

- Usagebar has no project-operated backend.
- Provider credentials remain on the local Mac.
- Browser-session credentials saved by Usagebar are encrypted at rest with AES-256-GCM and a device-derived key.
- Requests go directly to Anthropic, OpenAI, GitHub's release API, or a user-configured Codex base URL.
- Users are responsible for the security of their macOS account and provider sessions.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full credential and network model.
