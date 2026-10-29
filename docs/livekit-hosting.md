# LiveKit hosting: Cloud vs self-hosted

LiveKit is open-source and can be self-hosted. **LiveKit Cloud** is the managed
service, priced as a monthly plan tier plus metered usage. Prices quoted here
are the public USD figures from LiveKit's pricing page as of 24 October 2026 —
recheck them before launch.

**Decision: self-host, in a Brazil region, for the pilot and beyond.** Three of
the product decisions point the same way, and one of them is close to
disqualifying for Cloud. Reasoning below.

## Trade-offs

| | LiveKit Cloud | Self-hosted |
| --- | --- | --- |
| **Cost shape** | Plan fee + metered participant-minutes + metered bandwidth. Grows with usage. | Fixed machine + host egress. Flat until capacity runs out. |
| **Unlimited free hours** | **Unbounded liability.** Every free hour bills participant-minutes. | Costs CPU, which is capped by the box. Degrades instead of billing. |
| **Brazil-only users** | Global edge network, most of which you would not use. | A Brazil region VM is already the right topology. |
| **Cost at pilot scale** | $50/month plan plus overage | Plausibly $0 on Oracle Always Free |
| **Ops burden** | None. Upgrades, scaling, TURN and routing handled. | Yours: TLS, UDP ranges, TURN, upgrades, capacity, monitoring. |
| **Scaling** | Elastic, multi-region. | Manual. One VM is one failure domain. |
| **Restrictive networks** | Managed TURN included. | You must run TURN, or some users cannot connect. |
| **Failure mode** | Invoice spikes. | Quality degradation, single point of failure. |

## Why unlimited free hours decides this

Cloud meters participant-minutes. A 10-person room-hour is **600
participant-minutes**. An unlimited free tier means that meter has no product-side
ceiling at all — a handful of users who leave rooms open all day generate
participant-minutes indefinitely, and the ad revenue meant to offset them is a
future implementation that does not exist yet.

On a metered plan, "unlimited free" is a promise whose cost is set by your
users' habits rather than by you. On self-hosted hardware the same promise costs
nothing extra until the VM saturates, and the failure mode is a room that
degrades rather than an invoice that grows. For a free tier with no time limit,
**fixed-cost hosting is structurally the right match**, independent of the
per-GB arithmetic.

If ads ship and the free tier becomes revenue-generating per hour, revisit this.
Until then, do not put an uncapped meter behind an uncapped promise.

## Why Brazil-only reinforces it

A single-region product does not need an edge network. Cloud's global routing is
real engineering value that this product would be paying for and not using. One
VM in São Paulo or Vinhedo *is* the correct topology for Brazilian users, so the
usual latency argument for Cloud does not apply here.

This also removes the strongest trigger in the earlier switch criteria — demand
for a second region — which was the condition most likely to force a migration.

## The API now depends on the SFU to admit anyone

Recorded here because it is a coupling the earlier design did not have. The
ordered check's capacity step counts the SFU's participant list, because the
`sessions` table it would otherwise count is not written until the Phase 4
webhook recorder exists, and a capacity check against an empty table is worse
than none — it reads as a working guarantee.

The consequence: **every** admission, public or private, needs
`RoomService.ListParticipants` to answer. If the SFU is unreachable the token
endpoint returns 500 and nobody can join, which is the correct failure — a
participant could not reach the SFU either — but it is a new single point of
failure on the control path, and it is a loopback call only while the API and
the SFU share this VM. Splitting the SFU onto its own host, which the capacity
section below contemplates, turns it into a network call on the critical path
of every join.

Once Phase 4 writes session rows, capacity could move back to the database and
drop this dependency. That would be a deliberate change, not a cleanup: the
SFU's list is authoritative about who is connected right now, and session rows
are only as current as the last webhook.

## The Oracle VM: 2 OCPU / 12 GB RAM

**Confirmed `VM.Standard.A1.Flex`, Always Free.** That matches Oracle's
documented Always Free Ampere A1 ceiling of 2 OCPUs and 12 GB RAM in total, so
this VM is the entire free A1 allowance — there is no headroom to vertically
scale within the free tier. Growing means paying, or adding a second host.

Two things still to verify in the console:

- **Region.** Is the instance in `sa-saopaulo-1` or `sa-vinhedo-1`? A VM outside
  Brazil adds ~110–160 ms RTT for your only user base. Migrate in Phase 0 if so.
- **Storage and egress charges.** Compute being free does not make block volumes
  and outbound transfer free. Oracle documents a monthly free outbound allowance
  (commonly cited as 10 TB) — confirm the current figure and that it applies to
  this account.

ARM64 matters beyond billing: the Go API, PostgreSQL and the LiveKit server all
need `arm64` builds and images. Routine for all three, but plan for it rather
than discovering it at deploy time.

### Can it run everything?

For the pilot, 2 OCPU / 12 GB can plausibly host the Go API, a small PostgreSQL
instance and self-hosted LiveKit. At the decided model's ~20 Mbps downstream per
10-person room, egress is not the constraint — roughly 1,100 room-hours fit in a
10 TB allowance.

**CPU is the constraint, and the no-publisher-cap decision is what puts pressure
on it.** Ten inbound streams per room must be received, decrypted and forwarded,
and under selective subscription most of them have no viewer. This is why
dynacast is a requirement rather than a tuning option — see
[`media-bandwidth.md`](media-bandwidth.md). With dynacast pausing unwatched
tracks, a room converging on 2–3 watched screens costs a fraction of its
worst case.

Co-location costs worth naming:

- Single point of failure for all three services.
- The SFU competes with the API and database for CPU **and** network. Media
  forwarding is bursty and latency-sensitive; a database checkpoint at the wrong
  moment appears as packet loss in someone's screen share.
- 2 OCPU is thin for sustained packet forwarding plus encryption.

Monitor CPU, packet loss, bandwidth, memory and latency, and **split the media
server onto its own host when measurements justify it** — not on principle.

### Do not estimate capacity from CPU and RAM

LiveKit's own benchmarking guidance is explicit that SFU capacity depends on
published tracks, subscriber counts and forwarded volume — not core count.
"2 OCPU supports N rooms" is not a derivable statement.

The load test that matters for *this* design: 10 participants, **all 10
publishing** at 720p30, each viewer subscribed to one stream, dynacast on,
sustained. Then scale concurrent rooms until CPU or loss degrades. That number —
concurrent rooms per VM — is the real capacity figure, and it is also the input
to pricing premium.

## Switch criteria

Self-hosting is the decision, not a permanent commitment. Keep the LiveKit
integration deployment-agnostic — URL, API key and secret from configuration —
so moving is a config and DNS change, not a rewrite. That is what keeps this
reversible.

Revisit when any of these is true:

- sustained CPU above ~70%, or measurable packet loss during normal rooms
- the concurrent-room ceiling from the load test is being hit in practice
- users on restrictive networks failing to connect, and TURN becoming real work
- the product expands beyond Brazil
- ads ship and free hours become revenue-generating, changing the unlimited-hours
  calculus above
