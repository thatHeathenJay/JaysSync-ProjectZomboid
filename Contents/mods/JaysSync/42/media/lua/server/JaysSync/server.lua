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
local lastThreatSync = {}       -- [onlineID] = jsTick of last threat proximity sync

-- Vehicle tracking
local trackedVehicles = {}      -- [vehicleID] = {x,y,z,speed,angle,towedId,towedBy,jsTick}
local lastImmediateVehicle = {} -- [vehicleID] = jsTick

-- Shared
local jsTick = 0
local playerPosCache = {}       -- [{x,y}] pre-computed once per broadcast cycle

------------------------------------------------------------
-- Safe send wrapper
-- Note: 'zombie' here is the PZ Java namespace (zombie.network.GameServer),
-- NOT a zombie entity. Stored as upvalue to avoid confusion with function params.
------------------------------------------------------------

local _pzNetwork = zombie and zombie.network

local function safeSend(cmd, data)
    if _pzNetwork and _pzNetwork.GameServer
       and _pzNetwork.GameServer.udpEngine then
        sendServerCommand(JaysSync.MOD_ID, cmd, data)
    end
end

-- Send a batch in chunks to stay under UDP packet limits.
local function safeSendChunked(cmd, batch)
    local batchSize = JaysSync.BATCH_SIZE
    if #batch <= batchSize then
        safeSend(cmd, batch)
        return
    end
    for i = 1, #batch, batchSize do
        local chunk = {}
        for j = i, math.min(i + batchSize - 1, #batch) do
            chunk[#chunk + 1] = batch[j]
        end
        safeSend(cmd, chunk)
    end
end

------------------------------------------------------------
-- Player position cache (computed once, used by zombie + vehicle)
------------------------------------------------------------

local function refreshPlayerPositions()
    playerPosCache = {}
    local ok, players = JaysSync.safeCall("refreshPlayerPositions", getOnlinePlayers)
    if not ok or not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        if p then
            local px, py = p:getX(), p:getY()
            if JaysSync.isValidPos(px) and JaysSync.isValidPos(py) then
                playerPosCache[#playerPosCache + 1] = { x = px, y = py }
            end
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
-- Player sync
------------------------------------------------------------

local function getMoveState(player)
    if player.isSneaking and player:isSneaking() then return JaysSync.STATE_CROUCH end
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

    if not JaysSync.isValidPos(x) or not JaysSync.isValidPos(y) then
        JaysSync.warn("Invalid player position for", id, "x:", x, "y:", y)
        return nil, nil
    end

    local okDir, dir = pcall(function() return player:getDirectionAngle() end)
    if not okDir or not JaysSync.isFinite(dir) then dir = 0 end
    local moveState = getMoveState(player)

    local ok, bodyDamage = pcall(function() return player:getBodyDamage() end)
    local health = 100
    if ok and bodyDamage then
        health = bodyDamage:getOverallBodyHealth()
    end

    local vx, vy = 0, 0
    if prev and dt > 0 then
        vx = (x - prev.x) / dt
        vy = (y - prev.y) / dt
        local maxV = JaysSync.MAX_VELOCITY
        if vx > maxV then vx = maxV elseif vx < -maxV then vx = -maxV end
        if vy > maxV then vy = maxV elseif vy < -maxV then vy = -maxV end
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
            local okId, pid = pcall(function() return player:getOnlineID() end)
            if okId and pid then
                local prev = trackedPlayers[pid]
                local dt = prev and (jsTick - prev.jsTick) or 0
                local ok, snapshot, newTracked = JaysSync.safeCall("buildPlayerSnapshot",
                    buildPlayerSnapshot, player, prev, dt)
                if ok and snapshot then
                    trackedPlayers[pid] = newTracked
                    batch[#batch + 1] = snapshot
                end
            end
        end
    end

    if #batch > 0 then
        safeSendChunked(JaysSync.CMD_PLAYER_STATES, batch)
        JaysSync.log("Broadcast", #batch, "players")
    end
end

local function sendPlayerImmediate(player)
    local id = player:getOnlineID()
    if JaysSync.throttle(lastImmediatePlayer, id, jsTick, JaysSync.IMMEDIATE_COOLDOWN) then return end

    local prev = trackedPlayers[id]
    local dt = prev and (jsTick - prev.jsTick) or 0
    local snapshot, newTracked = buildPlayerSnapshot(player, prev, dt)
    if not snapshot then return end
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
    local okId, id = pcall(function() return zomb:getOnlineID() end)
    if not okId or not id then return nil end

    local okPos, x, y, z = pcall(function() return zomb:getX(), zomb:getY(), zomb:getZ() end)
    if not okPos then return nil end

    if not JaysSync.isValidPos(x) or not JaysSync.isValidPos(y) then
        JaysSync.warn("buildZombieSnapshot", "Invalid position for", id, "x:", x, "y:", y)
        return nil
    end

    local dir = 0
    if zomb.getDirectionAngle then
        local okDir, d = pcall(function() return zomb:getDirectionAngle() end)
        if okDir and JaysSync.isFinite(d) then dir = d end
    end

    local okH, health = pcall(function() return zomb:getHealth() end)
    if not okH then health = 1 end

    local okC, crawling = pcall(function() return zomb:isCrawling() end)
    if not okC then crawling = false end

    local vx, vy = 0, 0
    if prev and dt > 0 then
        vx = (x - prev.x) / dt
        vy = (y - prev.y) / dt
        local maxV = JaysSync.MAX_VELOCITY
        if vx > maxV then vx = maxV elseif vx < -maxV then vx = -maxV end
        if vy > maxV then vy = maxV elseif vy < -maxV then vy = -maxV end
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
    local ok, zombieList = JaysSync.safeCall("getZombieList", function() return cell:getZombieList() end)
    if not ok or not zombieList then return end

    local syncDistSq = JaysSync.ZOMBIE_SYNC_DISTANCE * JaysSync.ZOMBIE_SYNC_DISTANCE
    if #playerPosCache == 0 then return end

    -- Single pass: update trackedZombies from current zombieList
    -- Each zombie is individually pcall-wrapped so one failure doesn't kill the broadcast
    local seen = {}
    for i = 0, zombieList:size() - 1 do
        local zomb = zombieList:get(i)
        if zomb then
            pcall(function()
                local zHealth = zomb:getHealth()
                if not zHealth or zHealth <= 0 then return end
                local id = zomb:getOnlineID()
                if not id then return end
                local zx, zy = zomb:getX(), zomb:getY()
                if not JaysSync.isValidPos(zx) or not JaysSync.isValidPos(zy) then return end
                local dSq = nearestPlayerDistSq(zx, zy)
                if dSq > syncDistSq then return end

                seen[id] = true
                local prev = trackedZombies[id]
                local dt = prev and (jsTick - prev.jsTick) or 0

                local dir = 0
                if zomb.getDirectionAngle then
                    local d = zomb:getDirectionAngle()
                    if JaysSync.isFinite(d) then dir = d end
                end

                local crawling = false
                if zomb.isCrawling then crawling = zomb:isCrawling() end

                trackedZombies[id] = {
                    x = zx, y = zy, z = zomb:getZ(),
                    dir = dir,
                    health = zHealth,
                    crawling = crawling,
                    distSq = dSq,
                    jsTick = jsTick,
                    sentImmediate = prev and prev.sentImmediate or 0,
                    _prevX = prev and prev.x, _prevY = prev and prev.y, _dt = dt
                }
            end)
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
        safeSendChunked(JaysSync.CMD_ZOMBIE_STATES, batch)
        JaysSync.log("Broadcast", #batch, "zombies")
    end
end

local function sendZombieImmediate(zomb, forceHealth)
    if not zomb then return end
    local ok, id = pcall(function() return zomb:getOnlineID() end)
    if not ok or not id then return end

    -- OnZombieDead bypasses throttle via forceHealth
    if not forceHealth and JaysSync.throttle(lastImmediateZombie, id, jsTick, JaysSync.ZOMBIE_IMMEDIATE_COOLDOWN) then
        return
    end

    local prev = trackedZombies[id]
    local dt = prev and (jsTick - prev.jsTick) or 0
    local snapshot = buildZombieSnapshot(zomb, prev, dt)
    if not snapshot then return end
    if forceHealth then snapshot.hp = forceHealth end

    -- Mark as sent immediate this tick for dedup
    if trackedZombies[id] then
        trackedZombies[id].sentImmediate = jsTick
    end

    safeSend(JaysSync.CMD_ZOMBIE_IMMEDIATE, { snapshot })
    JaysSync.log("Immediate sync zombie", id)
end

------------------------------------------------------------
-- Zombie threat proximity sync
-- Immediately syncs any zombie within melee range of a player
------------------------------------------------------------

local function checkZombieThreatProximity()
    if #playerPosCache == 0 then return end
    local threatDistSq = JaysSync.ZOMBIE_THREAT_DISTANCE_SQ
    local cooldown = JaysSync.ZOMBIE_THREAT_COOLDOWN
    local cell = getCell()
    if not cell then return end

    local ok, zombieList = pcall(function() return cell:getZombieList() end)
    if not ok or not zombieList then return end

    local maxPerTick = JaysSync.ZOMBIE_THREAT_MAX_PER_TICK
    local batch = {}
    for i = 0, zombieList:size() - 1 do
        if #batch >= maxPerTick then break end
        local zomb = zombieList:get(i)
        if zomb then
            pcall(function()
                local id = zomb:getOnlineID()
                if not id then return end
                local last = lastThreatSync[id]
                if last and (jsTick - last) < cooldown then return end
                local zx, zy = zomb:getX(), zomb:getY()
                if not JaysSync.isValidPos(zx) or not JaysSync.isValidPos(zy) then return end
                local dSq = nearestPlayerDistSq(zx, zy)
                if dSq > threatDistSq then return end

                lastThreatSync[id] = jsTick
                local prev = trackedZombies[id]
                local dt = prev and (jsTick - prev.jsTick) or 0
                local snapshot = buildZombieSnapshot(zomb, prev, dt)
                if snapshot then
                    batch[#batch + 1] = snapshot
                    if trackedZombies[id] then
                        trackedZombies[id].sentImmediate = jsTick
                    end
                end
            end)
        end
    end

    if #batch > 0 then
        safeSendChunked(JaysSync.CMD_ZOMBIE_IMMEDIATE, batch)
        JaysSync.log("Threat proximity sync", #batch, "zombies")
    end
end

------------------------------------------------------------
-- Vehicle sync
------------------------------------------------------------

local function buildVehicleSnapshot(vehicle, prev, dt)
    local ok, id = pcall(function() return vehicle:getID() end)
    if not ok or not id then return nil end

    local x, y, z = vehicle:getX(), vehicle:getY(), vehicle:getZ()

    if not JaysSync.isValidPos(x) or not JaysSync.isValidPos(y) then
        JaysSync.warn("Invalid vehicle position for", id, "x:", x, "y:", y)
        return nil
    end

    local okSpeed, speed = pcall(function() return vehicle:getCurrentSpeedKmHour() end)
    if not okSpeed then speed = 0 end

    local okAngle, angle = pcall(function() return vehicle:getAngleZ() end)
    if not okAngle then angle = nil end

    local towedId = nil
    if vehicle.getTowedVehicle then
        local okTow, towed = pcall(function() return vehicle:getTowedVehicle() end)
        if okTow and towed and towed.getID then towedId = towed:getID() end
    end

    local towedBy = nil
    if vehicle.getTowedBy then
        local okTow, tower = pcall(function() return vehicle:getTowedBy() end)
        if okTow and tower and tower.getID then towedBy = tower:getID() end
    end

    local vx, vy = 0, 0
    if prev and dt > 0 then
        vx = (x - prev.x) / dt
        vy = (y - prev.y) / dt
        local maxV = JaysSync.MAX_VELOCITY
        if vx > maxV then vx = maxV elseif vx < -maxV then vx = -maxV end
        if vy > maxV then vy = maxV elseif vy < -maxV then vy = -maxV end
    end

    -- Validate angle
    if angle and not JaysSync.isFinite(angle) then angle = nil end

    local snapshot = {
        id = id, x = x, y = y, z = z,
        vx = vx, vy = vy, sp = speed,
        ang = angle, towId = towedId, towBy = towedBy,
    }

    -- Vehicle visual/audio state (only when enabled)
    if JaysSync.VEHICLE_STATE_SYNC_ENABLED then
        local okEng, eng = pcall(function() return vehicle:isEngineRunning() end)
        local okHdl, hdl = pcall(function() return vehicle:getHeadlightsOn() end)
        local okStp, stp = pcall(function() return vehicle:getStoplightsOn() end)
        local okLbm, lbm = pcall(function() return vehicle:getLightbarLightsMode() end)
        local okLbs, lbs = pcall(function() return vehicle:getLightbarSirenMode() end)
        local okAlm, alm = pcall(function() return vehicle:isAlarmed() end)
        snapshot.eng = (okEng and eng) and 1 or 0
        snapshot.hdl = (okHdl and hdl) and 1 or 0
        snapshot.stp = (okStp and stp) and 1 or 0
        snapshot.lbm = okLbm and lbm or 0
        snapshot.lbs = okLbs and lbs or 0
        snapshot.alm = (okAlm and alm) and 1 or 0
    end
    return snapshot
end

local function broadcastVehicles()
    local cell = getCell()
    if not cell then return end
    local okVl, vehicleList = JaysSync.safeCall("getVehicles", function() return cell:getVehicles() end)
    if not okVl or not vehicleList then return end
    if #playerPosCache == 0 then return end

    local syncDistSq = JaysSync.VEHICLE_SYNC_DISTANCE * JaysSync.VEHICLE_SYNC_DISTANCE
    local included = {}  -- [vehicleID] = true
    local batch = {}

    -- Build vehicle map in single pass
    local vehiclesById = {}
    for i = 0, vehicleList:size() - 1 do
        local v = vehicleList:get(i)
        if v then
            local okId, vid = pcall(function() return v:getID() end)
            if okId and vid then vehiclesById[vid] = v end
        end
    end

    local function includeVehicle(vehicle, force)
        if not vehicle then return end
        local okId, vid = pcall(function() return vehicle:getID() end)
        if not okId or not vid then return end
        if included[vid] then return end

        local vx, vy = vehicle:getX(), vehicle:getY()
        if not JaysSync.isValidPos(vx) or not JaysSync.isValidPos(vy) then return end

        if not force then
            local dSq = nearestPlayerDistSq(vx, vy)
            if dSq > syncDistSq then return end
        end

        included[vid] = true
        local prev = trackedVehicles[vid]
        local dt = prev and (jsTick - prev.jsTick) or 0
        local snapshot = buildVehicleSnapshot(vehicle, prev, dt)
        if not snapshot then return end
        batch[#batch + 1] = snapshot

        trackedVehicles[vid] = {
            x = vx, y = vy, z = vehicle:getZ(),
            speed = snapshot.sp,
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
        safeSendChunked(JaysSync.CMD_VEHICLE_STATES, batch)
        JaysSync.log("Broadcast", #batch, "vehicles")
    end
end

------------------------------------------------------------
-- Stale cache purge
------------------------------------------------------------

local function purgeAllCaches()
    JaysSync.purgeStaleThrottles(lastImmediatePlayer, jsTick, 600)
    JaysSync.purgeStaleThrottles(lastImmediateZombie, jsTick, 600)
    JaysSync.purgeStaleThrottles(lastThreatSync, jsTick, 600)
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
-- Event hooks (all wrapped in pcall to never crash the server)
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
        if sv.ZombieSyncEnabled ~= nil then
            JaysSync.ZOMBIE_SYNC_ENABLED = sv.ZombieSyncEnabled
        end
        if sv.VehicleSyncEnabled ~= nil then
            JaysSync.VEHICLE_SYNC_ENABLED = sv.VehicleSyncEnabled
        end
        if sv.VehicleStateSyncEnabled ~= nil then
            JaysSync.VEHICLE_STATE_SYNC_ENABLED = sv.VehicleStateSyncEnabled
        end
        if sv.DebugLogs ~= nil then
            JaysSync.DEBUG = sv.DebugLogs
        end
    end

    trackedPlayers = {}
    lastImmediatePlayer = {}
    trackedZombies = {}
    lastImmediateZombie = {}
    zombieHealthCache = {}
    zombieCrawlCache = {}
    lastThreatSync = {}
    trackedVehicles = {}
    lastImmediateVehicle = {}
    playerPosCache = {}

    -- Re-resolve PZ network reference in case it wasn't available at load time
    _pzNetwork = zombie and zombie.network

    JaysSync.log("Server initialized")
end

local function onTick()
    jsTick = jsTick + 1
    JaysSync._globalTick = jsTick

    local zombieEnabled = JaysSync.ZOMBIE_SYNC_ENABLED
    local vehicleEnabled = JaysSync.VEHICLE_SYNC_ENABLED

    -- Only refresh player positions when something needs them this tick
    local isPlayerBroadcast = (jsTick % JaysSync.BROADCAST_INTERVAL == 0)
    local isZombieBroadcast = zombieEnabled and (jsTick % JaysSync.ZOMBIE_BROADCAST_INTERVAL == 0)
    local isVehicleBroadcast = vehicleEnabled and (jsTick % JaysSync.VEHICLE_BROADCAST_INTERVAL == 0)
    local isBroadcastTick = isPlayerBroadcast or isZombieBroadcast or isVehicleBroadcast
    local needsPlayerPos = isBroadcastTick or zombieEnabled

    if needsPlayerPos then
        refreshPlayerPositions()
    end

    -- Threat proximity: sync zombies within melee range (skip on broadcast ticks to avoid packet burst)
    if zombieEnabled and not isBroadcastTick then
        JaysSync.safeCall("threatProximity", checkZombieThreatProximity)
    end

    if isPlayerBroadcast then
        JaysSync.safeCall("broadcastPlayers", broadcastAllPlayers)
    end
    if isZombieBroadcast then
        JaysSync.safeCall("broadcastZombies", broadcastZombies)
    end
    if isVehicleBroadcast then
        JaysSync.safeCall("broadcastVehicles", broadcastVehicles)
    end

    -- Periodic stale purge
    if jsTick % 600 == 0 then
        purgeAllCaches()
    end
end

local function onPlayerUpdate(player)
    if not player then return end
    JaysSync.safeCall("onPlayerUpdate", function()
        if checkPlayerStateChange(player) then
            sendPlayerImmediate(player)
        end
    end)
end

local function onPlayerDisconnect(player)
    if not player then return end
    local ok, id = pcall(function() return player:getOnlineID() end)
    if ok and id then
        trackedPlayers[id] = nil
        lastImmediatePlayer[id] = nil
        JaysSync.log("Cleaned up player", id)
    end
end

-- Zombie: combat hit
local function onHitZombie(zomb)
    if not JaysSync.ZOMBIE_SYNC_ENABLED then return end
    JaysSync.safeCall("onHitZombie", sendZombieImmediate, zomb)
end

-- Zombie: death (bypass throttle, force health=0)
local function onZombieDead(zomb)
    if not JaysSync.ZOMBIE_SYNC_ENABLED then return end
    if not zomb then return end
    JaysSync.safeCall("onZombieDead", function()
        sendZombieImmediate(zomb, 0)
        local ok, id = pcall(function() return zomb:getOnlineID() end)
        if ok and id then
            trackedZombies[id] = nil
            zombieHealthCache[id] = nil
            zombieCrawlCache[id] = nil
            lastImmediateZombie[id] = nil
        end
    end)
end

-- Zombie: health or crawl state change
local function onZombieUpdate(zomb)
    if not JaysSync.ZOMBIE_SYNC_ENABLED then return end
    if not zomb then return end
    JaysSync.safeCall("onZombieUpdate", function()
        local ok, id = pcall(function() return zomb:getOnlineID() end)
        if not ok or not id then return end

        local okH, currentHealth = pcall(function() return zomb:getHealth() end)
        local okC, currentCrawling = pcall(function() return zomb:isCrawling() end)
        if not okH or not okC then return end

        local prevHealth = zombieHealthCache[id]
        local prevCrawling = zombieCrawlCache[id]

        zombieHealthCache[id] = currentHealth
        zombieCrawlCache[id] = currentCrawling

        if (prevHealth and prevHealth ~= currentHealth) or (prevCrawling ~= nil and prevCrawling ~= currentCrawling) then
            sendZombieImmediate(zomb)
        end
    end)
end

-- Zombie: AI state change (idle->attack, etc.)
local function onAIStateChange(character)
    if not JaysSync.ZOMBIE_SYNC_ENABLED then return end
    if not character then return end
    JaysSync.safeCall("onAIStateChange", function()
        if instanceof(character, "IsoZombie") then
            sendZombieImmediate(character)
        end
    end)
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
