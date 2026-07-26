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

*3c built 2026-07-26 — first tap wins, table pause, leave button.
Pending device test.*

**Arbitration is now by tap time, not arrival time.** The old rule
gave the host every contested pile (it committed instantly via
`playNow` while a guest's claim cost `latency + 0.3s`), and between
guests the faster connection won regardless of who moved first.
Three pieces, all inside the existing seam:

1. *A shared clock.* `TableClock` (Multiplayer.swift) estimates this
   device's offset from the host's clock off ping/pong — `ping`/`pong`
   now carry `t0`/`t1`, a 2s heartbeat runs for the whole match, and
   the best-of-8-by-lowest-RTT sample wins (a fast round trip is the
   least distorted one). `clock.synced` gates stamping: an unsynced
   stamp is worse than none, so until the first pong lands claims go
   out bare and the host times them on arrival. `hostID` is now bound
   from `tableConfig`'s seating (it drives which peer's pongs are the
   clock) and frozen once `inGame`.
2. *Every play is a claim.* `HostTableAuthority.playNow` no longer
   commits instantly — it enters `inner.submitClaim` like a bot or a
   guest, so the host carries the same small bounce risk it imposes.
   `FlyingCard.tapAt` (host-clock seconds) rides along, and
   `submitClaim` computes `resolveAt = tapAt + flight` — the flight
   runs from the TAP, so wire time is served, not added. `playNow`
   returns `Bool` now: at a networked table it commits nothing, so a
   pile id would have been a fiction. The host's hold window is
   `MatchSession.tableHold`: worst one-way × 1.5 + 40ms, clamped
   120–350ms. Cards launch from their owner's edge badge, and seat 0
   has no edge — `TableView` reads `f.fromSeat != 0 && (!f.landed ||
   f.bouncing)`, so your own cards slide out of your hand. (Keep that
   in the view: making the authority lie about `landed` instead put a
   rendering special case in the rules layer.) A seat-0 claim that
   loses leaves `flying` in the same breath it comes home — your board
   is the one on screen, so a lingering bouncing ghost would draw the
   same card twice.
3. *Ordering.* `LocalTableAuthority.settleDueClaims` resolves due
   claims oldest-tap-first, and blocks any claim while an earlier tap
   is still racing for the same pile — that second rule is what makes
   a slow connection safe. It loops rather than single-passes so a
   landed card frees its chain in the same tick. `endRound` settles
   the last scramble by the same order.

Bots are unchanged by design: they still throw with a 0.68s flight
and still can't see a pile fresher than `params.reaction`, so a human
tapping mid-flight has the earlier stamp and takes the pile. Solo is
untouched — `LocalTableAuthority.playNow` still commits instantly and
solo has no seat-0 flights at all.

Fixed on the way through: `pileAccepts` is now seat-scoped and used
by `submitClaim`, so a guest's chained run (4♥ then 5♥ inside one
hold window) validates at the host instead of being rejected because
the base hadn't committed — 3b's documented chaining wasn't actually
implemented host-side. Only the *thrower's* own flights count, so
nobody builds on a card they couldn't have seen.

**Pause is table-wide.** Anyone may call one; only the host declares
it. `pauseRequest(seat:on:)` → host → `pauseState(by:)` → everyone,
through `TableAuthority.requestPause` / `TableAuthorityDelegate.
tablePauseChanged`. `GameEngine.paused` is now computed from
`pausedBy` so every existing read still works. The host **holds**
gameplay messages while frozen (capped at 256) rather than dropping
them — a player who hadn't heard about the pause yet still threw
cards, and those resolve honestly on resume (their `tapAt` is older
than everything post-resume, so they land first, correctly). Resume
policy: the pauser, or the host after 5s as an override, plus a 120s
auto-resume backstop so a vanished pauser can't strand the table.
`roundLive` guards against a pause request arriving after the round
already settled here (it would otherwise start queueing against a
dead round). Backgrounding still does NOT pause an online table —
leaving your seat isn't grounds for freezing everyone else, and a
one-sided freeze would drift this device's deadlines off the host's.

**Leaving** moved to the top-right corner (`TableLayout.leavePos`,
deliberately *not* mirrored by left-hand mode — the point is that no
thumb rests there), and every online exit now confirms through one
`leaveTableConfirmation` modifier whose copy changes by role. The
scoreboard's QUIT and a guest's LEAVE TABLE previously dropped the
table with no warning at all. Solo quit stays confirmation-free (it
keeps the match on CONTINUE).

**NERTS calls are arbitrated the same way.** It was the last place
arrival order still decided anything — the host's call settled
instantly while a guest's cost a one-way trip. `nertsCalled` now
carries `tapAt`, `TableAuthority.endRound` takes `calledAt:`, and a
call opens the same window a contested pile gets: every call arriving
inside it competes and the earliest emptied pile takes the round.
The window runs from the *first* call's own stamp, which is always at
least as long as correctness needs (a call tapped at X arrives by
X + hold, so once host time passes winner.tapAt + hold no earlier
call can still be in flight, and firstTapAt ≥ winnerTapAt). Claims
arriving during the window still enter the pipeline and are settled
by `endRound`'s final sweep — cards in the air when NERTS is called
land if they legally can, exactly as before. `calledAt: nil` means
"not a race, settle now" (a departure); a call already in hand
outranks a departure, since somebody genuinely went out.

**Solo is provably unaffected by all of the above**, which is the
point of putting it behind the seam rather than forking the rules:
- Human plays still go `playNow` → `landOnFoundation`, instant. No
  seat-0 claim ever exists in solo, so there is nothing to order.
- Every bot claim uses the same 0.68s flight, so `resolveAt` order ==
  `tapAt` order == insertion order — the new sort reproduces the old
  array order exactly, and the "wait for an earlier tap" block can
  never fire (an earlier tap is always due first at equal flights).
- The seat-scoped `pileAccepts` widening is unreachable for bots:
  `AIBrain.decide` only ever reads committed foundations, so it
  cannot propose a card that chains onto its own in-flight one.
- `LocalTableAuthority.endRound` ignores `calledAt` entirely, so
  solo NERTS keeps the tick's deliberate head start for the human
  (the human check runs before the bot loop and returns).

Dev flags: `-mockonline` plays a real online table with nobody on the
other end — a genuine `HostTableAuthority` with a no-op wire, so the
hold window, tap ordering, pause broadcast and "too late to undo" are
the same code the device runs. (It deliberately does NOT just wear the
chrome over a solo table; that made the simulator disagree with the
device in exactly the places that are expensive to test.) `-mockpaused`
pauses 3s in, since simctl can't tap.

Everything that stamps a moment goes through `TableAuthority.tableNow`
— solo and the host answer with their own clock because they *are* the
reference, a guest answers with its measured offset. No caller has to
know which device it's on.

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
