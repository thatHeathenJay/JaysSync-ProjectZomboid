require "JaysSync/shared"

JaysSync.log("Client script loaded")

------------------------------------------------------------
-- Remote entity state tables
------------------------------------------------------------

local remotePlayers  = {}  -- [onlineID] = {x,y,z,vx,vy,dir,ms,hp,receivedTick,predX,predY,errorX,errorY}
local remoteZombies  = {}  -- [onlineID] = {x,y,z,vx,vy,dir,hp,cr,receivedTick,predX,predY,errorX,errorY}
local remoteVehicles = {}  -- [vehicleID] = {x,y,z,vx,vy,sp,ang,towId,towBy,receivedTick,predX,predY,errorX,errorY}
local clientTick = 0

-- Per-entity-type config (set in onInitGlobalModData from sandbox vars)
local playerConfig = {
    decay = JaysSync.PREDICT_DECAY,
    correctionBlend = JaysSync.CORRECTION_BLEND,
    interpSpeed = JaysSync.INTERP_SPEED,
    snapDist = JaysSync.SNAP_DISTANCE,
    staleTicks = JaysSync.STALE_TICKS,
}
local zombieConfig = {
    decay = JaysSync.ZOMBIE_PREDICT_DECAY,
    correctionBlend = JaysSync.CORRECTION_BLEND,
    interpSpeed = JaysSync.ZOMBIE_INTERP_SPEED,
    snapDist = JaysSync.ZOMBIE_SNAP_DISTANCE,
    staleTicks = JaysSync.ZOMBIE_STALE_TICKS,
}
local vehicleConfig = {
    decay = JaysSync.VEHICLE_PREDICT_DECAY,
    correctionBlend = JaysSync.CORRECTION_BLEND,
    interpSpeed = JaysSync.VEHICLE_INTERP_SPEED,
    snapDist = JaysSync.VEHICLE_SNAP_DISTANCE,
    staleTicks = JaysSync.VEHICLE_STALE_TICKS,
}

-- Client-side ID lookup caches (rebuilt per tick when needed)
local zombieById  = {}
local vehicleById = {}

------------------------------------------------------------
-- Snapshot field whitelists (only these fields are copied from network data)
------------------------------------------------------------

local playerFields  = { "id", "x", "y", "z", "vx", "vy", "dir", "ms", "hp" }
local zombieFields  = { "id", "x", "y", "z", "vx", "vy", "dir", "hp", "cr" }
local vehicleFields = { "id", "x", "y", "z", "vx", "vy", "sp", "ang", "towId", "towBy",
                        "eng", "hdl", "stp", "lbm", "lbs", "alm" }

------------------------------------------------------------
-- Generic dead reckoning functions
------------------------------------------------------------

-- Process a received snapshot into a remote state table (whitelist copy)
local function processSnapshot(remoteTable, id, data, snapDistSq, fields)
    if not JaysSync.isValidSnapshot(data) then
        JaysSync.warn("Dropped invalid snapshot for entity", id)
        return
    end

    local existing = remoteTable[id]
    if existing then
        local errorX = (existing.predX or existing.x) - data.x
        local errorY = (existing.predY or existing.y) - data.y
        local errorDistSq = errorX * errorX + errorY * errorY
        if errorDistSq > snapDistSq then
            errorX, errorY = 0, 0
        end
        for i = 1, #fields do existing[fields[i]] = data[fields[i]] end
        existing.receivedTick = clientTick
        existing.predX = data.x
        existing.predY = data.y
        existing.errorX = errorX
        existing.errorY = errorY
    else
        local entry = {}
        for i = 1, #fields do entry[fields[i]] = data[fields[i]] end
        entry.receivedTick = clientTick
        entry.predX = data.x
        entry.predY = data.y
        entry.errorX = 0
        entry.errorY = 0
        remoteTable[id] = entry
    end
end

-- Advance dead reckoning + error blending. Returns finalX, finalY, isStale.
local function advanceDeadReckoning(state, config, age)
    if age > config.staleTicks then
        return nil, nil, true
    end

    local vx = (state.vx or 0) * (config.decay ^ age)
    local vy = (state.vy or 0) * (config.decay ^ age)
    state.predX = state.x + vx * age
    state.predY = state.y + vy * age

    state.errorX = (state.errorX or 0) * (1 - config.correctionBlend)
    state.errorY = (state.errorY or 0) * (1 - config.correctionBlend)

    local fx = state.predX + state.errorX
    local fy = state.predY + state.errorY

    -- Bounds check the final predicted position
    if not JaysSync.isValidPos(fx) or not JaysSync.isValidPos(fy) then
        return state.x, state.y, false  -- fall back to last known good position
    end

    return fx, fy, false
end

-- Lerp an entity toward a target position. Returns true if teleported.
local function lerpPosition(obj, finalX, finalY, finalZ, config)
    local ok, cx, cy = pcall(function() return obj:getX(), obj:getY() end)
    if not ok then return false end

    local dx, dy = finalX - cx, finalY - cy
    local distSq = dx * dx + dy * dy
    local snapDistSq = config.snapDist * config.snapDist

    if distSq > snapDistSq then
        pcall(function()
            obj:setX(finalX)
            obj:setY(finalY)
            obj:setZ(finalZ)
        end)
        return true
    elseif distSq > 0.0001 then
        local t = config.interpSpeed
        pcall(function()
            obj:setX(cx + dx * t)
            obj:setY(cy + dy * t)
            obj:setZ(finalZ)
        end)
    end
    return false
end

------------------------------------------------------------
-- Entity-specific apply functions (all pcall-wrapped)
------------------------------------------------------------

local function applyMovementState(player, moveState)
    if player.setSneaking then
        pcall(function() player:setSneaking(moveState == JaysSync.STATE_CROUCH) end)
    end
end

local function applyToPlayer(player, state, finalX, finalY, config)
    lerpPosition(player, finalX, finalY, state.z, config)

    if state.dir then
        pcall(function()
            player:setDirectionAngle(JaysSync.lerpAngle(player:getDirectionAngle(), state.dir, config.interpSpeed))
        end)
    end

    applyMovementState(player, state.ms)

    local age = clientTick - state.receivedTick
    if state.hp and age < 10 then
        pcall(function()
            player:getBodyDamage():setOverallBodyHealth(state.hp)
        end)
    end
end

local function applyToZombie(zomb, state, finalX, finalY, config)
    lerpPosition(zomb, finalX, finalY, state.z, config)

    if state.dir then
        pcall(function()
            zomb:setDirectionAngle(JaysSync.lerpAngle(zomb:getDirectionAngle(), state.dir, config.interpSpeed))
        end)
    end

    -- Only set health if it actually changed
    if state.hp ~= nil then
        local okH, currentHp = pcall(function() return zomb:getHealth() end)
        if okH and currentHp ~= state.hp then
            pcall(function() zomb:setHealth(state.hp) end)
        end
    end

    if state.cr ~= nil then
        local okC, currentCr = pcall(function() return zomb:isCrawling() end)
        if okC and (currentCr ~= (state.cr == 1)) then
            pcall(function() zomb:setCrawling(state.cr == 1) end)
        end
    end

    if state.hp and state.hp <= 0 then
        pcall(function() zomb:setDead(true) end)
        return true  -- signal removal
    end
    return false
end

local function applyToVehicle(vehicle, state, finalX, finalY, config)
    lerpPosition(vehicle, finalX, finalY, state.z, config)

    if state.ang then
        pcall(function()
            local current = vehicle:getAngleZ()
            vehicle:setAngleZ(JaysSync.lerpAngleRad(current, state.ang, config.interpSpeed))
        end)
    end

    -- Vehicle visual/audio state (only set when changed)
    pcall(function()
        if state.hdl ~= nil then
            local on = state.hdl == 1
            if vehicle:getHeadlightsOn() ~= on then vehicle:setHeadlightsOn(on) end
        end
        if state.stp ~= nil then
            local on = state.stp == 1
            if vehicle:getStoplightsOn() ~= on then vehicle:setStoplightsOn(on) end
        end
        if state.lbm ~= nil and vehicle.hasLightbar and vehicle:hasLightbar() then
            if vehicle:getLightbarLightsMode() ~= state.lbm then vehicle:setLightbarLightsMode(state.lbm) end
        end
        if state.lbs ~= nil and vehicle.hasLightbar and vehicle:hasLightbar() then
            if vehicle:getLightbarSirenMode() ~= state.lbs then vehicle:setLightbarSirenMode(state.lbs) end
        end
        if state.alm ~= nil then
            local armed = state.alm == 1
            if vehicle:isAlarmed() ~= armed then vehicle:setAlarmed(armed) end
        end
    end)
end

------------------------------------------------------------
-- Driver/passenger exclusion helper
------------------------------------------------------------

local function getLocalVehicleID()
    local localPlayer = getPlayer()
    if not localPlayer then return nil end
    local ok, vehicle = pcall(function() return localPlayer:getVehicle() end)
    if ok and vehicle then
        local okId, vid = pcall(function() return vehicle:getID() end)
        if okId then return vid end
    end
    return nil
end

------------------------------------------------------------
-- Lookup cache rebuild (once per tick, only when needed)
------------------------------------------------------------

local function rebuildLookupCaches()
    zombieById = {}
    vehicleById = {}
    local ok, cell = pcall(getCell)
    if not ok or not cell then return end

    local okZl, zl = pcall(function() return cell:getZombieList() end)
    if okZl and zl then
        for i = 0, zl:size() - 1 do
            local z = zl:get(i)
            if z then
                local okId, zid = pcall(function() return z:getOnlineID() end)
                if okId and zid then zombieById[zid] = z end
            end
        end
    end

    local okVl, vl = pcall(function() return cell:getVehicles() end)
    if okVl and vl then
        for i = 0, vl:size() - 1 do
            local v = vl:get(i)
            if v then
                local okId, vid = pcall(function() return v:getID() end)
                if okId and vid then vehicleById[vid] = v end
            end
        end
    end
end

------------------------------------------------------------
-- Per-tick client update
------------------------------------------------------------

local function onClientTick()
    clientTick = clientTick + 1

    local localPlayer = getPlayer()
    if not localPlayer then return end
    local okId, localID = pcall(function() return localPlayer:getOnlineID() end)
    if not okId then return end

    -- Rebuild lookup caches only when we have remote zombies or vehicles
    local hasZombies = next(remoteZombies) ~= nil
    local hasVehicles = next(remoteVehicles) ~= nil
    if hasZombies or hasVehicles then
        rebuildLookupCaches()
    end

    -- Get local player's vehicle ID for driver exclusion
    local localVehicleID = hasVehicles and getLocalVehicleID() or nil

    -- Players
    local toRemove = {}
    for id, state in pairs(remotePlayers) do
        if id == localID then
            toRemove[#toRemove + 1] = id
        else
            local okP, player = pcall(getPlayerByOnlineID, id)
            if not okP or not player then
                toRemove[#toRemove + 1] = id
            else
                local age = clientTick - state.receivedTick
                local fx, fy, stale = advanceDeadReckoning(state, playerConfig, age)
                if stale then
                    toRemove[#toRemove + 1] = id
                else
                    JaysSync.safeCall("applyToPlayer", applyToPlayer, player, state, fx, fy, playerConfig)
                end
            end
        end
    end
    for i = 1, #toRemove do remotePlayers[toRemove[i]] = nil end

    -- Zombies
    if hasZombies then
        toRemove = {}
        for id, state in pairs(remoteZombies) do
            local age = clientTick - state.receivedTick
            local fx, fy, stale = advanceDeadReckoning(state, zombieConfig, age)
            if stale then
                toRemove[#toRemove + 1] = id
            else
                local zomb = zombieById[id]
                if not zomb then
                    toRemove[#toRemove + 1] = id
                else
                    local okDead, isDead = pcall(function() return zomb:isDead() end)
                    if okDead and isDead then
                        toRemove[#toRemove + 1] = id
                    else
                        local okApply, dead = JaysSync.safeCall("applyToZombie", applyToZombie, zomb, state, fx, fy, zombieConfig)
                        if okApply and dead then toRemove[#toRemove + 1] = id end
                    end
                end
            end
        end
        for i = 1, #toRemove do remoteZombies[toRemove[i]] = nil end
    end

    -- Vehicles (skip vehicle we're driving)
    if hasVehicles then
        toRemove = {}
        for id, state in pairs(remoteVehicles) do
            -- Driver exclusion: don't fight our own vehicle input
            if id == localVehicleID then
                toRemove[#toRemove + 1] = id
            else
                local age = clientTick - state.receivedTick
                local fx, fy, stale = advanceDeadReckoning(state, vehicleConfig, age)
                if stale then
                    toRemove[#toRemove + 1] = id
                else
                    local vehicle = vehicleById[id]
                    if not vehicle then
                        toRemove[#toRemove + 1] = id
                    else
                        JaysSync.safeCall("applyToVehicle", applyToVehicle, vehicle, state, fx, fy, vehicleConfig)
                    end
                end
            end
        end
        for i = 1, #toRemove do remoteVehicles[toRemove[i]] = nil end
    end
end

------------------------------------------------------------
-- Network receive
------------------------------------------------------------

local function onServerCommand(module, command, args)
    if module ~= JaysSync.MOD_ID then return end
    if not args or type(args) ~= "table" then return end

    local localPlayer = getPlayer()
    local localID = localPlayer and localPlayer:getOnlineID()

    if command == JaysSync.CMD_PLAYER_STATES or command == JaysSync.CMD_PLAYER_IMMEDIATE then
        local snapDistSq = playerConfig.snapDist * playerConfig.snapDist
        for _, data in ipairs(args) do
            if data and data.id and data.id ~= localID then
                processSnapshot(remotePlayers, data.id, data, snapDistSq, playerFields)
            end
        end
        JaysSync.log("Received", command, "#", #args)

    elseif (command == JaysSync.CMD_ZOMBIE_STATES or command == JaysSync.CMD_ZOMBIE_IMMEDIATE)
           and JaysSync.ZOMBIE_SYNC_ENABLED then
        local snapDistSq = zombieConfig.snapDist * zombieConfig.snapDist
        for _, data in ipairs(args) do
            if data and data.id then
                processSnapshot(remoteZombies, data.id, data, snapDistSq, zombieFields)
            end
        end
        JaysSync.log("Received", command, "#", #args)

    elseif (command == JaysSync.CMD_VEHICLE_STATES or command == JaysSync.CMD_VEHICLE_IMMEDIATE)
           and JaysSync.VEHICLE_SYNC_ENABLED then
        local snapDistSq = vehicleConfig.snapDist * vehicleConfig.snapDist
        for _, data in ipairs(args) do
            if data and data.id then
                processSnapshot(remoteVehicles, data.id, data, snapDistSq, vehicleFields)
            end
        end
        JaysSync.log("Received", command, "#", #args)
    end
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------

local function onInitGlobalModData()
    if SandboxVars.JaysSync then
        local sv = SandboxVars.JaysSync
        if sv.InterpSpeed then JaysSync.INTERP_SPEED = sv.InterpSpeed end
        if sv.SnapDistance then JaysSync.SNAP_DISTANCE = sv.SnapDistance end
        if sv.ZombieInterpSpeed then JaysSync.ZOMBIE_INTERP_SPEED = sv.ZombieInterpSpeed end
        if sv.ZombieSnapDistance then JaysSync.ZOMBIE_SNAP_DISTANCE = sv.ZombieSnapDistance end
        if sv.VehicleInterpSpeed then JaysSync.VEHICLE_INTERP_SPEED = sv.VehicleInterpSpeed end
        if sv.VehicleSnapDistance then JaysSync.VEHICLE_SNAP_DISTANCE = sv.VehicleSnapDistance end
        if sv.ZombieSyncEnabled ~= nil then JaysSync.ZOMBIE_SYNC_ENABLED = sv.ZombieSyncEnabled == 1 end
        if sv.VehicleSyncEnabled ~= nil then JaysSync.VEHICLE_SYNC_ENABLED = sv.VehicleSyncEnabled == 1 end
        if sv.VehicleStateSyncEnabled ~= nil then JaysSync.VEHICLE_STATE_SYNC_ENABLED = sv.VehicleStateSyncEnabled == 1 end
        if sv.DebugLogs then JaysSync.DEBUG = sv.DebugLogs == 1 end
    end

    -- Rebuild config tables from (possibly updated) constants
    playerConfig.interpSpeed = JaysSync.INTERP_SPEED
    playerConfig.snapDist = JaysSync.SNAP_DISTANCE
    playerConfig.decay = JaysSync.PREDICT_DECAY
    playerConfig.staleTicks = JaysSync.STALE_TICKS
    playerConfig.correctionBlend = JaysSync.CORRECTION_BLEND

    zombieConfig.interpSpeed = JaysSync.ZOMBIE_INTERP_SPEED
    zombieConfig.snapDist = JaysSync.ZOMBIE_SNAP_DISTANCE
    zombieConfig.decay = JaysSync.ZOMBIE_PREDICT_DECAY
    zombieConfig.staleTicks = JaysSync.ZOMBIE_STALE_TICKS
    zombieConfig.correctionBlend = JaysSync.CORRECTION_BLEND

    vehicleConfig.interpSpeed = JaysSync.VEHICLE_INTERP_SPEED
    vehicleConfig.snapDist = JaysSync.VEHICLE_SNAP_DISTANCE
    vehicleConfig.decay = JaysSync.VEHICLE_PREDICT_DECAY
    vehicleConfig.staleTicks = JaysSync.VEHICLE_STALE_TICKS
    vehicleConfig.correctionBlend = JaysSync.CORRECTION_BLEND

    remotePlayers = {}
    remoteZombies = {}
    remoteVehicles = {}
    clientTick = 0
end

Events.OnInitGlobalModData.Add(onInitGlobalModData)
Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onClientTick)
