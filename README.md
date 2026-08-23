# RS Motorlift — FiveM-resource

Standalone OneSync-integratie voor de geanimeerde `rs_moto_lift` Fragment.

Versie 1.0.1 gebruikt een CodeWalker-repacked YTYP met conventionele 8 KiB
resourcepage-flags voor FiveM/RAGE-compatibiliteit.

Versie 1.0.2 koppelt het Fragment expliciet aan `rs_moto_lift_anim` en laat
`drawableDictionary` leeg, omdat de lift een `.yft` en geen `.ydd` gebruikt.

## Installatie

1. Clone de repository als `resources/[local]/rs_moto_lift`:

   ```bash
   git clone https://github.com/Rico-Scripts/rs-motorlift.git rs_moto_lift
   ```

2. Vul uitsluitend echte liftplaatsingen in bij `Config.Placements` in `config.lua`.
3. Voeg `ensure rs_moto_lift` toe aan `server.cfg`.
4. Herstart de resource/server en test beide standen met `E` of `/rslift`.

De resource vereist OneSync en spawnt geconfigureerde liften server-side. Zonder
`Config.Placements` wordt bewust niets geplaatst.

## Lift spawnen met een command

Gebruik als bevoegde speler:

```text
/rsliftspawn
/rsliftspawn use
/rsliftspawn drive
```

De lift verschijnt exact op de huidige positie en heading van de speler. Er wordt
geen oncontroleerbare clientpositie of verzonnen plaatsingsafstand gebruikt. Een
command-lift is runtime-only: hij wordt bij het stoppen van de resource verwijderd
en wordt niet als vaste plaatsing opgeslagen.

Spawnen gebruikt standaard het aparte ACE-recht `rs_moto_lift.spawn`:

```cfg
add_ace group.admin rs_moto_lift.spawn allow
```

Het command, de standaardstand en de toegangscontrole zijn instelbaar onder
`Config.Spawn` in `config.lua`.

## Toegang

Standaard kan iedere speler binnen bereik de lift bedienen. Voor ACE-beveiliging:

```lua
Config.Security.requireAce = true
```

En in `server.cfg` bijvoorbeeld:

```cfg
add_ace group.admin rs_moto_lift.use allow
```

## Exports voor andere resources

Server:

```lua
local ok, netIdOrError = exports.rs_moto_lift:RegisterLift(entity, 'unieke_id', 'use_lowered')
exports.rs_moto_lift:SetLiftState(entity, 'drive_locked')
local state = exports.rs_moto_lift:GetLiftState(entity)
```

Client:

```lua
exports.rs_moto_lift:ToggleLift(entity)
```

Externe entities moeten netwerkentities zijn, model `rs_moto_lift` gebruiken en
server-side aan de resource worden geregistreerd.

De voorbeelden gaan ervan uit dat de resourcefolder `rs_moto_lift` heet. Gebruik
je een andere mapnaam, pas dan ook de naam bij `ensure` en `exports` aan.

## Synchronisatie en beveiliging

- Eén atomaire entity-statebag synchroniseert state, action en revision.
- De server valideert model, registratie, routing bucket, afstand en optioneel ACE.
- Gelijktijdige bediening wordt tijdens de animatie geblokkeerd.
- Eindstanden worden exact op animatietijd `0.0` of `1.0` vastgezet.
- Geconfigureerde states kunnen via resource-KVP een restart overleven.
- Server-created entities krijgen orphan mode `KeepEntity`.

## Assetnamen

- Model/Fragment: `rs_moto_lift`
- Animdict: `rs_moto_lift_anim`
- Gebruik → rijstand: `RS_LIFT_FOLD_TO_DRIVE_LOCKED`
- Rijstand → gebruik: `RS_LIFT_LOWER_TO_USE`
