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

*Landed 2026-07-08 — `Nertz/TableAuthority.swift`.* `TableAuthority`
protocol owns all contested state (foundations, flying claims, scores,
round number, summary) with exactly three doors onto a foundation:
`playNow` (instant commit — human solo path, host-local later),
`submitClaim` (in-flight claim — bots today, remote humans in Phase 2),
`undoFoundationPlay` (rollback — solo undo today, optimistic-commit
reject path later). `TableAuthorityDelegate` is the host→all stream
(`claimLanded`/`claimBounced`/`nertsLeftCounts`/`roundEnded`/
`tableShuffleCalled`), synchronous in solo. `LocalTableAuthority` keeps
the rules (`landOnFoundation` is still the single mutation primitive,
`endRound` still the single `StatsStore.record` door). Pacing doors
(`settleDueClaims`/`checkStuck`/`shiftDeadlines`) are driven from the
engine's tick/pause so table deadlines stay pause-shifted. GameEngine
keeps boards, AI, deal, input, presentation; views are untouched (the
engine forwards `foundations`/`flying`/`scores`/`roundNumber`/`summary`
as computed reads of the observable authority).

**Phase 1 — GameKit plumbing.** GC capability + App Store Connect config,
`GKLocalPlayer` auth on launch (behind a setting), matchmaking UI
(invite/auto-match), seat assignment, message codec, echo test between
Joel's iPhone and iPad.

*Landed 2026-07-08 — echo test passed between Joel's iPhone and iPad
(both on iOS 26.5; needs Xcode ≥ 26.6 to deploy to the M4 iPad, and the
iPad's Game Center runs a second Apple ID since same-account devices
can't match).* GC entitlement at
`Support/Nertz.entitlements` (wired into both configs). `GameCenter.swift`:
`GameCenterManager` (opt-in auth via the menu's GAME CENTER toggle —
`gameCenterOn` in UserDefaults, `-gameCenterOn YES` for dev runs — plus
invite listener) and `MatchmakerView` wrapping GKMatchmakerViewController
(min 2 / max 4, auto-match + invites). `Multiplayer.swift`: `NetMessage`
(Codable JSON over `.reliable` — hello/ping/pong for now), `OnlineSeat`,
and `MatchSession` (GKMatch delegate via bridge; deterministic seating =
everyone sorts gamePlayerIDs, seat 0 hosts — zero negotiation messages).
`LobbyView.swift`: seats, host crown, connection dots, event log, PING
button with measured RTT. Menu gets PLAY ONLINE + the toggle; solo flow
untouched. Test notes: the two devices must be signed into *different*
Game Center accounts (you can't match with yourself); if auto-match
errors, enable Game Center for the app record in App Store Connect
(App Store tab → Game Center) — the entitlement alone usually suffices
for sandbox play.

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
