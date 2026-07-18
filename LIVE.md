# Nertzy In-Person Mode (live scorekeeping)

Built 2026-07-18 with Joel. Real cards on a real table; the app is the shared
scorecard — no calculator, no Notes app. Decisions: local-only (no server, no
database), **MultipeerConnectivity** transport (Game Center's GKMatch caps at 4
players and stores nothing anyway), Game Center used for *identity only* (a
signed-in player's id is their gamePlayerID, so in-person rivals merge with
online ones in the record book), **paper players** for people with no device.

## Shape

- `LiveScore.swift` — `LiveMatch/LivePlayer/LiveRound/LiveEntry` (Codable),
  the scoring math (`delta = table − 2×nertzLeft`), `LiveIdentity` (GC id →
  device UUID fallback; name/emoji in UserDefaults), `LiveSaver` (live.json,
  MatchSaver pattern), `LiveRecorder` (the stats bridge).
- `LiveSession.swift` — the room. Host-authoritative full-snapshot sync:
  guests send `hello`/`submit`, host applies to the one true match, bumps
  `revision`, rebroadcasts the whole thing (a few KB). Snapshots are
  idempotent → ordering, late joins, and reconnects heal for free. Guests
  queue unsent submits and re-apply them on top of adopted snapshots until
  echoed. serviceType `nertzy-score`; host advertises room id + name, guests
  browse and self-invite (profile as context), host approves (rejoiners with
  a known player id walk right in; lapsed invites get ONE quiet re-knock so a
  denial isn't nagged). Radios die on background — `rearmIfNeeded()` from
  RootView's scenePhase revives them, same pattern as `CodeMatchmaker`.
- Views: `LiveHubView` (host / join-nearby / resume / invite ShareLink),
  `LiveScoreboardView` (standings + scorecard grid, newest round on top;
  join-approval card; champion banner; finished overlay), `LiveEntrySheet`
  (TOTAL keypad ↔ COUNT IT rows with live math; "went out" toggle zeroes the
  nertz count and marks the round's caller).
- Rules living in `LiveMatch`: rounds keyed by player id (not device);
  auto-close when every player has an entry (host CLOSE ROUND force-closes,
  empty cells score 0); `champion` computed from closed rounds only, so host
  edits can un-crown until FINISH locks `winnerID`; an unfinished match with
  no champion always has an open round (`healOpenRound`).
- Permissions: your own column always; paper columns from any device; the
  host anything, any round, until finished. Trust model same as online.
- **Play again** (host, winner screen): `LiveMatch.rematch()` — new match id,
  same players, fresh card. The advertised **roomID is session-stable**
  (minted at `host()`, in LiveSave, survives rematches) so connected guests
  ride the next snapshot into the new match (adoptSnapshot adopts
  unconditionally on match-id change, drops stale pending) and napping
  guests rejoin by the same room id.
- **Remove player** (host, tap a column header → confirm): drops them from
  `players`; their entries stay dormant in the rounds, so totals/records
  ignore them but the column resurrects — scores and all — if they rejoin.
  A round waiting only on them auto-closes. A removed guest's device sees
  itself gone from the card and bows out to the hub (`wasSeated` guards the
  first-snapshot-races-hello case).

## Stats

`MatchRecord.Mode.live`. Nothing records until FINISH/END NIGHT (the book is
append-only and the host edits all night); then **every device that claimed a
player** runs `LiveRecorder.recordIfNeeded` — loops `StatsStore.record()` per
round with the shared match UUID, seats permuted **me-first** (leaderboard
reporter's `deltas.first` convention), counted entries keep real
foundation/nertz numbers, direct entries store zeros. Dedupe by match id in
UserDefaults (`liveRecordedMatches`). END NIGHT with nobody over the target →
`winnerSeat` nil ("LEFT", streaks unbroken) — same as walking away. Paper
players record nothing but appear in everyone's book as `.human(id:
"paper:<name-slug>")` (stable across nights). `opponentRecords()` and the VS
HUMANS section now cover `.multiplayer` + `.live`.

## Info.plist

`NSLocalNetworkUsageDescription` + `NSBonjourServices`
(`_nertzy-score._tcp/_udp`) in Support/Info.plist — the local-network prompt
fires on first browse/advertise (the hub browses on appear, deliberately).

## Dev flags

- `-showlive` — open the IN PERSON hub at launch.
- `-livedemo` — seed a staged 6-player night (2 paper), round 8 open, no
  radios/disk/records; auto-opens the cover.
- `-livedemo -liveentry` / `-liveentrytotal` — also pop the entry sheet
  (COUNT IT prefill / TOTAL prefill; simctl can't tap).
- `-livedemo -livefinished` — grandma crosses 100, winner overlay.
- `-livedemo -livefinished -liveplayagain` — the rematch's fresh card.
- `-livedemo -liveremove` — the card with Mike removed mid-game.
- `-livedemo -liverecordtest` — same, plus the recorder actually writes
  matches.json (recording deliberately enabled) — inspect the sim container
  to verify the bridge.

## Verified / pending

Simulator-verified: all screens (screenshots), record bridge end-to-end
(matches.json contents: mode live, me-first seats, callers mapped, winnerSeat,
totals). **Pending Joel's devices** (MC is unreliable sim-to-sim): join
handshake + approval, guest submit → host echo, host edit → guest update,
background/lock both sides then reopen (snapshot heal), host force-kill then
REOPEN YOUR TABLE (guests auto-rejoin), paper-player entry from a guest
device. Watch: a wedged MCSession after long suspension — if reconnects fail
on device, recreate the session object in `rearmIfNeeded` instead of reusing.
