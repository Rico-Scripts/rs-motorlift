local MODEL_HASH = joaat(Config.Model)
local lifts = {}
local netIdByEntity = {}
local nextRevision = 0

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

local function setSync(entity, state, target, action, busy)
    local sync = {
        state = state,
        target = target or state,
        action = action or '',
        busy = busy == true,
        revision = newRevision()
    }
    Entity(entity).state:set(Config.StateBagKey, sync, true)
    return sync
end

local function registerLift(entity, id, initialState, ownedByResource)
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
    initialState = loadPersistentState(id, initialState)

    lifts[netId] = {
        entity = entity,
        id = id or ('net_%s'):format(netId),
        state = initialState,
        busy = false,
        ownedByResource = ownedByResource == true
    }
    netIdByEntity[entity] = netId

    Entity(entity).state:set(Config.ManagedStateBagKey, true, true)
    setSync(entity, initialState, initialState, '', false)
    debugLog(('Lift %s geregistreerd als netId %s'):format(lifts[netId].id, netId))
    return true, netId
end

local function spawnConfiguredLift(placement)
    if type(placement) ~= 'table' or type(placement.coords) ~= 'table' or not placement.id then
        print('[rs_moto_lift] Ongeldige Config.Placements-entry overgeslagen.')
        return
    end

    local coords = placement.coords
    local entity = CreateObjectNoOffset(MODEL_HASH, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, true, true, false)
    if not entity or entity == 0 then
        print(('[rs_moto_lift] Kon plaatsing %s niet spawnen.'):format(placement.id))
        return
    end

    SetEntityHeading(entity, (coords.w or 0.0) + 0.0)
    FreezeEntityPosition(entity, true)
    SetEntityOrphanMode(entity, 2)

    local ok, reason = registerLift(entity, placement.id, placement.initialState, true)
    if not ok then
        print(('[rs_moto_lift] Registratie van %s mislukt: %s'):format(placement.id, reason))
        DeleteEntity(entity)
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
    local transitionSync = setSync(lift.entity, transitionState, targetState, animation, true)

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
        setSync(lift.entity, targetState, targetState, '', false)
        savePersistentState(lift.id, targetState)
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

exports('RegisterLift', function(entity, id, initialState)
    if not Config.Security.allowExternalRegistration then
        return false, 'external_registration_disabled'
    end
    return registerLift(entity, id, initialState, false)
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
        netIdByEntity[entity] = nil
        lifts[netId] = nil
    end
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
        if lift.ownedByResource and DoesEntityExist(lift.entity) then
            DeleteEntity(lift.entity)
        end
    end
end)
