-- spellbound_gui.lua — Spellbound Tool (manuell, kein Voll-Auto)
--   AUTO-SPELL (G): re-equippt ueber den no-CD-Bug (casts=0) staendig den gewaehlten
--       Spell -> jeder deiner Klicks feuert ihn ohne Cooldown (echte Hits). Auswaehlbar.
--   COMBO: nach JEDEM Auto-Spell-Fire wird einmal der gewaehlte Combo-Spell equippt
--       + gecastet, danach sofort wieder der Auto-Spell scharf. Toggle + auswaehlbar.
--   SILENT-AIM: lenkt jeden Klick auf den Gegner am naechsten zum Cursor.
--   AUTO-SHIELD: reaktives Protego gegen eingehende Casts.
--   AUTO-CLASH: gewinnt das Clash-Minigame automatisch (echter Space-Input, kein Miss-Stun).
-- BEDIENUNG: ClickGUI im Future-Style — RechtsShift ODER B blendet das Overlay ein/aus.
--   Module per Klick togglen, Rechtsklick oeffnet die Settings. F/H-Hotkeys entfernt;
--   P=Clash, C=Dodge, T=Apparate, G=Appa-laden bleiben als Aktions-Hotkeys.
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
g.SB_CLICK_HOOKED, g.SB_CASTING, g.SB_REFS = false, false, nil
g.SB_PRELOADED, g.SB_LAST_CAST = nil, 0
g.SB_TEAM_ESP, g.SB_ESP_NAMES, g.SB_CHAMS = false, false, false   -- Visuals beim Reload aus
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
    while g.SB_SAFE or g.SB_AIM or g.SB_APPA_PENDING do
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
        if g.SB_SAFE and not g.SB_APPA_PENDING and not g.SB_CASTING and not g.SB_PRELOADED
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

--========================= Silent-Aim (Auto-Hit) =========================--
local function startAim()
  if g.SB_AIM_LOOP then return end
  g.SB_AIM_LOOP = true
  local okM, pm = pcall(function() return require(RS.shared.modules.PlayerMouse) end)
  if not (okM and pm) then g.SB_AIM_LOOP = false; return end
  local u13 = pm:GetMouse()
  local okSpL, spellsL = pcall(function() return require(RS.shared.modules.spells) end)
  local slist = okSpL and spellsL and (spellsL.list or spellsL) or nil
  -- Projektilgeschwindigkeit des AKTUELL geladenen Spells automatisch ablesen
  local function currentSpeed()
    local refs = g.SB_REFS
    local loaded = refs and refs.state and refs.state.loadedSpell
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
    local speed = g.SB_AIM_PRED and currentSpeed() or 0
    local bestH, bestHum, bestScreen, bestName
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
        bestH, bestHum, bestScreen, bestName = h, hu, sd, name
      end
    end
    for _, pl in ipairs(Players:GetPlayers()) do
      if pl ~= lp then
        local fid = playerFactionId(pl)
        -- Fraktion ausgenommen? -> ueberspringen, ausser der Spieler steht in der Keep-Target-Liste
        local facExempt = fid and g.SB_AIM_EXEMPT_FACTION[fid] and not g.SB_AIM_KEEP[pl.Name]
        if not facExempt then consider(pl.Character, pl.Name) end
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
      local vel = bestH.AssemblyLinearVelocity
      -- Sprung/Fall: vertikalen Anteil rauslassen (sonst zielt der Vorhalt zu weit hoch),
      -- horizontaler Vorhalt bleibt. Anderes vertikales Movement bleibt erhalten.
      if bestHum then
        local ok, st = pcall(function() return bestHum:GetState() end)
        if ok and (st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.Freefall) then
          vel = Vector3.new(vel.X, 0, vel.Z)
        end
      end
      local aimPos = leadPos(origin, bestH.Position, vel, speed)
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
    pcall(function() if o.hl then o.hl:Destroy() end end)
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
    local anyLayer = g.SB_TEAM_ESP or g.SB_ESP_NAMES or g.SB_CHAMS
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
          o = { box = box, stroke = stroke, nm = nm, hl = nil }
          objs[pl] = o
        end
        local col = (g.SB_AIM_TARGET == pl.Name) and ESP_PURPLE or factionColor(playerFactionId(pl))
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
          else o.nm.Visible = false end
        else
          o.box.Visible = false; o.nm.Visible = false
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

  -- === Theme (Phobos/Future: gruener Header, aktiv = ganz gruen, scharfe Ecken) ===
  local ACCENT  = Color3.fromRGB(95, 205, 90)     -- Phobos-Gruen (Header + aktives Modul)
  local ACCENT2 = Color3.fromRGB(95, 205, 90)
  local ENABLED = Color3.fromRGB(95, 205, 90)
  local DARKTXT = Color3.fromRGB(10, 16, 10)      -- dunkler Text auf Gruen
  local PANEL_BG= Color3.fromRGB(10, 11, 14)
  local HEAD_BG = ACCENT
  local ROW_OFF = Color3.fromRGB(15, 15, 19)
  local ROW_ON  = ACCENT
  local TXT_OFF = Color3.fromRGB(188, 188, 194)
  local function corner(o) local c = Instance.new("UICorner", o); c.CornerRadius = UDim.new(0, 0); return c end

  local openList                 -- offenes Dropdown (nur eins gleichzeitig)
  local moduleRefs = {}          -- Modul-Zeilen fuer Farb-Refresh
  local function closeList() if openList then openList:Destroy(); openList = nil end end

  -- === Dim-Overlay (ClickGUI-Wurzel, per RechtsShift ein/aus) ===
  local clickRoot = Instance.new("Frame")
  clickRoot.Size = UDim2.fromScale(1, 1); clickRoot.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
  clickRoot.BackgroundTransparency = 0.4; clickRoot.BorderSizePixel = 0
  clickRoot.Active = true; clickRoot.Visible = false; clickRoot.Parent = gui
  local guiOpen = false
  local function setOpen(v) guiOpen = v; clickRoot.Visible = v; if not v then closeList() end end
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
  -- Alles laeuft in einem skalierten Host -> min. 3x groesser ueber EINEN Regler
  local UI_SCALE = 2.3
  local panelHost = Instance.new("Frame")
  panelHost.Size = UDim2.fromScale(1, 1); panelHost.BackgroundTransparency = 1
  panelHost.BorderSizePixel = 0; panelHost.Parent = clickRoot
  Instance.new("UIScale", panelHost).Scale = UI_SCALE

  -- === Einstellungs-Widgets ===
  local function makeToggleW(parent, ord, label, get, set)
    local r = Instance.new("TextButton")
    r.Size = UDim2.new(1, -12, 0, 22); r.LayoutOrder = ord; r.AutoButtonColor = false
    r.BackgroundColor3 = Color3.fromRGB(28, 28, 40); r.BorderSizePixel = 0
    r.Font = Enum.Font.Gotham; r.TextSize = 12; r.TextXAlignment = Enum.TextXAlignment.Left
    r.Text = "  " .. label; r.TextColor3 = TXT_OFF; r.Parent = parent; corner(r, 4)
    local box = Instance.new("Frame"); box.Size = UDim2.fromOffset(14, 14)
    box.Position = UDim2.new(1, -20, 0.5, -7); box.BorderSizePixel = 0; box.Parent = r; corner(box, 3)
    local function paint() box.BackgroundColor3 = get() and ACCENT or Color3.fromRGB(60, 60, 78) end
    paint()
    r.MouseButton1Click:Connect(function() set(not get()); paint() end)
  end

  local function makeSliderW(parent, ord, label, mn, mx, get, set, fmt)
    local holder = Instance.new("Frame"); holder.Size = UDim2.new(1, -12, 0, 34)
    holder.LayoutOrder = ord; holder.BackgroundTransparency = 1; holder.Parent = parent
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(1, 0, 0, 16)
    lbl.BackgroundTransparency = 1; lbl.Font = Enum.Font.Gotham; lbl.TextSize = 12
    lbl.TextColor3 = Color3.fromRGB(210, 210, 225); lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = holder
    local track = Instance.new("Frame"); track.Size = UDim2.new(1, 0, 0, 8)
    track.Position = UDim2.fromOffset(0, 20); track.BackgroundColor3 = Color3.fromRGB(44, 44, 60)
    track.BorderSizePixel = 0; track.Active = true; track.Parent = holder; corner(track, 4)
    local fill = Instance.new("Frame"); fill.BackgroundColor3 = ACCENT; fill.BorderSizePixel = 0
    fill.Parent = track; corner(fill, 4)
    local function upd()
      lbl.Text = label .. ": " .. fmt(get())
      fill.Size = UDim2.new(math.clamp((get() - mn) / (mx - mn), 0, 1), 0, 1, 0)
    end
    upd()
    local dragging = false
    local function setFrom(px)
      local rel = math.clamp((px - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
      set(mn + rel * (mx - mn)); upd()
    end
    track.InputBegan:Connect(function(i)
      if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
        dragging = true; setFrom(i.Position.X)
      end
    end)
    table.insert(g.SB_CONNS, UIS.InputChanged:Connect(function(i)
      if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then setFrom(i.Position.X) end
    end))
    table.insert(g.SB_CONNS, UIS.InputEnded:Connect(function(i)
      if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
  end

  local function makeDropdownW(parent, ord, labelFn, itemsFn, onPick)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -12, 0, 22); btn.LayoutOrder = ord; btn.AutoButtonColor = false
    btn.BackgroundColor3 = Color3.fromRGB(34, 30, 50); btn.BorderSizePixel = 0
    btn.Font = Enum.Font.Gotham; btn.TextSize = 12; btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextColor3 = Color3.fromRGB(215, 210, 235); btn.Text = "  " .. labelFn(); btn.Parent = parent; corner(btn, 4)
    btn.MouseButton1Click:Connect(function()
      closeList()
      local items = itemsFn()
      local sf = Instance.new("ScrollingFrame")
      -- panelHost ist um UI_SCALE skaliert -> in Host-lokalen (unskalierten) Koordinaten setzen
      local baseW = btn.AbsoluteSize.X / UI_SCALE
      sf.Size = UDim2.fromOffset(math.max(baseW, 110), math.min(math.max(#items, 1) * 22, 150))
      sf.Position = UDim2.fromOffset(btn.AbsolutePosition.X / UI_SCALE, (btn.AbsolutePosition.Y + btn.AbsoluteSize.Y) / UI_SCALE + 2)
      sf.BackgroundColor3 = Color3.fromRGB(18, 18, 22); sf.BorderSizePixel = 0
      sf.ScrollBarThickness = 4; sf.CanvasSize = UDim2.fromOffset(0, #items * 22)
      sf.ZIndex = 60; sf.Parent = panelHost; corner(sf)
      local lay = Instance.new("UIListLayout", sf); lay.SortOrder = Enum.SortOrder.LayoutOrder
      for _, name in ipairs(items) do
        local it = Instance.new("TextButton")
        it.Size = UDim2.new(1, 0, 0, 22); it.BackgroundColor3 = Color3.fromRGB(32, 32, 46)
        it.BorderSizePixel = 0; it.Font = Enum.Font.Gotham; it.TextSize = 12
        it.TextColor3 = Color3.fromRGB(220, 214, 240); it.Text = name; it.ZIndex = 61; it.Parent = sf
        it.MouseButton1Click:Connect(function() onPick(name); btn.Text = "  " .. labelFn(); closeList() end)
      end
      openList = sf
    end)
  end

  -- Inline-Spielerliste (z.B. Aim-Ausnahmen): scrollbare Haekchen pro Spieler
  local function makePlayerToggles(parent, ord, isOn, onToggle)
    local others = {}
    for _, pl in ipairs(Players:GetPlayers()) do if pl ~= lp then others[#others + 1] = pl end end
    table.sort(others, function(a, b) return a.Name:lower() < b.Name:lower() end)
    if #others == 0 then
      local none = Instance.new("TextLabel"); none.Size = UDim2.new(1, -12, 0, 18)
      none.LayoutOrder = ord; none.BackgroundTransparency = 1; none.Font = Enum.Font.Gotham
      none.TextSize = 11; none.TextColor3 = Color3.fromRGB(150, 150, 165)
      none.Text = "keine anderen Spieler"; none.Parent = parent; return
    end
    -- Scrollbarer Container: max MAXROWS Zeilen sichtbar, der Rest wird gescrollt
    local ROW, MAXROWS = 22, 6
    local box = Instance.new("ScrollingFrame")
    box.Size = UDim2.new(1, 0, 0, math.min(#others, MAXROWS) * ROW)
    box.LayoutOrder = ord; box.BackgroundTransparency = 1; box.BorderSizePixel = 0
    box.ScrollBarThickness = 4; box.ScrollBarImageColor3 = Color3.fromRGB(120, 110, 160)
    box.CanvasSize = UDim2.fromOffset(0, #others * ROW)
    box.ScrollingDirection = Enum.ScrollingDirection.Y; box.Parent = parent
    local lay = Instance.new("UIListLayout", box); lay.SortOrder = Enum.SortOrder.LayoutOrder
    for idx, pl in ipairs(others) do
      makeToggleW(box, idx, pl.Name, function() return isOn(pl.Name) end, function() onToggle(pl.Name) end)
    end
  end

  -- === Panel (Kategorie) ===
  local PANEL_W = 120
  local function makePanel(title, px, py)
    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(PANEL_W, 0); panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.Position = UDim2.fromOffset(px, py); panel.BackgroundColor3 = PANEL_BG
    panel.BackgroundTransparency = 0.05; panel.BorderSizePixel = 0; panel.Active = true
    panel.Parent = panelHost; corner(panel)
    local plist = Instance.new("UIListLayout", panel); plist.SortOrder = Enum.SortOrder.LayoutOrder
    local head = Instance.new("TextLabel")
    head.Size = UDim2.new(1, 0, 0, 19); head.LayoutOrder = 0; head.BackgroundColor3 = HEAD_BG
    head.BorderSizePixel = 0; head.Font = Enum.Font.GothamBold; head.TextSize = 12
    head.TextColor3 = DARKTXT; head.TextXAlignment = Enum.TextXAlignment.Left
    head.Text = "  " .. title; head.Active = true; head.Parent = panel; corner(head)
    local hmark = Instance.new("TextLabel"); hmark.Size = UDim2.fromOffset(16, 19)
    hmark.Position = UDim2.new(1, -16, 0, 0); hmark.BackgroundTransparency = 1
    hmark.Font = Enum.Font.GothamBold; hmark.TextSize = 12; hmark.TextColor3 = DARKTXT
    hmark.Text = "-"; hmark.Parent = head
    local body = Instance.new("Frame"); body.BackgroundTransparency = 1
    body.Size = UDim2.new(1, 0, 0, 0); body.AutomaticSize = Enum.AutomaticSize.Y
    body.LayoutOrder = 1; body.Parent = panel
    local bl = Instance.new("UIListLayout", body); bl.SortOrder = Enum.SortOrder.LayoutOrder
    local bp = Instance.new("UIPadding", body); bp.PaddingTop = UDim.new(0, 1); bp.PaddingBottom = UDim.new(0, 2)
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
    return { body = body, ord = 0 }
  end

  -- Baut den ein/ausklappbaren Einstellungs-Container (Rechtsklick / Pfeil)
  local function makeExpander(panel, ord, arrow, buildSettings)
    local expanded, sf = false, nil
    local function toggle()
      expanded = not expanded
      if expanded then
        sf = Instance.new("Frame"); sf.LayoutOrder = ord * 10 + 1
        sf.Size = UDim2.new(1, 0, 0, 0); sf.AutomaticSize = Enum.AutomaticSize.Y
        sf.BackgroundColor3 = Color3.fromRGB(22, 22, 32); sf.BorderSizePixel = 0; sf.Parent = panel.body
        local sl = Instance.new("UIListLayout", sf); sl.SortOrder = Enum.SortOrder.LayoutOrder
        sl.Padding = UDim.new(0, 3); sl.HorizontalAlignment = Enum.HorizontalAlignment.Center
        local spad = Instance.new("UIPadding", sf); spad.PaddingTop = UDim.new(0, 5); spad.PaddingBottom = UDim.new(0, 6)
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
    row.Size = UDim2.new(1, 0, 0, 18); row.LayoutOrder = ord * 10; row.AutoButtonColor = false
    row.BackgroundColor3 = ROW_OFF; row.BorderSizePixel = 0; row.Font = Enum.Font.Gotham
    row.TextSize = 12; row.TextXAlignment = Enum.TextXAlignment.Left; row.Text = "  " .. name
    row.TextColor3 = TXT_OFF; row.Parent = panel.body
    local dot = Instance.new("Frame"); dot.Size = UDim2.fromOffset(8, 8)
    dot.Position = UDim2.new(1, (buildSettings and -26 or -12), 0.5, -4)
    dot.BorderSizePixel = 0; dot.Parent = row
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
    local arrow
    if buildSettings then
      arrow = Instance.new("TextButton"); arrow.Size = UDim2.fromOffset(16, 18)
      arrow.Position = UDim2.new(1, -16, 0, 0); arrow.BackgroundTransparency = 1
      arrow.Font = Enum.Font.GothamBold; arrow.TextSize = 13; arrow.Text = "+"; arrow.Parent = row
    end
    local function paint()
      local on = get()
      row.BackgroundColor3 = on and ROW_ON or ROW_OFF
      row.TextColor3 = on and DARKTXT or TXT_OFF
      dot.BackgroundColor3 = on and DARKTXT or Color3.fromRGB(70, 70, 78)
      if arrow then arrow.TextColor3 = on and DARKTXT or Color3.fromRGB(140, 140, 150) end
    end
    paint(); moduleRefs[#moduleRefs + 1] = paint
    row.MouseButton1Click:Connect(function() set(not get()); paint() end)
    if buildSettings then
      local toggle = makeExpander(panel, ord, arrow, buildSettings)
      arrow.MouseButton1Click:Connect(toggle)
      row.MouseButton2Click:Connect(toggle)
    end
  end

  -- Aktion-Zeile (kein Toggle) — z.B. Apparate / Appa laden
  local function addAction(panel, labelFn, onClick, buildSettings)
    panel.ord = panel.ord + 1
    local ord = panel.ord
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 18); row.LayoutOrder = ord * 10; row.AutoButtonColor = true
    row.BackgroundColor3 = Color3.fromRGB(20, 20, 26); row.BorderSizePixel = 0; row.Font = Enum.Font.Gotham
    row.TextSize = 12; row.TextXAlignment = Enum.TextXAlignment.Left; row.Text = "  " .. labelFn()
    row.TextColor3 = Color3.fromRGB(210, 215, 235); row.Parent = panel.body
    moduleRefs[#moduleRefs + 1] = function() row.Text = "  " .. labelFn() end
    local arrow
    if buildSettings then
      arrow = Instance.new("TextButton"); arrow.Size = UDim2.fromOffset(18, 18)
      arrow.Position = UDim2.new(1, -18, 0, 0); arrow.BackgroundTransparency = 1
      arrow.Font = Enum.Font.GothamBold; arrow.TextSize = 13; arrow.TextColor3 = Color3.fromRGB(150, 150, 165)
      arrow.Text = "+"; arrow.Parent = row
    end
    row.MouseButton1Click:Connect(function() onClick(); row.Text = "  " .. labelFn() end)
    if buildSettings then
      local toggle = makeExpander(panel, ord, arrow, buildSettings)
      arrow.MouseButton1Click:Connect(toggle)
      row.MouseButton2Click:Connect(toggle)
    end
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
      local lblEx = Instance.new("TextLabel"); lblEx.Size = UDim2.new(1, -12, 0, 16); lblEx.LayoutOrder = 5
      lblEx.BackgroundTransparency = 1; lblEx.Font = Enum.Font.GothamBold; lblEx.TextSize = 11
      lblEx.TextColor3 = Color3.fromRGB(160, 160, 180); lblEx.TextXAlignment = Enum.TextXAlignment.Left
      lblEx.Text = "Aim-Ausnahmen:"; lblEx.Parent = sf
      makePlayerToggles(sf, 6, function(n) return g.SB_AIM_EXEMPT[n] == true end,
        function(n) if g.SB_AIM_EXEMPT[n] then g.SB_AIM_EXEMPT[n] = nil else g.SB_AIM_EXEMPT[n] = true end end)
      -- Ganze Fraktion ausnehmen (aus dem Spiel: factionConfig-IDs + GroupService-Namen)
      local lblFac = Instance.new("TextLabel"); lblFac.Size = UDim2.new(1, -12, 0, 16); lblFac.LayoutOrder = 7
      lblFac.BackgroundTransparency = 1; lblFac.Font = Enum.Font.GothamBold; lblFac.TextSize = 11
      lblFac.TextColor3 = Color3.fromRGB(160, 160, 180); lblFac.TextXAlignment = Enum.TextXAlignment.Left
      lblFac.Text = "Fraktions-Ausnahmen:"; lblFac.Parent = sf
      local refreshKeep   -- forward-declared: baut die Keep-Target-Liste bei Fraktions-Aenderung neu
      for i, fid in ipairs(factionIds()) do
        makeToggleW(sf, 7 + i, factionName(fid),
          function() return g.SB_AIM_EXEMPT_FACTION[fid] == true end,
          function()
            if g.SB_AIM_EXEMPT_FACTION[fid] then g.SB_AIM_EXEMPT_FACTION[fid] = nil else g.SB_AIM_EXEMPT_FACTION[fid] = true end
            if refreshKeep then refreshKeep() end
          end)
      end
      -- Keep-Target: einzelne Mitglieder ausgenommener Fraktionen doch anvisieren (Override der Fraktions-Ausnahme)
      local lblKeep = Instance.new("TextLabel"); lblKeep.Size = UDim2.new(1, -12, 0, 16); lblKeep.LayoutOrder = 20
      lblKeep.BackgroundTransparency = 1; lblKeep.Font = Enum.Font.GothamBold; lblKeep.TextSize = 11
      lblKeep.TextColor3 = Color3.fromRGB(190, 150, 235); lblKeep.TextXAlignment = Enum.TextXAlignment.Left
      lblKeep.Text = "Keep-Target (trotzdem anvisieren):"; lblKeep.Parent = sf
      local keepHost = Instance.new("Frame"); keepHost.LayoutOrder = 21; keepHost.BackgroundTransparency = 1
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

  -- === Utility-Panel ===
  local util = makePanel("Utility", 26 + PANEL_W + 10, 40)
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

  -- Hinweis unten in Utility
  local hint = Instance.new("TextLabel"); hint.Size = UDim2.new(1, -12, 0, 30); hint.LayoutOrder = 999
  hint.BackgroundTransparency = 1; hint.Font = Enum.Font.Gotham; hint.TextSize = 11
  hint.TextColor3 = Color3.fromRGB(150, 150, 170); hint.TextWrapped = true
  hint.TextXAlignment = Enum.TextXAlignment.Left; hint.Text = "Rechtsklick = Settings.  RShift/B schliesst."
  hint.Parent = util.body

  -- === Client-Panel (globale Optionen) ===
  local cfg = makePanel("Client", 26 + (PANEL_W + 10) * 2, 40)
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
  }
  local function rebuildArray()
    for _, c in ipairs(arrayHolder:GetChildren()) do if c:IsA("TextLabel") then c:Destroy() end end
    local on = {}
    for _, m in ipairs(ACTIVE) do if m[2]() then on[#on + 1] = m[1] end end
    table.sort(on, function(a, b) return #a > #b end)
    for idx, nm in ipairs(on) do
      local t = Instance.new("TextLabel"); t.AutomaticSize = Enum.AutomaticSize.X
      t.Size = UDim2.fromOffset(0, 26); t.LayoutOrder = idx
      t.BackgroundColor3 = Color3.fromRGB(12, 13, 16); t.BackgroundTransparency = 0.1
      t.Font = Enum.Font.GothamBold; t.TextSize = 18; t.TextColor3 = Color3.fromRGB(240, 245, 240)
      t.Text = "  " .. nm .. "  "; t.Parent = arrayHolder
      local b = Instance.new("Frame"); b.Size = UDim2.new(0, 3, 1, 0); b.Position = UDim2.new(1, 0, 0, 0)
      b.BorderSizePixel = 0; b.BackgroundColor3 = ACCENT; b.Parent = t
    end
  end

  -- Refresh-Loop: Modul-Farben + ArrayList (Toggles via Hotkey/extern spiegeln)
  task.spawn(function()
    while gui.Parent do
      for _, p in ipairs(moduleRefs) do pcall(p) end
      pcall(rebuildArray)
      task.wait(0.2)
    end
  end)

  -- === Watermark oben links (Future-Style) ===
  local wm = Instance.new("TextLabel")
  wm.AnchorPoint = Vector2.new(0, 0); wm.Position = UDim2.fromOffset(10, 6)
  wm.Size = UDim2.fromOffset(0, 0); wm.AutomaticSize = Enum.AutomaticSize.XY
  wm.BackgroundTransparency = 1; wm.Font = Enum.Font.GothamBlack; wm.TextSize = 34
  wm.TextColor3 = ACCENT; wm.Text = "Spellbound"; wm.Parent = gui
  local wmg = Instance.new("UIGradient", wm)
  wmg.Color = ColorSequence.new(ACCENT, Color3.fromRGB(120, 90, 220))

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
    end
  end))

  return gui
end

mountGui()
return "Spellbound GUI geladen"
