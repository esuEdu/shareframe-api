# shareframe-api

**Go · PostgreSQL · LiveKit integration**

OAuth2 authentication, room permissions, subscription limits, session management, and secure generation of LiveKit access tokens.

## Scope

- **Authentication** — OAuth2 social login (Google first), sessions and token issuance
- **Room permissions** — roles and per-room capability enforcement
- **Subscription limits** — plan quotas (participants, concurrent rooms, session length, share quality)
- **Session management** — lifecycle and tracking of live room sessions
- **LiveKit access tokens** — grants derived server-side from role and plan, never from client input

## Documentation

See [`docs/`](docs/) for architecture, security rules, bandwidth cost model and
the hosting decision. Start with [`docs/README.md`](docs/README.md).

## Related

- [`shareframe-web`](https://github.com/esuEdu/shareframe-web) — React frontend, design system and room UI
