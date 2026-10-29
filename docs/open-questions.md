# Decisions and open questions

Answered 24 October 2026. One item remains open.

## Decided

### 1. The Oracle VM is `VM.Standard.A1.Flex`, Always Free — **confirmed**

Compute is $0. Note that 2 OCPU / 12 GB is Oracle's *entire* Always Free Ampere
A1 allowance, so there is no vertical headroom left inside the free tier:
growing means paying or adding a host. All builds must target `arm64`.

Still to check in the console: the instance's **region** (must be
`sa-saopaulo-1` or `sa-vinhedo-1` — see decision 5) and the **storage and
outbound-transfer charges**, since free compute does not imply free volumes or
egress.

### 2. Any participant may publish — **no publisher cap**

All ten people in a ten-person room may share simultaneously. No slots, no
queue, no request-to-present flow.

This was affordable only because of decision 3. The two are a pair: with
watch-everything subscription, ten publishers would have been 81 GB/hour, nine
times the chosen model. Do not revisit either decision alone.

Consequence: pressure moves to **SFU ingest**. Ten inbound streams per room, most
unwatched, on 2 OCPU. **Dynacast is mandatory** — see
[`media-bandwidth.md`](media-bandwidth.md).

### 3. Viewers subscribe to one screen at a time

Downstream becomes `participants × 1 stream × bitrate` — about 20 Mbps, or
**9.0 GB/hour**, for a 10-person 720p room, independent of how many people are
sharing.

This is now the only structural limit protecting cost, so it must be enforced
server-side via LiveKit participant permissions rather than in frontend state.
The screen picker is part of this limit: a live thumbnail grid of all ten
screens re-creates the 81 GB/hour case. See the thumbnail trap in
[`media-bandwidth.md`](media-bandwidth.md).

### 4. Unlimited hours, with an hourly ad break for free users (future)

No session time limit on either tier. Non-premium participants will watch an ad
at roughly hourly intervals; **the ad mechanism is a future implementation** and
the pilot ships without it.

Two consequences that are not deferrable:

- **This decided the hosting question.** Unlimited free hours against LiveKit
  Cloud's participant-minute meter is an uncapped cost behind an uncapped
  promise. Fixed-cost self-hosting is the structural match. See
  [`livekit-hosting.md`](livekit-hosting.md).
- **Watched-time accounting and the server-side permission hook must exist from
  the start**, even though ads do not. An ad break enforced only in the client
  is skippable from devtools. See [`plans-and-limits.md`](plans-and-limits.md).

### 5. Brazil only — single region

One LiveKit deployment in an Oracle Brazil region serves everyone. No edge
routing, no multi-region coordination, and no need for the global network that
is a large part of what Cloud sells.

This removes the switch criterion most likely to have forced a migration later.
It also makes the VM's current region a Phase 0 blocker rather than a detail: a
US-region VM costs Brazilian users ~110–160 ms RTT, which is tolerable for
playback and poor for the interactive feel of a shared screen.

### 6. A disconnected participant is removed immediately; the slot is freed

No grace period and no reserved place. Since decision 2 removed publisher slots,
this applies to **room capacity** — the tenth place goes to whoever claims it
next.

Accepted consequence: a user on a flaky connection may return to find the room
full. With unlimited session length, a room half-occupied by ghosts was judged
the worse failure.

Implementation: LiveKit's `participant_left` webhook is the authoritative
signal, not a client-sent "leaving" message — a crashed browser cannot send one.

### 8. OAuth2 social login only — Google for the first test

No passwords, no credential storage, no reset flow. Google is the single enabled
provider initially; Facebook and others follow as configuration.

Two structural requirements that come with it:

- **Backend-for-frontend.** The Go backend is a confidential client and does the
  code exchange; the SPA receives only an HttpOnly session cookie, never a
  provider token. This matches the existing no-secrets-in-frontend rule.
- **Multi-provider schema from day one.** A separate `identities` table keyed on
  `(provider, provider_user_id)` rather than a `users.google_id` column.
  Google-only works either way; only one of them makes adding Facebook an insert
  instead of a live-data migration.

The risk to document before provider two arrives: **account linking on
unverified email is an account-takeover path.** Google-only hides it completely.
See [`authentication.md`](authentication.md).

### 9. Rooms have a title and description; private rooms use code + password

Rooms carry a required `title` (1–80 chars) and optional `description`
(0–500 chars), both plain text. Private rooms are entered with a generated
10-character join code **and** a room password.

Three consequences worth tracking:

- **It reverses the "private rooms require sign-in" rule.** A correct code and
  password admit a guest. Creating, owning and invite-based access still need an
  identity.
- **It partially reverses "no passwords, ever."** The API now hashes room
  passwords with Argon2id. User authentication stays OAuth2-only; a room
  password is a secret for an object, not a credential for a person.
- **Verify code and password together, with one generic error.** A two-step
  flow would confirm which codes exist without needing any password.

Full design, including the Argon2id-on-2-OCPU DoS interaction, in
[`room-access.md`](room-access.md).

## Still open

### 7. What is the premium price?

**Status:** open; needs the load test in Phase 5 plus two figures from vendor
pricing pages. Here is the calculation, with everything that can be derived
already filled in.

**Derived — bandwidth per participant-hour.** Each viewer receives one stream, so
cost scales per participant rather than per room:

| Tier | Stream | GB per participant-hour |
| --- | --- | --- |
| Free | 720p @ 2 Mbps | **0.9** |
| Premium | 1080p @ 4 Mbps | **1.8** |

A premium participant costs **2× the bandwidth of a free one**, which is the
single most important input to the price. A premium user active 40 hours/month
moves 72 GB.

**On self-hosted Oracle Always Free, the marginal cost of that is $0** — within
the free compute and egress allowances. So premium is not priced against
per-hour cost; it is priced against **capacity**. The real question is what the
*next* host costs when concurrency outgrows this VM:

```
premium price × premium users  ≥  (extra hosts × host cost/month)
                                + payment processing
                                + any Cloud fallback
```

**What to fill in:**

1. **C = concurrent rooms per VM**, from the Phase 5 load test — 10 participants,
   all 10 publishing at 720p30, one subscription each, dynacast on, scaled up
   until CPU or packet loss degrades. Without `C` there is no capacity model and
   no defensible price.
2. **Host cost** for a paid Oracle A1 shape roughly double this one, from the
   Oracle pricing estimator.
3. **Peak-to-average concurrency ratio**, once there is real usage. Capacity is
   sized for peak, not for monthly totals.

**Cloud comparison, for reference.** At the published $0.12/GB overage rate, a
premium participant-hour costs about **$0.22** in bandwidth (1080p) and a free
one about **$0.11** (720p) — plus participant-minutes at a rate to look up on the
pricing page, 60 of them per participant-hour. That gives a floor: a premium user
active 40 hours/month would cost roughly $8.60/month in bandwidth alone on Cloud
rates, before the $50 plan fee and before participant-minutes. Self-hosting is
what makes a price well below that viable.

**Do not set the price before step 1.** Pricing against an unmeasured capacity
ceiling is how an unlimited-hours tier becomes unprofitable quietly.

### 10. Does "public room" mean link-joinable, or listed in a directory?

**Status:** open — product decision, newly urgent now that rooms have titles.

The documents have used "public" to mean "no invite needed", but never settled
whether public rooms are **discoverable**. The two readings diverge sharply:

**Link-joinable only.** A public room is reachable by anyone with its URL, and
nothing lists it. Titles and descriptions are seen by people who were already
given the link. Low moderation burden.

**Listed in a directory.** Anyone can browse public rooms. This makes `title`
and `description` a public broadcast surface, which means spam, advertising and
slurs in room titles from the first week it is popular — plus a need for
moderation tooling, reporting queues, and probably a default of unlisted.

**Why it matters now:** the second reading needs a `listed` flag, a browse
endpoint, text moderation and an abuse queue, none of which are in the roadmap.
It also changes what "public" implies for a user's privacy expectations.

**Recommendation: link-joinable only for the pilot**, with an explicit `listed`
column defaulting to false so a directory can be added later without a
migration. Discovery is a growth feature and it arrives with a moderation cost
that a pilot should not be paying.
