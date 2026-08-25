Config = {}

Config.Model = 'rs_moto_lift'
Config.AnimDict = 'rs_moto_lift_anim'
Config.Animations = {
    fold = 'rs_lift_fold_to_drive_locked',
    lower = 'rs_lift_lower_to_use'
}

Config.States = {
    use = 'use_lowered',
    drive = 'drive_locked',
    folding = 'folding_to_drive',
    lowering = 'lowering_to_use'
}

Config.StateBagKey = 'rsMotoLiftSync'
Config.ManagedStateBagKey = 'rsMotoLiftManaged'
Config.AnimationDurationMs = 1000
Config.TransitionGraceMs = 150

Config.PlatformCollision = {
    model = 'rs_moto_lift_platform_proxy_v150',
    -- Nieuwe Blender-lift: dek van 0,18 m naar 1,00 m.
    travel = 0.820,
    -- De proxy bevat nu een geleidelijke collision-oprijplaat van 0,70 m.
    -- Houd de proxy exact op het visuele dek om een onzichtbare instaprand te
    -- voorkomen.
    surfaceOffset = 0.00,
    deckTop = 0.180,
    supportEnabled = false,
    supportIntervalMs = 20,
    maxRisePerTick = 0.06,
    raisedAdmissionTolerance = 0.30,
    halfLength = 1.50,
    halfWidth = 0.35,
    vehicleMargin = 0.20,
    vehicleZTolerance = 1.40
}

Config.Interaction = {
    enabled = true,
    control = 38, -- INPUT_CONTEXT / E
    distance = 2.25,
    scanDistance = 15.0,
    scanIntervalMs = 350,
    command = 'rslift'
}

Config.Spawn = {
    enabled = true,
    command = 'rsliftspawn',
    despawnCommand = 'rsliftdespawn',
    despawnDistance = 5.0,
    requireAce = true,
    acePermission = 'rs_moto_lift.spawn',
    initialState = Config.States.use
}

Config.Security = {
    requireAce = false,
    acePermission = 'rs_moto_lift.use',
    serverDistanceTolerance = 1.25,
    allowExternalRegistration = true
}

Config.Persistence = {
    enabled = true,
    kvpPrefix = 'rs_moto_lift:state:'
}

Config.Debug = false

-- Voeg hier uitsluitend echte, gemeten plaatsingen toe. De resource verzint geen
-- wereldcoördinaten. Elke id moet uniek en stabiel blijven voor state persistence.
--
-- Voorbeeldvorm (bewust niet actief):
-- Config.Placements = {
--     {
--         id = 'werkplaats_lift_1',
--         coords = { x = <x>, y = <y>, z = <z>, w = <heading> },
--         initialState = Config.States.use
--     }
-- }
Config.Placements = {
    {
        id = 'werkplaats_lift_1',
        coords = {
            x = 322.879120,
            y = -1112.294556,
            z = 29.498902,
            w = 93.543304
        },
        initialState = Config.States.use
    }
}
