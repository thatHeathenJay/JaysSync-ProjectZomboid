# Jay's Sync - Position Fix

**Multiplayer only.** This mod is designed for dedicated servers and has no effect in singleplayer. Both the server and all connecting clients need it installed.

Player, zombie, and vehicle position sync with dead reckoning for Project Zomboid Build 42 dedicated servers. Fixes crouch desync, frozen players, position drift, ghost zombies, and vehicle rubber-banding.

## What it syncs

| Entity | Data | Method |
|--------|------|--------|
| Players | Position, velocity, direction, movement state (idle/walk/run/sprint/crouch), health | Dead reckoning + error blending |
| Zombies | Position, velocity, direction, health, crawling state | Dead reckoning + error blending |
| Vehicles | Position, velocity, angle, speed, tow chains, engine, headlights, brake lights, lightbar, siren, alarm | Dead reckoning + error blending |

## How it works

### Server (authoritative)
- Periodic broadcasts at configurable intervals (staggered per entity type)
- Immediate sync on critical events: player state changes, zombie hits/deaths/AI changes
- Pre-computed player position cache for efficient distance filtering
- Zombie cap with distance-based priority (closest first)
- Towed vehicles are always included when the towing vehicle is in range
- Deduplication: entities sent via immediate sync are skipped in the next periodic broadcast
- Stale cache purging every 600 ticks to prevent memory leaks

### Client (interpolation)
- Dead reckoning: predicts positions between updates using velocity with decay
- Error blending: smoothly corrects prediction errors instead of snapping
- Per-entity-type config: players, zombies, and vehicles each have independent tuning
- O(1) entity lookups via ID caches rebuilt once per tick (only when needed)
- Snap threshold: teleports entities that are too far from their expected position

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

Both server and client need the mod files. The `WorkshopItems` line is not needed for local installs.

## Sandbox Options

### Player Sync
| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| Player Broadcast Interval | 20 ticks | 5-120 | How often player positions are sent (~660ms at default) |
| Player Interpolation Speed | 0.35 | 0.05-1.0 | Client lerp speed toward target position |
| Player Snap Distance | 10.0 sq | 2-50 | Teleport instead of interpolate above this distance |

### Zombie Sync
| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| Zombie Sync Distance | 100 sq | 20-300 | Max range to track zombies from any player |
| Zombie Broadcast Interval | 30 ticks | 10-120 | How often zombie positions are sent (~1s at default) |
| Max Tracked Zombies | 150 | 20-500 | Hard cap, closest zombies prioritized |
| Zombie Interpolation Speed | 0.40 | 0.05-1.0 | Client lerp speed |
| Zombie Snap Distance | 6.0 sq | 2-50 | Teleport threshold |

### Vehicle Sync
| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| Vehicle Sync Distance | 140 sq | 30-400 | Max range to track vehicles |
| Vehicle Broadcast Interval | 25 ticks | 10-120 | How often vehicle positions are sent (~830ms at default) |
| Vehicle Interpolation Speed | 0.50 | 0.05-1.0 | Client lerp speed |
| Vehicle Snap Distance | 8.0 sq | 2-50 | Teleport threshold |

### Debug
| Option | Default | Description |
|--------|---------|-------------|
| Debug Logging | 0 (off) | Set to 1 for detailed console output |

## Tuning tips

For a **snappier feel** on a private server with low player count:
- Lower broadcast intervals (10-15 for players, 15-20 for zombies)
- Raise interpolation speeds (0.5+ for players, 0.5+ for zombies)

For **high player count / bandwidth concerns**:
- Raise broadcast intervals
- Lower Max Tracked Zombies
- Reduce sync distances

## Architecture

```
shared.lua   - Constants, commands, generic helpers (throttle, purge, angle lerp)
server.lua   - Server-authoritative tracking, broadcasts, event hooks
client.lua   - Dead reckoning, error blending, interpolation, ID caches
```

All sync follows the same pattern:
1. Server tracks entity state in an ID-keyed map
2. Server broadcasts snapshots (position + velocity) at configurable intervals
3. Server sends immediate updates on critical events (throttled, deduplicated)
4. Client receives snapshots, calculates prediction error, stores state
5. Client advances dead reckoning each tick using velocity with decay
6. Client blends out prediction error smoothly over time
7. Client lerps the game object toward the final predicted position

## Changelog

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
