# Plans and limits

Decided values for the pilot. Resolution and frame-rate figures remain
hypotheses to validate; the structural decisions (no publisher cap, selective
subscription, unlimited hours) are settled — see
[`open-questions.md`](open-questions.md).

## Limits

| | Free | Premium |
| --- | --- | --- |
| Target resolution | 720p | 1080p |
| Target frame rate | 30 FPS | higher where supported |
| Concurrent screen publishers per room | **no cap** (up to all participants) | no cap |
| **Concurrent subscriptions per viewer** | **1** | 1 |
| Participants per room | 5–10 | 5–10 |
| Session length | **unlimited** | unlimited |
| Hourly ad break | **yes** (future) | no |
| Room visibility | public and private | public and private |
| System audio | optional, best-effort | optional, best-effort |

Resolution and frame rate are **targets, not guarantees.** Screen content,
encoder behaviour, device capability and network conditions all affect what is
delivered. Premium should be sold as "up to 1080p", and the premium price should
not be set before the figures in [`media-bandwidth.md`](media-bandwidth.md)
have been rechecked against live pricing.

## The limit that carries the cost model

With no publisher cap, **the concurrent-subscription limit is the only
structural protection against the bandwidth multiplication.** It replaces the
publisher cap entirely as the enforcement point.

This is worth stating plainly because it is easy to get wrong: the system is
safe not because few people share, but because few streams are *received*. If
the subscription cap leaks — a thumbnail grid, a debug view, a reconnect that
fails to unsubscribe the old track — the room silently reverts to the 81 GB/hour
case. Guard it accordingly:

- Enforce the cap server-side. **Correction, 29 October 2026:** LiveKit has no
  numeric subscription cap. `canSubscribe` is a boolean in the token grant, the
  same boolean in `ParticipantPermission`, and the room service API exposes no
  per-viewer limit, so "`maxSubscriptions` via participant permissions" — as
  earlier versions of this document and of [`security.md`](security.md) put it
  — is not a thing the SFU can be told.

  What enforces it instead: the client connects with **auto-subscribe
  disabled**, so a participant receives no track until the API subscribes it,
  and `POST /v1/rooms/{code}/subscription` switches streams through the room
  service. That makes the API the only thing able to create a subscription,
  which is a stronger guarantee than a cap the SFU would police. It is also a
  frontend contract: a client that enables auto-subscribe gets the 81 GB/hour
  case back, so the token response carries
  `subscription_mode: "server_driven"` to say so explicitly.
- Unsubscribe the previous track **before** subscribing to the next on a
  stream switch, not after.
- Treat the screen picker as part of this limit. See the thumbnail trap in
  [`media-bandwidth.md`](media-bandwidth.md).

## Where each limit is enforced

The pattern: the client may *request*, the API *decides*, the token *carries*,
the SFU *enforces*.

| Limit | Enforced by |
| --- | --- |
| Concurrent subscriptions | API sets participant permissions; SFU refuses extra subscriptions |
| Publish permission | API grants `canPublish` to any admitted participant — no slot accounting |
| Resolution / FPS cap | API sets the cap from the plan; server-side simulcast layer config; client applies capture constraints |
| Room capacity | API rejects token requests past `max_participants` |
| Private-room access | API checks the invite before minting any token |
| Concurrent rooms per owner | API checks at room creation |
| Ad break (future) | API tracks watched-time per session; pauses subscription at the checkpoint |

Note what is **absent**: there is no session-length enforcement and no
publisher-slot accounting. Both were in the earlier design and both are now
removed. Dead enforcement code is worse than none, because it reads as a
guarantee that isn't there.

On the resolution cap: it is advisory at the capture layer — the browser chooses
the capture resolution, so the API cannot force a client to encode at 720p.
**Correction, 29 October 2026:** nor can it cap forwarded simulcast layers, as
an earlier version of this line claimed. LiveKit exposes no server-side layer
limit — not on the room, not on the token, not through the room service. The
publisher picks its layers.

What the API does do is carry the cap in signed token metadata, so the client
has an authoritative figure to apply as a capture constraint, and **record the
mismatch**: a `track_published` webhook carries the track's height, so
`sessions.max_published_height` shows what each session actually published and
the Phase 4 report can compare it against the plan. A free session publishing
1080p is therefore visible after the fact even though it cannot be prevented. A free client publishing 1080p into a room that will not forward the
higher layer gains nothing and wastes its own upstream, which is sufficient
deterrence.

## Unlimited hours, ad-supported free tier

Free sessions have no time limit. Instead, non-premium participants watch an ad
at roughly hourly intervals. **This is a future implementation** — the pilot
ships without ads — but two parts of it must be designed in now, because
retrofitting them is expensive:

**1. Watched-time accounting.** The `sessions` table needs to accumulate time
per participant, surviving reconnects, so an ad checkpoint can fire at the right
moment. Adding this later means backfilling nothing and losing the pilot's
baseline data.

**2. Server-side enforcement.** An ad break enforced only in the client is
skippable by anyone who opens devtools, which makes the free tier free in a way
the business model does not intend. The enforceable version: at the checkpoint
the API revokes `canSubscribe` through LiveKit's participant-permissions API,
the client plays the ad, confirms completion, and the API restores the
permission. The media stops because the server stopped it, not because the
client cooperated.

Deferring the ad *mechanism* is fine. Deferring the accounting and the
permission hook is what makes it hard later.

## Behaviour requirements

- **Viewers select which screen they receive**, one at a time. The cost model
  depends on it — a factor of 9 against the watch-everything case.
- **Dynacast enabled**, so published tracks with no subscribers are paused.
  With no publisher cap this is what protects SFU ingest and CPU.
  **Correction, 29 October 2026:** this is a publishing-client option in
  LiveKit, not a room or token setting — `CreateRoomRequest` has no dynacast
  field and neither does the token grant. The API cannot turn it on; it can
  only state the requirement, which the token response now does with
  `requires_dynacast: true`. A client that ignores it re-creates the ingest
  problem on 2 OCPU and the API cannot tell.
- **Adaptive bitrate** on publish, so a degrading network reduces quality
  rather than dropping the share.
- **System audio falls back gracefully.** When the browser or OS does not offer
  system audio, the share proceeds video-only with a clear indication in the UI.
  The API must not treat an audio-less share as a failed share.
