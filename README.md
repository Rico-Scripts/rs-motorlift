# RS Motorlift — FiveM-resource

Standalone OneSync-integratie voor de geanimeerde `rs_moto_lift` Fragment.

Versie 1.0.1 gebruikt een CodeWalker-repacked YTYP met conventionele 8 KiB
resourcepage-flags voor FiveM/RAGE-compatibiliteit.

Versie 1.0.2 koppelt het Fragment expliciet aan `rs_moto_lift_anim` en laat
`drawableDictionary` leeg, omdat de lift een `.yft` en geen `.ydd` gebruikt.

Versie 1.0.5 markeert `RS_LIFT_RAMP` in de native YFT expliciet met de
`RotX`, `RotY` en `RotZ` boneflags, zodat GTA de YCD-rotatietrack toepast.

Versie 1.0.6 corrigeert de YCD-clipgrenzen naar exact `0.0–1.0` seconde.
De eerdere clips eindigden één frame buiten de onderliggende animatie.

Versie 1.0.7 splitst `/rsliftdebug` in korte status- en animatieregels en
schrijft dezelfde diagnose naar F8, zodat `start` en `phase` niet wegvallen.

Versie 1.0.8 gebruikt RAGE-compatibele lowercase hashes voor de twee RS-clips.
De eerdere uppercase hashes konden wel laden, maar niet via `PlayEntityAnim`
worden gevonden.

Versie 1.0.9 speelt de lift als een lokale synchronized entity scene af. De
serverstatus blijft via OneSync gesynchroniseerd, terwijl iedere client de
fragmentanimatie via GTA's object-scene-pad rendert.

Versie 1.0.10 zet de vereiste YTYP-archetypeflag `Has Anim (YCD)` en neemt de
YCD expliciet op in het manifest. De interne namen eindigen volgens de
RAGE/Sollumz-conventie op `.clip`, zodat de twee RS-clips worden geregistreerd.

Versie 1.0.11 laat `/rsliftspawn` client-side de echte vloer onder de speler
meten. De server valideert het eenmalige meetresultaat voordat de lift wordt
gemaakt, zodat de model-origin op de vloer staat en niet op de ped-positie.

Versie 1.0.12 gebruikt voor de geregistreerde fragmentclips eerst GTA's directe
entity-animatiepad. Alleen wanneer dat pad de entity weigert, wordt de
synchronized-scene-route als fallback geprobeerd en in `/rsliftdebug` vermeld.

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

De lift verschijnt op de gemeten vloer onder de huidige positie en krijgt de
heading van de speler. Er wordt
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
- Gebruik → rijstand: `rs_lift_fold_to_drive_locked`
- Rijstand → gebruik: `rs_lift_lower_to_use`
