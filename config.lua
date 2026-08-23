Config = {}

Config.Model = 'rs_moto_lift'
Config.AnimDict = 'rs_moto_lift_anim'
Config.Animations = {
    fold = 'RS_LIFT_FOLD_TO_DRIVE_LOCKED',
    lower = 'RS_LIFT_LOWER_TO_USE'
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
