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

*Landed 2026-07-08 — played iPhone↔iPad. Invite-path hardening after the
first session: GameKit's transient `.unknown` connection state is not a
disconnect (was displayed — and mid-game treated — as one), hello re-sends
on `.connected` (invites connect after didFind), matchmaking/lobby keep
the screen awake (auto-lock killed the handshake), and a fresh invite
re-presents the matchmaker sheet.* `NetworkPlay.swift`:
`SeatMap` (wire seats are GLOBAL — humans sorted by gamePlayerID, host
first, bots appended; in memory every device keeps 0 = me, so engine and
views never learned about global seats), `HostTableAuthority` (wraps
LocalTableAuthority and sits on its delegate line — remote claims enter
the same claim pipeline bots use with a 0.3s flight, "first card down"
= landing at the host's table; every landing/bounce/shuffle/settlement
broadcasts), `GuestTableAuthority` (strictly host-ordered replica;
your own play = a short claim born `landed` so the card slides hand →
pile while the claim races the wire; outcomes queue on `flying` and
settle through the solo pipeline). Guest plays are optimistic-feel:
score haptic at drop, rare bounce comes home with a nope. Bots are just
extra host-simulated seats (lobby picker, up to 4 total). Badges ride
`nertsCount` self-reports (bounce-adjusted at settlement for the tally);
host gates NEXT ROUND/rematch; undo of foundation plays returns false
online ("too late" banner); pause is a leave-confirm online; any human
disconnect mid-game dissolves the table (rejoin is Phase 3). Stats:
every device records `.multiplayer` rounds with human(id:) seats from
the shared host summary and matchID.

**Phase 3 — Hardening + extras.** Disconnect/host-drop handling (end round
gracefully; no mid-round rejoin in v1), 3–4 player tables, GC leaderboards/
achievements fed from StatsStore, latency polish.

*3a landed 2026-07-08 (a2bf77d):* guest drop → host settles the round
(caller −1, "ROUND OVER — X left the table"), next deal seats a bot in
the empty chair (seatConverted message, name + 🤖); host drop → menu
with a "closed the table" note.

*3b built 2026-07-08 — latency + ordering, pending device test:*
replica mutations now apply strictly in host-broadcast order via a
FIFO drain (two cards racing one pile 0.3s apart could previously
stack backwards on guests); your own toss settles the instant the
host's answer arrives instead of on the next tick; `pileAccepts` on
the seam makes validation pending-aware, so runs (4♥ then 5♥ then 6♥)
chain onto your own in-flight cards without waiting a round trip —
if the base bounces the host bounces the chain. Timeouts widened for
bad wifi (unanswered toss 5s, nerts-call watchdog 8s). Known gap: a
freshly tossed ACE can't be chained onto until it commits (~RTT) —
fixing needs client-proposed pile ids + host-side deferred claims;
do it if it stumbles in play.

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
