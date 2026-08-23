local MODEL_HASH = joaat(Config.Model)
local cachedEntity = 0
local cachedDistance = math.huge
local appliedRevision = {}
local applicationToken = {}
local animLoadFailureShown = false
local lastAnimationAttempt = {}

local function debugLog(message)
    if Config.Debug then
        print(('[rs_moto_lift] %s'):format(message))
    end
end

local function notify(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, false)
end

local function showHelp(message)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function ensureAnimDict(timeoutMs)
    if HasAnimDictLoaded(Config.AnimDict) then
        return true
    end

    RequestAnimDict(Config.AnimDict)
    local deadline = GetGameTimer() + timeoutMs
    while not HasAnimDictLoaded(Config.AnimDict) and GetGameTimer() < deadline do
        Wait(0)
    end

    if not HasAnimDictLoaded(Config.AnimDict) then
        if not animLoadFailureShown then
            animLoadFailureShown = true
            notify('~r~RS-liftanimatie kon niet worden geladen. Controleer de .ycd.')
        end
        return false
    end

    return true
end

local function poseEntity(entity, normalizedTime)
    local started = PlayEntityAnim(
        entity,
        Config.Animations.fold,
        Config.AnimDict,
        8.0,
        false,
        true,
        false,
        0.0,
        0
    )
    local deadline = GetGameTimer() + 250
    while started and not IsEntityPlayingAnim(entity, Config.AnimDict, Config.Animations.fold, 3) and GetGameTimer() < deadline do
        Wait(0)
    end
    SetEntityAnimCurrentTime(entity, Config.AnimDict, Config.Animations.fold, normalizedTime)
    SetEntityAnimSpeed(entity, Config.AnimDict, Config.Animations.fold, 0.0)
    lastAnimationAttempt[entity] = {
        animation = Config.Animations.fold,
        started = started,
        pose = normalizedTime
    }
    return started
end

local function playTransition(entity, animation)
    local started = PlayEntityAnim(
        entity,
        animation,
        Config.AnimDict,
        8.0,
        false,
        true,
        false,
        0.0,
        0
    )
    SetEntityAnimSpeed(entity, Config.AnimDict, animation, 1.0)
    lastAnimationAttempt[entity] = {
        animation = animation,
        started = started,
        pose = nil
    }
    debugLog(('Animatie %s gestart=%s op entity=%s'):format(animation, tostring(started), entity))
    return started
end

local function applySync(entity, sync)
    if entity == 0 or not DoesEntityExist(entity) or type(sync) ~= 'table' then
        return
    end

    local revision = tonumber(sync.revision) or 0
    if appliedRevision[entity] == revision then
        return
    end
    appliedRevision[entity] = revision

    applicationToken[entity] = (applicationToken[entity] or 0) + 1
    local token = applicationToken[entity]

    CreateThread(function()
        if not ensureAnimDict(5000) then
            return
        end
        if applicationToken[entity] ~= token or not DoesEntityExist(entity) then
            return
        end

        FreezeEntityPosition(entity, true)

        if sync.state == Config.States.use then
            poseEntity(entity, 0.0)
        elseif sync.state == Config.States.drive then
            poseEntity(entity, 1.0)
        elseif sync.state == Config.States.folding then
            playTransition(entity, Config.Animations.fold)
        elseif sync.state == Config.States.lowering then
            playTransition(entity, Config.Animations.lower)
        else
            debugLog(('Onbekende liftstate ontvangen: %s'):format(tostring(sync.state)))
        end
    end)
end

local function entityFromStateBag(bagName)
    local entity = GetEntityFromStateBagName(bagName)
    if entity ~= 0 then
        return entity
    end

    local deadline = GetGameTimer() + 3000
    while entity == 0 and GetGameTimer() < deadline do
        Wait(50)
        entity = GetEntityFromStateBagName(bagName)
    end
    return entity
end

AddStateBagChangeHandler(Config.StateBagKey, nil, function(bagName, _, value)
    CreateThread(function()
        local entity = entityFromStateBag(bagName)
        if entity ~= 0 then
            applySync(entity, value)
        end
    end)
end)

local function findClosestManagedLift()
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local entity = GetClosestObjectOfType(
        playerCoords.x,
        playerCoords.y,
        playerCoords.z,
        Config.Interaction.scanDistance,
        MODEL_HASH,
        false,
        false,
        false
    )

    if entity == 0 or not DoesEntityExist(entity) then
        return 0, math.huge
    end

    local state = Entity(entity).state
    if not state[Config.ManagedStateBagKey] then
        return 0, math.huge
    end

    return entity, #(playerCoords - GetEntityCoords(entity))
end

local function requestToggle(entity)
    if entity == 0 or not DoesEntityExist(entity) then
        notify('~r~Geen beheerde RS-motorlift gevonden.')
        return false
    end
    if not NetworkGetEntityIsNetworked(entity) then
        notify('~r~Deze lift is niet netwerkgesynchroniseerd.')
        return false
    end

    TriggerServerEvent('rs_moto_lift:server:toggle', NetworkGetNetworkIdFromEntity(entity))
    return true
end

RegisterNetEvent('rs_moto_lift:client:message', function(message)
    notify(message)
end)

RegisterCommand(Config.Interaction.command, function()
    local entity, distance = findClosestManagedLift()
    if distance > Config.Interaction.distance then
        notify('~r~Je staat niet dicht genoeg bij een RS-motorlift.')
        return
    end
    requestToggle(entity)
end, false)

RegisterCommand('rsliftdebug', function()
    local entity, distance = findClosestManagedLift()
    local modelAvailable = IsModelInCdimage(MODEL_HASH)
    local animLoaded = ensureAnimDict(3000)
    if entity == 0 then
        notify(('~y~RS-debug: geen beheerde lift; model=%s animdict=%s'):format(tostring(modelAvailable), tostring(animLoaded)))
        return
    end

    local sync = Entity(entity).state[Config.StateBagKey]
    local state = sync and sync.state or 'geen_state'
    local foldPlaying = IsEntityPlayingAnim(entity, Config.AnimDict, Config.Animations.fold, 3)
    local lowerPlaying = IsEntityPlayingAnim(entity, Config.AnimDict, Config.Animations.lower, 3)
    local attempt = lastAnimationAttempt[entity] or {}
    local phase = GetEntityAnimCurrentTime(entity, Config.AnimDict, attempt.animation or Config.Animations.fold)
    local entitySummary = ('v1.0.8 ent=%s net=%s dist=%.2f state=%s model=%s dict=%s'):format(
        entity,
        NetworkGetNetworkIdFromEntity(entity),
        distance,
        state,
        tostring(modelAvailable),
        tostring(animLoaded)
    )
    local animationSummary = ('anim start=%s phase=%.3f fold=%s lower=%s'):format(
        tostring(attempt.started),
        tonumber(phase) or -1.0,
        tostring(foldPlaying),
        tostring(lowerPlaying)
    )
    print(('[rs_moto_lift] DEBUG %s | %s'):format(entitySummary, animationSummary))
    notify(('~b~RS-debug: %s'):format(entitySummary))
    notify(('~b~RS-debug: %s'):format(animationSummary))
end, false)

exports('ToggleLift', requestToggle)

CreateThread(function()
    while true do
        cachedEntity, cachedDistance = findClosestManagedLift()

        if cachedEntity ~= 0 then
            local sync = Entity(cachedEntity).state[Config.StateBagKey]
            if sync and appliedRevision[cachedEntity] ~= sync.revision then
                applySync(cachedEntity, sync)
            end
        end

        Wait(Config.Interaction.scanIntervalMs)
    end
end)

CreateThread(function()
    if not Config.Interaction.enabled then
        return
    end

    while true do
        if cachedEntity ~= 0 and cachedDistance <= Config.Interaction.distance then
            local sync = Entity(cachedEntity).state[Config.StateBagKey]
            if sync and (sync.state == Config.States.folding or sync.state == Config.States.lowering) then
                showHelp('RS-motorlift is in beweging...')
            else
                showHelp(('Druk op ~INPUT_CONTEXT~ om de RS-motorlift te bedienen (~b~/%s~s~)'):format(Config.Interaction.command))
                if IsControlJustReleased(0, Config.Interaction.control) then
                    requestToggle(cachedEntity)
                    Wait(500)
                end
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() and HasAnimDictLoaded(Config.AnimDict) then
        RemoveAnimDict(Config.AnimDict)
    end
end)
