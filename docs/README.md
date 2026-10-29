# shareframe-api docs

Planning and design documentation for the Go backend: authentication, room
permissions, subscription limits, session management and LiveKit token issuance.

These are **design documents, not a vendor quote and not a description of
shipped code.** The repository currently contains no implementation; every
endpoint, table and limit described here is a proposal to be confirmed during
implementation. All USD prices and included-usage figures are the public
LiveKit and Oracle figures as of **24 October 2026** — recheck the official
pricing pages before launch or before setting a premium price.

## Contents

| Document | Covers |
| --- | --- |
| [`architecture.md`](architecture.md) | Product scope, connection flow, service boundaries, proposed API surface and data model |
| [`authentication.md`](authentication.md) | OAuth2 login, the BFF flow, multi-provider schema, guest sessions, OAuth-specific security rules |
| [`room-access.md`](room-access.md) | Room title and description, join codes, private-room passwords, invites vs code+password |
| [`security.md`](security.md) | Non-negotiable security rules: secret handling, server-side enforcement, private-room checks, rate limiting |
| [`media-bandwidth.md`](media-bandwidth.md) | How traffic is calculated, worked scenarios, the ingest problem, the thumbnail trap |
| [`livekit-hosting.md`](livekit-hosting.md) | LiveKit Cloud vs self-hosted, the Oracle VM's real capacity, why self-hosting won |
| [`plans-and-limits.md`](plans-and-limits.md) | Free and premium limits, the ad-supported free tier, and where each limit is enforced |
| [`roadmap.md`](roadmap.md) | Implementation phases and what each one must prove |
| [`open-questions.md`](open-questions.md) | Decisions log, plus the one question still open |

## Decided shape

| | |
| --- | --- |
| Login | **OAuth2 only** — Google for the first test, no user passwords |
| Rooms | **Title + optional description**; public rooms get a slug, all rooms get a join code |
| Private access | **Join code + room password**, or a per-identity invite |
| Room size | 5–10 participants |
| Publishing | **Any participant may publish** — no cap |
| Subscribing | **One stream per viewer** |
| Session length | **Unlimited**, hourly ad break for free users (future) |
| Quality | Free 720p30, premium up to 1080p |
| Region | **Brazil only**, single region |
| Hosting | **Self-hosted LiveKit** on Oracle Always Free A1 (2 OCPU / 12 GB, confirmed) |
| Disconnect | Immediate removal, slot freed, no grace period |

## The three things that matter most

**1. Publishing is uncapped only because subscribing is capped.** Downstream
traffic is `participants × 1 stream × bitrate` — about 9.0 GB/hour for a
10-person 720p room, whether two people are sharing or all ten. Under
watch-everything the same room would be 81 GB/hour. These two decisions are a
pair; revisiting either one alone breaks the cost model. The subscription cap
must be enforced server-side, and the screen picker must not quietly hold ten
live subscriptions.

**2. Dynacast is mandatory, not a tuning option.** With no publisher cap, ten
streams arrive at the SFU and most have no viewer. Pausing unsubscribed tracks
is what protects 2 OCPU from paying to decrypt and discard media nobody watches.

**3. Unlimited free hours is why self-hosting won.** Against LiveKit Cloud's
participant-minute meter — 600 per 10-person room-hour — an unlimited free tier
is an uncapped cost behind an uncapped promise, with the offsetting ad revenue
still unbuilt. Fixed-cost hosting makes the failure mode a degraded room instead
of a growing invoice. Keep the integration config-driven so the decision stays
reversible.

## What is still open

The **premium price**, which needs the concurrent-rooms-per-VM figure from the
Phase 5 load test. The calculation is set up in
[`open-questions.md`](open-questions.md) with the derivable parts filled in: a
premium participant costs 2× a free one in bandwidth (1.8 vs 0.9 GB per
participant-hour), and on self-hosted hardware the marginal cost is $0, so
premium prices against *capacity* rather than per-hour cost.

One Phase 0 blocker: **confirm the VM is in a Brazil region.** A US-region
instance adds ~110–160 ms RTT for the only user base there is.

## Related

- [`shareframe-web`](https://github.com/esuEdu/shareframe-web) — React frontend, design system and room UI
