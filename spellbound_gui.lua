-- spellbound_gui.lua — Spellbound Tool (manuell, kein Voll-Auto)
--   AUTO-SPELL (G): re-equippt ueber den no-CD-Bug (casts=0) staendig den gewaehlten
--       Spell -> jeder deiner Klicks feuert ihn ohne Cooldown (echte Hits). Auswaehlbar.
--   COMBO: nach JEDEM Auto-Spell-Fire wird einmal der gewaehlte Combo-Spell equippt
--       + gecastet, danach sofort wieder der Auto-Spell scharf. Toggle + auswaehlbar.
--   SILENT-AIM: lenkt jeden Klick auf den Gegner am naechsten zum Cursor. Die Trefferzone
--       wechselt dabei (Torso/Kopf/Gliedmassen + Offset), damit es nicht nach Bot aussieht.
--   AUTO-SHIELD: reaktives Protego gegen eingehende Casts.
--   AUTO-CLASH: gewinnt das Clash-Minigame automatisch (echter Space-Input, kein Miss-Stun).
--   SHOTGUN (Troll): feuert NUR auf Linksklick, dann 6 Combat-Spells am Stueck (1 Frame
--       Abstand) aus den eigenen Bind-Sets, alphabetisch rotierend.
--   SNIPE (E): Tarnschuss aufs Silent-Aim-Ziel, punktgenau zum Einschlag TP unter das Ziel,
--       zweiter Spell von unten, sofort zurueck auf den Startpunkt.
--   AUTOFARM (Farm-Panel): loescht die Map lokal, teleportiert unter jeden Spieler und feuert dort
--       genau EINEN Spell nach oben, dann weiter zum naechsten. HRP wird dabei verankert.
--   KD-FARM (Farm-Panel): killt dich per resetEvent im Dauertakt (~3.9s pro Tod), haelt die K/D unten.
-- BEDIENUNG: ClickGUI im Future-Style — RechtsShift ODER B blendet das Overlay ein/aus.
--   Module per Klick togglen, Rechtsklick oeffnet die Settings. F/H-Hotkeys entfernt;
--   P=Clash, C=Dodge, T=Apparate, G=Appa-laden, E=Snipe bleiben als Aktions-Hotkeys.
--   Autofarm und KD-Farm haben BEWUSST keinen Hotkey - nur ueber das Farm-Panel schaltbar.
-- Standalone, per Autoexec ladbar. Cooldown wird durchgehend ueber casts=0 umgangen.

pcall(setthreadidentity, 2)

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local lp         = Players.LocalPlayer or Players.PlayerAdded:Wait()

local Http       = game:GetService("HttpService")
local g = getgenv()

-- === Re-Execute-Cleanup: altes vollstaendig killen, keine Zombies ===
-- laufende while-Loops beenden, alte Connections trennen, Toggles auf AUS.
g.SB_AIM, g.SB_SHIELD, g.SB_CLASH = false, false, false
g.SB_SAFE, g.SB_APPA_PENDING = false, false
g.SB_DODGE = false               -- reaktiver Auto-Dodge (ROLL via LeftControl)
g.SB_DODGE_SKIPACC = 0           -- Prozent-Gate Akkumulator (Pattern-Reset)
g.SB_DODGE_PCT = tonumber(g.SB_DODGE_PCT) or 100   -- Dodge-Rate in % (bleibt erhalten)
g.SB_LEGIT = tonumber(g.SB_LEGIT) or 0             -- Legitness 0-100%: so viel % ALLER Cheat-Aktionen failen absichtlich
g.SB_CURSE_LOOP, g.SB_AIM_LOOP, g.SB_CLASH_LOOP = false, false, false
g.SB_SHOT, g.SB_SHOT_LOOP = false, false          -- Shotgun (6er-Burst) beim Reload aus
g.SB_SHOT_HOOKED, g.SB_SHOT_REQ = false, false    -- Klick-Trigger wird beim Reload neu gelegt
g.SB_SHOT_IDX   = tonumber(g.SB_SHOT_IDX)   or 1  -- Position in der alphabetischen Liste
g.SB_SHOT_IV    = tonumber(g.SB_SHOT_IV)    or 0.02  -- Abstand: 1 Frame, kleinster sinnvoller Wert
g.SB_SHOT_BURST = tonumber(g.SB_SHOT_BURST) or 6     -- Schuesse pro Klick (Rate-Limit!)
if g.SB_SHOT_REEQUIP == nil then g.SB_SHOT_REEQUIP = true end  -- Stab vor jedem Schuss neu ziehen
if g.SB_SHOT_UNIQUE  == nil then g.SB_SHOT_UNIQUE  = true end  -- unique-Spells mitnehmen
g.SB_SNIPE_BUSY = false                           -- Snipe (M) beim Reload nicht "haengend"
g.SB_FARM, g.SB_FARM_LOOP = false, false   -- Autofarm beim Reload aus
g.SB_KD, g.SB_KD_LOOP = false, false       -- KD-Farm beim Reload aus
g.SB_FARM_HOME, g.SB_FARM_TARGET = nil, nil
pcall(function()                            -- evtl. verankertes HRP eines alten Farm-Laufs freigeben
  local h = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
  if h and h.Anchored then h.Anchored = false end
end)
g.SB_CLICK_HOOKED, g.SB_CASTING, g.SB_REFS = false, false, nil
g.SB_PRELOADED, g.SB_LAST_CAST = nil, 0
g.SB_TEAM_ESP, g.SB_ESP_NAMES, g.SB_CHAMS = false, false, false   -- Visuals beim Reload aus
g.SB_STAFF_ESP = false                                            -- Staff-Hervorhebung beim Reload aus
g.SB_STREAMPROOF = false                                          -- Streamproof (alle Visuals blind) beim Reload aus
g.SB_ESP_CONN = nil                                               -- alte Visual-Loop-Referenz loeschen
if g.SB_CONNS then
  for _, c in ipairs(g.SB_CONNS) do pcall(function() c:Disconnect() end) end
end
g.SB_CONNS = {}
-- Shield-Listener bleibt idempotent ueber SB_SHIELD_HOOKED (nicht doppelt legen).

g.SB_AIM_FOV     = g.SB_AIM_FOV     or 140
g.SB_AIM_RANGE   = g.SB_AIM_RANGE   or 500
g.SB_AIM_EXEMPT  = g.SB_AIM_EXEMPT  or {}   -- [Name]=true -> von Silent-Aim ausgenommen
g.SB_AIM_EXEMPT_FACTION = g.SB_AIM_EXEMPT_FACTION or {}  -- [factionId]=true -> ganze Fraktion aus Silent-Aim aus
g.SB_AIM_KEEP = g.SB_AIM_KEEP or {}  -- [Name]=true -> trotz Fraktions-Ausnahme doch anvisieren (Override)
if g.SB_AIM_SKIP_STAFF == nil then g.SB_AIM_SKIP_STAFF = false end  -- Silent-Aim auf Staff (Moderatoren) auslassen
if g.SB_AIM_NPC == nil then g.SB_AIM_NPC = false end  -- Silent-Aim auch auf NPCs
-- Vorhalt (Lead-Prediction): Projektil-Flugzeit einrechnen, dorthin zielen wo das Ziel sein WIRD.
-- Speed wird automatisch aus dem geladenen Spell gelesen (spells.list[name].speed).
if g.SB_AIM_PRED == nil then g.SB_AIM_PRED = true end   -- Vorhalt an/aus
g.SB_AIM_PROJSPEED = g.SB_AIM_PROJSPEED or 250          -- Fallback, falls Spell-Speed unbekannt
g.SB_AIM_DETECTED  = g.SB_AIM_DETECTED  or 0            -- zuletzt automatisch erkannte Speed
g.SB_AIM_DETSPELL  = g.SB_AIM_DETSPELL  or nil          -- Name des erkannten Spells
g.SB_APPA_TARGET = g.SB_APPA_TARGET or nil  -- Name des Apparate-Ziels (Taste T)

-- Legitness-Gate: mit SB_LEGIT% Wahrscheinlichkeit "failt" diese Aktion (return true = auslassen).
-- 0% -> nie, 100% -> immer. Wird an JEDER diskreten Cheat-Aktion abgefragt (Aim/Dodge/Shield/Clash/Cast).
local legitRng = Random.new()
local function legitFail()
  local lg = tonumber(g.SB_LEGIT) or 0
  if lg <= 0 then return false end
  if lg >= 100 then return true end
  return legitRng:NextNumber(0, 100) < lg
end

-- gemeinsame Helper zum Finden der eigenen WandClient-Closures
local function hasConsts(f, need)
  local ok, cs = pcall(debug.getconstants, f); if not ok or type(cs) ~= "table" then return false end
  local s = {}; for _, c in ipairs(cs) do s[c] = true end
  for _, n in ipairs(need) do if not s[n] then return false end end
  return true
end
local function isMine(f)
  local ok, ups = pcall(debug.getupvalues, f); if not ok then return false end
  for _, v in pairs(ups) do
    if typeof(v) == "Instance" and v:IsA("Tool") and (v:IsDescendantOf(lp.Character or lp) or v:IsDescendantOf(lp)) then return true end
  end
  return false
end
local function acquire()
  local setLoadedSpell, fireSpell, state
  for _, f in ipairs(getgc(true)) do
    if type(f) == "function" then
      local ok, info = pcall(debug.getinfo, f)
      if ok and info and type(info.source) == "string" and info.source:find("WandClient") then
        if hasConsts(f, {"canLoadSpell","elderOnly","list"}) and isMine(f) then
          setLoadedSpell = f
          for _, v in pairs(debug.getupvalues(f)) do
            if type(v) == "table" and rawget(v,"casts") ~= nil and (rawget(v,"loadedSpell") ~= nil or rawget(v,"equipped") ~= nil) then state = v end
          end
        end
        if hasConsts(f, {"isClashing","lastCastTime"}) and isMine(f) then fireSpell = f end
      end
    end
  end
  return setLoadedSpell, state, fireSpell
end

--===== server-akzeptierter Cast (wie spellbound_spam: load->fire+localFire) =====--
local okPk,  packets   = pcall(function() return require(RS.packets) end)
local okReg, registry  = pcall(function() return require(RS.shared.modules.spellRegistry) end)
local okSp,  spellsMod = pcall(function() return require(RS.shared.modules.spells) end)
local localFire = RS:FindFirstChild("shared") and RS.shared:FindFirstChild("bridges")
                  and RS.shared.bridges:FindFirstChild("localFireSpell")

-- feuert spell serverseitig echt (nicht nur clientseitig), Ziel = targetPos
local function castReplicated(state, wand, spell, targetPos)
  if not (okPk and packets and okReg and registry and localFire and wand and spell) then return false end
  if okSp and spellsMod and not spellsMod.list[spell] then return false end
  local char   = lp.Character
  local hrp    = char and char:FindFirstChild("HumanoidRootPart")
  local center = wand:FindFirstChild("Center", true)
  if not (hrp and center) then return false end
  if state then state.casts = 0; state.loadedSpell = spell end
  packets.loadSpellReplication.send({ wand = wand, spell = spell, enabled = true })
  local origin = center.WorldPosition
  local target = targetPos or (hrp.Position + hrp.CFrame.LookVector * 100)
  local dir    = (target - origin)
  dir = (dir.Magnitude < 1) and hrp.CFrame.LookVector or dir.Unit
  local guid = Http:GenerateGUID(false)
  registry[guid] = true
  local pkt = {
    wand = wand, spellName = spell, spellId = guid,
    origin = origin, target = target, direction = dir,
    serverTimeAtFire = workspace:GetServerTimeNow(),
  }
  packets.fireSpellReplication.send(pkt)   -- an Server
  pkt.isLocal = true
  localFire:Fire(pkt)                       -- lokales Projektil + Hit-Detection
  return true
end

--========================= Auto-Spell + Combo Loop =========================--
-- Spell-Namen tolerant auf den echten spells.list-Key aufloesen (Leerzeichen/Case)
local function resolveSpell(name)
  if not (okSp and spellsMod and spellsMod.list) then return name end
  if spellsMod.list[name] then return name end
  local low = name:lower()
  local nospace = (low:gsub("%s", ""))
  for k in pairs(spellsMod.list) do
    local kl = k:lower()
    if kl == low or (kl:gsub("%s", "")) == nospace then return k end
  end
  return name
end
-- Safe-Combat-Rotation: pro Slot waehlbar, ueber Reloads erhalten (getgenv)
local DEFAULT_ROT = {
  resolveSpell("deletrius"), resolveSpell("avada kedavra"),
  resolveSpell("sectumsempra"), resolveSpell("defodio"),
}
if type(g.SB_SAFE_ROT) ~= "table" or #g.SB_SAFE_ROT ~= 4 then g.SB_SAFE_ROT = DEFAULT_ROT end
local APPA_NAME = resolveSpell("appa")   -- fuer den "APPA LADEN"-Knopf
g.SB_ROT_IDX = tonumber(g.SB_ROT_IDX) or 1
g.SB_LAST_CAST = g.SB_LAST_CAST or 0

-- Zustands-Checks via CollectionService-Tags (so prueft es die Spiel-Logik intern)
local CS = game:GetService("CollectionService")
local function charHasTag(tag)
  local ch = lp.Character
  return ch ~= nil and CS:HasTag(ch, tag)
end
local function isRagdolled() return charHasTag("Ragdoll") end
local function isStunnedOrBound()
  return charHasTag("stunned") or charHasTag("binded") or charHasTag("immobilized")
end

-- appa als echten Unique-Cast auf eine Zielposition (Packet-Pfad, wie beim Capture)
local function castApparToPos(target)
  if not (okPk and packets and packets.loadSpellReplication and packets.uniqueSpellReplication) then return end
  local mychar = lp.Character
  local myroot = mychar and mychar:FindFirstChild("HumanoidRootPart")
  local wand   = mychar and mychar:FindFirstChildWhichIsA("Tool")
  if not (myroot and wand) then return end
  local origin = myroot.Position
  target = target or (origin + myroot.CFrame.LookVector * 60)
  local guid = Http:GenerateGUID(false)
  if okReg and registry then registry[guid] = true end
  packets.loadSpellReplication.send({ spell = "appa", enabled = true, wand = wand })
  packets.uniqueSpellReplication.send({
    serverTimeAtFire = workspace:GetServerTimeNow(), spellId = guid,
    origin = origin, target = target, spellName = "appa", wand = wand,
  })
end

-- feuert den aktuellen Rotations-Slot. instant=true -> schon vorgeladen, kein Load/Wait.
local function fireSafeSlot(instant)
  local refs = g.SB_REFS
  if not (refs and refs.set and refs.state and refs.fire) then return end
  if isStunnedOrBound() then return end            -- kein Equip/Cast wenn stunned/bound
  if legitFail() then return end                   -- Legitness: Cast manchmal verschlucken (Whiff)
  local set, state, fire = refs.set, refs.state, refs.fire
  local u13 = g.SB_MOUSE
  local target = u13 and u13.Hit and u13.Hit.Position
  local ROT = g.SB_SAFE_ROT
  local idx = g.SB_ROT_IDX
  local spell = ROT[idx] or ROT[1]
  if not instant then
    state.casts = 0
    set(spell, true)
    task.wait(0.07)                                -- Server den Load registrieren lassen
  end
  if state.loadedSpell == spell then
    state.casts = 0
    pcall(fire, target)
    g.SB_CASTS = (tonumber(g.SB_CASTS) or 0) + 1
    g.SB_LOADED = spell
  end
  g.SB_PRELOADED = nil
  g.SB_LAST_CAST = os.clock()
  g.SB_ROT_IDX = (idx % #ROT) + 1                  -- IMMER weiterrotieren (kein Haengenbleiben)
end

-- ECHTE Mausposition per Kamera-Raycast (unabhaengig vom Silent-Aim-Override auf u13.Hit).
-- Appa soll NIE auto/silent-aimen -> immer dorthin wo der Cursor wirklich zeigt.
local function realMouseHit()
  local cam = workspace.CurrentCamera
  if not cam then return nil end
  local ml = UIS:GetMouseLocation()
  local ray = cam:ScreenPointToRay(ml.X, ml.Y)
  local params = RaycastParams.new()
  params.FilterType = Enum.RaycastFilterType.Exclude
  params.FilterDescendantsInstances = { lp.Character }
  local res = workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
  if res then return res.Position end
  return ray.Origin + ray.Direction * 300         -- Fallback: Punkt entlang des Strahls
end

-- Ein Klick = aktuellen Spell casten (vorgeladen -> sofort, sonst load+wait)
local function castCurrent()
  if g.SB_APPA_PENDING then                        -- appa hat Vorrang, danach NICHTS nachladen
    castApparToPos(realMouseHit())                 -- echte Maus, kein Silent-Aim
    g.SB_APPA_PENDING = false; g.SB_LAST_CAST = os.clock(); return
  end
  if not g.SB_SAFE then return end
  fireSafeSlot(g.SB_PRELOADED ~= nil)
end

local function startSelector()
  -- Klick-Caster EINMALIG verbinden (liest Refs live aus g.SB_REFS)
  if not g.SB_CLICK_HOOKED then
    g.SB_CLICK_HOOKED = true
    table.insert(g.SB_CONNS, UIS.InputBegan:Connect(function(i, gp)
      if gp then return end                                   -- Klick auf GUI ignorieren
      if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
      if not (g.SB_SAFE or g.SB_APPA_PENDING) then return end
      if g.SB_CASTING then return end                         -- kein Ueberlappen
      g.SB_CASTING = true
      task.spawn(function() pcall(castCurrent); g.SB_CASTING = false end)
    end))
  end
  -- Hintergrund-Acquirer: haelt g.SB_REFS/g.SB_MOUSE aktuell (gedrosselt, kein per-Klick getgc)
  if g.SB_CURSE_LOOP then return end
  g.SB_CURSE_LOOP = true
  task.spawn(function()
    local nextAcquire = 0
    while g.SB_SAFE or g.SB_AIM or g.SB_APPA_PENDING or g.SB_FARM do
      pcall(function()
        if not g.SB_MOUSE then
          local okM, pm = pcall(function() return require(RS.shared.modules.PlayerMouse) end)
          g.SB_MOUSE = okM and pm and pm:GetMouse() or nil
        end
        local char = lp.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local wand = char and char:FindFirstChildWhichIsA("Tool")
        if not (char and hum and hum.Health > 0 and wand) then
          g.SB_REFS = nil; g.SB_STATUS = "keine Wand in der Hand"; return
        end
        local refs = g.SB_REFS
        if not (refs and refs.state and refs.state.equipped) then
          if os.clock() < nextAcquire then g.SB_STATUS = "warte auf Wand..."; return end
          nextAcquire = os.clock() + 1.5
          local set, st, fire = acquire()
          if set and st and st.equipped and fire then
            g.SB_REFS = { set = set, state = st, fire = fire }
          else g.SB_STATUS = "lade Wand..."; return end
          refs = g.SB_REFS
        end
        g.SB_STATUS = nil
        -- Vor-Equip: nach 0.4s ohne Cast den aktuellen Slot schon laden (naechster Klick feuert sofort)
        if g.SB_SAFE and not g.SB_FARM and not g.SB_APPA_PENDING and not g.SB_CASTING and not g.SB_PRELOADED
           and os.clock() >= (g.SB_APPA_LOCK or 0)
           and refs and refs.set and refs.state and not isStunnedOrBound() then
          if (os.clock() - (g.SB_LAST_CAST or 0)) >= 0.4 then
            local spell = g.SB_SAFE_ROT[g.SB_ROT_IDX] or g.SB_SAFE_ROT[1]
            refs.state.casts = 0
            refs.set(spell, true)
            if refs.state.loadedSpell == spell then g.SB_PRELOADED = spell end
          end
        end
      end)
      task.wait(0.1)
    end
    g.SB_CURSE_LOOP = false
    g.SB_STATUS = nil
  end)
end

-- Entwaffnet den evtl. vorgeladenen Kampf-Spell SOFORT, damit ein Appa-Klick nicht
-- gleichzeitig einen Spell nativ mitfeuert (nichts geladen -> Klick feuert keinen Spell).
local function disarmSpell()
  g.SB_PRELOADED = nil
  local refs = g.SB_REFS
  if refs and refs.state then
    refs.state.loadedSpell = nil   -- nichts geladen
    refs.state.casts = 1           -- Cooldown "aktiv" als zusaetzliche Sperre
  end
end

--========================= Fraktionen (Team-Zugehoerigkeit) =========================--
-- Jeder Spieler traegt das Attribut "CurrentFactionId" (Roblox-Gruppen-ID). factionConfig
-- listet die gueltigen Fraktionen (Farbe/Bild); die Klarnamen kommen aus GroupService.
-- Aus dem Spiel geprueft: 553013368 = Covenant of Death Eaters, 967983905 = Ministry of
-- Magic, 690294439 = Order of the Phoenix. factionConfig enthaelt genau diese 3.
local okFC, factionConfig = pcall(function() return require(RS.shared.modules.factionConfig) end)
if not okFC then factionConfig = nil end
local FACTION_FALLBACK = {
  [553013368] = "Covenant of Death Eaters",
  [967983905] = "Ministry of Magic",
  [690294439] = "Order of the Phoenix",
}
-- WICHTIG: factionConfig ist mit STRING-Keys ("553013368") indiziert, das Spieler-Attribut
-- CurrentFactionId ist aber eine ZAHL -> auf numerische Keys normalisieren, sonst schlaegt
-- der Farb-Lookup fehl (alles wurde grau). FACTION_COLOR: [numId] = Color3.
local FACTION_COLOR = {}
if factionConfig then
  for k, v in pairs(factionConfig) do
    local nk = tonumber(k)
    if nk and type(v) == "table" and typeof(v.color) == "Color3" then FACTION_COLOR[nk] = v.color end
  end
end
if not next(FACTION_COLOR) then   -- Fallback, falls factionConfig fehlt: wenigstens die IDs kennen
  for id in pairs(FACTION_FALLBACK) do FACTION_COLOR[id] = Color3.fromRGB(200, 200, 210) end
end
g.SB_FACTION_NAMES = g.SB_FACTION_NAMES or {}   -- id -> aufgeloester Name (Cache)
local function factionIds()
  local ids = {}
  for id in pairs(FACTION_COLOR) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end
local function factionColor(id)
  return (id and FACTION_COLOR[id]) or Color3.fromRGB(200, 200, 210)
end
local function factionName(id)
  if not id then return nil end
  local cached = g.SB_FACTION_NAMES[id]
  if cached then return cached end
  -- sofort Fallback setzen (verhindert Doppel-Requests), Name async via GroupService verfeinern
  g.SB_FACTION_NAMES[id] = FACTION_FALLBACK[id] or ("Fraktion " .. tostring(id))
  task.spawn(function()
    local ok, info = pcall(function() return game:GetService("GroupService"):GetGroupInfoAsync(id) end)
    if ok and info and type(info.Name) == "string" then
      g.SB_FACTION_NAMES[id] = (info.Name:gsub("^%s*%[%w+%]%s*", ""))   -- "[MB] "-Gruppentag strippen
    end
  end)
  return g.SB_FACTION_NAMES[id]
end
local function playerFactionId(pl)
  return pl and tonumber(pl:GetAttribute("CurrentFactionId")) or nil
end
-- Staff-Erkennung: das Spiel setzt bei Moderatoren das Attribut IsModerator=true.
local function isStaff(pl)
  return pl and pl:GetAttribute("IsModerator") == true
end

--========================= Freunde (Ausnahmen, ueberleben den Rejoin) =========================--
-- Freunde werden von Silent-Aim UND Autofarm komplett ausgelassen.
-- getgenv() ist nach einem Rejoin weg, deshalb liegt die Liste zusaetzlich als JSON im
-- Executor-Workspace. Gespeichert wird per UserId (Namen koennen sich aendern).
local FRIENDS_FILE = "spellbound_friends.json"
g.SB_FRIENDS   = g.SB_FRIENDS   or {}   -- [tostring(UserId)] = Anzeigename
g.SB_RBXFRIEND = g.SB_RBXFRIEND or {}   -- Cache fuer IsFriendsWith (pro UserId)
if g.SB_FRIEND_AUTO == nil then g.SB_FRIEND_AUTO = false end   -- echte Roblox-Freunde mitzaehlen

local function saveFriends()
  return pcall(function()
    writefile(FRIENDS_FILE, Http:JSONEncode({ auto = g.SB_FRIEND_AUTO == true, list = g.SB_FRIENDS }))
  end)
end
local function loadFriends()
  local ok, data = pcall(function()
    if isfile and isfile(FRIENDS_FILE) then return Http:JSONDecode(readfile(FRIENDS_FILE)) end
    return nil
  end)
  if ok and type(data) == "table" then
    if type(data.list) == "table" then g.SB_FRIENDS = data.list end
    if data.auto ~= nil then g.SB_FRIEND_AUTO = data.auto == true end
  end
end
if not g.SB_FRIENDS_LOADED then loadFriends(); g.SB_FRIENDS_LOADED = true end

-- Wird pro Frame im Aim-Loop abgefragt -> IsFriendsWith nur einmal pro UserId.
local function isFriend(pl)
  if not pl then return false end
  if g.SB_FRIENDS[tostring(pl.UserId)] then return true end
  if g.SB_FRIEND_AUTO then
    local c = g.SB_RBXFRIEND[pl.UserId]
    if c == nil then
      local ok, res = pcall(function() return lp:IsFriendsWith(pl.UserId) end)
      c = (ok and res) and true or false
      g.SB_RBXFRIEND[pl.UserId] = c
    end
    return c
  end
  return false
end
local function toggleFriend(pl)
  local k = tostring(pl.UserId)
  if g.SB_FRIENDS[k] then g.SB_FRIENDS[k] = nil else g.SB_FRIENDS[k] = pl.Name end
  saveFriends()
end
local function friendCount()
  local n = 0
  for _ in pairs(g.SB_FRIENDS) do n = n + 1 end
  return n
end

--========================= Auto-Leave bei Staff =========================--
-- Moderator im Server -> alle Module aus und raus: entweder zurueck ins Menue (Kick mit
-- neutraler Meldung, nichts das nach Cheat aussieht) oder direkt auf einen neuen Server.
-- Einmal-Guard, damit nicht mehrere Staff-Joins gleichzeitig feuern.
if g.SB_STAFF_LEAVE == nil then g.SB_STAFF_LEAVE = false end   -- Auto-Leave an/aus
if g.SB_STAFF_HOP   == nil then g.SB_STAFF_HOP   = false end   -- Server-Hop statt Menue
g.SB_STAFF_PANICKED = false                                    -- Guard beim Reload zuruecksetzen
local function staffPanic(who)
  if not g.SB_STAFF_LEAVE or g.SB_STAFF_PANICKED then return end
  g.SB_STAFF_PANICKED = true
  g.SB_LEAVE_REASON = tostring(who)
  -- erst alles abschalten (falls der Leave scheitert, laeuft nichts weiter)
  g.SB_AIM, g.SB_SAFE, g.SB_SHIELD, g.SB_CLASH, g.SB_DODGE = false, false, false, false, false
  g.SB_FARM, g.SB_APPA_PENDING = false, false
  task.spawn(function()
    if g.SB_STAFF_HOP then
      local ok = pcall(function() game:GetService("TeleportService"):Teleport(game.PlaceId, lp) end)
      if ok then return end                       -- Hop laeuft; sonst faellt es auf Leave zurueck
    end
    pcall(function() lp:Kick("Verbindung unterbrochen.") end)
  end)
end
-- Prueft alle bereits anwesenden Spieler (z.B. direkt beim Einschalten der Option).
local function staffScan()
  if not g.SB_STAFF_LEAVE then return end
  for _, pl in ipairs(Players:GetPlayers()) do
    if pl ~= lp and isStaff(pl) then staffPanic(pl.Name); return true end
  end
  return false
end

--========================= Aim-Helfer (geteilt: Silent-Aim + Autofarm) =========================--
-- Projektilgeschwindigkeit des AKTUELL geladenen Spells automatisch ablesen.
local function spellSpeed()
  local refs   = g.SB_REFS
  local loaded = refs and refs.state and refs.state.loadedSpell
  local slist  = (okSp and spellsMod and spellsMod.list) or nil
  if loaded and slist and slist[loaded] and tonumber(slist[loaded].speed) then
    g.SB_AIM_DETECTED, g.SB_AIM_DETSPELL = tonumber(slist[loaded].speed), loaded
    return tonumber(slist[loaded].speed)
  end
  return tonumber(g.SB_AIM_PROJSPEED) or 250   -- Fallback wenn nichts geladen / kein Speed-Feld
end
-- Vorhalt: loese iterativ wo das Ziel bei Projektil-Ankunft ist (pos + vel * flugzeit)
local function leadPos(origin, pos, vel, speed)
  if not speed or speed <= 0 or not vel then return pos end
  local t = (pos - origin).Magnitude / speed
  for _ = 1, 4 do
    local p = pos + vel * t
    t = (p - origin).Magnitude / speed
  end
  return pos + vel * t
end
-- Zielpunkt inkl. Vorhalt fuer ein Ziel-Root. Sprung/Fall: vertikalen Anteil rauslassen
-- (sonst zielt der Vorhalt zu weit hoch), horizontaler Vorhalt bleibt.
local function aimPointFor(origin, root, hum, speed)
  local vel = root.AssemblyLinearVelocity
  if hum then
    local ok, st = pcall(function() return hum:GetState() end)
    if ok and (st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.Freefall) then
      vel = Vector3.new(vel.X, 0, vel.Z)
    end
  end
  return leadPos(origin, root.Position, vel, speed)
end

--========================= Trefferzone (nicht immer der Torso) =========================--
-- Silent-Aim zielte bisher immer auf HumanoidRootPart, also exakt Brustmitte - das sieht in
-- Aufnahmen sofort nach Bot aus. Jetzt wird pro Ziel eine Koerperzone gewichtet gewuerfelt
-- (Torso oft, Kopf/Gliedmassen seltener), dazu ein Zufalls-Offset innerhalb des Teils, und
-- die Wahl bleibt SB_AIM_ZONEROLL Sekunden stehen (sonst zappelt der Zielpunkt pro Frame).
-- Funktioniert fuer R15 und R6: es werden nur real vorhandene Teile gezogen.
if g.SB_AIM_ZONES == nil then g.SB_AIM_ZONES = true end
g.SB_AIM_ZONEROLL = tonumber(g.SB_AIM_ZONEROLL) or 1.2
g.SB_AIM_ZONE = {}                                  -- [Charaktername] = { part, off, expires }
local AIM_ZONES = {
  { "HumanoidRootPart", 24 }, { "UpperTorso", 20 }, { "Torso", 20 }, { "LowerTorso", 14 },
  { "Head", 12 }, { "LeftUpperArm", 5 }, { "RightUpperArm", 5 }, { "Left Arm", 5 }, { "Right Arm", 5 },
  { "LeftUpperLeg", 4 }, { "RightUpperLeg", 4 }, { "Left Leg", 4 }, { "Right Leg", 4 },
}
local zoneRng = Random.new()
local function aimZone(char, root)
  if not g.SB_AIM_ZONES or not char then return root, Vector3.zero end
  local z = g.SB_AIM_ZONE[char.Name]
  if z and z.expires > os.clock() and z.part and z.part.Parent then return z.part, z.off end
  local pool, total = {}, 0
  for _, e in ipairs(AIM_ZONES) do
    local part = char:FindFirstChild(e[1])
    if part and part:IsA("BasePart") then total = total + e[2]; pool[#pool + 1] = { part, total } end
  end
  if total <= 0 then return root, Vector3.zero end
  local roll = zoneRng:NextNumber(0, total)
  local pick = pool[#pool][1]
  for _, e in ipairs(pool) do if roll <= e[2] then pick = e[1]; break end end
  local half = pick.Size * 0.35                     -- nie exakt der Mittelpunkt
  local off = Vector3.new(zoneRng:NextNumber(-half.X, half.X),
                          zoneRng:NextNumber(-half.Y, half.Y),
                          zoneRng:NextNumber(-half.Z, half.Z))
  g.SB_AIM_ZONE[char.Name] = { part = pick, off = off,
                               expires = os.clock() + (tonumber(g.SB_AIM_ZONEROLL) or 1.2) }
  return pick, off
end

--========================= Silent-Aim (Auto-Hit) =========================--
local function startAim()
  if g.SB_AIM_LOOP then return end
  g.SB_AIM_LOOP = true
  local okM, pm = pcall(function() return require(RS.shared.modules.PlayerMouse) end)
  if not (okM and pm) then g.SB_AIM_LOOP = false; return end
  local u13 = pm:GetMouse()
  local aimConn = RunService.RenderStepped:Connect(function()
    if not g.SB_AIM then rawset(u13, "Hit", nil); return end
    -- Legitness: fuer kurze Fenster (~0.2s) den Aim ganz aussetzen -> so viel % der Shots gehen daneben
    if os.clock() >= (g.SB_LEGIT_AIMNEXT or 0) then
      g.SB_LEGIT_AIMOFF = legitFail()
      g.SB_LEGIT_AIMNEXT = os.clock() + 0.2
    end
    if g.SB_LEGIT_AIMOFF then rawset(u13, "Hit", nil); g.SB_AIM_TARGET = nil; return end
    local cam = workspace.CurrentCamera
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (cam and myHRP) then rawset(u13, "Hit", nil); return end
    local mp = UIS:GetMouseLocation()
    local origin = myHRP.Position
    local speed = g.SB_AIM_PRED and spellSpeed() or 0
    local bestH, bestHum, bestScreen, bestName, bestChar
    local function consider(char, name)
      if not char or (g.SB_AIM_EXEMPT and g.SB_AIM_EXEMPT[name]) then return end
      local h  = char:FindFirstChild("HumanoidRootPart")
      local hu = char:FindFirstChildOfClass("Humanoid")
      if not (h and hu and hu.Health > 0) then return end
      local sp, onScreen = cam:WorldToViewportPoint(h.Position)
      if not (onScreen and sp.Z > 0) then return end
      local sd = (Vector2.new(sp.X, sp.Y) - Vector2.new(mp.X, mp.Y)).Magnitude
      local wd = (h.Position - origin).Magnitude
      if sd <= g.SB_AIM_FOV and wd <= g.SB_AIM_RANGE and (not bestScreen or sd < bestScreen) then
        bestH, bestHum, bestScreen, bestName, bestChar = h, hu, sd, name, char
      end
    end
    for _, pl in ipairs(Players:GetPlayers()) do
      if pl ~= lp then
        local fid = playerFactionId(pl)
        -- Fraktion ausgenommen? -> ueberspringen, ausser der Spieler steht in der Keep-Target-Liste
        local facExempt = fid and g.SB_AIM_EXEMPT_FACTION[fid] and not g.SB_AIM_KEEP[pl.Name]
        -- Staff ausgenommen? (Moderatoren) -> ueberspringen, Keep-Target hebt es ebenfalls auf
        local staffExempt = g.SB_AIM_SKIP_STAFF and isStaff(pl) and not g.SB_AIM_KEEP[pl.Name]
        -- Freunde (eigene Liste / echte Roblox-Freunde) werden nie anvisiert
        if not facExempt and not staffExempt and not isFriend(pl) then consider(pl.Character, pl.Name) end
      end
    end
    -- NPCs (Workspace.Terrain.characters) nur wenn NPC-Aim aktiv
    if g.SB_AIM_NPC then
      local terr = workspace:FindFirstChild("Terrain")
      local folder = terr and terr:FindFirstChild("characters")
      if folder then
        for _, m in ipairs(folder:GetChildren()) do
          if m ~= lp.Character and m:IsA("Model") then consider(m, m.Name) end
        end
      end
    end
    if bestH then
      local zonePart, zoneOff = aimZone(bestChar, bestH)     -- mal Kopf, mal Arm, mal Torso
      local aimPos = aimPointFor(origin, zonePart, bestHum, speed) + zoneOff
      rawset(u13, "Hit", CFrame.new(aimPos)); g.SB_AIM_TARGET = bestName
    else rawset(u13, "Hit", nil); g.SB_AIM_TARGET = nil end
  end)
  table.insert(g.SB_CONNS, aimConn)
end

--========================= Visuals: Box-ESP / Namen / Chams =========================--
-- Drei unabhaengige Layer pro Spieler, alle in Fraktionsfarbe (Silent-Aim-Ziel = lila):
--   Box-ESP  (g.SB_TEAM_ESP): 2D-Box um den Spieler.
--   Namen    (g.SB_ESP_NAMES): Name ueber dem Kopf (getrennt von der Box schaltbar).
--   Chams    (g.SB_CHAMS):     Highlight-Fuellung, DepthMode=Occluded -> nur sichtbare Teile.
local ESP_PURPLE = Color3.fromRGB(180, 70, 230)
local STAFF_BLUE = Color3.fromRGB(45, 155, 255)   -- helles Blau fuer Staff-Highlight + "Moderator"-Label
local function startVisuals()
  if g.SB_ESP_CONN then return end
  local parent
  local ok, h = pcall(function() return gethui and gethui() end)
  if ok and typeof(h) == "Instance" then parent = h end
  if not parent then local ok2, c = pcall(function() return game:GetService("CoreGui") end); if ok2 then parent = c end end
  if not parent then parent = lp:WaitForChild("PlayerGui") end
  local old = parent:FindFirstChild("SB_TeamESP"); if old then old:Destroy() end
  local espGui = Instance.new("ScreenGui")
  espGui.Name = "SB_TeamESP"; espGui.ResetOnSpawn = false
  espGui.IgnoreGuiInset = true; espGui.DisplayOrder = 500
  espGui.Enabled = not g.SB_STREAMPROOF          -- respektiert einen aktiven Streamproof-Modus
  espGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; espGui.Parent = parent

  local objs = {}   -- [player] = { box, stroke, nm, hl }
  local function destroyObj(o)
    pcall(function() o.box:Destroy() end)
    pcall(function() if o.nm then o.nm:Destroy() end end)
    pcall(function() if o.sub then o.sub:Destroy() end end)
    pcall(function() if o.hl then o.hl:Destroy() end end)
    pcall(function() if o.shl then o.shl:Destroy() end end)
  end
  local function clearAll() for _, o in pairs(objs) do destroyObj(o) end; objs = {} end
  -- 2D-Bildschirm-Bounding-Box aus den 8 Ecken der Character-BoundingBox
  local function screenBox(char)
    local cam = workspace.CurrentCamera; if not cam then return nil end
    local cf, size = char:GetBoundingBox()
    local sx, sy, sz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
    local minX, minY, maxX, maxY, front = math.huge, math.huge, -math.huge, -math.huge, false
    local corners = { {sx,sy,sz},{-sx,sy,sz},{sx,-sy,sz},{-sx,-sy,sz},{sx,sy,-sz},{-sx,sy,-sz},{sx,-sy,-sz},{-sx,-sy,-sz} }
    for _, c in ipairs(corners) do
      local wp = (cf * CFrame.new(c[1], c[2], c[3])).Position
      local sp = cam:WorldToViewportPoint(wp)
      if sp.Z > 0 then
        front = true
        if sp.X < minX then minX = sp.X end
        if sp.Y < minY then minY = sp.Y end
        if sp.X > maxX then maxX = sp.X end
        if sp.Y > maxY then maxY = sp.Y end
      end
    end
    if not front then return nil end
    return minX, minY, maxX, maxY
  end

  g.SB_ESP_CONN = RunService.Heartbeat:Connect(function()
    local anyLayer = g.SB_TEAM_ESP or g.SB_ESP_NAMES or g.SB_CHAMS or g.SB_STAFF_ESP
    if not anyLayer then if next(objs) then clearAll() end; return end
    local needScreen = g.SB_TEAM_ESP or g.SB_ESP_NAMES
    for _, pl in ipairs(Players:GetPlayers()) do
      if pl ~= lp then
        local char = pl.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local alive = char and hrp and hum and hum.Health > 0
        local o = objs[pl]
        if not o then
          local box = Instance.new("Frame")
          box.Name = "Box"; box.BackgroundTransparency = 1; box.BorderSizePixel = 0; box.Visible = false; box.Parent = espGui
          local stroke = Instance.new("UIStroke", box); stroke.Thickness = 1.6
          stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
          local nm = Instance.new("TextLabel")
          nm.Name = "Nm"; nm.BackgroundTransparency = 1; nm.Font = Enum.Font.GothamBold
          nm.TextSize = 13; nm.TextStrokeTransparency = 0.4; nm.TextStrokeColor3 = Color3.new(0, 0, 0)
          nm.Size = UDim2.fromOffset(220, 15); nm.Visible = false; nm.Parent = espGui
          -- Zweite Zeile unter dem Namen: "Moderator" (nur bei Staff), hellblau
          local sub = Instance.new("TextLabel")
          sub.Name = "Sub"; sub.BackgroundTransparency = 1; sub.Font = Enum.Font.GothamBold
          sub.TextSize = 12; sub.TextStrokeTransparency = 0.4; sub.TextStrokeColor3 = Color3.new(0, 0, 0)
          sub.Size = UDim2.fromOffset(220, 14); sub.Visible = false; sub.Parent = espGui
          o = { box = box, stroke = stroke, nm = nm, sub = sub, hl = nil, shl = nil }
          objs[pl] = o
        end
        -- Farbe: Silent-Aim-Ziel = lila. Staff ohne Fraktion = standardmaessig hellblau
        -- (statt grauer Fallback). Sonst Fraktionsfarbe.
        local pfid = playerFactionId(pl)
        local col
        if g.SB_AIM_TARGET == pl.Name then
          col = ESP_PURPLE
        elseif isStaff(pl) and not pfid then
          col = STAFF_BLUE
        else
          col = factionColor(pfid)
        end
        -- Chams (Highlight, nur sichtbare Teile)
        if g.SB_CHAMS and alive then
          if not o.hl or not o.hl.Parent then
            o.hl = Instance.new("Highlight")
            o.hl.DepthMode = Enum.HighlightDepthMode.Occluded   -- "visible only"
            o.hl.FillTransparency = 0.5; o.hl.OutlineTransparency = 0
            o.hl.Parent = espGui
          end
          o.hl.Adornee = char
          o.hl.FillColor = col; o.hl.OutlineColor = col
          o.hl.Enabled = true
        elseif o.hl then o.hl.Enabled = false end
        -- Staff-Highlight (immer hellblau, durch Waende sichtbar -> man sieht sofort einen Mod)
        if g.SB_STAFF_ESP and alive and isStaff(pl) then
          if not o.shl or not o.shl.Parent then
            o.shl = Instance.new("Highlight")
            o.shl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            o.shl.FillTransparency = 0.6; o.shl.OutlineTransparency = 0
            o.shl.Parent = espGui
          end
          o.shl.Adornee = char
          o.shl.FillColor = STAFF_BLUE; o.shl.OutlineColor = STAFF_BLUE
          o.shl.Enabled = true
        elseif o.shl then o.shl.Enabled = false end
        -- Box + Namen (brauchen Screen-Projektion)
        local minX, minY, maxX, maxY
        if needScreen and alive then minX, minY, maxX, maxY = screenBox(char) end
        if minX then
          local w, ht = maxX - minX, maxY - minY
          if g.SB_TEAM_ESP then
            o.box.Position = UDim2.fromOffset(minX, minY); o.box.Size = UDim2.fromOffset(w, ht)
            o.stroke.Color = col; o.box.Visible = true
          else o.box.Visible = false end
          if g.SB_ESP_NAMES then
            o.nm.Text = pl.Name; o.nm.TextColor3 = col
            o.nm.Position = UDim2.fromOffset(minX + w * 0.5 - 110, minY - 16)
            o.nm.Visible = true
            -- "Moderator" direkt unter dem Namen, hellblau (nur bei Staff)
            if isStaff(pl) then
              o.sub.Text = "Moderator"; o.sub.TextColor3 = STAFF_BLUE
              o.sub.Position = UDim2.fromOffset(minX + w * 0.5 - 110, minY - 3)
              o.sub.Visible = true
            else o.sub.Visible = false end
          else o.nm.Visible = false; o.sub.Visible = false end
        else
          o.box.Visible = false; o.nm.Visible = false; o.sub.Visible = false
        end
      end
    end
    for pl, o in pairs(objs) do
      if not pl.Parent then destroyObj(o); objs[pl] = nil end
    end
  end)
  table.insert(g.SB_CONNS, g.SB_ESP_CONN)
end

--========================= Reaktives Auto-Protego =========================--
local function hookShield()
  if g.SB_SHIELD_HOOKED then return end
  local okP, packets = pcall(function() return require(RS.packets) end)
  local okS, spells  = pcall(function() return require(RS.shared.modules.spells) end)
  if not (okP and okS and packets and spells) then return end
  g.SB_SHIELD_HOOKED = true
  packets.fireSpellReplication.listen(function(pl)
    if not g.SB_SHIELD then return end
    if lp:GetAttribute("Client_IsClashing") == true then return end   -- waehrend Clash kein Shield
    if isRagdolled() then return end                                  -- kein Shield wenn ragdollt
    local wand = pl and pl.wand; if not wand then return end
    local cc = wand:FindFirstAncestorWhichIsA("Model"); if not cc then return end
    if Players:GetPlayerFromCharacter(cc) == lp then return end
    local sd = spells.list[pl.spellName]; if not (sd and sd.hostile) then return end
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not myHRP then return end
    local me = myHRP.Position
    local speed = sd.speed or 300
    local originDist = pl.origin and (pl.origin - me).Magnitude or 9999
    if originDist > speed * 1.8 then return end
    local threatened = false
    if pl.target and (pl.target - me).Magnitude <= 16 then threatened = true end
    if not threatened and pl.origin and pl.direction then
      local o, d = pl.origin, pl.direction
      local t = (me - o):Dot(d)
      if t > 0 and t <= (sd.distance or 500) and ((o + d * t) - me).Magnitude <= 10 then threatened = true end
    end
    if not threatened then return end
    if lp:GetAttribute("ProtegoActive") == true then return end
    local cd = tonumber(lp:GetAttribute("ProtegoCooldownFinishTime"))
    if cd and cd >= workspace:GetServerTimeNow() then return end
    if legitFail() then return end                            -- Legitness: Schild manchmal nicht poppen
    pcall(function() packets.protego.send() end)
    g.SB_SHIELD_POPS = (tonumber(g.SB_SHIELD_POPS) or 0) + 1
  end)
end

--========================= Reaktiver Auto-Dodge (ROLL) =========================--
-- Gleiche Bedrohungserkennung wie Auto-Shield: prueft ob ein eingehender feindlicher
-- Cast uns treffen wird. Der Dash haengt in Spellbound auf LeftControl (bindAction
-- "Dash", Enum.KeyCode.LeftControl) -> ein kurzer Tap (<0.5s, moving) loest den ROLL
-- aus. Wir tippen LeftControl nativ (keypress) an, damit der echte Dash-Handler laeuft
-- (inkl. Bewegung/iFrames, respektiert den Client-Cooldown wie beim manuellen Spielen).
-- Der Dodge feuert NUR wenn das Schild die Bedrohung nicht abfaengt (Shield aus oder
-- gerade auf Cooldown). Der %-Slider drosselt gleichmaessig: 66.6% -> dodge,dodge,skip.
local function threatenedByCast(pl)
  if not (okSp and spellsMod and spellsMod.list) then return false end
  local wand = pl and pl.wand; if not wand then return false end
  local cc = wand:FindFirstAncestorWhichIsA("Model"); if not cc then return false end
  if Players:GetPlayerFromCharacter(cc) == lp then return false end     -- nicht die eigenen Casts
  local sd = spellsMod.list[pl.spellName]; if not (sd and sd.hostile) then return false end
  local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
  if not myHRP then return false end
  local me = myHRP.Position
  local speed = sd.speed or 300
  local originDist = pl.origin and (pl.origin - me).Magnitude or 9999
  if originDist > speed * 1.8 then return false end                     -- zu weit -> keine akute Gefahr
  if pl.target and (pl.target - me).Magnitude <= 16 then return true end
  if pl.origin and pl.direction then
    local o, d = pl.origin, pl.direction
    local t = (me - o):Dot(d)
    if t > 0 and t <= (sd.distance or 500) and ((o + d * t) - me).Magnitude <= 10 then return true end
  end
  return false
end

local function hookDodge()
  if g.SB_DODGE_HOOKED then return end
  local okP, packets = pcall(function() return require(RS.packets) end)
  if not (okP and packets and packets.fireSpellReplication) then return end
  g.SB_DODGE_HOOKED = true
  packets.fireSpellReplication.listen(function(pl)
    if not g.SB_DODGE then return end
    if lp:GetAttribute("Client_IsClashing") == true then return end     -- waehrend Clash kein Dodge
    if isRagdolled() then return end                                    -- ragdollt -> kein Dash moeglich
    if not threatenedByCast(pl) then return end
    -- Nur wenn das Schild NICHT bereit ist (aus oder auf Cooldown) -> sonst blockt das Schild
    local shieldReady = g.SB_SHIELD and lp:GetAttribute("ProtegoActive") ~= true
    if shieldReady then
      local cd = tonumber(lp:GetAttribute("ProtegoCooldownFinishTime"))
      if not (cd and cd >= workspace:GetServerTimeNow()) then return end -- Schild ready -> uebernimmt
    end
    if legitFail() then return end                                      -- Legitness: Dodge manchmal auslassen
    -- Ausweichrichtung = 90° zum Spell-Vektor, auf die Seite die uns AUS der Flugbahn zieht
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if not (hrp and hum) then return end
    local me = hrp.Position
    local dodgeDir
    local d = pl.direction
    local dh = d and Vector3.new(d.X, 0, d.Z)
    if dh and dh.Magnitude > 1e-3 then
      dh = dh.Unit
      local perp = Vector3.new(-dh.Z, 0, dh.X)                           -- exakt 90° zum Spell-Vektor
      if pl.origin then                                                 -- Seite waehlen, die uns wegzieht
        local foot = pl.origin + dh * (me - pl.origin):Dot(dh)
        local away = me - foot; away = Vector3.new(away.X, 0, away.Z)
        if away.Magnitude > 1e-3 and away.Unit:Dot(perp) < 0 then perp = -perp end
      end
      dodgeDir = perp
    elseif pl.target then
      local away = me - pl.target; away = Vector3.new(away.X, 0, away.Z)
      if away.Magnitude > 1e-3 then dodgeDir = away.Unit end
    end
    if not dodgeDir then return end
    -- Mindestabstand zwischen zwei Dodges (kein Gehaemmer bei Burst)
    local now = os.clock()
    if now - (tonumber(g.SB_DODGE_LAST) or 0) < 0.25 then return end
    -- Prozent-Gate (skip-Akkumulator): bei 66.6% -> dodge,dodge,skip,dodge,dodge,skip...
    local pct = tonumber(g.SB_DODGE_PCT) or 100
    if pct <= 0 then return end
    if pct < 100 then
      local skipRate = (100 - pct) / 100
      g.SB_DODGE_SKIPACC = (tonumber(g.SB_DODGE_SKIPACC) or 0) + skipRate
      if g.SB_DODGE_SKIPACC >= 1 then
        g.SB_DODGE_SKIPACC = g.SB_DODGE_SKIPACC - 1
        return                                                          -- diesen dodge auslassen
      end
    end
    g.SB_DODGE_LAST = now
    -- ROLL echt via LeftControl-Tap, aber die BEWEGUNGSrichtung senkrecht zum Spell steuern
    -- (Humanoid:Move) -> die Engine dreht dich (AutoRotate) und rollt dich aus der Flugbahn.
    task.spawn(function()
      local endT = os.clock() + 0.4
      pcall(function() hum:Move(dodgeDir, false) end)                   -- erst senkrecht bewegen...
      task.wait(0.03)
      pcall(keypress, 0xA2)                                             -- ...dann ROLL antippen
      task.wait(0.06)
      pcall(keyrelease, 0xA2)   -- Tap<0.5s -> ROLL nimmt MoveDirection = senkrecht zum Spell
      while os.clock() < endT do
        pcall(function() hum:Move(dodgeDir, false) end)                 -- Richtung ueber den Dash halten
        RunService.Heartbeat:Wait()
      end
    end)
    g.SB_DODGE_POPS = (tonumber(g.SB_DODGE_POPS) or 0) + 1
  end)
end

--========================= Auto-Clash (Minigame-Win) =========================--
-- Der Pointer-Winkel wird live auf Pointer.Rotation gespiegelt; der Goal-Arc ist
-- Goal.Rotation (Start) + dessen UIGradient.Rotation (Groesse), analog der Bonus-Arc.
-- Wir pruefen jeden Frame mit der spieleigenen Regel ((winkel-start)%360)<=groesse,
-- ob der Pointer im Arc ist, und druecken exakt beim Eintritt Space (VirtualInputManager
-- = legitimer Input-Pfad: spielt Success, sendet echtes moveClash-Packet, rueckt vor).
-- armed-Guard = genau ein Fire pro Arc-Eintritt -> nie der 1s-Miss-Stun.
local function startClashAuto()
  if g.SB_CLASH_LOOP then return end
  g.SB_CLASH_LOOP = true
  local VIM = game:GetService("VirtualInputManager")
  local pg  = lp:WaitForChild("PlayerGui")
  g.SB_CLASH_HITS = tonumber(g.SB_CLASH_HITS) or 0
  local armed = true
  local function inArc(angle, start, size)
    return ((angle - start) % 360) <= size
  end
  local clashConn = RunService.Heartbeat:Connect(function()
    if not g.SB_CLASH then armed = true; return end
    local Clashing = pg:FindFirstChild("Clashing")
    if not Clashing or not Clashing.Enabled or lp:GetAttribute("Client_IsClashing") ~= true then
      armed = true; return
    end
    local bg = Clashing:FindFirstChild("Background")
    if not bg then return end
    local Pointer = bg:FindFirstChild("Pointer")
    local Goal    = bg:FindFirstChild("Goal")
    local Bonus   = bg:FindFirstChild("BonusGoal")
    if not (Pointer and Goal) then return end
    local ang    = Pointer.Rotation                                  -- aktueller Pointer-Winkel
    local pStart = Goal.Rotation                                     -- Goal-Arc Start
    local pSize  = Goal.Half.Marker.UIStroke.UIGradient.Rotation     -- Goal-Arc Groesse
    local hit = inArc(ang, pStart, pSize)
    if not hit and Bonus and Bonus.Visible then
      hit = inArc(ang, Bonus.Rotation, Bonus.Half.Marker.UIStroke.UIGradient.Rotation)
    end
    if hit and armed then
      armed = false                             -- genau EINE Entscheidung pro Arc-Eintritt
      if not legitFail() then                   -- Legitness: manche Arc-Treffer absichtlich verpassen
        g.SB_CLASH_HITS = (tonumber(g.SB_CLASH_HITS) or 0) + 1
        pcall(function() keypress(0x20) end)   -- Space DOWN
        pcall(function() keyrelease(0x20) end)  -- Space UP
      end
    elseif not hit then
      armed = true
    end
  end)
  table.insert(g.SB_CONNS, clashConn)
end

--========================= Apparate-to-Player (echter appa-Cast) =========================--
-- Castet den ECHTEN Apparition-Spell "appa" auf die Ziel-Position (mit Animation/Effekt),
-- via loadSpellReplication(spell="appa") + uniqueSpellReplication(target=Zielpos).
-- Funktioniert unabhaengig davon, ob Auto-Spell/Combo an sind (eigener Packet-Pfad).
local function apparateTo(name)
  if not name then return false, "kein Ziel gewaehlt" end
  if not (okPk and packets and packets.loadSpellReplication and packets.uniqueSpellReplication) then
    return false, "packets fehlen"
  end
  local tp = Players:FindFirstChild(name)
  local tchar = tp and tp.Character
  local troot = tchar and (tchar:FindFirstChild("HumanoidRootPart") or tchar.PrimaryPart)
  local mychar = lp.Character
  local myroot = mychar and mychar:FindFirstChild("HumanoidRootPart")
  local wand = mychar and mychar:FindFirstChildWhichIsA("Tool")
  if not (troot and myroot and wand) then return false, "Ziel/Wand fehlt" end
  local origin = myroot.Position
  local target = troot.Position
  local guid = Http:GenerateGUID(false)
  if okReg and registry then registry[guid] = true end
  -- Kampf-Spell entwaffnen + kurzes Fenster sperren, damit kein Spell zeitgleich zum Appa feuert
  g.SB_APPA_LOCK = os.clock() + 0.4
  disarmSpell()
  -- appa laden, dann auf Zielposition feuern (back-to-back, keine Yields -> Auto-Spell dazwischen unmoeglich)
  packets.loadSpellReplication.send({ spell = "appa", enabled = true, wand = wand })
  packets.uniqueSpellReplication.send({
    serverTimeAtFire = workspace:GetServerTimeNow(),
    spellId          = guid,
    origin           = origin,
    target           = target,
    spellName        = "appa",
    wand             = wand,
  })
  g.SB_APPA_COUNT = (tonumber(g.SB_APPA_COUNT) or 0) + 1
  return true
end

--========================= Autofarm (Map weg + Untergrund-Hopping) =========================--
-- Ablauf pro Runde: Map lokal wegraeumen -> unter den naechsten Spieler teleportieren ->
-- dort EINEN Spell mit Silent-Aim nach oben feuern -> naechster Spieler.
-- Aus dem Spiel geprueft: ALLE Charaktere haengen in Workspace.Terrain.characters, die
-- Spell-Effekte in Terrain.effects/shields/protegos -> alles was direkt unter Workspace
-- haengt ist reine Map und kann weg, ohne Spieler oder Effekte zu treffen.
-- UMKEHRBAR: die Map wird NICHT zerstoert, sondern nur ausgehaengt (Parent = nil) und in
-- g.SB_MAP_PARKED gemerkt -> "Map zurueckholen" haengt sie 1:1 wieder ein.
-- Der Boden ist echtes Terrain-Voxel. Terrain:Clear() waere endgueltig (nur ein Rejoin
-- holt es zurueck), deshalb wird standardmaessig pro Farm-Spot nur eine kleine Blase
-- ausgeschnitten: vorher CopyRegion sichern, FillRegion(Air) schneiden, PasteRegion legt
-- sie beim Restore wieder rein. Alles rein clientseitig.
g.SB_FARM_SPELL = g.SB_FARM_SPELL or resolveSpell("avada kedavra")
g.SB_FARM_DEPTH = tonumber(g.SB_FARM_DEPTH) or 15     -- Studs unter dem Ziel
g.SB_FARM_DELAY = tonumber(g.SB_FARM_DELAY) or 0.25   -- Wartezeit nach dem TP vor dem Cast
g.SB_FARM_ROUND = tonumber(g.SB_FARM_ROUND) or 0.5    -- Pause zwischen zwei Runden
if g.SB_FARM_NUKE         == nil then g.SB_FARM_NUKE = true end          -- Map beim Start wegraeumen
if g.SB_FARM_UNNUKE       == nil then g.SB_FARM_UNNUKE = true end        -- beim Stoppen zurueckholen
if g.SB_FARM_CARVE        == nil then g.SB_FARM_CARVE = true end         -- Terrain-Blase (umkehrbar)
if g.SB_FARM_WIPE_TERRAIN == nil then g.SB_FARM_WIPE_TERRAIN = false end -- Terrain global (endgueltig)
if g.SB_FARM_EXEMPT_OK    == nil then g.SB_FARM_EXEMPT_OK = true end     -- Aim-Ausnahmen beachten
if g.SB_FARM_SKIP_SAFE    == nil then g.SB_FARM_SKIP_SAFE = true end     -- Safe-Zone-Spieler auslassen
if g.SB_FARM_SKIP_STAFF   == nil then g.SB_FARM_SKIP_STAFF = true end    -- Moderatoren auslassen
if g.SB_FARM_RETURN       == nil then g.SB_FARM_RETURN = true end        -- am Ende zurueck
if g.SB_FARM_REPEAT       == nil then g.SB_FARM_REPEAT = true end        -- endlos rotieren
g.SB_MAP_PARKED = g.SB_MAP_PARKED or {}   -- ausgehaengte Map-Teile: { {inst=, parent=} }
g.SB_TERR_SNAP  = g.SB_TERR_SNAP  or {}   -- gesicherte Blasen: [key] = { reg=TerrainRegion, corner=Vector3int16 }
local TERR_SNAP_MAX = 400                 -- Deckel, sonst waechst der Speicher endlos

-- Map aushaengen statt zerstoeren -> jederzeit 1:1 wieder einhaengbar.
-- Terrain (haelt die Charaktere), Camera und alles mit "_" (z.B. _Anchor) bleiben stehen.
local function parkMap()
  local n = 0
  for _, c in ipairs(workspace:GetChildren()) do
    if not c:IsA("Terrain") and not c:IsA("Camera") and c.Name:sub(1, 1) ~= "_" then
      local par = c.Parent
      if pcall(function() c.Parent = nil end) then
        g.SB_MAP_PARKED[#g.SB_MAP_PARKED + 1] = { inst = c, parent = par }
        n = n + 1
      end
    end
  end
  g.SB_MAP_NUKED = true
  return n
end

-- Terrain-Blase um pos ausschneiden, vorher sichern (damit der Restore sie zurueckholt).
local function carveTerrain(pos, radius)
  local terr = workspace.Terrain
  local r = math.max(1, math.floor(radius / 4))
  local cx, cy, cz = math.floor(pos.X / 4), math.floor(pos.Y / 4), math.floor(pos.Z / 4)
  local mn = Vector3int16.new(cx - r, cy - r, cz - r)
  local mx = Vector3int16.new(cx + r, cy + r, cz + r)
  local key = mn.X .. "," .. mn.Y .. "," .. mn.Z .. "/" .. r
  if not g.SB_TERR_SNAP[key] then
    if (tonumber(g.SB_TERR_COUNT) or 0) >= TERR_SNAP_MAX then
      g.SB_TERR_TRUNC = true                       -- Deckel erreicht: ab hier ohne Sicherung
    else
      local ok, reg = pcall(function() return terr:CopyRegion(Region3int16.new(mn, mx)) end)
      if ok and typeof(reg) == "Instance" then
        g.SB_TERR_SNAP[key] = { reg = reg, corner = mn }
        g.SB_TERR_COUNT = (tonumber(g.SB_TERR_COUNT) or 0) + 1
      end
    end
  end
  pcall(function()
    terr:FillRegion(Region3.new(Vector3.new(mn.X * 4, mn.Y * 4, mn.Z * 4),
                                Vector3.new((mx.X + 1) * 4, (mx.Y + 1) * 4, (mx.Z + 1) * 4)),
                    4, Enum.Material.Air)
  end)
end

-- Genau EINE Blase wieder zumachen (gleicher Key wie beim Schneiden) - fuer Aktionen, die
-- nur kurz ein Loch brauchen (Snipe): schneiden, schiessen, sofort wieder zu.
local function uncarveTerrain(pos, radius)
  local terr = workspace.Terrain
  local r = math.max(1, math.floor(radius / 4))
  local cx, cy, cz = math.floor(pos.X / 4), math.floor(pos.Y / 4), math.floor(pos.Z / 4)
  local mn = Vector3int16.new(cx - r, cy - r, cz - r)
  local key = mn.X .. "," .. mn.Y .. "," .. mn.Z .. "/" .. r
  local snap = g.SB_TERR_SNAP[key]
  if not snap or not snap.reg then return false end
  local ok = pcall(function() terr:PasteRegion(snap.reg, snap.corner, true) end)
  pcall(function() snap.reg:Destroy() end)
  g.SB_TERR_SNAP[key] = nil
  g.SB_TERR_COUNT = math.max((tonumber(g.SB_TERR_COUNT) or 1) - 1, 0)
  return ok
end

-- Map + gesicherte Terrain-Blasen zurueckholen, ohne Rejoin.
local function restoreMap()
  local parts, bubbles = 0, 0
  for _, e in ipairs(g.SB_MAP_PARKED) do
    if e.inst and pcall(function() e.inst.Parent = e.parent or workspace end) then parts = parts + 1 end
  end
  g.SB_MAP_PARKED = {}
  local terr = workspace.Terrain
  for k, s in pairs(g.SB_TERR_SNAP) do
    if s.reg then
      if pcall(function() terr:PasteRegion(s.reg, s.corner, true) end) then bubbles = bubbles + 1 end
      pcall(function() s.reg:Destroy() end)
    end
    g.SB_TERR_SNAP[k] = nil
  end
  g.SB_TERR_COUNT, g.SB_TERR_TRUNC = 0, false
  g.SB_MAP_NUKED = false
  g.SB_MAP_LAST  = parts .. "/" .. bubbles
  return parts, bubbles
end

-- HRP holen und (waehrend des Farmens) verankern - ohne Boden faellt man sonst raus.
local function farmHRP(anchor)
  local ch  = lp.Character
  local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
  if not hrp then return nil end
  if anchor and not hrp.Anchored then
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.Anchored = true
  end
  return hrp
end

local function farmTeleport(pos)
  local hrp = farmHRP(true)
  if not hrp then return false end
  local rot = hrp.CFrame - hrp.CFrame.Position     -- Blickrichtung beibehalten
  hrp.CFrame = CFrame.new(pos) * rot
  hrp.AssemblyLinearVelocity = Vector3.zero
  return true
end

-- Ein Cast auf ein Ziel-Root (ohne Mausklick), MIT Silent-Aim: der Zielpunkt kommt aus
-- derselben Lead-Rechnung wie beim Silent-Aim (aimPointFor) und wird zusaetzlich auf die
-- Spiel-Maus gelegt, damit auch der interne Fire-Pfad genau dorthin zielt.
local function farmCast(root, hum, spellOverride)
  if legitFail() then return false end             -- Legitness: Cast absichtlich verschlucken
  local spell  = resolveSpell(spellOverride or g.SB_FARM_SPELL or "avada kedavra")
  local refs   = g.SB_REFS
  local myHRP  = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
  local origin = myHRP and myHRP.Position or root.Position
  local function aimAt()                           -- nach dem Load: spellSpeed() kennt den Spell
    local zonePart, zoneOff = aimZone(root.Parent, root)   -- Trefferzone variieren
    return aimPointFor(origin, zonePart, hum, g.SB_AIM_PRED and spellSpeed() or 0) + zoneOff
  end
  local function pushMouse(p)                      -- Silent-Aim-Override auf die Spiel-Maus
    if g.SB_MOUSE then pcall(function() rawset(g.SB_MOUSE, "Hit", p and CFrame.new(p) or nil) end) end
  end
  if refs and refs.set and refs.state and refs.fire then
    local st = refs.state
    st.casts = 0
    pcall(refs.set, spell, true)
    task.wait(0.07)                                -- Server den Load registrieren lassen
    if st.loadedSpell == spell then
      st.casts = 0
      local target = aimAt()
      pushMouse(target)
      local ok = pcall(refs.fire, target)
      if not g.SB_AIM then pushMouse(nil) end      -- Override wieder freigeben (Silent-Aim ist aus)
      if ok then
        g.SB_FARM_CASTS = (tonumber(g.SB_FARM_CASTS) or 0) + 1
        g.SB_CASTS      = (tonumber(g.SB_CASTS) or 0) + 1
        g.SB_LAST_CAST  = os.clock()
        g.SB_PRELOADED  = nil
        return true
      end
    end
  end
  local ch   = lp.Character
  local wand = ch and ch:FindFirstChildWhichIsA("Tool")
  if wand and castReplicated(refs and refs.state or nil, wand, spell, aimAt()) then
    g.SB_FARM_CASTS = (tonumber(g.SB_FARM_CASTS) or 0) + 1
    g.SB_LAST_CAST  = os.clock()
    return true
  end
  return false
end

-- Zielliste: lebende Spieler, naechster zuerst. Uebersprungen werden (je nach Option)
-- Safe-Zone-Spieler (Attribut InSafeZone), Staff und die Silent-Aim-Ausnahmen.
local function farmTargets()
  local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
  local me    = myHRP and myHRP.Position or Vector3.zero
  local list  = {}
  for _, pl in ipairs(Players:GetPlayers()) do
    if pl ~= lp then
      local ch   = pl.Character
      local root = ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
      local hum  = ch and ch:FindFirstChildOfClass("Humanoid")
      if root and hum and hum.Health > 0 then
        local skip = false
        if g.SB_FARM_EXEMPT_OK then
          local fid = playerFactionId(pl)
          if g.SB_AIM_EXEMPT[pl.Name] then skip = true end
          if fid and g.SB_AIM_EXEMPT_FACTION[fid] and not g.SB_AIM_KEEP[pl.Name] then skip = true end
        end
        if isFriend(pl) then skip = true end
        if g.SB_FARM_SKIP_SAFE and pl:GetAttribute("InSafeZone") == true then skip = true end
        if g.SB_FARM_SKIP_STAFF and isStaff(pl) then skip = true end
        if not skip then list[#list + 1] = { pl = pl, d = (root.Position - me).Magnitude } end
      end
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  local out = {}
  for i, e in ipairs(list) do out[i] = e.pl end
  return out
end

local function startFarm()
  if g.SB_FARM_LOOP then return end
  g.SB_FARM_LOOP = true
  startSelector()                                  -- haelt g.SB_REFS/Wand-Closures aktuell
  task.spawn(function()
    local hrp0 = farmHRP(false)
    g.SB_FARM_HOME = g.SB_FARM_HOME or (hrp0 and hrp0.CFrame)
    if g.SB_FARM_NUKE and not g.SB_MAP_NUKED then parkMap() end
    if g.SB_FARM_WIPE_TERRAIN and not g.SB_TERR_WIPED then
      pcall(function() workspace.Terrain:Clear() end)
      g.SB_TERR_WIPED = true                       -- global geloescht -> nur ein Rejoin holt das zurueck
    end
    while g.SB_FARM do
      local targets = farmTargets()
      if #targets == 0 then
        g.SB_FARM_TARGET = nil
        task.wait(0.5)
      else
        for _, pl in ipairs(targets) do
          if not g.SB_FARM then break end
          local ch   = pl.Character
          local root = ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
          local hum  = ch and ch:FindFirstChildOfClass("Humanoid")
          -- Safe-Zone kann sich waehrend der Runde aendern -> direkt vor dem Hop nochmal pruefen
          local safe = g.SB_FARM_SKIP_SAFE and pl:GetAttribute("InSafeZone") == true
          if root and hum and hum.Health > 0 and not safe then
            g.SB_FARM_TARGET = pl.Name
            local depth = tonumber(g.SB_FARM_DEPTH) or 15
            local spot  = root.Position - Vector3.new(0, depth, 0)
            if farmTeleport(spot) then
              if g.SB_FARM_CARVE and not g.SB_TERR_WIPED then
                carveTerrain((spot + root.Position) * 0.5, depth * 0.5 + 14)
              end
              task.wait(tonumber(g.SB_FARM_DELAY) or 0.25)
              -- Ziel koennte inzwischen weg/tot/in einer Safe Zone sein -> frisch pruefen
              local stillSafe = g.SB_FARM_SKIP_SAFE and pl:GetAttribute("InSafeZone") == true
              if g.SB_FARM and root.Parent and hum.Health > 0 and not stillSafe and not isStunnedOrBound() then
                farmCast(root, hum)
              end
            end
          end
        end
        g.SB_FARM_TARGET = nil
        if not g.SB_FARM_REPEAT then g.SB_FARM = false end
      end
      task.wait(tonumber(g.SB_FARM_ROUND) or 0.5)
    end
    -- Aufraeumen: erst Map/Terrain zurueck (sonst faellt man beim Entankern ins Nichts),
    -- dann an den Startpunkt und entankern.
    if g.SB_FARM_UNNUKE then pcall(restoreMap) end
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if hrp then
      if g.SB_FARM_RETURN and g.SB_FARM_HOME then pcall(function() hrp.CFrame = g.SB_FARM_HOME end) end
      hrp.Anchored = false
      hrp.AssemblyLinearVelocity = Vector3.zero
    end
    g.SB_FARM_HOME, g.SB_FARM_TARGET = nil, nil
    g.SB_FARM_LOOP = false
  end)
end

--===================== SNIPE (Taste M): 1 Ziel, unter die Map, 1 Spell =====================--
-- Einzelschuss-Variante des Autofarms: nimmt das aktuelle Silent-Aim-Ziel (sonst den Spieler
-- am naechsten zum Cursor), merkt sich die eigene Position, teleportiert direkt UNTER das Ziel,
-- feuert dort EINEN Spell aus der Safe-Combat-Rotation nach oben (mit Silent-Aim-Vorhalt) und
-- ist sofort wieder zuhause. Gesamtdauer ~0.1s -> faellt praktisch nicht auf.
g.SB_SNIPE_DEPTH = tonumber(g.SB_SNIPE_DEPTH) or 15    -- Studs unter dem Ziel
g.SB_SNIPE_DELAY = tonumber(g.SB_SNIPE_DELAY) or 0.05  -- Wartezeit nach dem TP vor dem Cast
if g.SB_SNIPE_CARVE == nil then g.SB_SNIPE_CARVE = true end  -- Terrain-Blase (sonst blockt der Boden)

-- Ziel: erst das Silent-Aim-Ziel, sonst der Spieler am naechsten zum Cursor.
local function snipePickTarget()
  local function alive(pl)
    local ch  = pl and pl.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local root = ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
    if root and hum and hum.Health > 0 then return root, hum end
  end
  local name = g.SB_AIM_TARGET
  if name then
    local pl = Players:FindFirstChild(name)
    if pl and alive(pl) then return pl end
  end
  local cam   = workspace.CurrentCamera
  local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
  if not (cam and myHRP) then return nil end
  local mp = UIS:GetMouseLocation()
  local best, bestD
  for _, pl in ipairs(Players:GetPlayers()) do
    if pl ~= lp and not (g.SB_AIM_EXEMPT and g.SB_AIM_EXEMPT[pl.Name]) then
      local root = alive(pl)
      if root then
        local sp, onScreen = cam:WorldToViewportPoint(root.Position)
        local wd = (root.Position - myHRP.Position).Magnitude
        if onScreen and sp.Z > 0 and wd <= (tonumber(g.SB_AIM_RANGE) or 500) then
          local sd = (Vector2.new(sp.X, sp.Y) - Vector2.new(mp.X, mp.Y)).Magnitude
          if not bestD or sd < bestD then best, bestD = pl, sd end
        end
      end
    end
  end
  return best
end

local function doSnipe()
  if g.SB_SNIPE_BUSY then return end
  if g.SB_FARM then g.SB_SNIPE_STATUS = "Autofarm laeuft"; return end   -- der fasst die Position selbst an
  local pl = snipePickTarget()
  local ch   = pl and pl.Character
  local root = ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
  local hum  = ch and ch:FindFirstChildOfClass("Humanoid")
  local hrp  = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
  if not (pl and root and hum and hrp) then g.SB_SNIPE_STATUS = "kein Ziel"; return end
  if isStunnedOrBound() or isRagdolled() then g.SB_SNIPE_STATUS = "gestunnt"; return end
  g.SB_SNIPE_BUSY = true
  startSelector()                                   -- haelt g.SB_REFS/Wand-Closures aktuell
  task.spawn(function()
    local home = hrp.CFrame
    local carvedAt, carvedR                          -- gemerkt, damit das Loch wieder zugeht
    local ROT = g.SB_SAFE_ROT or {}
    local function nextSpell()                       -- naechster Slot der Safe-Combat-Rotation
      local idx = tonumber(g.SB_ROT_IDX) or 1
      local sp  = ROT[idx] or ROT[1]
      g.SB_ROT_IDX = (idx % math.max(#ROT, 1)) + 1
      return sp
    end
    local function speedOf(name)
      local sd = okSp and spellsMod and spellsMod.list and spellsMod.list[name]
      return tonumber(sd and sd.speed) or 300
    end

    -- 1) TARNSCHUSS: ganz normaler Cast von der eigenen Position auf das Ziel. Sieht nach
    --    einem gewoehnlichen Angriff aus und liefert das Zeitfenster fuer den echten Schuss.
    local decoy  = nextSpell()
    local flight = 0
    if decoy then
      flight = (root.Position - hrp.Position).Magnitude / speedOf(decoy)
      pcall(farmCast, root, hum, decoy)
      g.SB_SNIPE_STATUS = "Tarnschuss " .. decoy .. " -> " .. pl.Name
    end

    -- 2) So lange warten, dass der Schuss von unten GENAU mit dem Einschlag des Tarnschusses
    --    zusammenfaellt: Flugzeit minus dem, was die Sequenz selbst braucht
    --    (Spell-Load + TP-Delay + Flugzeit der Tiefe).
    local depth     = tonumber(g.SB_SNIPE_DEPTH) or 15
    local killSpell = nextSpell()
    local prep      = 0.07 + (tonumber(g.SB_SNIPE_DELAY) or 0.05) + depth / speedOf(killSpell)
    local waitT     = flight - prep
    if waitT > 0 then task.wait(waitT) end

    -- 3) ASSASSINEN-SEQUENZ, getarnt vom Einschlag des ersten Spells
    pcall(function()
      if not (root.Parent and hum.Health > 0) then
        g.SB_SNIPE_STATUS = pl.Name .. ": Tarnschuss hat gereicht"
        return
      end
      local spot = root.Position - Vector3.new(0, depth, 0)
      if not farmTeleport(spot) then return end     -- verankert das HRP (sonst faellt man)
      if g.SB_SNIPE_CARVE and not g.SB_TERR_WIPED and not g.SB_MAP_NUKED then
        carvedAt, carvedR = (spot + root.Position) * 0.5, depth * 0.5 + 14
        carveTerrain(carvedAt, carvedR)
      end
      task.wait(tonumber(g.SB_SNIPE_DELAY) or 0.05)
      if killSpell and root.Parent and hum.Health > 0 then
        if farmCast(root, hum, killSpell) then
          g.SB_SNIPE_COUNT  = (tonumber(g.SB_SNIPE_COUNT) or 0) + 1
          g.SB_SNIPE_STATUS = pl.Name .. " / " .. tostring(decoy) .. " + " .. killSpell
        else
          g.SB_SNIPE_STATUS = "Cast fehlgeschlagen"
        end
      end
    end)
    -- IMMER zurueck nach Hause: das GANZE Modell bewegen (PivotTo), nicht nur das HRP - sonst
    -- steht man fuer die anderen wieder daheim, auf dem eigenen Schirm aber noch unter der Map.
    local function goHome()
      local ch2  = lp.Character
      local hrp2 = ch2 and ch2:FindFirstChild("HumanoidRootPart")
      if not (ch2 and hrp2) then return end
      pcall(function() ch2:PivotTo(home) end)
      hrp2.AssemblyLinearVelocity = Vector3.zero
      hrp2.Anchored = false
      local hum2 = ch2:FindFirstChildOfClass("Humanoid")
      local cam  = workspace.CurrentCamera
      if cam and hum2 and cam.CameraSubject ~= hum2 then cam.CameraSubject = hum2 end
    end
    goHome()
    task.spawn(function()
      for _ = 1, 4 do                                -- Nachhalten gegen Physik-Rubberband
        RunService.Heartbeat:Wait()
        local ch2  = lp.Character
        local hrp2 = ch2 and ch2:FindFirstChild("HumanoidRootPart")
        if hrp2 then
          if (hrp2.Position - home.Position).Magnitude > 3 then goHome() end
          if hrp2.Anchored then hrp2.Anchored = false end
        end
      end
    end)
    -- Terrain-Blase wieder zumachen, sobald der Spell durch ist (sonst bleibt das Loch offen)
    if carvedAt then
      task.spawn(function()
        task.wait(0.45)
        pcall(uncarveTerrain, carvedAt, carvedR)
      end)
    end
    g.SB_SNIPE_BUSY = false
  end)
end

--========================= SHOTGUN (Troll) =========================--
-- Feuert NIE von selbst: nur ein echter Linksklick (InputBegan) loest EINEN Burst aus —
-- genau SB_SHOT_BURST (=6) Spells hintereinander, Takt SB_SHOT_IV (=0.02s = 1 Frame, der
-- kleinste Wert der noch je Frame einen eigenen Cast ergibt). Danach ist Schluss bis zum
-- naechsten Klick: Dauerfeuer kappt der Server ("hard spell over time limit").
-- WELCHE Spells: nur die aus den eigenen Spell-Bind-Sets (= die man wirklich hat; eine
-- Besitz-Liste gibt es clientseitig nicht, spellPermissions erlaubt pauschal fast alles) und
-- davon nur die COMBAT-Spells (hostile). Damit fliegen Heal/Buff/Utility (protego, episkey,
-- rennervate, lumos...), Movement (appa/ascendio) und Elder-Wand-Spells automatisch raus.
-- Sie laufen alphabetisch durch: der naechste Burst macht dort weiter, wo der letzte aufhoerte.
-- Vor JEDEM Schuss wird der Stab einmal aus- und wieder eingepackt (Humanoid:UnequipTools/
-- EquipTool) -> jeder Cast sieht nach frischem Equip+Load+Fire aus statt nach Dauerfeuer.
local SHOT_SKIP = {
  ["appa"] = true, ["appa duo"] = true, ["ascendio"] = true,   -- Teleport / Hochschleudern
}
local function shotSpellPool()
  local list, seen = {}, {}
  local okB, bindSets = pcall(function() return require(RS.shared.modules.spellBindSets) end)
  if okB and bindSets and okSp and spellsMod and spellsMod.list then
    local okD, data = pcall(function() return bindSets:getSpellBindSetsData() end)
    if okD and type(data) == "table" then
      for _, set in pairs(data) do
        if type(set) == "table" then
          for _, incantation in pairs(set) do
            local name = tostring(incantation)                 -- "__empty" ist nicht in spells.list
            local d = spellsMod.list[name]
            if type(d) == "table" and d.hostile == true and not seen[name]
               and not SHOT_SKIP[name] and d.elderOnly ~= true and d.elder ~= true then
              seen[name] = true; list[#list + 1] = name
            end
          end
        end
      end
    end
  end
  table.sort(list)                       -- alphabetisch
  return list
end

-- Stab einmal weg- und wieder einpacken, gibt das (wieder equippte) Tool zurueck
local function shotCycleWand()
  local char = lp.Character
  local hum  = char and char:FindFirstChildOfClass("Humanoid")
  if not (char and hum and hum.Health > 0) then return nil end
  local wand = char:FindFirstChildWhichIsA("Tool")
  if not wand then
    local bp = lp:FindFirstChildOfClass("Backpack")
    wand = bp and bp:FindFirstChildWhichIsA("Tool")
  end
  if not wand then return nil end
  -- Bei sehr kleinem Takt (<0.05s) ohne Frame-Pause zwischen Aus- und Einpacken arbeiten,
  -- sonst sind die zwei Heartbeats (~0.03s) der Flaschenhals und der Takt greift gar nicht.
  local slow = (tonumber(g.SB_SHOT_IV) or 0.02) >= 0.05
  if g.SB_SHOT_REEQUIP ~= false and wand.Parent == char then
    pcall(function() hum:UnequipTools() end)
    if slow then RunService.Heartbeat:Wait() end
  end
  if wand.Parent ~= char then
    pcall(function() hum:EquipTool(wand) end)
    if slow then RunService.Heartbeat:Wait() end
  end
  return char:FindFirstChildWhichIsA("Tool") or wand
end

-- Zielpunkt: Silent-Aim-Ziel falls aktiv, sonst der echte Cursor
local function shotTarget()
  local m = g.SB_MOUSE
  if not m then
    local okM, pm = pcall(function() return require(RS.shared.modules.PlayerMouse) end)
    g.SB_MOUSE = okM and pm and pm:GetMouse() or nil
    m = g.SB_MOUSE
  end
  local hit = m and m.Hit
  if hit then return hit.Position end
  return realMouseHit()
end

-- feuert EINEN beliebigen Spell (normal oder unique) auf target
local function castAnySpell(wand, spell, target)
  local sd = okSp and spellsMod and spellsMod.list and spellsMod.list[spell]
  if sd and sd.unique then
    if g.SB_SHOT_UNIQUE == false then return false end
    if not (okPk and packets and packets.loadSpellReplication and packets.uniqueSpellReplication) then return false end
    local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local guid = Http:GenerateGUID(false)
    if okReg and registry then registry[guid] = true end
    packets.loadSpellReplication.send({ spell = spell, enabled = true, wand = wand })
    packets.uniqueSpellReplication.send({
      serverTimeAtFire = workspace:GetServerTimeNow(), spellId = guid,
      origin = hrp.Position, target = target or (hrp.Position + hrp.CFrame.LookVector * 60),
      spellName = spell, wand = wand,
    })
    return true
  end
  local st = g.SB_REFS and g.SB_REFS.state
  return castReplicated(st, wand, spell, target)
end

-- ein Schuss: naechster Spell der Liste, Stab neu ziehen, feuern, Index weiterdrehen
local function shotFireOne(list)
  if isRagdolled() then return false end             -- ragdollt -> kein Equip moeglich
  local idx = tonumber(g.SB_SHOT_IDX) or 1
  if idx < 1 or idx > #list then idx = 1 end
  local spell = list[idx]
  local wand  = shotCycleWand()
  if not wand then return false end
  if castAnySpell(wand, spell, shotTarget()) then
    g.SB_SHOT_COUNT = (tonumber(g.SB_SHOT_COUNT) or 0) + 1
  else
    g.SB_SHOT_FAILS = (tonumber(g.SB_SHOT_FAILS) or 0) + 1
    g.SB_SHOT_LASTFAIL = spell
  end
  g.SB_SHOT_SPELL = spell
  g.SB_SHOT_IDX = (idx % #list) + 1                  -- alphabetisch weiter, dann von vorn
  return true
end

local function startShotgun()
  -- Klick-Trigger als EVENT (nicht pollen): ein kurzer Klick darf nie verschluckt werden.
  if not g.SB_SHOT_HOOKED then
    g.SB_SHOT_HOOKED = true
    table.insert(g.SB_CONNS, UIS.InputBegan:Connect(function(i, gp)
      if gp or g.SB_GUI_OPEN then return end                  -- Klicks im ClickGUI feuern nicht
      if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
      if not g.SB_SHOT then return end
      if tick() < (tonumber(g.SB_SHOT_ARMED_AT) or 0) then return end  -- Einschalt-Klick zaehlt nicht
      g.SB_SHOT_REQ = true                                   -- genau EIN Burst pro Klick
      g.SB_SHOT_CLICKS = (tonumber(g.SB_SHOT_CLICKS) or 0) + 1
    end))
  end
  if g.SB_SHOT_LOOP then return end
  g.SB_SHOT_LOOP = true
  g.SB_SHOT_COUNT = tonumber(g.SB_SHOT_COUNT) or 0
  g.SB_SHOT_REQ = false
  g.SB_SHOT_ARMED_AT = tick() + 0.3   -- NIE von selbst feuern: erst 0.3s nach dem Einschalten scharf
  task.spawn(function()
    local list = shotSpellPool()
    g.SB_SHOT_LIST = list
    while g.SB_SHOT do
      if g.SB_SHOT_REQ then
        g.SB_SHOT_REQ = false
        list = shotSpellPool()                      -- Bind-Sets koennen sich geaendert haben
        g.SB_SHOT_LIST = list
        if #list == 0 then
          g.SB_SHOT_SPELL = "keine Combat-Spells gebunden"
        else
          local n = math.max(1, math.floor(tonumber(g.SB_SHOT_BURST) or 6))
          g.SB_SHOT_BURSTLEFT = n
          local tBurst = tick()
          for i = 1, n do
            if not g.SB_SHOT then break end
            -- tick() = echte Wall-Clock; os.clock() laeuft im Executor langsamer als Echtzeit
            -- und haette den Abstand auf ~0.055s zusammengeschoben (= Rate-Limit-Falle).
            local t0 = tick()
            pcall(shotFireOne, list)
            g.SB_SHOT_BURSTLEFT = n - i
            if i < n then
              local rest = (tonumber(g.SB_SHOT_IV) or 0.02) - (tick() - t0)
              while rest > 0 do                     -- task.wait kann kuerzer zurueckkommen
                task.wait(rest)
                rest = (tonumber(g.SB_SHOT_IV) or 0.02) - (tick() - t0)
              end
            end
          end
          g.SB_SHOT_LASTDUR = tick() - tBurst                 -- echte Dauer des Bursts
          -- Nach dem letzten Schuss den Stab garantiert wieder in die Hand geben (bei sehr
          -- kleinem Takt bleibt er sonst im Rucksack liegen).
          task.spawn(function()
            for _ = 1, 3 do
              RunService.Heartbeat:Wait()
              local ch = lp.Character
              if ch and ch:FindFirstChildWhichIsA("Tool") then return end
              local hum = ch and ch:FindFirstChildOfClass("Humanoid")
              local bp  = lp:FindFirstChildOfClass("Backpack")
              local bw  = bp and bp:FindFirstChildWhichIsA("Tool")
              if hum and bw then pcall(function() hum:EquipTool(bw) end) end
            end
          end)
          g.SB_SHOT_REQ = false                               -- Klicks WAEHREND des Bursts zaehlen nicht
        end
      end
      RunService.Heartbeat:Wait()
    end
    g.SB_SHOT_LOOP = false
    g.SB_SHOT_BURSTLEFT = 0
  end)
end

--========================= KD-Farm (Auto-Reset) =========================--
-- Toetet dich per shared.bridges.resetEvent (genau der Pfad, den der Reset-Knopf des
-- Spiels benutzt) und wartet auf den Respawn, endlos oder bis zu einer Zielzahl.
-- In-game gemessen: Tod nach 0.15s, neuer Character nach 3.2s -> ~3.3s pro Tod (~18/min).
-- Der Respawn-Takt kommt vom Server (CharacterAutoLoads=false, RespawnTime=3), schneller
-- geht es clientseitig nicht. Geprueft: der Reset zaehlt wirklich als Death (47 -> 48).
if g.SB_KD_PAUSE == nil then g.SB_KD_PAUSE = 0.3 end   -- Extra-Pause nach dem Respawn
g.SB_KD_LIMIT = tonumber(g.SB_KD_LIMIT) or 0           -- 0 = endlos, sonst Stopp nach n Toden
g.SB_KD_COUNT = tonumber(g.SB_KD_COUNT) or 0

-- Eigene oeffentliche Stats (Kills/Deaths) live aus der Registry des Spiels.
local function kdStats()
  local ok, ppd = pcall(function() return require(RS.shared.modules.publicPlayerData) end)
  if not ok or type(ppd) ~= "table" or type(ppd.registry) ~= "table" then return nil end
  local e = ppd.registry[lp.Name]
  if type(e) ~= "table" then return nil end
  return tonumber(e.Kills) or 0, tonumber(e.Deaths) or 0
end
local function kdLabel()
  local k, d = kdStats()
  if not k then return "K/D: -" end
  return string.format("K/D: %d/%d (%.2f)", k, d, (d > 0) and (k / d) or k)
end

local function startKD()
  if g.SB_KD_LOOP then return end
  local bridges = RS:FindFirstChild("shared") and RS.shared:FindFirstChild("bridges")
  local reset   = bridges and bridges:FindFirstChild("resetEvent")
  if not reset then g.SB_KD, g.SB_KD_LOOP = false, false; return end
  g.SB_KD_LOOP = true
  task.spawn(function()
    while g.SB_KD do
      local ch  = lp.Character
      local hum = ch and ch:FindFirstChildOfClass("Humanoid")
      if ch and ch.Parent and hum and hum.Health > 0 then
        pcall(function() reset:FireServer() end)
        g.SB_KD_COUNT = (tonumber(g.SB_KD_COUNT) or 0) + 1
        -- auf den Character-Wechsel warten (Tod), dann auf den fertigen Respawn
        local t0 = os.clock()
        while g.SB_KD and lp.Character == ch and os.clock() - t0 < 8 do task.wait(0.1) end
        local t1 = os.clock()
        while g.SB_KD and not (lp.Character and lp.Character:FindFirstChild("HumanoidRootPart"))
              and os.clock() - t1 < 15 do task.wait(0.1) end
        task.wait(math.max(tonumber(g.SB_KD_PAUSE) or 0.3, 0.1))
        local lim = tonumber(g.SB_KD_LIMIT) or 0
        if lim > 0 and (tonumber(g.SB_KD_COUNT) or 0) >= lim then g.SB_KD = false end
      else
        task.wait(0.2)                              -- tot / noch kein Character: warten
      end
    end
    g.SB_KD_LOOP = false
  end)
end

--========================= Spell-Liste (fuer Dropdowns) =========================--
local function getSpellList()
  local okS, spells = pcall(function() return require(RS.shared.modules.spells) end)
  local list = {}
  if okS and spells then
    for name, d in pairs(spells.list) do
      if type(d) == "table" and (d.cooldownTime ~= nil or d.spellType ~= nil) then list[#list + 1] = name end
    end
  end
  table.sort(list)
  return list
end

--================= GUI (ClickGUI im Future-Style, RechtsShift oeffnet) =================--
local function mountGui()
  local parent
  local ok, h = pcall(function() return gethui and gethui() end)
  if ok and typeof(h) == "Instance" then parent = h end
  if not parent then local ok2, c = pcall(function() return game:GetService("CoreGui") end); if ok2 and c then parent = c end end
  if not parent then parent = lp:WaitForChild("PlayerGui") end
  local old = parent:FindFirstChild("SpellboundGUI"); if old then old:Destroy() end
  local oldEsp = parent:FindFirstChild("SB_TeamESP"); if oldEsp then oldEsp:Destroy() end  -- alte ESP-Tags nach Reload entfernen

  local gui = Instance.new("ScreenGui")
  gui.Name = "SpellboundGUI"; gui.ResetOnSpawn = false
  gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
  gui.IgnoreGuiInset = true; gui.DisplayOrder = 9999; gui.Parent = parent

  -- === Theme (Phobos/Future: gruen, scharfe Ecken, aber mit Hover/Tiefe/Anim) ===
  local TW       = game:GetService("TweenService")
  local ACCENT   = Color3.fromRGB(95, 205, 90)     -- Phobos-Gruen (Header + aktives Modul)
  local ACCENT_D = Color3.fromRGB(58, 148, 58)     -- dunkleres Gruen fuer Verlauf/Stripe
  local DARKTXT  = Color3.fromRGB(8, 16, 8)        -- dunkler Text auf Gruen
  local PANEL_BG = Color3.fromRGB(13, 14, 17)
  local SET_BG   = Color3.fromRGB(17, 18, 22)      -- Einstellungs-Container
  local ROW_OFF  = Color3.fromRGB(19, 20, 24)
  local ROW_HOV  = Color3.fromRGB(30, 32, 38)
  local ROW_ON   = ACCENT
  local TXT      = Color3.fromRGB(198, 200, 206)
  local TXT_DIM  = Color3.fromRGB(122, 126, 134)
  local WIDGET   = Color3.fromRGB(26, 28, 34)
  local WIDGET_H = Color3.fromRGB(34, 37, 44)
  local TRACK    = Color3.fromRGB(44, 47, 55)
  local ROW_H    = 20                              -- Zeilenhoehe (vorher 18: zu eng)
  local function corner(o, r)                      -- r=0 -> scharfe Phobos-Ecke
    local c = Instance.new("UICorner", o); c.CornerRadius = UDim.new(0, r or 0); return c
  end
  local function stroke(o, col, tr)
    local s = Instance.new("UIStroke", o); s.Color = col or Color3.fromRGB(0, 0, 0)
    s.Transparency = tr or 0.55; s.Thickness = 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; return s
  end
  local function tween(o, t, props)
    return TW:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
  end

  local openList                 -- offenes Dropdown (nur eins gleichzeitig)
  local moduleRefs = {}          -- Modul-Zeilen fuer Farb-/Text-Refresh
  local function closeList() if openList then openList:Destroy(); openList = nil end end

  -- === Dim-Overlay (ClickGUI-Wurzel, per RechtsShift ein/aus) ===
  local clickRoot = Instance.new("Frame")
  clickRoot.Size = UDim2.fromScale(1, 1); clickRoot.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
  clickRoot.BackgroundTransparency = 1; clickRoot.BorderSizePixel = 0
  clickRoot.Active = true; clickRoot.Visible = false; clickRoot.Parent = gui
  local guiOpen = false
  local function setOpen(v)
    guiOpen = v; g.SB_GUI_OPEN = v          -- Shotgun feuert nicht bei Klicks im ClickGUI
    if v then
      clickRoot.Visible = true
      clickRoot.BackgroundTransparency = 1
      tween(clickRoot, 0.12, { BackgroundTransparency = 0.45 })   -- weich abdunkeln
    else
      closeList(); clickRoot.Visible = false
    end
  end
  g.SB_GUI_OPEN = false
  -- Streamproof: blendet ALLE Visuals aus, bis erneut gedrueckt (Hotkey: Bild-Ab / PageDown).
  -- gui.Enabled=false versteckt Panel, Watermark UND ArrayList in einem Rutsch; das ESP/Chams-
  -- Overlay (SB_TeamESP) wird separat abgeschaltet. Die Cheats laufen unsichtbar weiter.
  local function setStreamproof(on)
    g.SB_STREAMPROOF = on and true or false
    gui.Enabled = not g.SB_STREAMPROOF
    local esp = gui.Parent and gui.Parent:FindFirstChild("SB_TeamESP")
    if esp then esp.Enabled = not g.SB_STREAMPROOF end
  end
  clickRoot.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then closeList() end   -- Klick ins Leere schliesst Liste
  end)
  -- Alles laeuft in einem skalierten Host -> Groesse ueber EINEN Regler
  local UI_SCALE = 2.3
  local panelHost = Instance.new("Frame")
  panelHost.Size = UDim2.fromScale(1, 1); panelHost.BackgroundTransparency = 1
  panelHost.BorderSizePixel = 0; panelHost.Parent = clickRoot
  Instance.new("UIScale", panelHost).Scale = UI_SCALE

  -- === Einstellungs-Widgets ===
  -- Pill-Schalter mit gleitendem Knopf statt Kaestchen.
  local function makeToggleW(parent, ord, label, get, set)
    local r = Instance.new("TextButton")
    r.Size = UDim2.new(1, -10, 0, 20); r.LayoutOrder = ord; r.AutoButtonColor = false
    r.BackgroundColor3 = WIDGET; r.BorderSizePixel = 0
    r.Font = Enum.Font.Gotham; r.TextSize = 11; r.TextXAlignment = Enum.TextXAlignment.Left
    r.Text = "  " .. label; r.TextTruncate = Enum.TextTruncate.AtEnd
    r.TextColor3 = TXT_DIM; r.Parent = parent; corner(r, 2)
    local track = Instance.new("Frame"); track.Size = UDim2.fromOffset(20, 10)
    track.Position = UDim2.new(1, -26, 0.5, -5); track.BorderSizePixel = 0
    track.BackgroundColor3 = TRACK; track.Parent = r; corner(track, 5)
    local knob = Instance.new("Frame"); knob.Size = UDim2.fromOffset(8, 8)
    knob.Position = UDim2.fromOffset(1, 1); knob.BorderSizePixel = 0
    knob.BackgroundColor3 = Color3.fromRGB(150, 154, 162); knob.Parent = track; corner(knob, 4)
    local hovered = false
    local function paint(anim)
      local on = get() and true or false
      local kp = UDim2.fromOffset(on and 11 or 1, 1)
      if anim then
        tween(knob, 0.12, { Position = kp, BackgroundColor3 = on and DARKTXT or Color3.fromRGB(150, 154, 162) })
        tween(track, 0.12, { BackgroundColor3 = on and ACCENT or TRACK })
      else
        knob.Position = kp
        knob.BackgroundColor3 = on and DARKTXT or Color3.fromRGB(150, 154, 162)
        track.BackgroundColor3 = on and ACCENT or TRACK
      end
      r.TextColor3 = on and TXT or TXT_DIM
      r.BackgroundColor3 = hovered and WIDGET_H or WIDGET
    end
    paint(false)
    r.MouseEnter:Connect(function() hovered = true; paint(false) end)
    r.MouseLeave:Connect(function() hovered = false; paint(false) end)
    r.MouseButton1Click:Connect(function() set(not get()); paint(true) end)
    moduleRefs[#moduleRefs + 1] = function() if r.Parent then paint(false) end end
  end

  -- Slider mit Knopf, Wert rechts im Label und Klick/Drag auf der ganzen Zeile.
  local function makeSliderW(parent, ord, label, mn, mx, get, set, fmt)
    local holder = Instance.new("Frame"); holder.Size = UDim2.new(1, -10, 0, 32)
    holder.LayoutOrder = ord; holder.BackgroundColor3 = WIDGET; holder.BorderSizePixel = 0
    holder.Parent = parent; corner(holder, 2)
    local pad = Instance.new("UIPadding", holder)
    pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6); pad.PaddingTop = UDim.new(0, 3)
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, 0, 0, 13)
    lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.Gotham; lbl.TextSize = 11
    lbl.TextColor3 = TXT_DIM; lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = label; lbl.Parent = holder
    local val = Instance.new("TextLabel"); val.Size = UDim2.new(0, 60, 0, 13)
    val.Position = UDim2.new(1, -60, 0, 0); val.BackgroundTransparency = 1
    val.Font = Enum.Font.GothamBold; val.TextSize = 11; val.TextColor3 = ACCENT
    val.TextXAlignment = Enum.TextXAlignment.Right; val.Parent = holder
    local track = Instance.new("Frame"); track.Size = UDim2.new(1, 0, 0, 5)
    track.Position = UDim2.fromOffset(0, 18); track.BackgroundColor3 = TRACK
    track.BorderSizePixel = 0; track.Active = true; track.Parent = holder; corner(track, 3)
    local fill = Instance.new("Frame"); fill.BackgroundColor3 = ACCENT; fill.BorderSizePixel = 0
    fill.Size = UDim2.new(0, 0, 1, 0); fill.Parent = track; corner(fill, 3)
    local knob = Instance.new("Frame"); knob.Size = UDim2.fromOffset(9, 9); knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(0, 0, 0.5, 0); knob.BackgroundColor3 = Color3.fromRGB(240, 245, 240)
    knob.BorderSizePixel = 0; knob.ZIndex = 3; knob.Parent = track; corner(knob, 5)
    local function upd()
      local a = math.clamp((get() - mn) / (mx - mn), 0, 1)
      val.Text = fmt(get())
      fill.Size = UDim2.new(a, 0, 1, 0)
      knob.Position = UDim2.new(a, 0, 0.5, 0)
    end
    upd()
    local dragging = false
    local function setFrom(px)
      local rel = math.clamp((px - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
      set(mn + rel * (mx - mn)); upd()
    end
    local function grab(i)
      if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dragging = true; setFrom(i.Position.X); tween(knob, 0.1, { Size = UDim2.fromOffset(12, 12) })
      end
    end
    track.InputBegan:Connect(grab)
    holder.InputBegan:Connect(grab)                 -- ganze Zeile ist Greiflaeche
    holder.MouseEnter:Connect(function() holder.BackgroundColor3 = WIDGET_H end)
    holder.MouseLeave:Connect(function() holder.BackgroundColor3 = WIDGET end)
    table.insert(g.SB_CONNS, UIS.InputChanged:Connect(function(i)
      if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then setFrom(i.Position.X) end
    end))
    table.insert(g.SB_CONNS, UIS.InputEnded:Connect(function(i)
      if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        if dragging then tween(knob, 0.1, { Size = UDim2.fromOffset(9, 9) }) end
        dragging = false
      end
    end))
    moduleRefs[#moduleRefs + 1] = function() if holder.Parent and not dragging then upd() end end
  end

  local function makeDropdownW(parent, ord, labelFn, itemsFn, onPick)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -10, 0, 20); btn.LayoutOrder = ord; btn.AutoButtonColor = false
    btn.BackgroundColor3 = WIDGET; btn.BorderSizePixel = 0
    btn.Font = Enum.Font.Gotham; btn.TextSize = 11; btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextColor3 = TXT; btn.Text = "  " .. labelFn(); btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.Parent = parent; corner(btn, 2)
    local chev = Instance.new("TextLabel"); chev.Size = UDim2.fromOffset(14, 20)
    chev.Position = UDim2.new(1, -16, 0, 0); chev.BackgroundTransparency = 1
    chev.Font = Enum.Font.GothamBold; chev.TextSize = 10; chev.TextColor3 = ACCENT
    chev.Text = "\xe2\x96\xbc"; chev.Parent = btn
    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = WIDGET_H end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3 = WIDGET end)
    btn.MouseButton1Click:Connect(function()
      local wasOpen = openList
      closeList()
      if wasOpen then return end                       -- zweiter Klick schliesst nur
      local items = itemsFn()
      local sf = Instance.new("ScrollingFrame")
      -- panelHost ist um UI_SCALE skaliert -> in Host-lokalen (unskalierten) Koordinaten setzen
      local baseW = btn.AbsoluteSize.X / UI_SCALE
      sf.Size = UDim2.fromOffset(math.max(baseW, 110), math.min(math.max(#items, 1) * 20, 160))
      sf.Position = UDim2.fromOffset(btn.AbsolutePosition.X / UI_SCALE, (btn.AbsolutePosition.Y + btn.AbsoluteSize.Y) / UI_SCALE + 2)
      sf.BackgroundColor3 = Color3.fromRGB(14, 15, 18); sf.BorderSizePixel = 0
      sf.ScrollBarThickness = 3; sf.ScrollBarImageColor3 = ACCENT
      sf.CanvasSize = UDim2.fromOffset(0, #items * 20)
      sf.ZIndex = 60; sf.Parent = panelHost; corner(sf, 2); stroke(sf, Color3.fromRGB(0, 0, 0), 0.35)
      local lay = Instance.new("UIListLayout", sf); lay.SortOrder = Enum.SortOrder.LayoutOrder
      local cur = labelFn()
      for _, name in ipairs(items) do
        local it = Instance.new("TextButton")
        it.Size = UDim2.new(1, 0, 0, 20); it.BackgroundColor3 = Color3.fromRGB(20, 21, 26)
        it.BorderSizePixel = 0; it.Font = Enum.Font.Gotham; it.TextSize = 11
        it.AutoButtonColor = false; it.TextXAlignment = Enum.TextXAlignment.Left
        it.Text = "  " .. name; it.ZIndex = 61; it.Parent = sf
        local picked = cur:find(name, 1, true) ~= nil
        it.TextColor3 = picked and ACCENT or Color3.fromRGB(205, 208, 215)
        it.MouseEnter:Connect(function() it.BackgroundColor3 = Color3.fromRGB(32, 35, 41) end)
        it.MouseLeave:Connect(function() it.BackgroundColor3 = Color3.fromRGB(20, 21, 26) end)
        it.MouseButton1Click:Connect(function() onPick(name); btn.Text = "  " .. labelFn(); closeList() end)
      end
      openList = sf
    end)
    moduleRefs[#moduleRefs + 1] = function() if btn.Parent then btn.Text = "  " .. labelFn() end end
  end

  -- Ueberschrift innerhalb eines Einstellungs-Blocks
  local function makeHeadingW(parent, ord, text, col)
    local l = Instance.new("TextLabel"); l.Size = UDim2.new(1, -10, 0, 15); l.LayoutOrder = ord
    l.BackgroundTransparency = 1; l.Font = Enum.Font.GothamBold; l.TextSize = 10
    l.TextColor3 = col or Color3.fromRGB(140, 144, 152); l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = string.upper(text); l.Parent = parent
    return l
  end

  -- Inline-Spielerliste (z.B. Aim-Ausnahmen): scrollbare Haekchen pro Spieler
  local function makePlayerToggles(parent, ord, isOn, onToggle)
    local others = {}
    for _, pl in ipairs(Players:GetPlayers()) do if pl ~= lp then others[#others + 1] = pl end end
    table.sort(others, function(a, b) return a.Name:lower() < b.Name:lower() end)
    if #others == 0 then
      local none = Instance.new("TextLabel"); none.Size = UDim2.new(1, -10, 0, 18)
      none.LayoutOrder = ord; none.BackgroundTransparency = 1; none.Font = Enum.Font.Gotham
      none.TextSize = 11; none.TextColor3 = TXT_DIM; none.TextXAlignment = Enum.TextXAlignment.Left
      none.Text = "  keine anderen Spieler"; none.Parent = parent; return
    end
    -- Scrollbarer Container: max MAXROWS Zeilen sichtbar, der Rest wird gescrollt
    local ROW, MAXROWS = 23, 6
    local box = Instance.new("ScrollingFrame")
    box.Size = UDim2.new(1, 0, 0, math.min(#others, MAXROWS) * ROW)
    box.LayoutOrder = ord; box.BackgroundTransparency = 1; box.BorderSizePixel = 0
    box.ScrollBarThickness = 3; box.ScrollBarImageColor3 = ACCENT
    box.CanvasSize = UDim2.fromOffset(0, #others * ROW)
    box.ScrollingDirection = Enum.ScrollingDirection.Y; box.Parent = parent
    local lay = Instance.new("UIListLayout", box); lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Padding = UDim.new(0, 3); lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
    for idx, pl in ipairs(others) do
      makeToggleW(box, idx, pl.Name, function() return isOn(pl.Name) end, function() onToggle(pl.Name) end)
    end
  end

  -- === Panel (Kategorie) ===
  local PANEL_W = 132
  local function makePanel(title, px, py)
    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(PANEL_W, 0); panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.Position = UDim2.fromOffset(px, py); panel.BackgroundColor3 = PANEL_BG
    panel.BackgroundTransparency = 0.02; panel.BorderSizePixel = 0; panel.Active = true
    panel.Parent = panelHost; corner(panel, 0); stroke(panel, Color3.fromRGB(0, 0, 0), 0.35)
    local plist = Instance.new("UIListLayout", panel); plist.SortOrder = Enum.SortOrder.LayoutOrder
    -- Header mit Verlauf + Drag + Einklappen
    local head = Instance.new("TextLabel")
    head.Size = UDim2.new(1, 0, 0, 21); head.LayoutOrder = 0; head.BackgroundColor3 = ACCENT
    head.BorderSizePixel = 0; head.Font = Enum.Font.GothamBold; head.TextSize = 12
    head.TextColor3 = DARKTXT; head.TextXAlignment = Enum.TextXAlignment.Left
    head.Text = "   " .. title; head.Active = true; head.Parent = panel
    local hg = Instance.new("UIGradient", head)
    hg.Color = ColorSequence.new(ACCENT, ACCENT_D); hg.Rotation = 90
    local stripe = Instance.new("Frame"); stripe.Size = UDim2.new(0, 3, 1, 0)
    stripe.BackgroundColor3 = Color3.fromRGB(245, 255, 245); stripe.BackgroundTransparency = 0.55
    stripe.BorderSizePixel = 0; stripe.Parent = head
    local hmark = Instance.new("TextButton"); hmark.Size = UDim2.fromOffset(18, 21)
    hmark.Position = UDim2.new(1, -18, 0, 0); hmark.BackgroundTransparency = 1
    hmark.Font = Enum.Font.GothamBold; hmark.TextSize = 13; hmark.TextColor3 = DARKTXT
    hmark.AutoButtonColor = false; hmark.Text = "\xe2\x80\x93"; hmark.Parent = head
    local body = Instance.new("Frame"); body.BackgroundTransparency = 1
    body.Size = UDim2.new(1, 0, 0, 0); body.AutomaticSize = Enum.AutomaticSize.Y
    body.LayoutOrder = 1; body.Parent = panel
    local bl = Instance.new("UIListLayout", body); bl.SortOrder = Enum.SortOrder.LayoutOrder
    bl.Padding = UDim.new(0, 1)
    local bp = Instance.new("UIPadding", body)
    bp.PaddingTop = UDim.new(0, 2); bp.PaddingBottom = UDim.new(0, 3)
    bp.PaddingLeft = UDim.new(0, 2); bp.PaddingRight = UDim.new(0, 2)
    -- Einklappen (Klick auf das Zeichen rechts im Header)
    hmark.MouseButton1Click:Connect(function()
      body.Visible = not body.Visible
      hmark.Text = body.Visible and "\xe2\x80\x93" or "+"
    end)
    -- Drag am Header
    local dragging, ds, sp
    head.InputBegan:Connect(function(i)
      if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dragging = true; ds = i.Position; sp = panel.Position
      end
    end)
    table.insert(g.SB_CONNS, UIS.InputChanged:Connect(function(i)
      if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
        local d = i.Position - ds
        panel.Position = UDim2.fromOffset(sp.X.Offset + d.X, sp.Y.Offset + d.Y)
      end
    end))
    table.insert(g.SB_CONNS, UIS.InputEnded:Connect(function(i)
      if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
    return { body = body, ord = 0, frame = panel }
  end

  -- Baut den ein/ausklappbaren Einstellungs-Container (Rechtsklick / Pfeil)
  local function makeExpander(panel, ord, arrow, buildSettings)
    local expanded, sf = false, nil
    local function toggle()
      expanded = not expanded
      if expanded then
        sf = Instance.new("Frame"); sf.LayoutOrder = ord * 10 + 1
        sf.Size = UDim2.new(1, 0, 0, 0); sf.AutomaticSize = Enum.AutomaticSize.Y
        sf.BackgroundColor3 = SET_BG; sf.BorderSizePixel = 0; sf.Parent = panel.body
        corner(sf, 2)
        local sl = Instance.new("UIListLayout", sf); sl.SortOrder = Enum.SortOrder.LayoutOrder
        sl.Padding = UDim.new(0, 3); sl.HorizontalAlignment = Enum.HorizontalAlignment.Center
        local spad = Instance.new("UIPadding", sf)
        spad.PaddingTop = UDim.new(0, 5); spad.PaddingBottom = UDim.new(0, 6)
        -- gruene Kante links: zeigt, dass der Block zum Modul darueber gehoert
        local edge = Instance.new("Frame"); edge.Size = UDim2.new(0, 2, 1, 0)
        edge.BackgroundColor3 = ACCENT; edge.BackgroundTransparency = 0.35
        edge.BorderSizePixel = 0; edge.ZIndex = 2; edge.Parent = sf
        buildSettings(sf)
        if arrow then arrow.Text = "\xe2\x80\x93" end
      else
        if sf then sf:Destroy(); sf = nil end
        if arrow then arrow.Text = "+" end
      end
    end
    return toggle
  end

  -- Modul-Zeile (Toggle) mit optionalen Einstellungen
  local function addModule(panel, name, get, set, buildSettings)
    panel.ord = panel.ord + 1
    local ord = panel.ord
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, ROW_H); row.LayoutOrder = ord * 10; row.AutoButtonColor = false
    row.BackgroundColor3 = ROW_OFF; row.BorderSizePixel = 0; row.Font = Enum.Font.Gotham
    row.TextSize = 12; row.TextXAlignment = Enum.TextXAlignment.Left; row.Text = "   " .. name
    row.TextTruncate = Enum.TextTruncate.AtEnd
    row.TextColor3 = TXT_DIM; row.Parent = panel.body; corner(row, 2)
    -- Aktiv-Kante links (statt des alten Punktes rechts)
    local bar = Instance.new("Frame"); bar.Size = UDim2.new(0, 2, 1, 0)
    bar.BackgroundColor3 = ACCENT; bar.BorderSizePixel = 0; bar.Visible = false; bar.Parent = row
    local arrow
    if buildSettings then
      arrow = Instance.new("TextButton"); arrow.Size = UDim2.fromOffset(16, ROW_H)
      arrow.Position = UDim2.new(1, -16, 0, 0); arrow.BackgroundTransparency = 1
      arrow.AutoButtonColor = false
      arrow.Font = Enum.Font.GothamBold; arrow.TextSize = 13; arrow.Text = "+"; arrow.Parent = row
    end
    local hovered = false
    local function paint()
      local on = get()
      row.BackgroundColor3 = on and ROW_ON or (hovered and ROW_HOV or ROW_OFF)
      row.TextColor3 = on and DARKTXT or (hovered and TXT or TXT_DIM)
      bar.Visible = (not on) and hovered
      if arrow then arrow.TextColor3 = on and DARKTXT or Color3.fromRGB(130, 134, 142) end
    end
    paint(); moduleRefs[#moduleRefs + 1] = paint
    row.MouseEnter:Connect(function() hovered = true; paint() end)
    row.MouseLeave:Connect(function() hovered = false; paint() end)
    row.MouseButton1Click:Connect(function() set(not get()); paint() end)
    if buildSettings then
      local toggle = makeExpander(panel, ord, arrow, buildSettings)
      arrow.MouseButton1Click:Connect(toggle)
      row.MouseButton2Click:Connect(toggle)
    end
  end

  -- Aktion-Zeile (kein Toggle) - z.B. Apparate / Map zurueckholen
  local function addAction(panel, labelFn, onClick, buildSettings)
    panel.ord = panel.ord + 1
    local ord = panel.ord
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, ROW_H); row.LayoutOrder = ord * 10; row.AutoButtonColor = false
    row.BackgroundColor3 = Color3.fromRGB(16, 17, 21); row.BorderSizePixel = 0; row.Font = Enum.Font.Gotham
    row.TextSize = 12; row.TextXAlignment = Enum.TextXAlignment.Left; row.Text = "   " .. labelFn()
    row.TextTruncate = Enum.TextTruncate.AtEnd
    row.TextColor3 = Color3.fromRGB(178, 182, 192); row.Parent = panel.body; corner(row, 2)
    local bar = Instance.new("Frame"); bar.Size = UDim2.new(0, 2, 1, 0)
    bar.BackgroundColor3 = ACCENT; bar.BorderSizePixel = 0; bar.Visible = false; bar.Parent = row
    moduleRefs[#moduleRefs + 1] = function() if row.Parent then row.Text = "   " .. labelFn() end end
    local arrow
    if buildSettings then
      arrow = Instance.new("TextButton"); arrow.Size = UDim2.fromOffset(16, ROW_H)
      arrow.Position = UDim2.new(1, -16, 0, 0); arrow.BackgroundTransparency = 1
      arrow.AutoButtonColor = false
      arrow.Font = Enum.Font.GothamBold; arrow.TextSize = 13; arrow.TextColor3 = Color3.fromRGB(130, 134, 142)
      arrow.Text = "+"; arrow.Parent = row
    end
    row.MouseEnter:Connect(function()
      row.BackgroundColor3 = ROW_HOV; row.TextColor3 = TXT; bar.Visible = true
    end)
    row.MouseLeave:Connect(function()
      row.BackgroundColor3 = Color3.fromRGB(16, 17, 21)
      row.TextColor3 = Color3.fromRGB(178, 182, 192); bar.Visible = false
    end)
    row.MouseButton1Click:Connect(function()
      onClick(); row.Text = "   " .. labelFn()
      -- kurzer gruener Blitz als Klick-Feedback
      row.BackgroundColor3 = ACCENT; row.TextColor3 = DARKTXT
      task.delay(0.12, function()
        if row.Parent then row.BackgroundColor3 = ROW_HOV; row.TextColor3 = TXT end
      end)
    end)
    if buildSettings then
      local toggle = makeExpander(panel, ord, arrow, buildSettings)
      arrow.MouseButton1Click:Connect(toggle)
      row.MouseButton2Click:Connect(toggle)
    end
  end

  -- Info-Text innerhalb eines Einstellungs-Blocks
  local function addInfo(parent, ord, text, height)
    local i = Instance.new("TextLabel"); i.Size = UDim2.new(1, -12, 0, height or 44); i.LayoutOrder = ord
    i.BackgroundTransparency = 1; i.Font = Enum.Font.Gotham; i.TextSize = 10
    i.TextColor3 = Color3.fromRGB(120, 124, 132); i.TextWrapped = true
    i.TextXAlignment = Enum.TextXAlignment.Left; i.TextYAlignment = Enum.TextYAlignment.Top
    i.Text = text; i.Parent = parent
    return i
  end

  -- === Combat-Panel ===
  local combat = makePanel("Combat", 26, 40)
  addModule(combat, "Silent-Aim",
    function() return g.SB_AIM end,
    function(v) g.SB_AIM = v; if v then startSelector(); startAim() end end,
    function(sf)
      makeSliderW(sf, 1, "FOV", 20, 500, function() return tonumber(g.SB_AIM_FOV) or 140 end,
        function(v) g.SB_AIM_FOV = math.floor(v + 0.5) end, function(v) return tostring(math.floor(v + 0.5)) end)
      makeSliderW(sf, 2, "Range", 50, 1000, function() return tonumber(g.SB_AIM_RANGE) or 500 end,
        function(v) g.SB_AIM_RANGE = math.floor(v + 0.5) end, function(v) return tostring(math.floor(v + 0.5)) end)
      makeToggleW(sf, 3, "Vorhalt (Lead)", function() return g.SB_AIM_PRED == true end, function() g.SB_AIM_PRED = not g.SB_AIM_PRED end)
      makeToggleW(sf, 4, "NPC-Aim", function() return g.SB_AIM_NPC == true end, function() g.SB_AIM_NPC = not g.SB_AIM_NPC end)
      makeToggleW(sf, 5, "Trefferzone variieren", function() return g.SB_AIM_ZONES == true end,
        function() g.SB_AIM_ZONES = not g.SB_AIM_ZONES; g.SB_AIM_ZONE = {} end)
      makeSliderW(sf, 6, "Zonen-Wechsel", 0.2, 5, function() return tonumber(g.SB_AIM_ZONEROLL) or 1.2 end,
        function(v) g.SB_AIM_ZONEROLL = math.floor(v * 10 + 0.5) / 10 end,
        function(v) return string.format("%.1fs", v) end)
      local lblEx = Instance.new("TextLabel"); lblEx.Size = UDim2.new(1, -12, 0, 16); lblEx.LayoutOrder = 30
      lblEx.BackgroundTransparency = 1; lblEx.Font = Enum.Font.GothamBold; lblEx.TextSize = 11
      lblEx.TextColor3 = Color3.fromRGB(160, 160, 180); lblEx.TextXAlignment = Enum.TextXAlignment.Left
      lblEx.Text = "Aim-Ausnahmen:"; lblEx.Parent = sf
      makePlayerToggles(sf, 31, function(n) return g.SB_AIM_EXEMPT[n] == true end,
        function(n) if g.SB_AIM_EXEMPT[n] then g.SB_AIM_EXEMPT[n] = nil else g.SB_AIM_EXEMPT[n] = true end end)
      -- Ganze Fraktion ausnehmen (aus dem Spiel: factionConfig-IDs + GroupService-Namen)
      local lblFac = Instance.new("TextLabel"); lblFac.Size = UDim2.new(1, -12, 0, 16); lblFac.LayoutOrder = 32
      lblFac.BackgroundTransparency = 1; lblFac.Font = Enum.Font.GothamBold; lblFac.TextSize = 11
      lblFac.TextColor3 = Color3.fromRGB(160, 160, 180); lblFac.TextXAlignment = Enum.TextXAlignment.Left
      lblFac.Text = "Fraktions-Ausnahmen:"; lblFac.Parent = sf
      local refreshKeep   -- forward-declared: baut die Keep-Target-Liste bei Fraktions-Aenderung neu
      for i, fid in ipairs(factionIds()) do
        makeToggleW(sf, 32 + i, factionName(fid),
          function() return g.SB_AIM_EXEMPT_FACTION[fid] == true end,
          function()
            if g.SB_AIM_EXEMPT_FACTION[fid] then g.SB_AIM_EXEMPT_FACTION[fid] = nil else g.SB_AIM_EXEMPT_FACTION[fid] = true end
            if refreshKeep then refreshKeep() end
          end)
      end
      -- Keep-Target: einzelne Mitglieder ausgenommener Fraktionen doch anvisieren (Override der Fraktions-Ausnahme)
      local lblKeep = Instance.new("TextLabel"); lblKeep.Size = UDim2.new(1, -12, 0, 16); lblKeep.LayoutOrder = 50
      lblKeep.BackgroundTransparency = 1; lblKeep.Font = Enum.Font.GothamBold; lblKeep.TextSize = 11
      lblKeep.TextColor3 = Color3.fromRGB(190, 150, 235); lblKeep.TextXAlignment = Enum.TextXAlignment.Left
      lblKeep.Text = "Keep-Target (trotzdem anvisieren):"; lblKeep.Parent = sf
      local keepHost = Instance.new("Frame"); keepHost.LayoutOrder = 51; keepHost.BackgroundTransparency = 1
      keepHost.Size = UDim2.new(1, 0, 0, 0); keepHost.AutomaticSize = Enum.AutomaticSize.Y; keepHost.Parent = sf
      local keepLay = Instance.new("UIListLayout", keepHost); keepLay.SortOrder = Enum.SortOrder.LayoutOrder; keepLay.Padding = UDim.new(0, 3)
      refreshKeep = function()
        for _, c in ipairs(keepHost:GetChildren()) do if not c:IsA("UIListLayout") then c:Destroy() end end
        local mem = {}
        for _, pl in ipairs(Players:GetPlayers()) do
          if pl ~= lp then
            local fid = playerFactionId(pl)
            if fid and g.SB_AIM_EXEMPT_FACTION[fid] then mem[#mem + 1] = pl end
          end
        end
        table.sort(mem, function(a, b) return a.Name:lower() < b.Name:lower() end)
        if #mem == 0 then
          local none = Instance.new("TextLabel"); none.Size = UDim2.new(1, -12, 0, 18); none.LayoutOrder = 1
          none.BackgroundTransparency = 1; none.Font = Enum.Font.Gotham; none.TextSize = 11
          none.TextColor3 = Color3.fromRGB(150, 150, 165); none.TextXAlignment = Enum.TextXAlignment.Left
          none.Text = "  keine ausgenommene Fraktion online"; none.Parent = keepHost; return
        end
        local ROW, MAXR = 22, 5
        local scr = Instance.new("ScrollingFrame"); scr.LayoutOrder = 1
        scr.Size = UDim2.new(1, 0, 0, math.min(#mem, MAXR) * ROW); scr.BackgroundTransparency = 1
        scr.BorderSizePixel = 0; scr.ScrollBarThickness = 4; scr.ScrollBarImageColor3 = Color3.fromRGB(150, 120, 200)
        scr.CanvasSize = UDim2.fromOffset(0, #mem * ROW); scr.ScrollingDirection = Enum.ScrollingDirection.Y; scr.Parent = keepHost
        local sl = Instance.new("UIListLayout", scr); sl.SortOrder = Enum.SortOrder.LayoutOrder
        for i, pl in ipairs(mem) do
          makeToggleW(scr, i, pl.Name,
            function() return g.SB_AIM_KEEP[pl.Name] == true end,
            function() if g.SB_AIM_KEEP[pl.Name] then g.SB_AIM_KEEP[pl.Name] = nil else g.SB_AIM_KEEP[pl.Name] = true end end)
        end
      end
      refreshKeep()
    end)
  addModule(combat, "Auto-Shield",
    function() return g.SB_SHIELD end,
    function(v) g.SB_SHIELD = v; if v then hookShield() end end)
  addModule(combat, "Auto-Clash",
    function() return g.SB_CLASH end,
    function(v) g.SB_CLASH = v; if v then startClashAuto() end end)
  addModule(combat, "Auto-Dodge",
    function() return g.SB_DODGE end,
    function(v) g.SB_DODGE = v; if v then g.SB_DODGE_SKIPACC = 0; hookDodge() end end,
    function(sf)
      makeSliderW(sf, 1, "Dodge-Rate", 0, 100, function() return tonumber(g.SB_DODGE_PCT) or 100 end,
        function(v) g.SB_DODGE_PCT = math.floor(v * 10 + 0.5) / 10 end, function(v) return string.format("%.1f%%", v) end)
    end)
  addModule(combat, "Safe-Combat",
    function() return g.SB_SAFE end,
    function(v) g.SB_SAFE = v; if v then startSelector() end end,
    function(sf)
      for i = 1, 4 do
        makeDropdownW(sf, i, function() return "Slot " .. i .. ": " .. tostring(g.SB_SAFE_ROT[i]) end,
          getSpellList, function(n) g.SB_SAFE_ROT[i] = n end)
      end
    end)

  -- === Troll-Panel ===
  local troll = makePanel("Troll", 26, 40 + 210)
  addModule(troll, "Shotgun",
    function() return g.SB_SHOT end,
    function(v) g.SB_SHOT = v; if v then startShotgun() end end,
    function(sf)
      makeSliderW(sf, 1, "Burst", 1, 12, function() return tonumber(g.SB_SHOT_BURST) or 6 end,
        function(v) g.SB_SHOT_BURST = math.floor(v + 0.5) end,
        function(v) return math.floor(v + 0.5) .. " Spells" end)
      makeSliderW(sf, 2, "Takt", 0, 0.5, function() return tonumber(g.SB_SHOT_IV) or 0.02 end,
        function(v) g.SB_SHOT_IV = math.floor(v * 100 + 0.5) / 100 end,
        function(v) return v <= 0.001 and "max. Speed" or string.format("%.2fs", v) end)
      makeToggleW(sf, 3, "Stab re-equip", function() return g.SB_SHOT_REEQUIP ~= false end,
        function() g.SB_SHOT_REEQUIP = not (g.SB_SHOT_REEQUIP ~= false) end)
      local st = Instance.new("TextLabel"); st.Size = UDim2.new(1, -12, 0, 46); st.LayoutOrder = 4
      st.BackgroundTransparency = 1; st.Font = Enum.Font.Gotham; st.TextSize = 11
      st.TextColor3 = Color3.fromRGB(150, 150, 170); st.TextWrapped = true
      st.TextXAlignment = Enum.TextXAlignment.Left; st.Text = "-"; st.Parent = sf
      moduleRefs[#moduleRefs + 1] = function()
        if not st.Parent then return end
        st.Text = g.SB_SHOT
          and ("Linksklick = " .. (tonumber(g.SB_SHOT_BURST) or 6) .. " Spells auf einmal.  Pool: "
               .. table.concat(g.SB_SHOT_LIST or {}, ", ") .. "  | zuletzt: " .. tostring(g.SB_SHOT_SPELL or "-")
               .. " (" .. (tonumber(g.SB_SHOT_COUNT) or 0) .. " Casts)")
          or "feuert nur auf Klick: 6 Combat-Spells am Stueck aus den eigenen Bind-Sets, alphabetisch rotierend."
      end
      local rb = Instance.new("TextButton"); rb.Size = UDim2.new(1, -12, 0, 20); rb.LayoutOrder = 5
      rb.BackgroundColor3 = Color3.fromRGB(34, 30, 50); rb.BorderSizePixel = 0
      rb.Font = Enum.Font.Gotham; rb.TextSize = 12; rb.TextColor3 = Color3.fromRGB(215, 210, 235)
      rb.Text = "zurueck auf A"; rb.Parent = sf; corner(rb, 4)
      rb.MouseButton1Click:Connect(function() g.SB_SHOT_IDX = 1 end)
    end)
  addAction(troll, function() return "Snipe [E] \xe2\x86\x92 " .. tostring(g.SB_AIM_TARGET or "Cursor-Ziel") end,
    function() task.spawn(doSnipe) end,
    function(sf)
      makeSliderW(sf, 1, "Tiefe", 5, 60, function() return tonumber(g.SB_SNIPE_DEPTH) or 15 end,
        function(v) g.SB_SNIPE_DEPTH = math.floor(v + 0.5) end,
        function(v) return math.floor(v + 0.5) .. " Studs" end)
      makeSliderW(sf, 2, "Cast-Delay", 0, 0.3, function() return tonumber(g.SB_SNIPE_DELAY) or 0.05 end,
        function(v) g.SB_SNIPE_DELAY = math.floor(v * 100 + 0.5) / 100 end,
        function(v) return string.format("%.2fs", v) end)
      makeToggleW(sf, 3, "Terrain-Blase", function() return g.SB_SNIPE_CARVE ~= false end,
        function() g.SB_SNIPE_CARVE = not (g.SB_SNIPE_CARVE ~= false) end)
      local sn = Instance.new("TextLabel"); sn.Size = UDim2.new(1, -12, 0, 46); sn.LayoutOrder = 4
      sn.BackgroundTransparency = 1; sn.Font = Enum.Font.Gotham; sn.TextSize = 11
      sn.TextColor3 = Color3.fromRGB(150, 150, 170); sn.TextWrapped = true
      sn.TextXAlignment = Enum.TextXAlignment.Left; sn.Parent = sf
      moduleRefs[#moduleRefs + 1] = function()
        if not sn.Parent then return end
        sn.Text = "M: erst ein normaler Tarnschuss, im Moment des Einschlags TP unter das Ziel + "
          .. "zweiter Spell von unten, sofort zurueck. "
          .. "zuletzt: " .. tostring(g.SB_SNIPE_STATUS or "-") .. " (" .. (tonumber(g.SB_SNIPE_COUNT) or 0) .. ")"
      end
    end)

  -- === Farm-Panel (Autofarm, Map-Handling, KD) ===
  local farm = makePanel("Farm", 26 + PANEL_W + 10, 40)
  addModule(farm, "Autofarm",
    function() return g.SB_FARM end,
    function(v) g.SB_FARM = v; if v then startFarm() end end,
    function(sf)
      makeDropdownW(sf, 1, function() return "Spell: " .. tostring(g.SB_FARM_SPELL) end,
        getSpellList, function(n) g.SB_FARM_SPELL = n end)
      makeSliderW(sf, 2, "Tiefe (Studs)", 3, 60, function() return tonumber(g.SB_FARM_DEPTH) or 15 end,
        function(v) g.SB_FARM_DEPTH = math.floor(v + 0.5) end, function(v) return tostring(math.floor(v + 0.5)) end)
      makeSliderW(sf, 3, "Delay/Ziel", 0.05, 1.5, function() return tonumber(g.SB_FARM_DELAY) or 0.25 end,
        function(v) g.SB_FARM_DELAY = math.floor(v * 100 + 0.5) / 100 end, function(v) return string.format("%.2fs", v) end)
      makeSliderW(sf, 4, "Runden-Pause", 0, 5, function() return tonumber(g.SB_FARM_ROUND) or 0.5 end,
        function(v) g.SB_FARM_ROUND = math.floor(v * 10 + 0.5) / 10 end, function(v) return string.format("%.1fs", v) end)
      makeToggleW(sf, 5, "Safe Zones auslassen", function() return g.SB_FARM_SKIP_SAFE == true end,
        function() g.SB_FARM_SKIP_SAFE = not g.SB_FARM_SKIP_SAFE end)
      makeToggleW(sf, 6, "Aim-Ausnahmen beachten", function() return g.SB_FARM_EXEMPT_OK == true end,
        function() g.SB_FARM_EXEMPT_OK = not g.SB_FARM_EXEMPT_OK end)
      makeToggleW(sf, 7, "Staff auslassen", function() return g.SB_FARM_SKIP_STAFF == true end,
        function() g.SB_FARM_SKIP_STAFF = not g.SB_FARM_SKIP_STAFF end)
      makeToggleW(sf, 8, "Map wegraeumen beim Start", function() return g.SB_FARM_NUKE == true end,
        function() g.SB_FARM_NUKE = not g.SB_FARM_NUKE end)
      makeToggleW(sf, 9, "Map beim Stoppen zurueck", function() return g.SB_FARM_UNNUKE == true end,
        function() g.SB_FARM_UNNUKE = not g.SB_FARM_UNNUKE end)
      makeToggleW(sf, 10, "Terrain-Blase (umkehrbar)", function() return g.SB_FARM_CARVE == true end,
        function() g.SB_FARM_CARVE = not g.SB_FARM_CARVE end)
      makeToggleW(sf, 11, "Terrain global loeschen", function() return g.SB_FARM_WIPE_TERRAIN == true end,
        function() g.SB_FARM_WIPE_TERRAIN = not g.SB_FARM_WIPE_TERRAIN end)
      makeToggleW(sf, 12, "Endlos wiederholen", function() return g.SB_FARM_REPEAT == true end,
        function() g.SB_FARM_REPEAT = not g.SB_FARM_REPEAT end)
      makeToggleW(sf, 13, "Am Ende zurueck", function() return g.SB_FARM_RETURN == true end,
        function() g.SB_FARM_RETURN = not g.SB_FARM_RETURN end)
      addInfo(sf, 14, "Map wird nur ausgehaengt und ist per 'Map zurueckholen' wieder da. Terrain-Blase = pro Spot nur ein kleines Loch (gesichert, kommt zurueck). 'Terrain global loeschen' ist endgueltig - nur ein Rejoin holt es wieder.", 76)
    end)
  addAction(farm, function()
      return g.SB_MAP_NUKED and ("Map weg (" .. #g.SB_MAP_PARKED .. " Teile)") or "Map wegraeumen (lokal)"
    end,
    function() parkMap() end)
  addAction(farm, function()
      if g.SB_TERR_WIPED then return "Map zurueckholen (Terrain: Rejoin)" end
      return g.SB_MAP_LAST and ("Map zurueckgeholt (" .. tostring(g.SB_MAP_LAST) .. ")") or "Map zurueckholen"
    end,
    function() restoreMap() end)
  addModule(farm, "KD-Farm",
    function() return g.SB_KD end,
    function(v) g.SB_KD = v; if v then g.SB_KD_COUNT = 0; startKD() end end,
    function(sf)
      makeSliderW(sf, 1, "Pause nach Respawn", 0.1, 10, function() return tonumber(g.SB_KD_PAUSE) or 0.3 end,
        function(v) g.SB_KD_PAUSE = math.floor(v * 10 + 0.5) / 10 end, function(v) return string.format("%.1fs", v) end)
      makeSliderW(sf, 2, "Stopp nach n Toden", 0, 200, function() return tonumber(g.SB_KD_LIMIT) or 0 end,
        function(v) g.SB_KD_LIMIT = math.floor(v + 0.5) end,
        function(v) local n = math.floor(v + 0.5); return (n == 0) and "endlos" or tostring(n) end)
      addInfo(sf, 3, "Nutzt den Reset-Pfad des Spiels (resetEvent). Tod nach ~0.15s, Respawn nach ~3s -> ca. 15 Tode/Minute; schneller laesst der Server nicht zu.", 52)
    end)
  -- Live-Anzeige der eigenen oeffentlichen Stats (aktualisiert sich im Refresh-Loop)
  addAction(farm, function() return kdLabel() end, function() end)

  -- === Utility-Panel ===
  local util = makePanel("Utility", 26 + (PANEL_W + 10) * 2, 40)
  addAction(util, function() return "Apparate \xe2\x86\x92 " .. tostring(g.SB_APPA_TARGET or "-") end,
    function() apparateTo(g.SB_APPA_TARGET) end,
    function(sf)
      makeDropdownW(sf, 1, function() return "Ziel: " .. tostring(g.SB_APPA_TARGET or "-") end,
        function()
          local names = {}
          for _, p in ipairs(Players:GetPlayers()) do if p ~= lp then names[#names + 1] = p.Name end end
          table.sort(names); return names
        end,
        function(n) g.SB_APPA_TARGET = n end)
    end)
  addAction(util, function() return g.SB_APPA_PENDING and "Appa geladen - Klick castet" or "Appa laden" end,
    function() g.SB_APPA_PENDING = true; disarmSpell(); startSelector() end)
  addModule(util, "Box-ESP",
    function() return g.SB_TEAM_ESP end,
    function(v) g.SB_TEAM_ESP = v; if v then startVisuals() end end)
  addModule(util, "ESP-Namen",
    function() return g.SB_ESP_NAMES end,
    function(v) g.SB_ESP_NAMES = v; if v then startVisuals() end end)
  addModule(util, "Chams (sichtbar)",
    function() return g.SB_CHAMS end,
    function(v) g.SB_CHAMS = v; if v then startVisuals() end end)

  -- Freunde: von Silent-Aim UND Autofarm ausgenommen, per UserId in einer Datei gemerkt
  addAction(util, function() return "Freunde (" .. friendCount() .. ")" end,
    function() end,
    function(sf)
      makeToggleW(sf, 1, "Roblox-Freunde automatisch",
        function() return g.SB_FRIEND_AUTO == true end,
        function() g.SB_FRIEND_AUTO = not g.SB_FRIEND_AUTO; saveFriends() end)
      local l1 = Instance.new("TextLabel"); l1.Size = UDim2.new(1, -12, 0, 16); l1.LayoutOrder = 2
      l1.BackgroundTransparency = 1; l1.Font = Enum.Font.GothamBold; l1.TextSize = 11
      l1.TextColor3 = Color3.fromRGB(160, 160, 180); l1.TextXAlignment = Enum.TextXAlignment.Left
      l1.Text = "Im Server:"; l1.Parent = sf
      local others = {}
      for _, pl in ipairs(Players:GetPlayers()) do if pl ~= lp then others[#others + 1] = pl end end
      table.sort(others, function(a, b) return a.Name:lower() < b.Name:lower() end)
      if #others == 0 then
        local none = Instance.new("TextLabel"); none.Size = UDim2.new(1, -12, 0, 18); none.LayoutOrder = 3
        none.BackgroundTransparency = 1; none.Font = Enum.Font.Gotham; none.TextSize = 11
        none.TextColor3 = Color3.fromRGB(150, 150, 165); none.TextXAlignment = Enum.TextXAlignment.Left
        none.Text = "  keine anderen Spieler"; none.Parent = sf
      else
        local ROW, MAXR = 22, 6
        local scr = Instance.new("ScrollingFrame"); scr.LayoutOrder = 3
        scr.Size = UDim2.new(1, 0, 0, math.min(#others, MAXR) * ROW); scr.BackgroundTransparency = 1
        scr.BorderSizePixel = 0; scr.ScrollBarThickness = 4; scr.ScrollBarImageColor3 = Color3.fromRGB(120, 110, 160)
        scr.CanvasSize = UDim2.fromOffset(0, #others * ROW); scr.ScrollingDirection = Enum.ScrollingDirection.Y
        scr.Parent = sf
        local sl = Instance.new("UIListLayout", scr); sl.SortOrder = Enum.SortOrder.LayoutOrder
        for i, pl in ipairs(others) do
          makeToggleW(scr, i, pl.Name,
            function() return g.SB_FRIENDS[tostring(pl.UserId)] ~= nil end,
            function() toggleFriend(pl) end)
        end
      end
      -- gespeicherte Freunde, die gerade nicht im Server sind (Haken weg = loeschen)
      local off = {}
      for id, nm in pairs(g.SB_FRIENDS) do
        if not Players:GetPlayerByUserId(tonumber(id) or 0) then off[#off + 1] = { id = id, nm = nm } end
      end
      table.sort(off, function(a, b) return tostring(a.nm):lower() < tostring(b.nm):lower() end)
      if #off > 0 then
        local l2 = Instance.new("TextLabel"); l2.Size = UDim2.new(1, -12, 0, 16); l2.LayoutOrder = 4
        l2.BackgroundTransparency = 1; l2.Font = Enum.Font.GothamBold; l2.TextSize = 11
        l2.TextColor3 = Color3.fromRGB(160, 160, 180); l2.TextXAlignment = Enum.TextXAlignment.Left
        l2.Text = "Gespeichert (offline):"; l2.Parent = sf
        local ROW, MAXR = 22, 5
        local scr2 = Instance.new("ScrollingFrame"); scr2.LayoutOrder = 5
        scr2.Size = UDim2.new(1, 0, 0, math.min(#off, MAXR) * ROW); scr2.BackgroundTransparency = 1
        scr2.BorderSizePixel = 0; scr2.ScrollBarThickness = 4; scr2.ScrollBarImageColor3 = Color3.fromRGB(120, 110, 160)
        scr2.CanvasSize = UDim2.fromOffset(0, #off * ROW); scr2.ScrollingDirection = Enum.ScrollingDirection.Y
        scr2.Parent = sf
        local sl2 = Instance.new("UIListLayout", scr2); sl2.SortOrder = Enum.SortOrder.LayoutOrder
        for i, e in ipairs(off) do
          makeToggleW(scr2, i, tostring(e.nm),
            function() return g.SB_FRIENDS[e.id] ~= nil end,
            function() g.SB_FRIENDS[e.id] = (g.SB_FRIENDS[e.id] == nil) and e.nm or nil; saveFriends() end)
        end
      end
      local fi = Instance.new("TextLabel"); fi.Size = UDim2.new(1, -12, 0, 54); fi.LayoutOrder = 6
      fi.BackgroundTransparency = 1; fi.Font = Enum.Font.Gotham; fi.TextSize = 11
      fi.TextColor3 = Color3.fromRGB(150, 150, 170); fi.TextWrapped = true
      fi.TextXAlignment = Enum.TextXAlignment.Left
      fi.Text = "Freunde werden von Silent-Aim und Autofarm ausgelassen. Gespeichert per UserId in spellbound_friends.json - bleibt nach Rejoin."
      fi.Parent = sf
    end)
  -- Staff-Optionen (aufklappbar): Silent-Aim fuer Staff aussetzen + Staff hervorheben
  addAction(util, function() return "Staff-Optionen" end,
    function() end,
    function(sf)
      makeToggleW(sf, 1, "Silent-Aim aus fuer Staff",
        function() return g.SB_AIM_SKIP_STAFF == true end,
        function() g.SB_AIM_SKIP_STAFF = not g.SB_AIM_SKIP_STAFF end)
      makeToggleW(sf, 2, "Staff hervorheben",
        function() return g.SB_STAFF_ESP == true end,
        function() g.SB_STAFF_ESP = not g.SB_STAFF_ESP; if g.SB_STAFF_ESP then startVisuals() end end)
      makeToggleW(sf, 3, "Auto-Leave bei Staff",
        function() return g.SB_STAFF_LEAVE == true end,
        function() g.SB_STAFF_LEAVE = not g.SB_STAFF_LEAVE; if g.SB_STAFF_LEAVE then staffScan() end end)
      makeToggleW(sf, 4, "Server-Hop statt Leave",
        function() return g.SB_STAFF_HOP == true end,
        function() g.SB_STAFF_HOP = not g.SB_STAFF_HOP end)
      local info = Instance.new("TextLabel"); info.Size = UDim2.new(1, -12, 0, 68); info.LayoutOrder = 5
      info.BackgroundTransparency = 1; info.Font = Enum.Font.Gotham; info.TextSize = 11
      info.TextColor3 = Color3.fromRGB(150, 150, 170); info.TextWrapped = true
      info.TextXAlignment = Enum.TextXAlignment.Left
      info.Text = "Staff = Moderatoren (Attribut IsModerator). Bei ESP-Namen steht 'Moderator' in Blau unter dem Namen. Auto-Leave schaltet erst alle Module ab und geht dann raus (Server-Hop: direkt neuer Server)."
      info.Parent = sf
    end)

  -- Statusleiste unten mittig (ersetzt den alten Hinweistext im Utility-Panel)
  local barHolder = Instance.new("Frame")
  barHolder.AnchorPoint = Vector2.new(0.5, 1); barHolder.Position = UDim2.new(0.5, 0, 1, -14)
  barHolder.Size = UDim2.fromOffset(0, 26); barHolder.AutomaticSize = Enum.AutomaticSize.X
  barHolder.BackgroundColor3 = Color3.fromRGB(12, 13, 16); barHolder.BackgroundTransparency = 0.12
  barHolder.BorderSizePixel = 0; barHolder.Parent = clickRoot
  corner(barHolder, 2); stroke(barHolder, Color3.fromRGB(0, 0, 0), 0.4)
  local barAcc = Instance.new("Frame"); barAcc.Size = UDim2.new(1, 0, 0, 2)
  barAcc.BackgroundColor3 = ACCENT; barAcc.BorderSizePixel = 0; barAcc.Parent = barHolder
  local barTxt = Instance.new("TextLabel"); barTxt.AutomaticSize = Enum.AutomaticSize.X
  barTxt.Size = UDim2.fromOffset(0, 26); barTxt.BackgroundTransparency = 1
  barTxt.Font = Enum.Font.Gotham; barTxt.TextSize = 13; barTxt.TextColor3 = Color3.fromRGB(170, 174, 182)
  barTxt.Text = "   Linksklick togglen  Â·  Rechtsklick = Einstellungen  Â·  Header ziehen / â klappt ein  Â·  RShift/B schliesst  Â·  Bild-Ab = Streamproof   "
  barTxt.Parent = barHolder

  -- === Client-Panel (globale Optionen) ===
  local cfg = makePanel("Client", 26 + (PANEL_W + 10) * 3, 40)
  makeSliderW(cfg.body, 1, "Legitness", 0, 100,
    function() return tonumber(g.SB_LEGIT) or 0 end,
    function(v) g.SB_LEGIT = math.floor(v + 0.5) end,
    function(v) return math.floor(v + 0.5) .. "%" end)
  local lgh = Instance.new("TextLabel"); lgh.Size = UDim2.new(1, -12, 0, 40); lgh.LayoutOrder = 2
  lgh.BackgroundTransparency = 1; lgh.Font = Enum.Font.Gotham; lgh.TextSize = 11
  lgh.TextColor3 = Color3.fromRGB(150, 150, 170); lgh.TextWrapped = true
  lgh.TextXAlignment = Enum.TextXAlignment.Left
  lgh.Text = "0% = voller Cheat. Bei X% failt jede Aktion (Aim/Dodge/Shield/Clash/Cast) mit X% Wahrscheinlichkeit."
  lgh.Parent = cfg.body
  addModule(cfg, "Streamproof [Bild-Ab]",
    function() return g.SB_STREAMPROOF == true end,
    function(v) setStreamproof(v) end)

  -- === ArrayList (oben rechts, immer sichtbar) ===
  local arrayHolder = Instance.new("Frame")
  arrayHolder.AnchorPoint = Vector2.new(1, 0); arrayHolder.Position = UDim2.new(1, -6, 0, 6)
  arrayHolder.Size = UDim2.fromOffset(0, 0); arrayHolder.AutomaticSize = Enum.AutomaticSize.XY
  arrayHolder.BackgroundTransparency = 1; arrayHolder.Parent = gui
  local al = Instance.new("UIListLayout", arrayHolder); al.SortOrder = Enum.SortOrder.LayoutOrder
  al.HorizontalAlignment = Enum.HorizontalAlignment.Right; al.Padding = UDim.new(0, 2)
  local ACTIVE = {
    { "Silent-Aim",  function() return g.SB_AIM end },
    { "Auto-Shield", function() return g.SB_SHIELD end },
    { "Auto-Clash",  function() return g.SB_CLASH end },
    { "Auto-Dodge",  function() return g.SB_DODGE end },
    { "Safe-Combat", function() return g.SB_SAFE end },
    { "Autofarm",    function() return g.SB_FARM end },
    { "Shotgun",     function() return g.SB_SHOT end },
    { "KD-Farm",     function() return g.SB_KD end },
  }
  local function rebuildArray()
    for _, c in ipairs(arrayHolder:GetChildren()) do if c:IsA("TextLabel") then c:Destroy() end end
    local on = {}
    for _, m in ipairs(ACTIVE) do if m[2]() then on[#on + 1] = m[1] end end
    table.sort(on, function(a, b) return #a > #b end)
    for idx, nm in ipairs(on) do
      local t = Instance.new("TextLabel"); t.AutomaticSize = Enum.AutomaticSize.X
      t.Size = UDim2.fromOffset(0, 24); t.LayoutOrder = idx
      t.BackgroundColor3 = Color3.fromRGB(12, 13, 16); t.BackgroundTransparency = 0.12
      t.Font = Enum.Font.GothamBold; t.TextSize = 17; t.TextColor3 = Color3.fromRGB(238, 243, 238)
      t.Text = "  " .. nm .. "  "; t.Parent = arrayHolder
      local tg = Instance.new("UIGradient", t)      -- nach links leicht auslaufen
      tg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35),
                                             NumberSequenceKeypoint.new(1, 0) })
      local b = Instance.new("Frame"); b.Size = UDim2.new(0, 3, 1, 0); b.Position = UDim2.new(1, 0, 0, 0)
      b.BorderSizePixel = 0; b.BackgroundColor3 = ACCENT; b.Parent = t
    end
  end

  -- Refresh-Loop: Modul-Farben + ArrayList (Toggles via Hotkey/extern spiegeln)
  task.spawn(function()
    while gui.Parent do
      for _, p in ipairs(moduleRefs) do pcall(p) end
      pcall(rebuildArray)
      -- Watchdog: Shotgun auch starten wenn der Toggle von aussen gesetzt wurde
      if g.SB_SHOT and not g.SB_SHOT_LOOP then pcall(startShotgun) end
      task.wait(0.2)
    end
  end)

  -- === Watermark oben links (Future-Style) ===
  local wmBox = Instance.new("Frame")
  wmBox.Position = UDim2.fromOffset(10, 6); wmBox.Size = UDim2.fromOffset(0, 40)
  wmBox.AutomaticSize = Enum.AutomaticSize.X; wmBox.BackgroundColor3 = Color3.fromRGB(12, 13, 16)
  wmBox.BackgroundTransparency = 0.15; wmBox.BorderSizePixel = 0; wmBox.Parent = gui
  corner(wmBox, 2); stroke(wmBox, Color3.fromRGB(0, 0, 0), 0.4)
  local wmEdge = Instance.new("Frame"); wmEdge.Size = UDim2.new(0, 3, 1, 0)
  wmEdge.BackgroundColor3 = ACCENT; wmEdge.BorderSizePixel = 0; wmEdge.Parent = wmBox
  local wm = Instance.new("TextLabel")
  wm.Position = UDim2.fromOffset(11, 0); wm.Size = UDim2.fromOffset(0, 40)
  wm.AutomaticSize = Enum.AutomaticSize.X; wm.BackgroundTransparency = 1
  wm.Font = Enum.Font.GothamBlack; wm.TextSize = 26; wm.TextColor3 = ACCENT
  wm.TextXAlignment = Enum.TextXAlignment.Left; wm.Text = "Spellbound   "; wm.Parent = wmBox
  local wmg = Instance.new("UIGradient", wm)
  wmg.Color = ColorSequence.new(ACCENT, Color3.fromRGB(120, 90, 220))
  local wmSub = Instance.new("TextLabel")
  wmSub.AnchorPoint = Vector2.new(1, 0.5); wmSub.Position = UDim2.new(1, -10, 0.5, 1)
  wmSub.Size = UDim2.fromOffset(0, 18); wmSub.AutomaticSize = Enum.AutomaticSize.X
  wmSub.BackgroundTransparency = 1; wmSub.Font = Enum.Font.GothamBold; wmSub.TextSize = 13
  wmSub.TextColor3 = Color3.fromRGB(150, 154, 162); wmSub.TextXAlignment = Enum.TextXAlignment.Right
  wmSub.Text = lp.Name; wmSub.Parent = wmBox
  -- FPS + laufender Status (Farm-Ziel / Wand-Status) im Watermark mitfuehren
  local fps, fpsAcc, fpsN = 60, 0, 0
  table.insert(g.SB_CONNS, RunService.RenderStepped:Connect(function(dt)
    fpsAcc = fpsAcc + dt; fpsN = fpsN + 1
    if fpsAcc >= 0.5 then fps = math.floor(fpsN / fpsAcc + 0.5); fpsAcc, fpsN = 0, 0 end
  end))
  moduleRefs[#moduleRefs + 1] = function()
    local extra = ""
    if g.SB_FARM and g.SB_FARM_TARGET then extra = "  Â·  â " .. tostring(g.SB_FARM_TARGET)
    elseif g.SB_STATUS then extra = "  Â·  " .. tostring(g.SB_STATUS) end
    wmSub.Text = lp.Name .. "  Â·  " .. fps .. " fps" .. extra
  end

  -- RechtsShift ODER B = ClickGUI toggle; C/P/T/G Aktions-Hotkeys (F/H entfernt)
  table.insert(g.SB_CONNS, UIS.InputBegan:Connect(function(i, gp)
    if i.KeyCode == Enum.KeyCode.PageDown then setStreamproof(not g.SB_STREAMPROOF); return end  -- Bild-Ab: Streamproof
    if i.KeyCode == Enum.KeyCode.RightShift then setOpen(not guiOpen); return end
    if gp or UIS:GetFocusedTextBox() then return end       -- im Chat/TextBox: keine Hotkeys (auch kein B)
    if i.KeyCode == Enum.KeyCode.B then setOpen(not guiOpen); return end
    if i.KeyCode == Enum.KeyCode.C then
      g.SB_DODGE = not g.SB_DODGE; if g.SB_DODGE then g.SB_DODGE_SKIPACC = 0; hookDodge() end
    elseif i.KeyCode == Enum.KeyCode.P then
      g.SB_CLASH = not g.SB_CLASH; if g.SB_CLASH then startClashAuto() end
    elseif i.KeyCode == Enum.KeyCode.T then
      apparateTo(g.SB_APPA_TARGET)
    elseif i.KeyCode == Enum.KeyCode.G then
      g.SB_APPA_PENDING = true; disarmSpell(); startSelector()
    elseif i.KeyCode == Enum.KeyCode.E then
      doSnipe()                                   -- 1 Ziel: runter, Spell, zurueck
    end
  end))

  -- === Staff-Join-Alert: rote 3s-Meldung, wenn ein Moderator den Server betritt ===
  -- An gui geparentet -> respektiert Streamproof (bei aktivem Streamproof kein Banner auf dem Stream).
  local function staffAlert(name)
    local a = Instance.new("TextLabel")
    a.AnchorPoint = Vector2.new(0.5, 0); a.Position = UDim2.new(0.5, 0, 0, 90)
    a.Size = UDim2.fromOffset(0, 36); a.AutomaticSize = Enum.AutomaticSize.X
    a.BackgroundColor3 = Color3.fromRGB(20, 0, 0); a.BackgroundTransparency = 0.12
    a.BorderSizePixel = 0; a.Font = Enum.Font.GothamBlack; a.TextSize = 22
    a.TextColor3 = Color3.fromRGB(255, 40, 40)
    a.Text = "   STAFF JOINED: " .. tostring(name) .. "   "; a.ZIndex = 80; a.Parent = gui
    staffPanic(name)                       -- Auto-Leave (macht nur was, wenn die Option an ist)
    Instance.new("UICorner", a).CornerRadius = UDim.new(0, 6)
    local st = Instance.new("UIStroke", a); st.Color = Color3.fromRGB(255, 40, 40); st.Thickness = 1.5
    task.delay(3, function() pcall(function() a:Destroy() end) end)
  end
  -- Neuer Spieler: sofort pruefen; das Attribut IsModerator kommt evtl. erst kurz nach dem
  -- Join -> zusaetzlich kurz auf die Attribut-Aenderung horchen (bis 15s, dann aufgeben).
  local function watchStaff(pl)
    if pl == lp then return end
    if isStaff(pl) then staffAlert(pl.Name); return end
    local conn
    conn = pl:GetAttributeChangedSignal("IsModerator"):Connect(function()
      if pl:GetAttribute("IsModerator") == true then
        staffAlert(pl.Name)
        if conn then conn:Disconnect() end
      end
    end)
    table.insert(g.SB_CONNS, conn)
    task.delay(15, function() if conn then pcall(function() conn:Disconnect() end) end end)
  end
  table.insert(g.SB_CONNS, Players.PlayerAdded:Connect(watchStaff))

  return gui
end

mountGui()
return "Spellbound GUI geladen"
