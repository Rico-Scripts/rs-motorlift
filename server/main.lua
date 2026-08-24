local MODEL_HASH = joaat(Config.Model)
local PROXY_MODEL_HASH = joaat(Config.PlatformCollision.model)
local lifts = {}
local netIdByEntity = {}
local nextRevision = 0
local spawnedLiftSequence = 0
local pendingSpawns = {}

local validFinalStates = {
    [Config.States.use] = true,
    [Config.States.drive] = true
}

local function debugLog(message)
    if Config.Debug then
        print(('[rs_moto_lift] %s'):format(message))
    end
end

local function playerMessage(source, message)
    if source and source > 0 then
        TriggerClientEvent('rs_moto_lift:client:message', source, message)
    end
end

local function persistenceKey(id)
    return Config.Persistence.kvpPrefix .. id
end

local function loadPersistentState(id, fallback)
    if not Config.Persistence.enabled or not id then
        return fallback
    end
    local state = GetResourceKvpString(persistenceKey(id))
    return validFinalStates[state] and state or fallback
end

local function savePersistentState(id, state)
    if Config.Persistence.enabled and id and validFinalStates[state] then
        SetResourceKvp(persistenceKey(id), state)
    end
end

local function newRevision()
    nextRevision = nextRevision + 1
    return nextRevision
end

local function setSync(entity, state, target, action, busy, carrierSource)
    local lift = lifts[NetworkGetNetworkIdFromEntity(entity)]
    local sync = {
        state = state,
        target = target or state,
        action = action or '',
        busy = busy == true,
        revision = newRevision(),
        proxyNetId = lift and lift.proxyNetId or 0,
        carrierSource = tonumber(carrierSource) or 0
    }
    Entity(entity).state:set(Config.StateBagKey, sync, true)
    return sync
end

local function createNetworkProxy(entity, initialState)
    local coords = GetEntityCoords(entity)
    local height = initialState == Config.States.drive and Config.PlatformCollision.travel or 0.0
    local proxy = CreateObjectNoOffset(
        PROXY_MODEL_HASH,
        coords.x,
        coords.y,
        coords.z + height + Config.PlatformCollision.surfaceOffset,
        true,
        true,
        false
    )
    if not proxy or proxy == 0 then return 0, 0 end
    SetEntityHeading(proxy, GetEntityHeading(entity))
    FreezeEntityPosition(proxy, true)
    SetEntityOrphanMode(proxy, 2)
    local netId = NetworkGetNetworkIdFromEntity(proxy)
    if not netId or netId == 0 then
        DeleteEntity(proxy)
        return 0, 0
    end
    return proxy, netId
end

local function registerLift(entity, id, initialState, ownedByResource, persistent)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return false, 'entity_not_found'
    end
    if GetEntityModel(entity) ~= MODEL_HASH then
        return false, 'invalid_model'
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId == 0 then
        return false, 'entity_not_networked'
    end

    initialState = validFinalStates[initialState] and initialState or Config.States.use
    persistent = persistent ~= false
    if persistent then
        initialState = loadPersistentState(id, initialState)
    end

    local proxyEntity, proxyNetId = createNetworkProxy(entity, initialState)
    if proxyEntity == 0 or proxyNetId == 0 then
        return false, 'proxy_spawn_failed'
    end

    lifts[netId] = {
        entity = entity,
        id = id or ('net_%s'):format(netId),
        state = initialState,
        busy = false,
        ownedByResource = ownedByResource == true,
        persistent = persistent,
        proxyEntity = proxyEntity,
        proxyNetId = proxyNetId
    }
    netIdByEntity[entity] = netId

    Entity(entity).state:set(Config.ManagedStateBagKey, true, true)
    setSync(entity, initialState, initialState, '', false)
    debugLog(('Lift %s geregistreerd als netId %s'):format(lifts[netId].id, netId))
    return true, netId
end


local function moveProxyTransition(lift, fromHeight, targetHeight, revision)
    CreateThread(function()
        local startedAt = GetGameTimer()
        local duration = math.max(1, Config.AnimationDurationMs)
        while lift.busy and DoesEntityExist(lift.entity) and DoesEntityExist(lift.proxyEntity) do
            local current = Entity(lift.entity).state[Config.StateBagKey]
            if not current or current.revision ~= revision then return end
            local progress = math.min(1.0, (GetGameTimer() - startedAt) / duration)
            local height = fromHeight + ((targetHeight - fromHeight) * progress)
            local coords = GetEntityCoords(lift.entity)
            SetEntityCoords(
                lift.proxyEntity,
                coords.x,
                coords.y,
                coords.z + height + Config.PlatformCollision.surfaceOffset,
                false,
                false,
                false,
                false
            )
            if progress >= 1.0 then return end
            Wait(0)
        end
    end)
end

local function spawnLift(coords, id, initialState, persistent)
    local entity = CreateObjectNoOffset(MODEL_HASH, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, true, true, false)
    if not entity or entity == 0 then
        return false, 'spawn_failed'
    end

    SetEntityHeading(entity, (coords.w or 0.0) + 0.0)
    FreezeEntityPosition(entity, true)
    SetEntityOrphanMode(entity, 2)

    local ok, reason = registerLift(entity, id, initialState, true, persistent)
    if not ok then
        DeleteEntity(entity)
        return false, reason
    end
    return true, reason, entity
end

local function spawnConfiguredLift(placement)
    if type(placement) ~= 'table' or type(placement.coords) ~= 'table' or not placement.id then
        print('[rs_moto_lift] Ongeldige Config.Placements-entry overgeslagen.')
        return
    end

    local ok, reason = spawnLift(placement.coords, placement.id, placement.initialState, true)
    if not ok then
        print(('[rs_moto_lift] Plaatsing %s kon niet worden gemaakt: %s'):format(placement.id, reason))
    end
end

local function validatePlayerRequest(source, netId)
    if Config.Security.requireAce and not IsPlayerAceAllowed(source, Config.Security.acePermission) then
        return nil, 'Je hebt geen toestemming om deze lift te bedienen.'
    end

    netId = tonumber(netId)
    local lift = netId and lifts[netId] or nil
    if not lift then
        return nil, 'Deze lift is niet door de RS-resource geregistreerd.'
    end
    if not DoesEntityExist(lift.entity) or GetEntityModel(lift.entity) ~= MODEL_HASH then
        netIdByEntity[lift.entity] = nil
        lifts[netId] = nil
        return nil, 'De liftentity bestaat niet meer.'
    end

    local playerPed = GetPlayerPed(source)
    if playerPed == 0 or not DoesEntityExist(playerPed) then
        return nil, 'Spelerentity niet beschikbaar.'
    end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(lift.entity) then
        return nil, 'De lift bevindt zich in een andere routing bucket.'
    end

    local maxDistance = Config.Interaction.distance + Config.Security.serverDistanceTolerance
    if #(GetEntityCoords(playerPed) - GetEntityCoords(lift.entity)) > maxDistance then
        return nil, 'Je staat te ver van de lift.'
    end

    return lift
end

local function transitionLift(lift, targetState, source)
    if lift.busy then
        playerMessage(source, '~y~De RS-motorlift is al in beweging.')
        return false
    end
    if not validFinalStates[targetState] or lift.state == targetState then
        return false
    end

    local transitionState
    local animation
    if targetState == Config.States.drive then
        transitionState = Config.States.folding
        animation = Config.Animations.fold
    else
        transitionState = Config.States.lowering
        animation = Config.Animations.lower
    end

    lift.busy = true
    local transitionSync = setSync(lift.entity, transitionState, targetState, animation, true, source)
    local fromHeight = lift.state == Config.States.drive and Config.PlatformCollision.travel or 0.0
    local targetHeight = targetState == Config.States.drive and Config.PlatformCollision.travel or 0.0
    moveProxyTransition(lift, fromHeight, targetHeight, transitionSync.revision)
    if source then
        local label = targetState == Config.States.drive and 'opgeklapt' or 'neergelaten'
        playerMessage(source, ('~b~RS-motorlift wordt %s.'):format(label))
    end

    SetTimeout(Config.AnimationDurationMs + Config.TransitionGraceMs, function()
        if not DoesEntityExist(lift.entity) or not lift.busy then
            return
        end
        local current = Entity(lift.entity).state[Config.StateBagKey]
        if not current or current.revision ~= transitionSync.revision then
            return
        end

        lift.state = targetState
        lift.busy = false
        if DoesEntityExist(lift.proxyEntity) then
            local coords = GetEntityCoords(lift.entity)
            SetEntityCoords(
                lift.proxyEntity,
                coords.x,
                coords.y,
                coords.z + targetHeight + Config.PlatformCollision.surfaceOffset,
                false,
                false,
                false,
                false
            )
        end
        setSync(lift.entity, targetState, targetState, '', false)
        if lift.persistent then
            savePersistentState(lift.id, targetState)
        end
    end)

    return true
end

RegisterNetEvent('rs_moto_lift:server:toggle', function(netId)
    local source = source
    local lift, errorMessage = validatePlayerRequest(source, netId)
    if not lift then
        playerMessage(source, ('~r~%s'):format(errorMessage))
        return
    end

    local target = lift.state == Config.States.drive and Config.States.use or Config.States.drive
    transitionLift(lift, target, source)
end)

RegisterCommand(Config.Spawn.command, function(source, args)
    if not Config.Spawn.enabled then
        playerMessage(source, '~r~Het spawnen van RS-motorliften is uitgeschakeld.')
        return
    end
    if source <= 0 then
        print(('[rs_moto_lift] /%s moet door een speler worden gebruikt; de serverconsole heeft geen positie.'):format(Config.Spawn.command))
        return
    end
    if Config.Spawn.requireAce and not IsPlayerAceAllowed(source, Config.Spawn.acePermission) then
        playerMessage(source, '~r~Je hebt geen toestemming om een RS-motorlift te spawnen.')
        return
    end

    local initialState = Config.Spawn.initialState
    local requestedState = args[1] and string.lower(args[1]) or nil
    if requestedState == 'drive' or requestedState == 'rijstand' then
        initialState = Config.States.drive
    elseif requestedState == 'use' or requestedState == 'gebruik' then
        initialState = Config.States.use
    elseif requestedState then
        playerMessage(source, ('~r~Gebruik: /%s [use|drive]'):format(Config.Spawn.command))
        return
    end

    spawnedLiftSequence = spawnedLiftSequence + 1
    local requestToken = spawnedLiftSequence
    pendingSpawns[source] = {
        token = requestToken,
        initialState = initialState,
        expiresAt = GetGameTimer() + 5000
    }
    TriggerClientEvent('rs_moto_lift:client:resolveSpawnGround', source, requestToken)
end, false)

RegisterCommand(Config.Spawn.despawnCommand, function(source)
    if not Config.Spawn.enabled then
        playerMessage(source, '~r~Het beheren van runtime RS-motorliften is uitgeschakeld.')
        return
    end
    if source <= 0 then
        print(('[rs_moto_lift] /%s moet door een speler worden gebruikt; de serverconsole heeft geen positie.'):format(Config.Spawn.despawnCommand))
        return
    end
    if Config.Spawn.requireAce and not IsPlayerAceAllowed(source, Config.Spawn.acePermission) then
        playerMessage(source, '~r~Je hebt geen toestemming om een RS-motorlift te verwijderen.')
        return
    end

    local playerPed = GetPlayerPed(source)
    if playerPed == 0 or not DoesEntityExist(playerPed) then
        playerMessage(source, '~r~Spelerpositie kon niet worden bepaald.')
        return
    end

    local playerCoords = GetEntityCoords(playerPed)
    local playerBucket = GetPlayerRoutingBucket(source)
    local nearestNetId, nearestLift, nearestDistance
    for netId, lift in pairs(lifts) do
        local isRuntime = type(lift.id) == 'string' and lift.id:sub(1, 8) == 'runtime_'
        if isRuntime and DoesEntityExist(lift.entity) and GetEntityRoutingBucket(lift.entity) == playerBucket then
            local distance = #(playerCoords - GetEntityCoords(lift.entity))
            if distance <= Config.Spawn.despawnDistance and (not nearestDistance or distance < nearestDistance) then
                nearestNetId, nearestLift, nearestDistance = netId, lift, distance
            end
        end
    end

    if not nearestLift then
        playerMessage(source, ('~r~Geen gespawnede RS-motorlift binnen %.1f meter gevonden.'):format(Config.Spawn.despawnDistance))
        return
    end
    if nearestLift.busy then
        playerMessage(source, '~y~Wacht tot de lift klaar is met bewegen voordat je hem verwijdert.')
        return
    end

    netIdByEntity[nearestLift.entity] = nil
    lifts[nearestNetId] = nil
    if nearestLift.proxyEntity and DoesEntityExist(nearestLift.proxyEntity) then
        DeleteEntity(nearestLift.proxyEntity)
    end
    if nearestLift.ownedByResource and DoesEntityExist(nearestLift.entity) then
        DeleteEntity(nearestLift.entity)
    end
    playerMessage(source, ('~g~RS-motorlift verwijderd (afstand %.1f m).'):format(nearestDistance))
end, false)

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

RegisterNetEvent('rs_moto_lift:server:spawnAtGround', function(requestToken, groundCoords)
    local source = source
    local pending = pendingSpawns[source]
    pendingSpawns[source] = nil

    if not pending or pending.token ~= tonumber(requestToken) or GetGameTimer() > pending.expiresAt then
        playerMessage(source, '~r~Het spawnverzoek is ongeldig of verlopen; probeer opnieuw.')
        return
    end
    if type(groundCoords) ~= 'table'
        or not isFiniteNumber(groundCoords.x)
        or not isFiniteNumber(groundCoords.y)
        or not isFiniteNumber(groundCoords.z) then
        playerMessage(source, '~r~De gemeten vloerpositie is ongeldig.')
        return
    end

    local playerPed = GetPlayerPed(source)
    if playerPed == 0 or not DoesEntityExist(playerPed) then
        playerMessage(source, '~r~Spelerpositie kon niet worden bepaald.')
        return
    end

    local requestedCoords = vector3(groundCoords.x, groundCoords.y, groundCoords.z)
    if #(GetEntityCoords(playerPed) - requestedCoords) > 3.0 then
        playerMessage(source, '~r~De gemeten vloerpositie ligt te ver van je vandaan.')
        return
    end

    spawnedLiftSequence = spawnedLiftSequence + 1
    local id = ('runtime_%s_%s_%s'):format(source, os.time(), spawnedLiftSequence)
    local coords = {
        x = groundCoords.x,
        y = groundCoords.y,
        z = groundCoords.z,
        w = GetEntityHeading(playerPed)
    }
    local ok, reason = spawnLift(coords, id, pending.initialState, false)
    if not ok then
        playerMessage(source, ('~r~De RS-motorlift kon niet worden gespawned: %s'):format(reason))
        return
    end

    playerMessage(source, ('~g~RS-motorlift op de gemeten vloer gespawned (%s).'):format(pending.initialState))
end)

exports('RegisterLift', function(entity, id, initialState)
    if not Config.Security.allowExternalRegistration then
        return false, 'external_registration_disabled'
    end
    return registerLift(entity, id, initialState, false, true)
end)

exports('SetLiftState', function(entity, state)
    if not entity or entity == 0 then
        return false, 'entity_not_found'
    end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    local lift = lifts[netId]
    if not lift then
        return false, 'lift_not_registered'
    end
    if not validFinalStates[state] then
        return false, 'invalid_state'
    end
    return transitionLift(lift, state, nil)
end)

exports('GetLiftState', function(entity)
    if not entity or entity == 0 then
        return nil
    end
    local lift = lifts[NetworkGetNetworkIdFromEntity(entity)]
    return lift and lift.state or nil
end)

AddEventHandler('entityRemoved', function(entity)
    local netId = netIdByEntity[entity]
    if netId then
        local lift = lifts[netId]
        if lift and lift.proxyEntity and DoesEntityExist(lift.proxyEntity) then
            DeleteEntity(lift.proxyEntity)
        end
        netIdByEntity[entity] = nil
        lifts[netId] = nil
    end
end)

AddEventHandler('playerDropped', function()
    pendingSpawns[source] = nil
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    CreateThread(function()
        Wait(500)
        if #Config.Placements == 0 then
            print('[rs_moto_lift] Geen Config.Placements ingesteld; assets en exports zijn beschikbaar, maar er wordt geen lift gespawned.')
        end
        for _, placement in ipairs(Config.Placements) do
            spawnConfiguredLift(placement)
            Wait(100)
        end
    end)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end
    for _, lift in pairs(lifts) do
        if lift.proxyEntity and DoesEntityExist(lift.proxyEntity) then
            DeleteEntity(lift.proxyEntity)
        end
        if lift.ownedByResource and DoesEntityExist(lift.entity) then
            DeleteEntity(lift.entity)
        end
    end
end)
