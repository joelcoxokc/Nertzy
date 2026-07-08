# Nertzy Multiplayer Plan

Decisions made 2026-07-08 (with Joel). Real-time Game Center (`GKMatch`),
host-authoritative, friendly-play trust model. No custom server. Max 4 players
(GKMatch's real-time cap — exactly one Nertz table). Mixed tables (humans +
bots filling empty seats) are in scope: bots already run on whatever device
hosts, so this is nearly free and makes 2-human games good.

## Why this maps well onto the existing engine

Nertz's only *contested* shared state is the foundations in the middle plus
round lifecycle. Each player's board (nerts pile, work piles, stock/waste) is
private and independent — remote players never need to see it, only a nerts
count for the edge badges. And opponents are already rendered as edge badges +
flying claim cards, so remote humans reuse the existing opponent presentation.

The claim system is the crux and it already exists: an opponent's foundation
play is an in-flight claim (`launchClaim`) that commits at `resolveAt` via
`landOnFoundation` or bounces via `returnToBoard`, first card down wins. A
remote human's play is just a claim whose flight time includes network
latency. The open UX question: locally, does *your* play on a shared
foundation stay instant-commit with rollback-on-reject (feels best, needs a
rollback path) or become a short claim like the AI path (simpler, adds ~RTT
of perceived lag)? Decide in Phase 2 by feel; the engine supports both.

## Protocol sketch (tiny, Codable structs over GKMatch .reliable)

- player → host: `claim(card, pileID?|newPile)` — foundation play attempt
- host → all: `claimResolved(card, pileID, landed|bounced)`
- player → all: `nertsCount(n)` — badge updates; `nertsCalled`
- host → all: `roundStart`, `roundEnd(summaryPerSeat)`, `matchOver(winner)`
- players self-report `nertsLeft` at round end (trust model, fine for v1)
- No shared deal: every player shuffles/deals their own 52-card deck locally.

## Phases

**Phase 0 — Authority seam (solo-only refactor, no networking).**
Extract the boundary inside GameEngine between "my private board sim" and
"shared table authority" (foundations, claim arbitration, round lifecycle,
scoring). Solo play = local authority, behavior identical. Fully testable
without a second device; this de-risks everything after. Touches the hot
paths (`applyMove`, `launchClaim`/`resolveClaim`, `endRound`, tick) — protect
the feel: human plays must stay instant in solo.

**Phase 1 — GameKit plumbing.** GC capability + App Store Connect config,
`GKLocalPlayer` auth on launch (behind a setting), matchmaking UI
(invite/auto-match), seat assignment, message codec, echo test between
Joel's iPhone and iPad.

**Phase 2 — Playable 2P.** Wire the protocol into the authority seam: claims,
badges, nerts call, round/scoreboard sync, rematch. Bots fillable by host.

**Phase 3 — Hardening + extras.** Disconnect/host-drop handling (end round
gracefully; no mid-round rejoin in v1), 3–4 player tables, GC leaderboards/
achievements fed from StatsStore, latency polish.

## Stats integration (already built for this)

`StatsStore.record(summary, settings:, match:)` is the one door; a multiplayer
round feeds the same call on the host's result. `MatchRecord.Mode` gains
`.multiplayer(...)`, `SeatRecord.Kind.human(id:)` already exists (use GC
`gamePlayerID`). Nothing else changes.

## Testing reality (the real cost driver)

GKMatch can't be exercised from the CLI/simulator alone — verification needs
two signed devices (iPhone + iPad work) and Joel in the loop each iteration.
Budget wall-clock accordingly; timing-dependent bugs are the norm in
real-time sync. Keep every phase independently shippable.
