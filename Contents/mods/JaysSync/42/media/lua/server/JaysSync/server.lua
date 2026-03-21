require "JaysSync/shared"

JaysSync.log("Server script loaded")

------------------------------------------------------------
-- State tables
------------------------------------------------------------

-- Player tracking
local trackedPlayers = {}       -- [onlineID] = {x,y,z,dir,moveState,jsTick}
local lastImmediatePlayer = {}  -- [onlineID] = jsTick

-- Zombie tracking
local trackedZombies = {}       -- [onlineID] = {x,y,z,dir,health,crawling,distSq,jsTick,sentImmediate}
local lastImmediateZombie = {}  -- [onlineID] = jsTick
local zombieHealthCache = {}    -- [onlineID] = lastHealth
local zombieCrawlCache = {}     -- [onlineID] = lastCrawling

-- Vehicle tracking
local trackedVehicles = {}      -- [vehicleID] = {x,y,z,speed,angle,towedId,towedBy,jsTick}
local lastImmediateVehicle = {} -- [vehicleID] = jsTick

-- Shared
local jsTick = 0
local playerPosCache = {}       -- [{x,y}] pre-computed once per broadcast cycle

------------------------------------------------------------
-- Safe send wrapper
------------------------------------------------------------

local function safeSend(cmd, data)
    if zombie and zombie.network and zombie.network.GameServer
       and zombie.network.GameServer.udpEngine then
        sendServerCommand(JaysSync.MOD_ID, cmd, data)
    end
end

------------------------------------------------------------
-- Player position cache (computed once, used by zombie + vehicle)
------------------------------------------------------------

local function refreshPlayerPositions()
    playerPosCache = {}
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            playerPosCache[#playerPosCache + 1] = { x = p:getX(), y = p:getY() }
        end
    end
end

local function nearestPlayerDistSq(x, y)
    local minDist = math.huge
    for i = 1, #playerPosCache do
        local pos = playerPosCache[i]
        local d = JaysSync.distSq(pos.x, pos.y, x, y)
        if d < minDist then minDist = d end
    end
    return minDist
end

------------------------------------------------------------
-- Player sync (preserved from original)
------------------------------------------------------------

local function getMoveState(player)
    if player:isSneaking() then return JaysSync.STATE_CROUCH end
    if player.isSprinting and player:isSprinting() then return JaysSync.STATE_SPRINT end
    if player.isRunning and player:isRunning() then return JaysSync.STATE_RUN end
    local prev = trackedPlayers[player:getOnlineID()]
    if prev then
        local speedSq = JaysSync.distSq(player:getX(), player:getY(), prev.x, prev.y)
        if speedSq > 0.001 then return JaysSync.STATE_WALK end
    end
    return JaysSync.STATE_IDLE
end

local function buildPlayerSnapshot(player, prev, dt)
    local id = player:getOnlineID()
    local x, y, z = player:getX(), player:getY(), player:getZ()
    local dir = player:getDirectionAngle()
    local moveState = getMoveState(player)
    local health = player:getBodyDamage():getOverallBodyHealth()

    local vx, vy = 0, 0
    if prev and dt > 0 then
        vx = (x - prev.x) / dt
        vy = (y - prev.y) / dt
    end

    local snapshot = {
        id = id, x = x, y = y, z = z,
        vx = vx, vy = vy, dir = dir,
        ms = moveState, hp = health
    }
    local newTracked = { x = x, y = y, z = z, dir = dir, moveState = moveState, jsTick = jsTick }
    return snapshot, newTracked
end

local function broadcastAllPlayers()
    local players = getOnlinePlayers()
    if not players or players:size() == 0 then return end

    local batch = {}
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player then
            local id = player:getOnlineID()
            local prev = trackedPlayers[id]
            local dt = prev and (jsTick - prev.jsTick) or 0
            local snapshot, newTracked = buildPlayerSnapshot(player, prev, dt)
            trackedPlayers[id] = newTracked
            batch[#batch + 1] = snapshot
        end
    end

    if #batch > 0 then
        safeSend(JaysSync.CMD_PLAYER_STATES, batch)
        JaysSync.log("Broadcast", #batch, "players")
    end
end

local function sendPlayerImmediate(player)
    local id = player:getOnlineID()
    if JaysSync.throttle(lastImmediatePlayer, id, jsTick, JaysSync.IMMEDIATE_COOLDOWN) then return end

    local prev = trackedPlayers[id]
    local dt = prev and (jsTick - prev.jsTick) or 0
    local snapshot, newTracked = buildPlayerSnapshot(player, prev, dt)
    trackedPlayers[id] = newTracked

    safeSend(JaysSync.CMD_PLAYER_IMMEDIATE, { snapshot })
    JaysSync.log("Immediate sync player", id, "state:", snapshot.ms)
end

local function checkPlayerStateChange(player)
    local id = player:getOnlineID()
    local prev = trackedPlayers[id]
    if not prev then return false end

    local currentState = getMoveState(player)
    if currentState ~= prev.moveState then return true end

    if currentState ~= JaysSync.STATE_IDLE then
        local dirDelta = math.abs(player:getDirectionAngle() - prev.dir)
        if dirDelta > 180 then dirDelta = 360 - dirDelta end
        if dirDelta > 45 then return true end
    end

    return false
end

------------------------------------------------------------
-- Zombie sync
------------------------------------------------------------

local function buildZombieSnapshot(zomb, prev, dt)
    local id = zomb:getOnlineID()
    local x, y, z = zomb:getX(), zomb:getY(), zomb:getZ()
    local dir = zomb:getDirectionAngle()
    local health = zomb:getHealth()
    local crawling = zomb:isCrawling()

    local vx, vy = 0, 0
    if prev and dt > 0 then
        vx = (x - prev.x) / dt
        vy = (y - prev.y) / dt
    end

    local snapshot = {
        id = id, x = x, y = y, z = z,
        vx = vx, vy = vy, dir = dir,
        hp = health, cr = crawling and 1 or 0
    }
    return snapshot
end

local function broadcastZombies()
    local cell = getCell()
    if not cell then return end
    local zombieList = cell:getZombieList()
    if not zombieList then return end

    local syncDistSq = JaysSync.ZOMBIE_SYNC_DISTANCE * JaysSync.ZOMBIE_SYNC_DISTANCE
    if #playerPosCache == 0 then return end

    -- Single pass: update trackedZombies from current zombieList
    local seen = {}
    for i = 0, zombieList:size() - 1 do
        local zomb = zombieList:get(i)
        if zomb and zomb:getHealth() > 0 then
            local id = zomb:getOnlineID()
            local zx, zy = zomb:getX(), zomb:getY()
            local dSq = nearestPlayerDistSq(zx, zy)

            if dSq <= syncDistSq then
                seen[id] = true
                local prev = trackedZombies[id]
                local dt = prev and (jsTick - prev.jsTick) or 0
                trackedZombies[id] = {
                    x = zx, y = zy, z = zomb:getZ(),
                    dir = zomb:getDirectionAngle(),
                    health = zomb:getHealth(),
                    crawling = zomb:isCrawling(),
                    distSq = dSq,
                    jsTick = jsTick,
                    sentImmediate = prev and prev.sentImmediate or 0,
                    -- store prev for velocity calc
                    _prevX = prev and prev.x, _prevY = prev and prev.y, _dt = dt
                }
            end
        end
    end

    -- Purge entries not seen or stale
    for id, data in pairs(trackedZombies) do
        if not seen[id] then
            if (jsTick - data.jsTick) > JaysSync.ZOMBIE_STALE_TICKS then
                trackedZombies[id] = nil
                zombieHealthCache[id] = nil
                zombieCrawlCache[id] = nil
                lastImmediateZombie[id] = nil
            end
        end
    end

    -- Build batch, cap at MAX_TRACKED_ZOMBIES
    local batch = {}
    for id, data in pairs(trackedZombies) do
        -- Skip if already sent via immediate this tick
        if data.sentImmediate ~= jsTick then
            local vx, vy = 0, 0
            if data._prevX and data._dt and data._dt > 0 then
                vx = (data.x - data._prevX) / data._dt
                vy = (data.y - data._prevY) / data._dt
            end
            batch[#batch + 1] = {
                id = id, x = data.x, y = data.y, z = data.z,
                vx = vx, vy = vy, dir = data.dir,
                hp = data.health, cr = data.crawling and 1 or 0,
                _distSq = data.distSq
            }
        end
    end

    -- Sort by distance, cap
    if #batch > JaysSync.MAX_TRACKED_ZOMBIES then
        table.sort(batch, function(a, b) return a._distSq < b._distSq end)
        local capped = {}
        for i = 1, JaysSync.MAX_TRACKED_ZOMBIES do
            capped[i] = batch[i]
        end
        batch = capped
    end

    -- Strip internal fields before sending
    for i = 1, #batch do
        batch[i]._distSq = nil
    end

    if #batch > 0 then
        safeSend(JaysSync.CMD_ZOMBIE_STATES, batch)
        JaysSync.log("Broadcast", #batch, "zombies")
    end
end

local function sendZombieImmediate(zomb, forceHealth)
    if not zomb then return end
    local id = zomb:getOnlineID()
    if not id then return end

    -- OnZombieDead bypasses throttle via forceHealth
    if not forceHealth and JaysSync.throttle(lastImmediateZombie, id, jsTick, JaysSync.ZOMBIE_IMMEDIATE_COOLDOWN) then
        return
    end

    local prev = trackedZombies[id]
    local dt = prev and (jsTick - prev.jsTick) or 0
    local snapshot = buildZombieSnapshot(zomb, prev, dt)
    if forceHealth then snapshot.hp = forceHealth end

    -- Mark as sent immediate this tick for dedup
    if trackedZombies[id] then
        trackedZombies[id].sentImmediate = jsTick
    end

    safeSend(JaysSync.CMD_ZOMBIE_IMMEDIATE, { snapshot })
    JaysSync.log("Immediate sync zombie", id)
end

------------------------------------------------------------
-- Vehicle sync
------------------------------------------------------------

local function buildVehicleSnapshot(vehicle, prev, dt)
    local id = vehicle:getID()
    local x, y, z = vehicle:getX(), vehicle:getY(), vehicle:getZ()
    local speed = vehicle:getCurrentSpeedKmHour()

    local okAngle, angle = pcall(function() return vehicle:getAngleZ() end)
    if not okAngle then angle = nil end

    local towedId = nil
    if vehicle.getTowedVehicle then
        local towed = vehicle:getTowedVehicle()
        if towed and towed.getID then towedId = towed:getID() end
    end

    local towedBy = nil
    if vehicle.getTowedBy then
        local tower = vehicle:getTowedBy()
        if tower and tower.getID then towedBy = tower:getID() end
    end

    local vx, vy = 0, 0
    if prev and dt > 0 then
        vx = (x - prev.x) / dt
        vy = (y - prev.y) / dt
    end

    local snapshot = {
        id = id, x = x, y = y, z = z,
        vx = vx, vy = vy, sp = speed,
        ang = angle, towId = towedId, towBy = towedBy
    }
    return snapshot
end

local function broadcastVehicles()
    local cell = getCell()
    if not cell then return end
    local vehicleList = cell:getVehicles()
    if not vehicleList then return end
    if #playerPosCache == 0 then return end

    local syncDistSq = JaysSync.VEHICLE_SYNC_DISTANCE * JaysSync.VEHICLE_SYNC_DISTANCE
    local included = {}  -- [vehicleID] = true
    local batch = {}

    -- First pass: collect vehicles within range
    local vehiclesById = {}
    for i = 0, vehicleList:size() - 1 do
        local v = vehicleList:get(i)
        if v then vehiclesById[v:getID()] = v end
    end

    local function includeVehicle(vehicle, force)
        if not vehicle then return end
        local vid = vehicle:getID()
        if included[vid] then return end

        local vx, vy = vehicle:getX(), vehicle:getY()
        if not force then
            local dSq = nearestPlayerDistSq(vx, vy)
            if dSq > syncDistSq then return end
        end

        included[vid] = true
        local prev = trackedVehicles[vid]
        local dt = prev and (jsTick - prev.jsTick) or 0
        local snapshot = buildVehicleSnapshot(vehicle, prev, dt)
        batch[#batch + 1] = snapshot

        trackedVehicles[vid] = {
            x = vx, y = vy, z = vehicle:getZ(),
            speed = vehicle:getCurrentSpeedKmHour(),
            jsTick = jsTick
        }

        -- Force-include towed vehicle
        if snapshot.towId and vehiclesById[snapshot.towId] then
            includeVehicle(vehiclesById[snapshot.towId], true)
        end
    end

    for _, vehicle in pairs(vehiclesById) do
        includeVehicle(vehicle, false)
    end

    -- Purge stale vehicles
    for vid, data in pairs(trackedVehicles) do
        if (jsTick - data.jsTick) > JaysSync.VEHICLE_STALE_TICKS then
            trackedVehicles[vid] = nil
            lastImmediateVehicle[vid] = nil
        end
    end

    if #batch > 0 then
        safeSend(JaysSync.CMD_VEHICLE_STATES, batch)
        JaysSync.log("Broadcast", #batch, "vehicles")
    end
end

------------------------------------------------------------
-- Stale cache purge
------------------------------------------------------------

local function purgeAllCaches()
    JaysSync.purgeStaleThrottles(lastImmediatePlayer, jsTick, 600)
    JaysSync.purgeStaleThrottles(lastImmediateZombie, jsTick, 600)
    JaysSync.purgeStaleThrottles(lastImmediateVehicle, jsTick, 600)

    -- Purge zombie state caches for zombies no longer tracked
    for id in pairs(zombieHealthCache) do
        if not trackedZombies[id] then
            zombieHealthCache[id] = nil
            zombieCrawlCache[id] = nil
        end
    end
end

------------------------------------------------------------
-- Event hooks
------------------------------------------------------------

local function onInitGlobalModData()
    if SandboxVars.JaysSync then
        local sv = SandboxVars.JaysSync
        JaysSync.BROADCAST_INTERVAL        = sv.BroadcastInterval or JaysSync.BROADCAST_INTERVAL
        JaysSync.SNAP_DISTANCE             = sv.SnapDistance or JaysSync.SNAP_DISTANCE
        JaysSync.INTERP_SPEED              = sv.InterpSpeed or JaysSync.INTERP_SPEED
        JaysSync.ZOMBIE_SYNC_DISTANCE      = sv.ZombieSyncDistance or JaysSync.ZOMBIE_SYNC_DISTANCE
        JaysSync.ZOMBIE_BROADCAST_INTERVAL = sv.ZombieBroadcastInterval or JaysSync.ZOMBIE_BROADCAST_INTERVAL
        JaysSync.MAX_TRACKED_ZOMBIES       = sv.MaxTrackedZombies or JaysSync.MAX_TRACKED_ZOMBIES
        JaysSync.ZOMBIE_INTERP_SPEED       = sv.ZombieInterpSpeed or JaysSync.ZOMBIE_INTERP_SPEED
        JaysSync.ZOMBIE_SNAP_DISTANCE      = sv.ZombieSnapDistance or JaysSync.ZOMBIE_SNAP_DISTANCE
        JaysSync.VEHICLE_SYNC_DISTANCE     = sv.VehicleSyncDistance or JaysSync.VEHICLE_SYNC_DISTANCE
        JaysSync.VEHICLE_BROADCAST_INTERVAL = sv.VehicleBroadcastInterval or JaysSync.VEHICLE_BROADCAST_INTERVAL
        JaysSync.VEHICLE_INTERP_SPEED      = sv.VehicleInterpSpeed or JaysSync.VEHICLE_INTERP_SPEED
        JaysSync.VEHICLE_SNAP_DISTANCE     = sv.VehicleSnapDistance or JaysSync.VEHICLE_SNAP_DISTANCE
        if sv.DebugLogs then
            JaysSync.DEBUG = sv.DebugLogs == 1
        end
    end

    trackedPlayers = {}
    lastImmediatePlayer = {}
    trackedZombies = {}
    lastImmediateZombie = {}
    zombieHealthCache = {}
    zombieCrawlCache = {}
    trackedVehicles = {}
    lastImmediateVehicle = {}
    playerPosCache = {}

    JaysSync.log("Server initialized")
end

local function onTick()
    jsTick = jsTick + 1

    -- Pre-compute player positions when needed by zombie or vehicle broadcast
    local needPos = (jsTick % JaysSync.ZOMBIE_BROADCAST_INTERVAL == 0)
                 or (jsTick % JaysSync.VEHICLE_BROADCAST_INTERVAL == 0)
    if needPos then refreshPlayerPositions() end

    -- Staggered broadcasts
    if jsTick % JaysSync.BROADCAST_INTERVAL == 0 then
        broadcastAllPlayers()
    end
    if jsTick % JaysSync.ZOMBIE_BROADCAST_INTERVAL == 0 then
        broadcastZombies()
    end
    if jsTick % JaysSync.VEHICLE_BROADCAST_INTERVAL == 0 then
        broadcastVehicles()
    end

    -- Periodic stale purge
    if jsTick % 600 == 0 then
        purgeAllCaches()
    end
end

local function onPlayerUpdate(player)
    if not player then return end
    if checkPlayerStateChange(player) then
        sendPlayerImmediate(player)
    end
end

local function onPlayerDisconnect(player)
    if not player then return end
    local id = player:getOnlineID()
    trackedPlayers[id] = nil
    lastImmediatePlayer[id] = nil
    JaysSync.log("Cleaned up player", id)
end

-- Zombie: combat hit
local function onHitZombie(zomb)
    sendZombieImmediate(zomb)
end

-- Zombie: death (bypass throttle, force health=0)
local function onZombieDead(zomb)
    if not zomb then return end
    sendZombieImmediate(zomb, 0)
    -- Clean up tracking
    local id = zomb:getOnlineID()
    if id then
        trackedZombies[id] = nil
        zombieHealthCache[id] = nil
        zombieCrawlCache[id] = nil
        lastImmediateZombie[id] = nil
    end
end

-- Zombie: health or crawl state change
local function onZombieUpdate(zomb)
    if not zomb then return end
    local id = zomb:getOnlineID()
    if not id then return end

    local currentHealth = zomb:getHealth()
    local currentCrawling = zomb:isCrawling()
    local prevHealth = zombieHealthCache[id]
    local prevCrawling = zombieCrawlCache[id]

    zombieHealthCache[id] = currentHealth
    zombieCrawlCache[id] = currentCrawling

    -- Only trigger if something actually changed
    if (prevHealth and prevHealth ~= currentHealth) or (prevCrawling ~= nil and prevCrawling ~= currentCrawling) then
        sendZombieImmediate(zomb)
    end
end

-- Zombie: AI state change (idle->attack, etc.)
local function onAIStateChange(character)
    if not character then return end
    if instanceof(character, "IsoZombie") then
        sendZombieImmediate(character)
    end
end

------------------------------------------------------------
-- Register events
------------------------------------------------------------

Events.OnInitGlobalModData.Add(onInitGlobalModData)
Events.OnTick.Add(onTick)
Events.OnPlayerUpdate.Add(onPlayerUpdate)

if Events.OnPlayerDisconnect then
    Events.OnPlayerDisconnect.Add(onPlayerDisconnect)
end

if Events.OnHitZombie then
    Events.OnHitZombie.Add(onHitZombie)
end
if Events.OnZombieDead then
    Events.OnZombieDead.Add(onZombieDead)
end
if Events.OnZombieUpdate then
    Events.OnZombieUpdate.Add(onZombieUpdate)
end
if Events.OnAIStateChange then
    Events.OnAIStateChange.Add(onAIStateChange)
end
