# TRPLite

A lightweight roleplay-profile addon for the WoW Classic Era 1.14 client, wire-compatible with the original [TurtleRP](https://github.com/tempranova/turtlerp) (1.12) protocol. Built specifically to work on a custom vanilla server where automated chat sends are silently dropped by the client — see _The Silent-Drop Story_ below for why that constraint shaped the entire design.

If you just want a clean RP profile addon for Classic Era and your server is fine with addon-driven chat, this works. If your server runs the same family of build that drops non-hardware-event channel sends, this is one of the few addons in this niche that handles it.

## What it does

- Read other players' RP profiles via the `TTRP` chat channel — the TurtleRP wire format, byte-for-byte.
- Edit and broadcast your own profile (identity, RP-info dropdowns, description) with per-field privacy toggles.
- Show RP details on player tooltip mouseover, drawn from cached data.
- Browse the directory of seen players, filter by name, click to fetch full profile.
- Inspect any cached profile in a read-only info viewer — including At-a-Glance entries received from 1.12 TurtleRP users (TRPLite doesn't author AAG of its own, but it parses and renders what others send).
- Minimap button (draggable, lockable, hideable).

## Install

Drop the `TRPLite/` folder into `Interface\AddOns\` of your Classic Era client:

```
World of Warcraft\_classic_era_\Interface\AddOns\TRPLite\
```

Reload the client. Type `/trp` in chat to see the command list.

## Slash commands

| Command | What it does |
|---|---|
| `/trp` | show command help |
| `/trp dir` | open the directory of seen players |
| `/trp profile` | open the profile editor |
| `/trp ping` | broadcast your full profile (P + MR + TR + DR) immediately |
| `/trp rejoin` | re-join the TTRP channel (recover from greyed-out state) |
| `/trp minimap` | toggle the minimap button on or off |

## How the directory works

Open `/trp dir`. Every player whose ping or data has reached you appears in the list with their zone and online status. Type in the **Filter** box to narrow the list by name. Click a row to:

1. Send M/T/D requests for that player's full profile (clicks are hardware events, so the requests actually go out)
2. Open the read-only info viewer for them — name, race, class, IC/OOC info, At-a-Glance entries (if any), RP-info dropdowns rendered with human-readable labels, full description

The viewer auto-refreshes as the requested chunks land.

## How the profile editor works

`/trp profile` opens a tabbed editor:

- **Identity** — full name, race, class, class colour, IC/OOC info, "currently IC" toggle
- **RP-info** — five TurtleRP-standard dropdowns: RP experience, Walk-Ups, Character Injury, Romance, Character Death
- **Description** — multiline free-form description

Each row has a small **share** checkbox to its right. When unchecked, the field is sent on the wire as an empty string — wire positions are preserved so receivers parse the rest correctly, they just see nothing for that slot. When you hit **Save & Broadcast**, all fields are saved and your profile is broadcast to everyone on the channel.

## Wire-protocol compatibility

TRPLite is wire-compatible with TurtleRP. It uses the same channel name (`TTRP`), the same message types and field orders, the same drunk-encoding trick (replacing `s`/`S` with `°`/`§` so the server-side drunk-speech filter doesn't mangle messages), and the same chunked-response format for long payloads. A 1.12 TurtleRP user and a 1.14 TRPLite user can see each other on the same TTRP channel without either side noticing the difference.

A few fields are forced empty on TRPLite's outgoing wire because TRPLite doesn't expose UI for them: At-a-Glance entries (atAGlance1/2/3 and their Title/Icon variants), the mouseover icon, and pronouns. Wire slots are preserved as empty strings so TurtleRP's parser is unaffected. _Receiving_ those fields from others is unconstrained — the info viewer renders incoming AAG just fine.

## The Silent-Drop Story

This is the interesting engineering bit, and the reason TRPLite exists rather than just being a port of TurtleRP.

On the server this addon was built for (a custom vanilla Classic build), the WoW 1.14 client silently drops `SendChatMessage` calls to a custom channel **unless the call originates from a recent hardware event** — a real keypress, a real mouse click, or a slash-command callback. Calls from `OnUpdate` timers, `OnEvent` handlers, or deferred `C_Timer.After` callbacks leave the client and never reach the channel. No error, no chat warning, no `ADDON_ACTION_BLOCKED` (unless another addon hooks `SendChatMessage` and triggers a protected call from a tainted context). Just silence.

This breaks the standard TurtleRP architecture, which relies on a 30-second background pinger and on auto-replying to incoming data requests. Both of those happen from non-hardware-event contexts and both silently disappear.

TRPLite's design accepts the constraint. Every outgoing channel send originates from a hardware event:

- **Save & Broadcast** in the editor — button click is a hardware event.
- **`/trp ping`** — slash command callbacks are hardware events.
- **Refresh** in the directory — same.
- **Click on a directory row** — same; this is also how you trigger an M/T/D request for someone whose profile you don't have yet.
- **Opportunistic broadcast on chat-Enter** — a hook on `ChatEdit_SendText` piggybacks a `broadcastSelf` onto your own outgoing chat (any `/say`, `/yell`, channel post, whisper). Since you pressed Enter to submit the chat, the send rides the same hardware-event window. Cooldown of 180 seconds keeps the channel quiet even when you're chatting heavily.

Auto-replies to incoming data requests are disabled — they fire from `CHAT_MSG_CHANNEL`'s `OnEvent` and would be silent-dropped (or trip `ADDON_ACTION_BLOCKED` if NobleSpeak or a similar `SendChatMessage` hook is loaded). When someone sends a request your way and their cached key is stale, TRPLite sets a `broadcastNeeded` flag instead, and the next user-driven broadcast (chat-Enter, click, slash command) bypasses the cooldown one time to answer them.

What this means in practice: TRPLite users are *visible* to others as long as they interact with the game — chatting, opening their profile, refreshing the directory. They're invisible if they go AFK without doing anything. There's no fully-automated background broadcaster, because the client wouldn't honour one anyway.

## File layout

```
TRPLite/
├── TRPLite.toc          -- manifest (version, savedvars, load order)
├── TRPLite.lua          -- comms, profile, slash commands, events
├── TRPLite_UI.lua       -- directory, editor, info viewer, tooltip, minimap
└── README.md
```

The `.toc` declares two account-wide saved variables (`TRPLiteCharacters` for the cache of received profiles, `TRPLiteSettings` for preferences and minimap position) and one per-character (`TRPLiteMyProfile` for your own editable profile).

There are no external library dependencies. ChatThrottleLib is intentionally not used — it's a dependency for many RP addons but its `OnUpdate`-driven send queue would also be silent-dropped on this server.

## Known limitations

- **No background pinger.** Your presence is driven by your activity. Stop interacting and you eventually drop off other players' "online" lists.
- **At-a-Glance: read-only.** TRPLite renders received AAG but doesn't author its own (the wire slot stays empty). This was a deliberate choice — the original TurtleRP renderer in the 1.12 client throws a nil-value error on certain AAG payloads, so TRPLite avoids triggering it. If you need to author AAG, edit your profile in TurtleRP itself.
- **Mouseover icons and pronouns: not exposed.** Wire slots are empty for these. No UI to set or display them.
- **Tooltip and info viewer don't bundle TurtleRP's icon table.** AAG entries with icon IDs render their title and body text but no icon graphic.
- **Mouseover-triggered auto-requests are disabled.** Mouseover events aren't hardware events, and on this server those sends silent-drop and may also trip `ADDON_ACTION_BLOCKED` via third-party `SendChatMessage` hooks. The directory-row click is the reliable substitute.

## Credits

- The TurtleRP wire-format design is the work of [Vee / Drixi / tempranova](https://github.com/tempranova/turtlerp). TRPLite reimplements the protocol in a cleaner architecture but the on-the-wire format is theirs.
- Built and tested on a private vanilla Classic server, against a 1.12 TurtleRP client running on a separate machine.

## License

MIT. See `LICENSE` for full text.
