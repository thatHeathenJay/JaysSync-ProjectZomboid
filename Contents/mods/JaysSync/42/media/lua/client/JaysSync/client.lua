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
-- Generic dead reckoning functions
------------------------------------------------------------

-- Process a received snapshot into a remote state table
local function processSnapshot(remoteTable, id, data, snapDistSq)
    local existing = remoteTable[id]
    if existing then
        local errorX = (existing.predX or existing.x) - data.x
        local errorY = (existing.predY or existing.y) - data.y
        local errorDistSq = errorX * errorX + errorY * errorY
        if errorDistSq > snapDistSq then
            errorX, errorY = 0, 0
        end
        for k, v in pairs(data) do existing[k] = v end
        existing.receivedTick = clientTick
        existing.predX = data.x
        existing.predY = data.y
        existing.errorX = errorX
        existing.errorY = errorY
    else
        local entry = {}
        for k, v in pairs(data) do entry[k] = v end
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

    return state.predX + state.errorX, state.predY + state.errorY, false
end

-- Lerp an entity toward a target position. Returns true if teleported.
local function lerpPosition(obj, finalX, finalY, finalZ, config)
    local cx, cy = obj:getX(), obj:getY()
    local dx, dy = finalX - cx, finalY - cy
    local distSq = dx * dx + dy * dy
    local snapDistSq = config.snapDist * config.snapDist

    if distSq > snapDistSq then
        obj:setX(finalX)
        obj:setY(finalY)
        obj:setZ(finalZ)
        return true
    elseif distSq > 0.0001 then
        local t = config.interpSpeed
        obj:setX(cx + dx * t)
        obj:setY(cy + dy * t)
        obj:setZ(finalZ)
    end
    return false
end

------------------------------------------------------------
-- Entity-specific apply functions
------------------------------------------------------------

local function applyMovementState(player, moveState)
    if player.setSneaking then
        player:setSneaking(moveState == JaysSync.STATE_CROUCH)
    end
end

local function applyToPlayer(player, state, finalX, finalY, config)
    lerpPosition(player, finalX, finalY, state.z, config)

    if state.dir then
        player:setDirectionAngle(JaysSync.lerpAngle(player:getDirectionAngle(), state.dir, config.interpSpeed))
    end

    applyMovementState(player, state.ms)

    local age = clientTick - state.receivedTick
    if state.hp and age < 10 then
        player:getBodyDamage():setOverallBodyHealth(state.hp)
    end
end

local function applyToZombie(zomb, state, finalX, finalY, config)
    lerpPosition(zomb, finalX, finalY, state.z, config)

    if state.dir then
        zomb:setDirectionAngle(JaysSync.lerpAngle(zomb:getDirectionAngle(), state.dir, config.interpSpeed))
    end

    if state.hp ~= nil then
        zomb:setHealth(state.hp)
    end

    if state.cr ~= nil then
        zomb:setCrawling(state.cr == 1)
    end

    if state.hp and state.hp <= 0 then
        zomb:setDead(true)
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
end

------------------------------------------------------------
-- Lookup cache rebuild (once per tick, only when needed)
------------------------------------------------------------

local function rebuildLookupCaches()
    zombieById = {}
    vehicleById = {}
    local cell = getCell()
    if not cell then return end

    local zl = cell:getZombieList()
    if zl then
        for i = 0, zl:size() - 1 do
            local z = zl:get(i)
            if z then zombieById[z:getOnlineID()] = z end
        end
    end

    local vl = cell:getVehicles()
    if vl then
        for i = 0, vl:size() - 1 do
            local v = vl:get(i)
            if v then vehicleById[v:getID()] = v end
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
    local localID = localPlayer:getOnlineID()

    -- Rebuild lookup caches only when we have remote zombies or vehicles
    local hasZombies = next(remoteZombies) ~= nil
    local hasVehicles = next(remoteVehicles) ~= nil
    if hasZombies or hasVehicles then
        rebuildLookupCaches()
    end

    -- Players
    local toRemove = {}
    for id, state in pairs(remotePlayers) do
        if id == localID then
            toRemove[#toRemove + 1] = id
        else
            local player = getPlayerByOnlineID(id)
            if not player then
                toRemove[#toRemove + 1] = id
            else
                local age = clientTick - state.receivedTick
                local fx, fy, stale = advanceDeadReckoning(state, playerConfig, age)
                if stale then
                    toRemove[#toRemove + 1] = id
                else
                    applyToPlayer(player, state, fx, fy, playerConfig)
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
                if not zomb or zomb:isDead() then
                    toRemove[#toRemove + 1] = id
                else
                    local dead = applyToZombie(zomb, state, fx, fy, zombieConfig)
                    if dead then toRemove[#toRemove + 1] = id end
                end
            end
        end
        for i = 1, #toRemove do remoteZombies[toRemove[i]] = nil end
    end

    -- Vehicles
    if hasVehicles then
        toRemove = {}
        for id, state in pairs(remoteVehicles) do
            local age = clientTick - state.receivedTick
            local fx, fy, stale = advanceDeadReckoning(state, vehicleConfig, age)
            if stale then
                toRemove[#toRemove + 1] = id
            else
                local vehicle = vehicleById[id]
                if not vehicle then
                    toRemove[#toRemove + 1] = id
                else
                    applyToVehicle(vehicle, state, fx, fy, vehicleConfig)
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
            if data.id ~= localID then
                processSnapshot(remotePlayers, data.id, data, snapDistSq)
            end
        end
        JaysSync.log("Received", command, "#", #args)

    elseif command == JaysSync.CMD_ZOMBIE_STATES or command == JaysSync.CMD_ZOMBIE_IMMEDIATE then
        local snapDistSq = zombieConfig.snapDist * zombieConfig.snapDist
        for _, data in ipairs(args) do
            processSnapshot(remoteZombies, data.id, data, snapDistSq)
        end
        JaysSync.log("Received", command, "#", #args)

    elseif command == JaysSync.CMD_VEHICLE_STATES or command == JaysSync.CMD_VEHICLE_IMMEDIATE then
        local snapDistSq = vehicleConfig.snapDist * vehicleConfig.snapDist
        for _, data in ipairs(args) do
            processSnapshot(remoteVehicles, data.id, data, snapDistSq)
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
