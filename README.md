# JaysSync

**Built for dedicated servers.** Player, zombie, and vehicle position sync with dead reckoning for Project Zomboid Build 42 multiplayer.

Fixes crouch desync, frozen players, position drift, ghost zombies, and vehicle rubber-banding.

This mod requires a dedicated server setup. Both the server and all connecting clients need it installed. No effect in singleplayer.

## What it syncs

| Entity | Data | Method |
|--------|------|--------|
| Players | Position, velocity, direction, movement state (idle/walk/run/sprint/crouch), health | Dead reckoning + error blending |
| Zombies | Position, velocity, direction, health, crawling state | Dead reckoning + error blending + threat proximity |
| Vehicles | Position, velocity, angle, speed, tow chains, engine, headlights, brake lights, lightbar, siren, alarm | Dead reckoning + error blending |

## How it works

### Server (authoritative)
- Periodic broadcasts at configurable intervals (staggered per entity type to avoid packet bursts)
- Immediate sync on critical events: player state changes, zombie hits/deaths/AI state changes
- Threat proximity sync: zombies within 3 tiles of any player get immediate position updates every 2 ticks (capped at 20/tick)
- Pre-computed player position cache for efficient distance filtering across all entity types
- Zombie cap with distance-based priority (closest first)
- Towed vehicles are always included when the towing vehicle is in range
- Deduplication: entities sent via immediate sync are skipped in the next periodic broadcast
- Threat proximity sync skips broadcast ticks to prevent packet flooding
- Stale cache purging every 600 ticks to prevent memory leaks
- All methods verified against PZ Build 42 source with existence checks and pcall wrapping

### Client (interpolation)
- Dead reckoning: predicts positions between updates using velocity with exponential decay
- Error blending: smoothly corrects prediction errors instead of snapping
- Combat exclusion: stops overriding nearby zombie positions while the local player is attacking (4 tiles, 10 tick cooldown) to avoid fighting PZ's own combat system
- Driver/passenger exclusion: does not sync the vehicle the local player is in
- Per-entity-type config: players, zombies, and vehicles each have independent tuning
- O(1) entity lookups via ID caches rebuilt once per tick (only when remote data exists)
- Snap threshold: teleports entities that are too far from their expected position
- Direction angle validation: guards against NaN/Infinity in interpolation
- Velocity cap: prevents prediction spikes from teleports or admin commands

### Error handling
- Every Java method call is pcall-wrapped — the mod cannot crash the server or client
- Each zombie is individually protected in broadcast loops — one bad entity never kills the whole broadcast
- Vehicle state checks are independently wrapped — one failed check doesn't skip the rest
- Rate-limited warnings (5 per context per 300 ticks) prevent console spam
- If the mod encounters any error, it silently falls back to vanilla sync behavior
- Existence checks on API methods that may not be present in all PZ builds

## Installation

### Server & Client
Copy the `JaysSync` folder to:
```
C:\Users\<you>\Zomboid\mods\JaysSync\
```

Add to your server config (`Zomboid\Server\<servername>.ini`):
```ini
Mods=JaysSync
```

Both server and client need the mod files. The `WorkshopItems` line is only needed for Steam Workshop installs.

## Sandbox Options

All settings are configurable in sandbox options. Each entity type can be independently toggled and tuned.

### Player Sync
| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| Broadcast Interval | 20 ticks | 5-120 | How often player positions are sent (~660ms at default) |
| Interpolation Speed | 0.35 | 0.05-1.0 | Client lerp speed toward target position |
| Snap Distance | 10.0 sq | 2.0-50.0 | Teleport instead of interpolate above this distance |

### Zombie Sync
| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| Enabled | true | true/false | Toggle zombie sync on/off |
| Sync Distance | 100 sq | 20-300 | Max range to track zombies from any player |
| Broadcast Interval | 30 ticks | 10-120 | How often zombie positions are sent (~1s at default) |
| Max Tracked Zombies | 150 | 20-500 | Hard cap, closest zombies prioritized |
| Interpolation Speed | 0.40 | 0.05-1.0 | Client lerp speed |
| Snap Distance | 6.0 sq | 2.0-50.0 | Teleport threshold |

### Vehicle Sync
| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| Enabled | true | true/false | Toggle vehicle position sync on/off |
| State Sync Enabled | true | true/false | Toggle vehicle state sync (engine, lights, siren) on/off |
| Sync Distance | 140 sq | 30-400 | Max range to track vehicles |
| Broadcast Interval | 25 ticks | 10-120 | How often vehicle positions are sent (~830ms at default) |
| Interpolation Speed | 0.50 | 0.05-1.0 | Client lerp speed |
| Snap Distance | 8.0 sq | 2.0-50.0 | Teleport threshold |

### Debug
| Option | Default | Description |
|--------|---------|-------------|
| Debug Logging | false | Prints detailed sync data to server/client console |

## Tuning tips

For a **snappier feel** on a private server (1-4 players):
- Lower broadcast intervals (10 for players, 15 for zombies, 10 for vehicles)
- Raise interpolation speeds (0.5 for players, 0.5 for zombies, 0.6 for vehicles)

For **high player count / bandwidth concerns**:
- Raise broadcast intervals
- Lower Max Tracked Zombies
- Reduce sync distances
- Disable vehicle state sync if another mod handles it

## Architecture

```
shared.lua   - Constants, commands, validation, helpers (throttle, purge, angle lerp, isFinite)
server.lua   - Server-authoritative tracking, broadcasts, threat proximity, event hooks
client.lua   - Dead reckoning, error blending, combat exclusion, interpolation, ID caches
```

All sync follows the same pattern:
1. Server tracks entity state in an ID-keyed map
2. Server broadcasts snapshots (position + velocity) at configurable intervals
3. Server sends immediate updates on critical events (throttled, deduplicated)
4. Server sends threat proximity updates for zombies near players (every 2 ticks)
5. Client receives snapshots, calculates prediction error, stores state
6. Client advances dead reckoning each tick using velocity with decay
7. Client blends out prediction error smoothly over time
8. Client lerps the game object toward the final predicted position (with combat/driver exclusion)

## Important notes

- This mod is not a miracle fix. PZ has engine-level sync issues (corrupted combat packets, buffer errors, AI state locks) that no Lua mod can solve. JaysSync supplements the engine's native sync.
- Compatible with vehicle mods — all vehicles use the same BaseVehicle API regardless of which mod added them.
- Compatible with other sync mods — if running alongside another sync mod, disable overlapping features via the sandbox toggles.
- Does not sync inventory, combat, damage, animations, or sounds — PZ's engine handles those natively.

## Changelog

### v1.6 - Desync Root Cause Fix + B42 API Audit

**Root cause fix — 15–20 minute zombie desync:**
- `broadcastZombies` was iterating all of `trackedZombies` (including stale entries held for up to 300 ticks) and broadcasting their last-known positions as current ground truth. Every zombie that passed through sync range and left contributed a "ghost" position that was re-sent every broadcast cycle. This compounded over time as more zombies cycled in and out of tracking. Fixed: batch now only includes zombies observed alive and in range during the current broadcast cycle (`seen` set).

**Performance fixes:**
- `onZombieUpdate` hook now returns immediately for zombies not in `trackedZombies` — eliminates unnecessary pcall overhead for all out-of-range zombies every AI update tick
- Threat proximity check throttled to every 3 non-broadcast ticks (was every non-broadcast tick) — reduces full O(Z) zombie list scans from ~58/s to ~20/s at 60 TPS
- Client lookup cache (`rebuildLookupCaches`) now only runs when a new zombie or vehicle packet has been received — `lookupsNeedRebuild` dirty flag prevents O(Z+V) rebuild every rendered frame

**B42 API audit fixes (all were silently non-functional):**
- Direction sync: replaced `getDirectionAngle()`/`setDirectionAngle()` (do not exist in B42) with `getDir():name()` on server and `setDir(IsoDirections[state.dir])` on client — direction sync now actually works for the first time
- Vehicle angle: replaced `setAngleZ()` (does not exist) with `setAngles(x, y, z)` reading current `getAngleX()`/`getAngleY()` — vehicle rotation sync now actually works
- Removed `zombie:setDead(true)` (does not exist in B42) — PZ's engine kills zombies when health reaches 0 via its own systems
- Removed `player:getBodyDamage():setOverallBodyHealth()` (setter does not exist; only getter exists) — PZ syncs player health natively over the network, no Lua override needed

### v1.5 - Intense Audit Fixes
- Fixed critical infinite loop bug in angle interpolation when receiving Infinity values
- Fixed combat exclusion staying permanently active after mod data reload
- Individual zombie pcall wrapping in broadcast loop — one bad zombie no longer kills the entire broadcast
- Split vehicle state apply into independent pcalls — one failed state check no longer skips the rest
- Added direction angle validation (isFinite) on all server snapshots and client interpolation
- Added existence checks for getDirectionAngle, isSneaking, getPlayerByOnlineID with warnings
- Cached getOnlineID in broadcastAllPlayers (was called 4x per player per broadcast)
- refreshPlayerPositions now only runs when zombie sync or a broadcast needs it
- Velocity capped at 15 tiles/tick to prevent teleport prediction spikes
- warn() rate-limited to 5 per context per 300 ticks to prevent console spam
- Verified all API methods against PZ Build 42 game source files

### v1.4 - Combat Awareness
- Threat proximity sync: zombies within 3 tiles of any player get immediate position updates every 2 ticks
- Combat exclusion: client stops overriding nearby zombie positions while the local player is attacking
- Threat sync skips broadcast ticks to avoid packet bursts
- Capped threat syncs at 20 per tick to prevent UDP flooding during hordes
- Sandbox options now use proper boolean type for toggles
- Fixed sandbox-options.txt comment syntax crash (PZ parser doesn't support `--` comments)

### v1.3 - Feature Toggles
- Added Enable Zombie Sync toggle (on/off, default: on)
- Added Enable Vehicle Sync toggle (on/off, default: on)
- Added Enable Vehicle State Sync toggle (on/off, default: on)
- Server skips all broadcasts and events for disabled features (zero overhead when off)
- Client ignores packets for disabled features

### v1.2 - Vehicle State Sync
- Sync vehicle visual/audio states: engine running, headlights, brake lights, lightbar lights, lightbar siren, alarm
- States only updated on client when value actually changed (no redundant calls)
- Lightbar sync only applied to vehicles that have a lightbar (police/emergency)

### v1.1 - Production Hardening
- All Java object access wrapped in pcall — mod never crashes the server or client
- Position validation (NaN, Infinity, world bounds) on all snapshots
- Packet chunking (batches of 50) to stay under UDP size limits
- Driver exclusion: vehicle sync skips the vehicle the local player is driving
- Whitelist copy on network data to prevent internal field leaks
- Zombie health/crawling only updated when value actually changed
- Fixed `zombie` namespace collision in server safeSend
- Always-on `warn()` logging for errors (separate from debug toggle)
- Each broadcast wrapped independently so one failure doesn't block others

### v1.0 - Initial Release
- Player, zombie, and vehicle position sync with dead reckoning
- Server-authoritative architecture with staggered broadcasts
- Immediate sync on combat events (OnHitZombie, OnZombieDead, OnZombieUpdate, OnAIStateChange)
- O(1) entity lookups via ID caches on client
- Pre-computed player position cache on server for efficient distance filtering
- Deduplication between immediate and periodic syncs
- Stale cache purging to prevent memory leaks
- 13 configurable sandbox options
