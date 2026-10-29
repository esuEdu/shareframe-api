# Rooms and access

Rooms carry a **title** and an optional **description**. Private rooms are
entered with a **join code plus a room password**. Decided 24 October 2026.

## Room identity

| Field | Rules |
| --- | --- |
| `title` | Required. 1–80 chars, plain text. Shown in room chrome and (for public rooms) wherever rooms are listed. |
| `description` | Optional. 0–500 chars, plain text, newlines allowed. |
| `code` | Generated. 10 chars, Crockford base32, grouped for display: `K7M2Q-9XBVT`. The canonical join identifier. |
| `slug` | **Public rooms only.** Derived from the title for readable URLs. Private rooms have none. |

Both `title` and `description` are **user-generated content rendered to other
people**, so they are stored and emitted as text and never as HTML. Normalise to
NFC on write, strip control characters, and reject zero-width and bidirectional
override characters — in anything that lists public rooms, those are the
standard tools for homoglyph and right-to-left display abuse.

## Why the code is not the slug

A slug is derived from the title; a code is random. Private rooms get a code and
**no slug**, because a slug derived from "Reunião Financeiro Q4" is guessable and
a code is not.

10 Crockford base32 characters is about 1.1 × 10¹⁵ combinations — enough that
enumeration is impractical once attempts are rate-limited. Eight characters
(~1.1 × 10¹²) is the floor; do not go below it. The alphabet excludes `I`, `L`,
`O` and `U`, so a code read aloud over a call does not turn into a support
ticket.

Nobody normally types a code: it travels in a link, `/j/K7M2Q-9XBVT`. Accept
input case-insensitively and ignore hyphens and spaces when parsing.

**The owner can regenerate the code.** A leaked code is otherwise permanent, and
regenerating is cheap. Same for the password.

## Private access: code **and** password

Both are required. The code identifies the room; the password is the gate.

```
POST /v1/rooms/join
{ "code": "K7M2Q9XBVT", "password": "…" }
```

### Verify both together, and leak nothing either way

There is no "check the code, then ask for the password" step. A wrong code, a
right code with a wrong password, and a code for a room that does not exist all
return the **same generic failure**, with no title, no description, no
participant count and no hint about which half was wrong.

Two-step validation feels better and is an enumeration oracle: it tells an
attacker which codes are real without needing any password. Since the code
arrives in a link anyway, the user is only ever typing the password, so the
single-step flow costs almost nothing in practice.

Concretely:

- One error string for every failure mode. `"Código ou senha inválidos."`
- **Do not reveal the room's title or description until both verify.** The join
  page for `/j/{code}` shows a password field and nothing about the room.
- Make the timing indistinguishable. A missing room must still burn a password
  verification against a dummy hash, or response time answers the question that
  the error message refused to.

### A room password is not a user credential

This corrects an earlier claim in these docs that the API stores no passwords
and hashes nothing. It now hashes one thing — but the distinction matters:

| | User credential | Room password |
| --- | --- | --- |
| Identifies | a person | an object |
| Compromise exposes | an account, and others via reuse | one room |
| Needs reset-by-email | yes | no — the owner changes it while signed in |
| Enables credential stuffing | yes | no |

So this does **not** reintroduce account-takeover risk, password-reset mail or
credential-recovery flows, and user authentication stays OAuth2-only — see
[`authentication.md`](authentication.md). It does mean the project now needs a
password-hashing dependency it previously did not.

Requirements:

- **Argon2id.** OWASP's baseline configuration (m = 19 MiB, t = 2, p = 1) is a
  reasonable starting point; measure on the target VM before settling — see the
  DoS note below.
- **Generate a strong password by default** and let the owner replace it, rather
  than presenting an empty field. Some fraction of owners will otherwise type a
  password they use elsewhere, and this one gets pasted into group chats.
- **Never log it**, never put it in a URL or a query string. It belongs in a
  POST body only.
- **It is returned exactly once**, in the response to `POST /v1/rooms` (or to a
  password reset). Because it is stored hashed, no endpoint can ever return it
  again — `GET /v1/rooms/{code}` must not expose it even to the owner, because
  there is nothing to expose.

That last point is a contract the UI depends on, so state it rather than leaving
it implied: the dashboard offers **reset**, never reveal, and the create-room
response is the only moment the plaintext exists. A later request to "show me my
room password" is not a missing feature, it is impossible by construction.
- Changing the password does not evict people already in the room — their
  LiveKit tokens stay valid until expiry. The owner removes them explicitly if
  that is the intent.

### Argon2id on 2 OCPU is a DoS surface

This one is specific to the hosting decision in
[`livekit-hosting.md`](livekit-hosting.md) and easy to miss. Argon2id is
deliberately expensive, and on this VM it competes for CPU with the SFU
forwarding media. A burst of join attempts against a private room is a cheap way
to make everyone's screen share stutter.

Mitigations, in order:

1. **Rate-limit before hashing.** Per code, per IP, with exponential backoff.
   The cheap check must reject the flood before any Argon2 work starts.
2. **Cap concurrent verifications** with a semaphore, so a burst queues instead
   of consuming every core.
3. **Tune the parameters against measurements on the VM**, not against a
   benchmark from a bigger machine.
4. If this becomes a real problem, it is another argument for splitting the SFU
   onto its own host.

## Invites and code+password are different tools

Both paths into a private room survive, because they answer different needs.

| | Invite | Code + password |
| --- | --- | --- |
| Granularity | one person | anyone holding both |
| Expiry | yes | until rotated |
| Revocation | individual | rotate, affecting everyone |
| Requires sign-in | yes | **no** |
| Good for | a named person, an audit trail | a group chat, a class, a team call |

### Code+password admits guests — a reversal worth noting

An earlier decision in these docs said private rooms require an authenticated
identity. **Code + password changes that**: a correct code and password admit a
guest session, with no Google sign-in.

The reasoning: the entire point of a shareable code and password is reaching
people who may not have accounts. Requiring sign-in on top would make the
feature pointless, and it matches how Zoom and Meet behave — the secret is the
credential.

What still requires sign-in:

- **Creating** a room
- **Owning** or moderating one
- Accessing a private room **by invite** (an invite is addressed to an identity;
  checking one against an anonymous session is meaningless)

The tradeoff accepted: an anonymous participant in a private room is less
accountable. For 5–10 person rooms entered through a secret the owner chose to
share, that is the normal bargain. Moderation controls are the backstop.

## The ordered check, updated

`POST /v1/rooms/{code}/token` now runs:

```
1. room exists and is not locked
2. visibility:
     public   → admit (authenticated or guest)
     private  → EITHER a valid invite for this identity
                OR a verified code + password
3. capacity
4. plan
→ mint the LiveKit token
```

Step 2 is still the whole security boundary, and both branches of it must
complete **before** a token exists. There is no path that mints first and checks
after.

## Data model

```
rooms          id, code, slug, owner_id,
               title, description,
               visibility (public|private),
               password_hash,        -- private rooms only
               max_participants, locked_at, created_at
               UNIQUE (code)
               UNIQUE (slug) WHERE slug IS NOT NULL
```

`password_hash` is null for public rooms. A private room without one is not
allowed to exist — enforce it in a check constraint rather than trusting the
handler, so a future code path cannot create a passwordless private room by
omission.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/v1/rooms` | Create with title, description, visibility; returns code and generated password |
| `GET` | `/v1/rooms/{code}` | Metadata the caller may see — **nothing for an unverified private room** |
| `PATCH` | `/v1/rooms/{code}` | Owner edits title, description, password; rotates code |
| `POST` | `/v1/rooms/join` | Verify code + password, establish access |
| `POST` | `/v1/rooms/{code}/token` | The gate. Full ordered check, mint the LiveKit token |

Public rooms additionally resolve by slug, as an alias that redirects to the
canonical code route.
