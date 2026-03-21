JaysSync = JaysSync or {}

JaysSync.MOD_ID = "JaysSync"
JaysSync.DEBUG = false

------------------------------------------------------------
-- Network commands (2-char for compact packets)
------------------------------------------------------------
JaysSync.CMD_PLAYER_STATES    = "ps"
JaysSync.CMD_PLAYER_IMMEDIATE = "pi"
JaysSync.CMD_ZOMBIE_STATES    = "zs"
JaysSync.CMD_ZOMBIE_IMMEDIATE = "zi"
JaysSync.CMD_VEHICLE_STATES   = "vs"
JaysSync.CMD_VEHICLE_IMMEDIATE = "vi"

------------------------------------------------------------
-- Player sync config
------------------------------------------------------------
JaysSync.BROADCAST_INTERVAL  = 20       -- ticks between full player broadcasts
JaysSync.IMMEDIATE_COOLDOWN  = 4        -- min ticks between immediate syncs per player
JaysSync.MIN_MOVE_DELTA_SQ   = 0.25     -- 0.5^2
JaysSync.INTERP_SPEED        = 0.35     -- client lerp factor (0-1)
JaysSync.SNAP_DISTANCE       = 10.0     -- teleport threshold (squares)
JaysSync.PREDICT_DECAY       = 0.92     -- velocity decay per tick
JaysSync.STALE_TICKS         = 120      -- drop after N ticks without update
JaysSync.CORRECTION_BLEND    = 0.25     -- error blend-out rate

-- Movement states
JaysSync.STATE_IDLE    = 0
JaysSync.STATE_WALK    = 1
JaysSync.STATE_RUN     = 2
JaysSync.STATE_SPRINT  = 3
JaysSync.STATE_CROUCH  = 4
JaysSync.STATE_PRONE   = 5

------------------------------------------------------------
-- Zombie sync config
------------------------------------------------------------
JaysSync.ZOMBIE_BROADCAST_INTERVAL = 30    -- ticks between zombie broadcasts
JaysSync.ZOMBIE_SYNC_DISTANCE      = 100   -- squares
JaysSync.MAX_TRACKED_ZOMBIES       = 150   -- hard cap
JaysSync.ZOMBIE_IMMEDIATE_COOLDOWN = 3
JaysSync.ZOMBIE_STALE_TICKS        = 300
JaysSync.ZOMBIE_SNAP_DISTANCE      = 6.0
JaysSync.ZOMBIE_INTERP_SPEED       = 0.40
JaysSync.ZOMBIE_PREDICT_DECAY      = 0.88

------------------------------------------------------------
-- Vehicle sync config
------------------------------------------------------------
JaysSync.VEHICLE_BROADCAST_INTERVAL = 25   -- ticks between vehicle broadcasts
JaysSync.VEHICLE_SYNC_DISTANCE      = 140  -- squares
JaysSync.VEHICLE_SNAP_DISTANCE      = 8.0
JaysSync.VEHICLE_INTERP_SPEED       = 0.50
JaysSync.VEHICLE_PREDICT_DECAY      = 0.95
JaysSync.VEHICLE_STALE_TICKS        = 180

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

function JaysSync.distSq(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
end

function JaysSync.log(...)
    if JaysSync.DEBUG then
        print("[JaysSync]", ...)
    end
end

-- Generic throttle check. Returns true if should throttle (too soon).
-- Sets cache[id] = tick if not throttled.
function JaysSync.throttle(cache, id, tick, cooldown)
    local last = cache[id]
    if last and (tick - last) < cooldown then
        return true
    end
    cache[id] = tick
    return false
end

-- Remove entries from a {[id] = tick} cache older than maxAge.
function JaysSync.purgeStaleThrottles(cache, tick, maxAge)
    for id, t in pairs(cache) do
        if (tick - t) > maxAge then
            cache[id] = nil
        end
    end
end

-- Shortest-arc angle interpolation (degrees). Returns interpolated angle.
function JaysSync.lerpAngle(current, target, t)
    local delta = target - current
    while delta > 180 do delta = delta - 360 end
    while delta < -180 do delta = delta + 360 end
    if math.abs(delta) < 0.5 then return target end
    return current + delta * t
end

-- Shortest-arc angle interpolation (radians). Returns interpolated angle.
function JaysSync.lerpAngleRad(current, target, t)
    local pi = math.pi
    local delta = target - current
    while delta > pi do delta = delta - pi * 2 end
    while delta < -pi do delta = delta + pi * 2 end
    if math.abs(delta) < 0.01 then return target end
    return current + delta * t
end
