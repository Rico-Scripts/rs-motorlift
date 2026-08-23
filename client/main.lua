local MODEL_HASH = joaat(Config.Model)
local cachedEntity = 0
local cachedDistance = math.huge
local appliedRevision = {}
local applicationToken = {}
local animLoadFailureShown = false
local lastAnimationAttempt = {}
local activeScenes = {}
local platformProxies = {}
local PROXY_MODEL_HASH = joaat(Config.PlatformCollision.model)

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

local function loadModel(hash, timeoutMs)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return false end
    RequestModel(hash)
    RequestCollisionForModel(hash)
    local deadline = GetGameTimer() + timeoutMs
    while (
        not HasModelLoaded(hash)
        or not HasCollisionForModelLoaded(hash)
    ) and GetGameTimer() < deadline do
        RequestModel(hash)
        RequestCollisionForModel(hash)
        Wait(0)
    end
    return HasModelLoaded(hash) and HasCollisionForModelLoaded(hash)
end

local function deletePlatformProxy(entity)
    local proxy = platformProxies[entity]
    if proxy and DoesEntityExist(proxy) then
        DeleteEntity(proxy)
    end
    platformProxies[entity] = nil
end

local function setPlatformProxyHeight(entity, height)
    local proxy = platformProxies[entity]
    if not proxy or not DoesEntityExist(proxy) or not DoesEntityExist(entity) then return false end
    local coords = GetEntityCoords(entity)
    SetEntityCoordsNoOffset(
        proxy,
        coords.x,
        coords.y,
        coords.z + height + Config.PlatformCollision.surfaceOffset,
        false,
        false,
        false
    )
    SetEntityHeading(proxy, GetEntityHeading(entity))
    return true
end

local function ensurePlatformProxy(entity, height)
    local current = platformProxies[entity]
    if current and DoesEntityExist(current) then
        setPlatformProxyHeight(entity, height or 0.0)
        return current
    end
    if not loadModel(PROXY_MODEL_HASH, 5000) then
        notify('~r~RS-platformcollision kon niet worden geladen.')
        return 0
    end
    local coords = GetEntityCoords(entity)
    local proxy = CreateObjectNoOffset(
        PROXY_MODEL_HASH,
        coords.x,
        coords.y,
        coords.z + (height or 0.0) + Config.PlatformCollision.surfaceOffset,
        false,
        false,
        false
    )
    if proxy == 0 then return 0 end
    SetEntityHeading(proxy, GetEntityHeading(entity))
    SetEntityAlpha(proxy, 0, false)
    RequestCollisionAtCoord(coords.x, coords.y, coords.z + (height or 0.0))
    SetEntityLoadCollisionFlag(proxy, true, 1)
    SetEntityRecordsCollisions(proxy, true)
    SetEntityDynamic(proxy, false)
    SetEntityCollision(proxy, true, true)
    ActivatePhysics(proxy)
    FreezeEntityPosition(proxy, true)
    SetEntityAsMissionEntity(proxy, true, true)
    platformProxies[entity] = proxy

    local collisionDeadline = GetGameTimer() + 3000
    while not HasCollisionLoadedAroundEntity(proxy) and GetGameTimer() < collisionDeadline do
        RequestCollisionAtCoord(coords.x, coords.y, coords.z + (height or 0.0))
        RequestCollisionForModel(PROXY_MODEL_HASH)
        Wait(0)
    end
    if not HasCollisionLoadedAroundEntity(proxy) then
        debugLog(('Platformproxy bestaat, maar YBN-collision is niet geladen: entity=%s proxy=%s'):format(entity, proxy))
    end
    SetModelAsNoLongerNeeded(PROXY_MODEL_HASH)
    return proxy
end

local function requestControl(entity, timeoutMs)
    if NetworkHasControlOfEntity(entity) then return true end
    local deadline = GetGameTimer() + timeoutMs
    repeat
        NetworkRequestControlOfEntity(entity)
        Wait(0)
    until NetworkHasControlOfEntity(entity) or GetGameTimer() >= deadline
    return NetworkHasControlOfEntity(entity)
end

local function motorcycleOnPlatform(entity, height)
    local liftCoords = GetEntityCoords(entity)
    local deckZ = liftCoords.z + 0.349 + height + Config.PlatformCollision.surfaceOffset
    local best, bestDistance
    local margin = Config.PlatformCollision.vehicleMargin
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(vehicle) and GetVehicleClass(vehicle) == 8 then
            local coords = GetEntityCoords(vehicle)
            local localCoords = GetOffsetFromEntityGivenWorldCoords(entity, coords.x, coords.y, coords.z)
            local inside = math.abs(localCoords.x) <= Config.PlatformCollision.halfLength + margin
                and math.abs(localCoords.y) <= Config.PlatformCollision.halfWidth + margin
                and math.abs(coords.z - deckZ) <= Config.PlatformCollision.vehicleZTolerance
            if inside then
                local distance = math.sqrt((coords.x - liftCoords.x) ^ 2 + (coords.y - liftCoords.y) ^ 2)
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = vehicle, distance
                end
            end
        end
    end
    return best
end

local function animatePlatformProxy(entity, fromHeight, targetHeight, token)
    if ensurePlatformProxy(entity, fromHeight) == 0 then return end
    local vehicle = motorcycleOnPlatform(entity, fromHeight)
    local vehicleFrozen = vehicle and requestControl(vehicle, 1200)
    if vehicleFrozen then
        FreezeEntityPosition(vehicle, true)
        SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
    else
        vehicle = nil
    end

    local startedAt = GetGameTimer()
    local duration = math.max(1, Config.AnimationDurationMs)
    local previousHeight = fromHeight
    while applicationToken[entity] == token and DoesEntityExist(entity) do
        local progress = math.min(1.0, (GetGameTimer() - startedAt) / duration)
        local height = fromHeight + ((targetHeight - fromHeight) * progress)
        local delta = height - previousHeight
        setPlatformProxyHeight(entity, height)
        if vehicle and DoesEntityExist(vehicle) and math.abs(delta) > 0.00001 then
            local coords = GetEntityCoords(vehicle)
            SetEntityCoordsNoOffset(vehicle, coords.x, coords.y, coords.z + delta, false, false, false)
            SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
        end
        previousHeight = height
        if progress >= 1.0 then break end
        Wait(0)
    end
    setPlatformProxyHeight(entity, targetHeight)
    if vehicle and DoesEntityExist(vehicle) and vehicleFrozen then
        FreezeEntityPosition(vehicle, false)
    end
end

local function startDirectEntityAnim(entity, animation, phase, rate)
    stopActiveScene(entity)
    local started = PlayEntityAnim(
        entity,
        animation,
        Config.AnimDict,
        1000.0,
        false,
        true,
        false,
        0.0,
        0
    )
    if started then
        Wait(0)
        if phase ~= nil then
            SetEntityAnimCurrentTime(entity, Config.AnimDict, animation, phase)
        end
        SetEntityAnimSpeed(entity, Config.AnimDict, animation, rate or 1.0)
        ForceEntityAiAndAnimationUpdate(entity)
    end
    lastAnimationAttempt[entity] = {
        animation = animation,
        started = started,
        pose = phase,
        mode = 'entity',
        duration = GetAnimDuration(Config.AnimDict, animation)
    }
    return started
end

local function startLiftAnimation(entity, animation, phase, rate)
    if startDirectEntityAnim(entity, animation, phase, rate) then
        return true
    end
    return startEntityScene(entity, animation, phase, rate)
end

local function poseEntity(entity, normalizedTime)
    return startLiftAnimation(entity, Config.Animations.fold, normalizedTime, 0.0)
end

local function playTransition(entity, animation)
    local started = startLiftAnimation(entity, animation, nil, 1.0)
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
            ensurePlatformProxy(entity, 0.0)
            poseEntity(entity, 0.0)
        elseif sync.state == Config.States.drive then
            ensurePlatformProxy(entity, Config.PlatformCollision.travel)
            poseEntity(entity, 1.0)
        elseif sync.state == Config.States.folding then
            playTransition(entity, Config.Animations.fold)
            animatePlatformProxy(entity, 0.0, Config.PlatformCollision.travel, token)
        elseif sync.state == Config.States.lowering then
            playTransition(entity, Config.Animations.lower)
            animatePlatformProxy(entity, Config.PlatformCollision.travel, 0.0, token)
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
    local phase = attempt.mode == 'scene' and attempt.scene and GetSynchronizedScenePhase(attempt.scene)
        or GetEntityAnimCurrentTime(entity, Config.AnimDict, attempt.animation or Config.Animations.fold)
    local proxy = platformProxies[entity]
    local proxyExists = proxy and DoesEntityExist(proxy) or false
    local proxyCollision = proxyExists and HasCollisionLoadedAroundEntity(proxy) or false
    local entitySummary = ('v1.2.3 ent=%s net=%s dist=%.2f state=%s model=%s dict=%s'):format(
        entity,
        NetworkGetNetworkIdFromEntity(entity),
        distance,
        state,
        tostring(modelAvailable),
        tostring(animLoaded)
    )
    local collisionSummary = ('proxy=%s coll=%s surf=%.2f'):format(
        tostring(proxyExists),
        tostring(proxyCollision),
        Config.PlatformCollision.surfaceOffset
    )
    local animationSummary = ('%s start=%s phase=%.3f dur=%.3f fold=%s lower=%s'):format(
        tostring(attempt.mode or 'none'),
        tostring(attempt.started),
        tonumber(phase) or -1.0,
        tonumber(attempt.duration) or -1.0,
        tostring(foldPlaying),
        tostring(lowerPlaying)
    )
    print(('[rs_moto_lift] DEBUG %s | %s | %s'):format(entitySummary, collisionSummary, animationSummary))
    notify(('~b~RS-debug: %s'):format(entitySummary))
    notify(('~b~RS-debug: %s'):format(collisionSummary))
    notify(('~b~RS-debug: %s'):format(animationSummary))
end, false)

exports('ToggleLift', requestToggle)

CreateThread(function()
    while true do
        cachedEntity, cachedDistance = findClosestManagedLift()

        if cachedEntity ~= 0 then
            local sync = Entity(cachedEntity).state[Config.StateBagKey]
            if sync and sync.state == Config.States.drive then
                ensurePlatformProxy(cachedEntity, Config.PlatformCollision.travel)
            elseif sync and sync.state == Config.States.use then
                ensurePlatformProxy(cachedEntity, 0.0)
            elseif not platformProxies[cachedEntity] then
                local initialHeight = sync and sync.state == Config.States.lowering and Config.PlatformCollision.travel or 0.0
                ensurePlatformProxy(cachedEntity, initialHeight)
            end
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
        for entity in pairs(platformProxies) do
            deletePlatformProxy(entity)
        end
        if HasAnimDictLoaded(Config.AnimDict) then
            RemoveAnimDict(Config.AnimDict)
        end
    end
end)
