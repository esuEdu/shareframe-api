# Authentication

**Decision: OAuth2 / OIDC social login only. No passwords, ever.** Google is the
only enabled provider for the first test; the schema and provider interface are
built multi-provider from day one so Facebook and others are configuration, not
migration.

The API does not store credentials, does not hash passwords, does not send
password-reset mail and does not own a credential-recovery flow. That is the
point: the largest category of auth vulnerability is removed by not having the
feature.

## Pattern: backend-for-frontend (BFF)

The Go backend is a **confidential OAuth2 client**. It performs the
authorization-code exchange server-side and issues its own session cookie. The
React SPA never sees a provider token, an authorization code or a client secret.

```
browser ──GET /v1/auth/google/start──▶ API
                                       │ generate state + PKCE verifier
                                       │ store in short-lived signed cookie
       ◀──302 to accounts.google.com───┘
       ──────── user consents ────────▶ Google
       ◀──302 to /v1/auth/google/callback?code&state
       ──callback──▶ API
                     │ verify state matches cookie
                     │ exchange code + PKCE verifier  ──▶ Google token endpoint
                     │ validate ID token (JWKS, iss, aud, exp, nonce)
                     │ upsert users + identities on (provider, sub)
                     │ set HttpOnly session cookie
       ◀──302 to app─┘
```

The alternative — SPA as a public client holding tokens — is rejected. This
backend must already hold a server-side session to enforce plans and mint
LiveKit tokens, so there is no benefit to also putting provider tokens in the
browser, and real cost in exposing them.

## Discard the provider's tokens

The product needs **authentication** ("who is this person"), not ongoing access
to Google data. So:

- Request the minimum scopes: `openid email profile`. Nothing else.
- Do **not** request offline access, and do **not** store Google access or
  refresh tokens. Read the ID token's claims, create the session, discard the
  rest.
- Never re-verify a user by calling Google on each request. The session cookie
  is the authority after login.

Storing refresh tokens you have no use for turns a database leak into a
third-party account compromise. There is nothing to steal if nothing is kept.

## Endpoints

Replaces the credential endpoints entirely.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/auth/providers` | Enabled providers, so the frontend does not hardcode Google |
| `GET` | `/v1/auth/{provider}/start` | Generate state + PKCE, redirect to provider |
| `GET` | `/v1/auth/{provider}/callback` | Validate, exchange, upsert, set session cookie |
| `GET` | `/v1/auth/me` | Current user, plan and entitlements |
| `DELETE` | `/v1/auth/session` | Sign out, clear cookie |
| `POST` | `/v1/auth/guest` | Ephemeral session for anonymous public-room access |

`/v1/auth/providers` exists so that enabling Facebook later is a backend
deployment, not a coordinated frontend release.

## Data model

```
users       id, email, display_name, avatar_url, plan_id,
            created_at, last_login_at

identities  id, user_id,
            provider            -- 'google', later 'facebook', …
            provider_user_id    -- the provider's stable subject claim
            email_at_provider,
            email_verified,
            created_at, last_login_at
            UNIQUE (provider, provider_user_id)
```

No `password_hash`. No `google_id` column on `users`.

**The separate `identities` table is the one decision here that is expensive to
retrofit.** Shipping Google-only with a `users.google_id` column works perfectly
until the day Facebook is added, and then it is a data migration against live
accounts plus a rewrite of every auth path. A join table with a
`(provider, provider_user_id)` unique constraint costs nothing extra now and
makes the second provider an insert.

**Key on the subject claim, not the email.** Google's `sub` is stable and
immutable; email addresses change. `UNIQUE (provider, provider_user_id)` is
correct; a unique index on `users.email` is not — it will eventually reject a
legitimate returning user, or merge two different people.

Note that `plan_id` lives on `users`, not on `identities`. A premium
subscription follows the person across providers and survives an email change.

## Provider abstraction

One interface, one implementation for now:

```go
type Provider interface {
    Name() string
    AuthCodeURL(state string, challenge string) string
    Exchange(ctx context.Context, code, verifier string) (*Identity, error)
}

// Identity is what every provider must produce, however it gets there.
type Identity struct {
    Subject       string // stable provider user id
    Email         string
    EmailVerified bool
    DisplayName   string
    AvatarURL     string
}
```

Abstract at the level of "return a verified `Identity`", **not** at the level of
OIDC discovery. Google is a clean OIDC provider; Facebook classically is not —
it is OAuth2 plus a Graph API call, and its OIDC-style Limited Login behaves
differently again. An abstraction that assumes OIDC discovery for everyone will
need breaking just as the second provider arrives, which defeats the purpose.

Suggested Go libraries: `golang.org/x/oauth2` for the flow,
`github.com/coreos/go-oidc/v3/oidc` for ID-token verification and JWKS
handling. Do not hand-roll JWT validation.

## Security requirements

These are the OAuth-specific rules. The general rules in
[`security.md`](security.md) still apply unchanged.

**`state` is mandatory.** Generate a random value per login attempt, bind it to
a cookie, and reject any callback whose `state` does not match. Without it the
callback is a CSRF endpoint that logs victims into an attacker's account.

**Use PKCE even though this is a confidential client.** OAuth 2.1 recommends it
unconditionally; it costs a hash and closes code-interception attacks.

**Exact-match redirect URI allowlist**, registered at Google. No wildcards. If
a `returnTo` parameter is supported for post-login landing, validate it against
an allowlist of internal paths — an unvalidated `returnTo` is an open redirect,
and open redirects are how OAuth flows get turned into token-leak primitives.

**Validate the ID token fully**: signature against Google's JWKS, `iss` is
`https://accounts.google.com` or `accounts.google.com`, `aud` equals your client
ID, `exp` not past, and `nonce` matches if one was sent. An unverified `aud` is
the classic hole — it lets a token minted for a *different* application be
replayed against yours.

**Only link accounts on a verified email, and prefer explicit confirmation.**
This is the vulnerability that matters most once a second provider exists. If a
Facebook login with email `victim@example.com` silently links to the account
created by a Google login with that address, anyone who can create a provider
account with an unverified email can take over the existing account. Require
`email_verified == true` before considering any link, and ideally make the user
confirm the link while signed in to the first identity. Google-only hides this
risk entirely — which is exactly why it should be written down before Facebook
is enabled.

**Cookie settings, with one gotcha.** The session cookie is `HttpOnly`,
`Secure`, `SameSite=Lax`, with the `__Host-` prefix where the path allows it.

As built, the cookie carries an HMAC-signed session rather than an opaque
identifier, so there is nothing to look up and a guest costs no storage. What
that gives up is revocation: see the correction in
[`security.md`](security.md).

`SameSite=Lax` is deliberate, not a compromise: the OAuth callback is a
cross-site top-level GET navigation from Google, and `SameSite=Strict` would
withhold the state cookie on exactly that request, breaking login in a way that
looks like a provider misconfiguration. Lax permits top-level GET navigations,
which is precisely what is needed and nothing more.

**Rate-limit `/start` and `/callback`** per IP, alongside the room-creation and
token-issuance limits.

## Anonymous access to public rooms

Public rooms admit users without an identity, so there are two session kinds:

| | Authenticated | Guest |
| --- | --- | --- |
| Origin | OAuth2 provider | `POST /v1/auth/guest` |
| `users` row | yes | no — ephemeral signed session only |
| Rooms | public and private | public, **plus private with a valid code + password** |
| Can own a room | yes | no |
| Plan | free or premium | free, always |
| Ads (future) | if non-premium | always |

A guest session carries a random display name and an identity string for
LiveKit, and expires on a short timer independent of the unlimited room session
length. Guests can never be premium, so they are always in the ad population —
worth noting now, because it means the ad path must work for sessions with no
`users` row.

**Private rooms no longer require a real identity in every case.** A guest who
presents a correct join code and room password is admitted — that is the point
of a shareable secret, and requiring sign-in on top would make the feature
pointless. What still requires an identity: creating a room, owning or
moderating one, and entering a private room **by invite**, since an invite is
addressed to a person and checking one against an anonymous session cannot mean
anything. See [`room-access.md`](room-access.md).

## What OAuth does not change

Worth stating explicitly, because it is easy to assume a login change ripples
further than it does:

- **The security boundary is unchanged.** `POST /v1/rooms/{code}/token` still
  runs visibility → (invite or code+password) → capacity → plan, and still mints
  the LiveKit token server-side. OAuth2 changes how the session is established,
  not what the session is allowed to do.
- **Nothing in the cost model moves.** Subscription caps, dynacast and the
  bandwidth arithmetic in [`media-bandwidth.md`](media-bandwidth.md) are
  untouched.
- **Google is not in the media path.** An outage at the provider blocks new
  logins; it does not interrupt live rooms or existing sessions.
