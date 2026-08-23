local MODEL_HASH = joaat(Config.Model)
local cachedEntity = 0
local cachedDistance = math.huge
local appliedRevision = {}
local applicationToken = {}
local animLoadFailureShown = false
local lastAnimationAttempt = {}
local activeScenes = {}

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

local function stopActiveScene(entity)
    local scene = activeScenes[entity]
    if scene then
        DetachSynchronizedScene(scene)
        activeScenes[entity] = nil
    end
end

local function startEntityScene(entity, animation, phase, rate)
    stopActiveScene(entity)
    local coords = GetEntityCoords(entity)
    local rotation = GetEntityRotation(entity, 2)
    local scene = CreateSynchronizedScene(
        coords.x,
        coords.y,
        coords.z,
        rotation.x,
        rotation.y,
        rotation.z,
        2
    )
    SetSynchronizedSceneLooped(scene, false)
    local started = PlaySynchronizedEntityAnim(
        entity,
        scene,
        animation,
        Config.AnimDict,
        8.0,
        -8.0,
        4,
        1000.0
    )
    if started then
        activeScenes[entity] = scene
        if phase ~= nil then
            SetSynchronizedScenePhase(scene, phase)
        end
        SetSynchronizedSceneRate(scene, rate or 1.0)
        ForceEntityAiAndAnimationUpdate(entity)
    end
    lastAnimationAttempt[entity] = {
        animation = animation,
        started = started,
        pose = phase,
        mode = 'scene',
        scene = scene,
        duration = GetAnimDuration(Config.AnimDict, animation)
    }
    return started
end

local function poseEntity(entity, normalizedTime)
    return startEntityScene(entity, Config.Animations.fold, normalizedTime, 0.0)
end

local function playTransition(entity, animation)
    local started = startEntityScene(entity, animation, nil, 1.0)
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

local function measureFloorBelowPlayer()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(
        coords.x,
        coords.y,
        coords.z + 1.0,
        coords.x,
        coords.y,
        coords.z - 5.0,
        1,
        ped,
        7
    )
    local _, hit, hitCoords = GetShapeTestResult(ray)
    if hit == 1 and hitCoords then
        return hitCoords
    end

    local foundGround, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 1.0, false)
    if foundGround then
        return vector3(coords.x, coords.y, groundZ)
    end

    return nil
end

RegisterNetEvent('rs_moto_lift:client:resolveSpawnGround', function(requestToken)
    local floorCoords = measureFloorBelowPlayer()
    if not floorCoords then
        notify('~r~Er kon geen vloer onder je worden gemeten; de lift is niet gespawned.')
        return
    end

    TriggerServerEvent('rs_moto_lift:server:spawnAtGround', requestToken, {
        x = floorCoords.x,
        y = floorCoords.y,
        z = floorCoords.z
    })
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
    local phase = attempt.scene and GetSynchronizedScenePhase(attempt.scene)
        or GetEntityAnimCurrentTime(entity, Config.AnimDict, attempt.animation or Config.Animations.fold)
    local entitySummary = ('v1.0.11 ent=%s net=%s dist=%.2f state=%s model=%s dict=%s'):format(
        entity,
        NetworkGetNetworkIdFromEntity(entity),
        distance,
        state,
        tostring(modelAvailable),
        tostring(animLoaded)
    )
    local animationSummary = ('scene start=%s phase=%.3f dur=%.3f fold=%s lower=%s'):format(
        tostring(attempt.started),
        tonumber(phase) or -1.0,
        tonumber(attempt.duration) or -1.0,
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
    if resourceName == GetCurrentResourceName() then
        for entity in pairs(activeScenes) do
            stopActiveScene(entity)
        end
        if HasAnimDictLoaded(Config.AnimDict) then
            RemoveAnimDict(Config.AnimDict)
        end
    end
end)
