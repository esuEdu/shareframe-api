# Architecture

## Product scope

ShareFrame is a browser-first screen-sharing service. Users create **public
rooms** or **private rooms** reachable only through an invite or permission
check. Several participants may publish screens in the same room at once, and
viewers choose which of those screens they receive rather than being subscribed
to all of them automatically.

Decided shape for the pilot:

- 5–10 people per room
- **Any participant may publish** — no publisher cap
- **Each viewer subscribes to one screen at a time**
- **Unlimited session length**, with an hourly ad break for non-premium users
  (future implementation)
- Free tier: 720p at 30 FPS
- Premium tier: 1080p, higher FPS where the browser, device, network and SFU
  allow it
- Optional system audio alongside the screen track
- **Brazil only** — single region, no global edge requirement

Treat 1080p and 60 FPS as **targets, not guarantees**. Screen content, encoder
behaviour and network conditions all affect what a participant actually
receives.

## Service boundaries

| Component | Responsibility |
| --- | --- |
| `shareframe-web` | Capture, publish, subscribe, room UI. Holds no secrets. |
| `shareframe-api` (this repo) | OAuth2 login and sessions, room visibility and invites, plan quotas, session lifecycle, LiveKit token minting. |
| OAuth2 provider | Identity only. Google for the first test. Not in the media path. |
| PostgreSQL | Users, rooms, invites, plans, session records. |
| LiveKit SFU | Media forwarding only. Self-hosted for the pilot — see [`livekit-hosting.md`](livekit-hosting.md). |

The API never proxies media. It is on the control path only: it decides *who
may do what*, encodes that decision into a short-lived token, and records what
happened.

## Connection flow

1. A user signs in through an OAuth2 provider (Google for the first test), or
   takes a guest session for a room that permits anonymous access. See
   [`authentication.md`](authentication.md).
2. The API checks, in this order: **room visibility**, then for a private room
   **either a valid invite or a verified join code + password**, then **room
   capacity**, then the user's **plan**. See
   [`room-access.md`](room-access.md).
3. The API mints a short-lived LiveKit token carrying only the required room
   name and the minimum publish/subscribe grants for that user's role and plan.
4. The browser connects to LiveKit with that token and joins the room.
5. On **Share screen**, the browser requests screen capture. System audio is
   requested **separately and optionally**, because browser and OS support
   varies.
6. The browser publishes the screen track, plus the audio track when it was
   granted.
7. Other participants subscribe only to the tracks they want to watch.
   Stopping a share unpublishes the track.

Steps 2–3 are the whole security boundary. Everything the client can do in
LiveKit was granted by the token, so a token must never be broader than the
check that produced it.

## Proposed API surface

Sketch, to be confirmed during implementation. Nothing here is built yet.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/auth/providers` | Enabled OAuth2 providers |
| `GET` | `/v1/auth/{provider}/start` | Begin OAuth2 login (Google only for now) |
| `GET` | `/v1/auth/{provider}/callback` | Exchange code, set session cookie |
| `GET` | `/v1/auth/me` | Current user, plan and entitlements |
| `DELETE` | `/v1/auth/session` | Sign out |
| `POST` | `/v1/auth/guest` | Ephemeral session for anonymous public-room access |
| `POST` | `/v1/rooms` | Create with title, description, visibility; returns code and generated password |
| `GET` | `/v1/rooms/{code}` | Metadata the caller may see — nothing for an unverified private room |
| `PATCH` | `/v1/rooms/{code}` | Owner edits title, description, password; rotates code |
| `POST` | `/v1/rooms/join` | Verify code + password for a private room |
| `POST` | `/v1/rooms/{code}/invites` | Issue an invite to a private room |
| `POST` | `/v1/rooms/{code}/token` | **The gate.** Run all checks, mint the LiveKit token |
| `GET` | `/v1/rooms/{code}/participants` | Current participants and active publishers |
| `POST` | `/v1/rooms/{code}/reports` | Abuse report |
| `POST` | `/v1/webhooks/livekit` | LiveKit room/track events → session records |

`POST /v1/rooms/{code}/token` is the only endpoint that produces LiveKit
credentials, so it is the only place subscription-cap and quality decisions are
made. Keeping that in one handler is what makes the rules auditable.

## Proposed data model

```
users          id, email, display_name, avatar_url, plan_id,
               created_at, last_login_at
identities     id, user_id, provider, provider_user_id,
               email_at_provider, email_verified,
               created_at, last_login_at
               UNIQUE (provider, provider_user_id)
plans          id, name, max_participants, max_subscriptions,
               max_video_height, max_fps, max_concurrent_rooms,
               ad_break_interval_minutes   -- NULL for premium
rooms          id, code, slug, owner_id,
               title, description,
               visibility (public|private),
               password_hash,        -- private rooms only
               max_participants, locked_at, created_at
               UNIQUE (code)
               UNIQUE (slug) WHERE slug IS NOT NULL
room_invites   id, room_id, token_hash, invited_email, expires_at, used_at
room_members   room_id, user_id, role (owner|moderator|viewer)
sessions       id, room_id, user_id, joined_at, left_at,
               published_seconds, watched_seconds,
               egress_bytes, ingress_bytes,
               ad_breaks_served, last_ad_break_at
```

Five things to note about this schema.

**No `password_hash` on `users`, and no `google_id`.** User authentication is
OAuth2 only, and provider links live in a separate `identities` table keyed on
`(provider, provider_user_id)` so the second provider is an insert rather than
a migration. See [`authentication.md`](authentication.md).

**`rooms.password_hash` is a different thing entirely** — a shared secret for an
object, not a credential for a person. Private rooms are entered with a join
code plus that password. Null for public rooms, and required for private ones
via a check constraint. See [`room-access.md`](room-access.md).

**No `max_publishers` and no `max_session_minutes`.** Both were in the earlier
design; both are gone. Any admitted participant may publish, and sessions have
no time limit. `max_subscriptions` replaces the publisher cap as the limit that
bounds cost.

**`sessions` carries measurement fields deliberately.** Participant-minutes and
downstream bytes are the two dimensions LiveKit Cloud meters, so recording them
from day one is what makes a later Cloud-vs-self-hosted decision evidence-based
rather than a guess. `ingress_bytes` is here because with no publisher cap,
inbound traffic is now a real cost — see
[`media-bandwidth.md`](media-bandwidth.md).

**`watched_seconds` and the ad fields exist before ads do.** The ad break is a
future implementation, but the accounting it needs must accumulate from the
first session or there is no baseline and no way to fire a checkpoint at the
right moment. See [`plans-and-limits.md`](plans-and-limits.md).

## Publish permission and the subscription cap

**Publishing is unrestricted.** Any participant admitted to a room receives
`canPublish` in their token. There is no slot accounting, no queue and no
"request to present" flow. All ten people in a ten-person room may share at
once.

**Subscribing is capped at one stream per viewer.** This is where the cost model
lives. Downstream traffic is `participants × 1 stream × bitrate`, so it scales
with room size rather than with `publishers × viewers`. Removing the publisher
cap was affordable *only because* of this cap; the two decisions are a pair and
should not be revisited independently.

Enforcement is server-side, through LiveKit participant permissions, not
frontend state. On a stream switch the client unsubscribes the previous track
**before** subscribing to the next one — the reverse order momentarily doubles
every viewer's downstream and, on a reconnect that fails midway, leaks a
subscription permanently.

## Participant lifecycle on disconnect

A participant who loses connectivity is **removed immediately and their
room-capacity slot is freed.** No grace period, no reserved place.

The consequence to accept: a user on a flaky connection can return to find a
full room, because someone else took the tenth place. With a 10-person cap and
unlimited session length, holding places for absent users was judged the worse
failure — a room half-occupied by ghosts is more visible than an occasional
unlucky rejoin.

Implementation note: this makes LiveKit's `participant_left` webhook the
authoritative signal for closing the `sessions` row and decrementing occupancy.
Do not rely on a client-sent "leaving" message, which is exactly the thing a
crashed browser cannot send.

## Region

**Brazil only.** A single LiveKit deployment in an Oracle Brazil region
(São Paulo or Vinhedo) serves all users, with no edge routing or multi-region
coordination.

Verify the existing VM is actually *in* a Brazil region. A VM in a US region
adds roughly 110–160 ms RTT for Brazilian users, which is tolerable for video
playback and noticeably bad for the interactive feel of a shared screen. If the
instance sits outside Brazil, migrating it is a Phase 0 task, not a later
optimisation.
