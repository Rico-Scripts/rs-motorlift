local MODEL_HASH = joaat(Config.Model)
local cachedEntity = 0
local cachedDistance = math.huge
local appliedRevision = {}
local applicationToken = {}
local animLoadFailureShown = false
local lastAnimationAttempt = {}
local activeScenes = {}
local platformProxies = {}
local platformHeights = {}
local supportedMotorcycles = {}
local networkProxyIds = {}
local lastCarryAttempt = {}
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
    if proxy and DoesEntityExist(proxy) and not NetworkGetEntityIsNetworked(proxy) then
        DeleteEntity(proxy)
    end
    platformProxies[entity] = nil
    platformHeights[entity] = nil
end

local function setPlatformProxyHeight(entity, height)
    local proxy = platformProxies[entity]
    if not proxy or not DoesEntityExist(proxy) or not DoesEntityExist(entity) then return false end
    if NetworkGetEntityIsNetworked(proxy) then
        platformHeights[entity] = height
        return true
    end
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
    platformHeights[entity] = height
    return true
end

local function ensurePlatformProxy(entity, height)
    local current = platformProxies[entity]
    local proxyNetId = networkProxyIds[entity]
    if current and DoesEntityExist(current) and proxyNetId and proxyNetId ~= 0 then
        local currentNetId = NetworkGetEntityIsNetworked(current) and NetworkGetNetworkIdFromEntity(current) or 0
        if currentNetId ~= proxyNetId then
            if currentNetId == 0 then
                DeleteEntity(current)
            end
            platformProxies[entity] = nil
            platformHeights[entity] = nil
            current = nil
        end
    end
    if current and DoesEntityExist(current) then
        setPlatformProxyHeight(entity, height or 0.0)
        return current
    end
    if proxyNetId and proxyNetId ~= 0 then
        local deadline = GetGameTimer() + 5000
        local proxy = NetworkGetEntityFromNetworkId(proxyNetId)
        while (proxy == 0 or not DoesEntityExist(proxy)) and GetGameTimer() < deadline do
            Wait(50)
            proxy = NetworkGetEntityFromNetworkId(proxyNetId)
        end
        if proxy ~= 0 and DoesEntityExist(proxy) then
            SetEntityAlpha(proxy, 0, false)
            SetEntityLoadCollisionFlag(proxy, true, 1)
            SetEntityRecordsCollisions(proxy, true)
            SetEntityCollision(proxy, true, true)
            ActivatePhysics(proxy)
            platformProxies[entity] = proxy
            platformHeights[entity] = height or 0.0
            return proxy
        end
        return 0
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
    platformHeights[entity] = height or 0.0

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
        local model = DoesEntityExist(vehicle) and GetEntityModel(vehicle) or 0
        if model ~= 0 and (GetVehicleClass(vehicle) == 8 or IsThisModelABike(model)) then
            local coords = GetEntityCoords(vehicle)
            local localCoords = GetOffsetFromEntityGivenWorldCoords(entity, coords.x, coords.y, coords.z)
            local modelMinimum = GetModelDimensions(model)
            local bottomZ = coords.z + modelMinimum.z
            local verticalInside
            if height > Config.PlatformCollision.travel * 0.5 then
                verticalInside = math.abs(bottomZ - deckZ) <= Config.PlatformCollision.raisedAdmissionTolerance
            else
                verticalInside = math.abs(coords.z - deckZ) <= Config.PlatformCollision.vehicleZTolerance
            end
            local inside = math.abs(localCoords.x) <= Config.PlatformCollision.halfLength + margin
                and math.abs(localCoords.y) <= Config.PlatformCollision.halfWidth + margin
                and verticalInside
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

local function supportSurfaceZ(entity, height)
    local coords = GetEntityCoords(entity)
    return coords.z + Config.PlatformCollision.deckTop + height + Config.PlatformCollision.surfaceOffset
end

local function vehicleBottomZ(vehicle)
    local minimum = GetModelDimensions(GetEntityModel(vehicle))
    return GetEntityCoords(vehicle).z + minimum.z
end

local function isInsidePlatform(entity, vehicle)
    local coords = GetEntityCoords(vehicle)
    local localCoords = GetOffsetFromEntityGivenWorldCoords(entity, coords.x, coords.y, coords.z)
    local margin = Config.PlatformCollision.vehicleMargin
    return math.abs(localCoords.x) <= Config.PlatformCollision.halfLength + margin
        and math.abs(localCoords.y) <= Config.PlatformCollision.halfWidth + margin
end


local function applyMotorcycleSupport(entity, vehicle, height)
    if not NetworkHasControlOfEntity(vehicle) then return end
    local targetBottom = supportSurfaceZ(entity, height)
    local bottom = vehicleBottomZ(vehicle)
    if bottom >= targetBottom - 0.002 then return end

    local correction = math.min(targetBottom - bottom, Config.PlatformCollision.maxRisePerTick)
    local coords = GetEntityCoords(vehicle)
    SetEntityCoordsNoOffset(vehicle, coords.x, coords.y, coords.z + correction, false, false, false)
    local velocity = GetEntityVelocity(vehicle)
    if velocity.z < 0.0 then
        SetEntityVelocity(vehicle, velocity.x, velocity.y, 0.0)
    end
end

local function animatePlatformProxy(entity, fromHeight, targetHeight, token, carrierSource)
    if ensurePlatformProxy(entity, fromHeight) == 0 then return end
    local isCarrier = tonumber(carrierSource) == GetPlayerServerId(PlayerId())
    local vehicle = isCarrier and motorcycleOnPlatform(entity, fromHeight) or nil
    local vehicleFrozen = vehicle and requestControl(vehicle, 1500)
    lastCarryAttempt[entity] = {
        source = tonumber(carrierSource) or 0,
        eligible = isCarrier,
        vehicle = vehicle or 0,
        control = vehicleFrozen == true
    }
    if vehicleFrozen then
        supportedMotorcycles[vehicle] = entity
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


CreateThread(function()
    if not Config.PlatformCollision.supportEnabled then return end

    while true do
        local hasProxy = next(platformProxies) ~= nil
        if not hasProxy then
            Wait(250)
        else
            local vehicles = GetGamePool('CVehicle')
            for entity, proxy in pairs(platformProxies) do
                if DoesEntityExist(entity) and proxy and DoesEntityExist(proxy) then
                    local height = platformHeights[entity] or 0.0
                    local isRaised = height > Config.PlatformCollision.travel * 0.5
                    local surface = supportSurfaceZ(entity, height)

                    for _, vehicle in ipairs(vehicles) do
                        if DoesEntityExist(vehicle) and GetVehicleClass(vehicle) == 8 and isInsidePlatform(entity, vehicle) then
                            local known = supportedMotorcycles[vehicle] == entity
                            local closeToSurface = math.abs(vehicleBottomZ(vehicle) - surface)
                                <= Config.PlatformCollision.raisedAdmissionTolerance
                            if not isRaised or known or closeToSurface then
                                supportedMotorcycles[vehicle] = entity
                                applyMotorcycleSupport(entity, vehicle, height)
                            end
                        elseif supportedMotorcycles[vehicle] == entity then
                            supportedMotorcycles[vehicle] = nil
                        end
                    end
                end
            end
            Wait(Config.PlatformCollision.supportIntervalMs)
        end
    end
end)

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
    networkProxyIds[entity] = tonumber(sync.proxyNetId) or 0

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
            animatePlatformProxy(entity, 0.0, Config.PlatformCollision.travel, token, sync.carrierSource)
        elseif sync.state == Config.States.lowering then
            playTransition(entity, Config.Animations.lower)
            animatePlatformProxy(entity, Config.PlatformCollision.travel, 0.0, token, sync.carrierSource)
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
    local entitySummary = ('v1.4.2 ent=%s net=%s dist=%.2f state=%s model=%s dict=%s'):format(
        entity,
        NetworkGetNetworkIdFromEntity(entity),
        distance,
        state,
        tostring(modelAvailable),
        tostring(animLoaded)
    )
    local collisionSummary = ('proxy=%s netproxy=%s coll=%s surf=%.2f support=%s'):format(
        tostring(proxyExists),
        tostring(proxyExists and NetworkGetEntityIsNetworked(proxy) or false),
        tostring(proxyCollision),
        Config.PlatformCollision.surfaceOffset,
        tostring(Config.PlatformCollision.supportEnabled)
    )
    local animationSummary = ('%s start=%s phase=%.3f dur=%.3f fold=%s lower=%s'):format(
        tostring(attempt.mode or 'none'),
        tostring(attempt.started),
        tonumber(phase) or -1.0,
        tonumber(attempt.duration) or -1.0,
        tostring(foldPlaying),
        tostring(lowerPlaying)
    )
    local carry = lastCarryAttempt[entity] or {}
    local carrySummary = ('carry src=%s eligible=%s veh=%s control=%s'):format(
        tostring(carry.source or 0),
        tostring(carry.eligible == true),
        tostring(carry.vehicle or 0),
        tostring(carry.control == true)
    )
    print(('[rs_moto_lift] DEBUG %s | %s | %s | %s'):format(entitySummary, collisionSummary, animationSummary, carrySummary))
    notify(('~b~RS-debug: %s'):format(entitySummary))
    notify(('~b~RS-debug: %s'):format(collisionSummary))
    notify(('~b~RS-debug: %s'):format(animationSummary))
    notify(('~b~RS-debug: %s'):format(carrySummary))
end, false)

RegisterCommand('rsliftunstuck', function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        local pedCoords = GetEntityCoords(ped)
        local bestDistance = 6.0
        for _, candidate in ipairs(GetGamePool('CVehicle')) do
            if DoesEntityExist(candidate) and GetVehicleClass(candidate) == 8 then
                local distance = #(GetEntityCoords(candidate) - pedCoords)
                if distance < bestDistance then
                    vehicle = candidate
                    bestDistance = distance
                end
            end
        end
    end

    if vehicle == 0 or not DoesEntityExist(vehicle) then
        notify('~r~Geen motorfiets binnen 6 meter gevonden.')
        return
    end
    if not requestControl(vehicle, 1500) then
        notify('~r~Geen netwerkcontrole over de motorfiets gekregen.')
        return
    end

    supportedMotorcycles[vehicle] = nil
    FreezeEntityPosition(vehicle, false)
    SetEntityCollision(vehicle, true, true)
    SetEntityDynamic(vehicle, true)
    ActivatePhysics(vehicle)
    SetEntityVelocity(vehicle, 0.0, 0.0, -0.2)
    SetVehicleOnGroundProperly(vehicle, 5.0)
    notify('~g~Motorfiets is vrijgegeven en op de grond gezet.')
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
            if sync and sync.state == Config.States.drive then
                ensurePlatformProxy(cachedEntity, Config.PlatformCollision.travel)
            elseif sync and sync.state == Config.States.use then
                ensurePlatformProxy(cachedEntity, 0.0)
            elseif not platformProxies[cachedEntity] then
                local initialHeight = sync and sync.state == Config.States.lowering and Config.PlatformCollision.travel or 0.0
                ensurePlatformProxy(cachedEntity, initialHeight)
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
        supportedMotorcycles = {}
        networkProxyIds = {}
        lastCarryAttempt = {}
        if HasAnimDictLoaded(Config.AnimDict) then
            RemoveAnimDict(Config.AnimDict)
        end
    end
end)
