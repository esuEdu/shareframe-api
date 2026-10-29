# Media bandwidth and cost model

A room with 10 participants is not automatically expensive. Traffic depends on
three things: **how many screens are published**, **each stream's bitrate**, and
**how many viewers subscribe to each stream**. An SFU forwards media without
transcoding, so downstream traffic is close to a straight multiplication.

All figures below exclude protocol overhead, retransmissions and audio, and use
GB = 1000 MB. They are order-of-magnitude planning numbers, not predictions of
your bill.

## The formula

```
downstream Mbps = Σ (subscribers of stream × bitrate of stream)
GB/hour = 0.45 × Mbps
```

The `0.45` is just unit conversion: `Mbps × 3600 s ÷ 8 bits = 450 MB/hour`.

Working bitrate assumptions for screen content:

| Quality | Assumed bitrate |
| --- | --- |
| 720p30 (free) | 2 Mbps |
| 1080p (premium) | 4 Mbps |

## The decided model: everyone may publish, viewers watch one

Two product decisions set the shape of the cost:

- **Any participant may publish** — up to 10 screens in a 10-person room, no
  publisher cap.
- **Each viewer subscribes to one screen at a time.**

Together these produce a result that is better than it first looks. Downstream
traffic is bounded by the number of *viewers*, not by the number of publishers:

```
downstream = participants × 1 stream × bitrate
```

Ten people in a room generate the same ~20 Mbps downstream whether two of them
are sharing or all ten are. Removing the publisher cap did **not** make
downstream more expensive, because selective subscription broke the
multiplication. These two decisions only work as a pair — all-may-publish with
watch-everything would have been the worst case in the table below.

## Worked scenarios

Ten participants.

| # | Scenario | Subscriptions | Downstream | GB/hour |
| --- | --- | --- | --- | --- |
| A | **Decided model**, 720p: 10 publishers, each viewer watches one | 10 | 20 Mbps | **9.0** |
| B | **Decided model**, 1080p premium | 10 | 40 Mbps | **18.0** |
| C | Same, but 2 publishers instead of 10 | 10 | 20 Mbps | **9.0** |
| D | *Rejected:* 4 publishers, everyone watches all four | 36 | 72 Mbps | 32.4 |
| E | *Rejected:* 10 publishers, everyone watches all ten | 90 | 180 Mbps | 81.0 |

Scenarios D and E are what the product would have cost under
watch-everything. The gap between A and E — **9 vs 81 GB/hour, a factor of
9** — is the entire value of the selective-subscription decision. It is worth
being deliberate about preserving it; see the thumbnail trap below.

## The new constraint: ingest, not egress

With no publisher cap, the pressure moves upstream. Ten publishers at 720p send
`10 × 2 = 20 Mbps` **into** the SFU, about 9.0 GB/hour inbound — and most of
those streams have no subscriber at all, because viewers are watching one each.

On a 2 OCPU VM, paying CPU to receive, decrypt and discard seven unwatched
streams is the most wasteful thing in the system.

**Dynacast is therefore required, not optional.** LiveKit can pause a published
track that has no subscribers, which stops the publisher encoding and uploading
it. With viewers converging on a few screens — the realistic pattern, since
people watch whoever is presenting — ingest drops to roughly:

| Distinct streams actually watched | Ingest | GB/hour in |
| --- | --- | --- |
| 10 (no dynacast) | 20 Mbps | 9.0 |
| 3 | 6 Mbps | 2.7 |
| 1 | 2 Mbps | 0.9 |

Without dynacast the VM carries full ingest no matter what viewers do, and the
publisher cap you chose not to impose becomes the thing you needed.

## The thumbnail trap

The screen picker in `shareframe-web` is the one UI decision that can silently
undo the cost model. If the picker shows **live thumbnails of all ten screens**,
every viewer is subscribed to every stream — that is scenario E wearing a
different name, even at a low simulcast layer:

```
10 viewers × 10 thumbnails × 300 kbps = 30 Mbps = 13.5 GB/hour
```

That is *more downstream than the ten full-quality streams people are actually
watching.* Acceptable approaches, in order of preference:

1. **Static poster frames** — periodic keyframe snapshots over data channel or
   HTTP, no live subscription.
2. **Subscribe on hover/open only**, one preview at a time, unsubscribed on
   close.
3. **Lowest simulcast layer, picker open only** — never a persistent grid.

A persistent live grid of all screens is not compatible with the cost model.
This belongs in the frontend contract, not just in a backend doc.

## What this means on LiveKit Cloud

Cloud meters **participant-minutes** and **bandwidth** as separate dimensions.
Recording and transcoding charges generally do not apply unless those features
are added later.

At scenario A's 9.0 GB/hour:

| Included downstream | Room-hours it covers |
| --- | --- |
| 50 GB | ≈ 5.6 |
| 250 GB | ≈ 27.8 |

Better than the 1.5 and 7.7 room-hours of the watch-everything model, but still
small. On the published Ship rate of $50/month plus $0.12/GB overage, 100 GB
beyond the allowance is about **$12** of bandwidth on top of the $50.
Illustration, not a quote.

**The decisive problem on Cloud is not bandwidth — it is participant-minutes
against an unlimited free tier.** One 10-person room-hour is 600
participant-minutes. Unlimited free hours means that meter has no ceiling, and
neither does the invoice. See [`livekit-hosting.md`](livekit-hosting.md).

## What this means self-hosted

Self-hosting replaces per-GB and per-minute charges with a fixed machine and
whatever the host charges for egress. Oracle documents a monthly free outbound
allowance for Always Free (commonly cited as 10 TB) — **confirm the current
figure in the Oracle Console.** If it holds, at 9.0 GB/hour it covers roughly
**1,100 room-hours per month** at no bandwidth cost.

Egress will not be the binding constraint. CPU on 2 OCPU will be, and it binds
on *concurrent* rooms rather than monthly hours. Load-test for it.

## What to measure

Record these from the first pilot, in the `sessions` table:

- **participant-minutes** per room and per plan
- **downstream GB** per room and per plan
- **ingest GB** and how many published tracks had zero subscribers — the
  dynacast effectiveness number
- concurrent publishers, peak and distribution
- how often viewers switch streams, and whether they ever hold more than one
