-- spellbound_gui.lua — Spellbound Tool (manuell, kein Voll-Auto)
--   AUTO-SPELL (G): re-equippt ueber den no-CD-Bug (casts=0) staendig den gewaehlten
--       Spell -> jeder deiner Klicks feuert ihn ohne Cooldown (echte Hits). Auswaehlbar.
--   COMBO: nach JEDEM Auto-Spell-Fire wird einmal der gewaehlte Combo-Spell equippt
--       + gecastet, danach sofort wieder der Auto-Spell scharf. Toggle + auswaehlbar.
--   SILENT-AIM (F): lenkt jeden Klick auf den Gegner am naechsten zum Cursor.
--   AUTO-SHIELD (H): reaktives Protego gegen eingehende Casts.
--   AUTO-CLASH (P): gewinnt das Clash-Minigame automatisch — drueckt Space exakt
--       wenn der Pointer in den Goal-/Bonus-Arc eintritt (echter Input, kein Miss-Stun).
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
g.SB_CURSE_LOOP, g.SB_AIM_LOOP, g.SB_CLASH_LOOP = false, false, false
g.SB_CLICK_HOOKED, g.SB_CASTING, g.SB_REFS = false, false, nil
g.SB_PRELOADED, g.SB_LAST_CAST = nil, 0
if g.SB_CONNS then
  for _, c in ipairs(g.SB_CONNS) do pcall(function() c:Disconnect() end) end
end
g.SB_CONNS = {}
-- Shield-Listener bleibt idempotent ueber SB_SHIELD_HOOKED (nicht doppelt legen).

g.SB_AIM_FOV     = g.SB_AIM_FOV     or 140
g.SB_AIM_RANGE   = g.SB_AIM_RANGE   or 500
g.SB_AIM_EXEMPT  = g.SB_AIM_EXEMPT  or {}   -- [Name]=true -> von Silent-Aim ausgenommen
if g.SB_AIM_NPC == nil then g.SB_AIM_NPC = false end  -- Silent-Aim auch auf NPCs
-- Vorhalt (Lead-Prediction): Projektil-Flugzeit einrechnen, dorthin zielen wo das Ziel sein WIRD.
-- Speed wird automatisch aus dem geladenen Spell gelesen (spells.list[name].speed).
if g.SB_AIM_PRED == nil then g.SB_AIM_PRED = true end   -- Vorhalt an/aus
g.SB_AIM_PROJSPEED = g.SB_AIM_PROJSPEED or 250          -- Fallback, falls Spell-Speed unbekannt
g.SB_AIM_DETECTED  = g.SB_AIM_DETECTED  or 0            -- zuletzt automatisch erkannte Speed
g.SB_AIM_DETSPELL  = g.SB_AIM_DETSPELL  or nil          -- Name des erkannten Spells
g.SB_APPA_TARGET = g.SB_APPA_TARGET or nil  -- Name des Apparate-Ziels (Taste T)

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

-- Ein Klick = aktuellen Spell casten (vorgeladen -> sofort, sonst load+wait)
local function castCurrent()
  if g.SB_APPA_PENDING then                        -- appa hat Vorrang, danach NICHTS nachladen
    local u13 = g.SB_MOUSE
    castApparToPos(u13 and u13.Hit and u13.Hit.Position)
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
      if pl ~= lp then consider(pl.Character, pl.Name) end
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
    pcall(function() packets.protego.send() end)
    g.SB_SHIELD_POPS = (tonumber(g.SB_SHIELD_POPS) or 0) + 1
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
      armed = false
      g.SB_CLASH_HITS = (tonumber(g.SB_CLASH_HITS) or 0) + 1
      -- genau EIN Leertasten-Druck pro Hit (native Input, zuverlaessiger als VIM)
      pcall(function() keypress(0x20) end)   -- Space DOWN
      pcall(function() keyrelease(0x20) end)  -- Space UP
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

--========================= GUI =========================--
local function mountGui()
  local parent
  local ok, h = pcall(function() return gethui and gethui() end)
  if ok and typeof(h) == "Instance" then parent = h end
  if not parent then local ok2, c = pcall(function() return game:GetService("CoreGui") end); if ok2 and c then parent = c end end
  if not parent then parent = lp:WaitForChild("PlayerGui") end
  local old = parent:FindFirstChild("SpellboundGUI"); if old then old:Destroy() end

  local gui = Instance.new("ScreenGui")
  gui.Name = "SpellboundGUI"; gui.ResetOnSpawn = false
  gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.Parent = parent

  local main = Instance.new("Frame")
  main.Size = UDim2.fromOffset(240, 516)
  main.Position = UDim2.fromScale(0.5, 0.3)
  main.BackgroundColor3 = Color3.fromRGB(24, 22, 34)
  main.BorderSizePixel = 0; main.Active = true; main.Parent = gui
  Instance.new("UICorner", main).CornerRadius = UDim.new(0, 8)
  local stroke = Instance.new("UIStroke", main); stroke.Color = Color3.fromRGB(120, 90, 200); stroke.Thickness = 1.4

  local header = Instance.new("TextLabel")
  header.Size = UDim2.new(1, 0, 0, 30); header.BackgroundColor3 = Color3.fromRGB(46, 38, 74)
  header.BorderSizePixel = 0; header.Text = "  \xe2\x9c\xa6 Spellbound"; header.TextColor3 = Color3.fromRGB(220, 210, 255)
  header.Font = Enum.Font.GothamBold; header.TextSize = 15; header.TextXAlignment = Enum.TextXAlignment.Left
  header.Parent = main
  Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)

  local collapseBtn = Instance.new("TextButton")
  collapseBtn.Size = UDim2.fromOffset(26, 22); collapseBtn.Position = UDim2.new(1, -32, 0, 4)
  collapseBtn.BackgroundColor3 = Color3.fromRGB(80, 66, 120); collapseBtn.BorderSizePixel = 0
  collapseBtn.Font = Enum.Font.GothamBold; collapseBtn.TextSize = 18
  collapseBtn.TextColor3 = Color3.fromRGB(230, 220, 255); collapseBtn.AutoButtonColor = true
  collapseBtn.Text = "\xe2\x80\x93"; collapseBtn.ZIndex = 3; collapseBtn.Parent = header
  Instance.new("UICorner", collapseBtn).CornerRadius = UDim.new(0, 4)

  local function mkButton(y, h2)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -20, 0, h2 or 34); b.Position = UDim2.fromOffset(10, y)
    b.BorderSizePixel = 0; b.Font = Enum.Font.GothamBold; b.TextSize = 14
    b.TextColor3 = Color3.fromRGB(255, 255, 255); b.AutoButtonColor = true; b.Parent = main
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
  end

  local btnAim   = mkButton(38, 34)   -- SILENT-AIM toggle (F)
  local btnPred  = mkButton(76, 28)   -- Vorhalt / Projektilgeschwindigkeit
  local btnNpc   = mkButton(108, 28)  -- Silent-Aim auch auf NPCs
  local btnShield= mkButton(140, 34)  -- AUTO-SHIELD toggle (H)
  local btnClash = mkButton(178, 34)  -- AUTO-CLASH toggle (P)
  local btnExempt= mkButton(216, 28)  -- Silent-Aim Ausnahmen (Whitelist)
  local btnAppa  = mkButton(248, 28)  -- Apparate-Ziel waehlen (TP mit Taste T)
  local btnAppaGo= mkButton(280, 30)  -- Apparate JETZT (Button + Taste T)
  local btnSafe  = mkButton(314, 30)  -- SAFE COMBAT toggle (Click-Cast Rotation)
  local btnRot1  = mkButton(348, 24)  -- Rotation Slot 1
  local btnRot2  = mkButton(374, 24)  -- Rotation Slot 2
  local btnRot3  = mkButton(400, 24)  -- Rotation Slot 3
  local btnRot4  = mkButton(426, 24)  -- Rotation Slot 4
  local rotBtns  = { btnRot1, btnRot2, btnRot3, btnRot4 }
  local btnAppaLoad = mkButton(454, 30)  -- appa in die Hand laden (Taste G)

  local status = Instance.new("TextLabel")
  status.Size = UDim2.new(1, -20, 0, 20); status.Position = UDim2.fromOffset(10, 488)
  status.BackgroundTransparency = 1; status.Font = Enum.Font.Gotham; status.TextSize = 12
  status.TextColor3 = Color3.fromRGB(170, 160, 200); status.TextXAlignment = Enum.TextXAlignment.Left
  status.Text = "bereit"; status.Parent = main

  -- Ein-/Ausklappen (Header bleibt sichtbar; Hotkeys laufen unabhaengig weiter)
  local openList   -- offenes Dropdown (von Spell-/Exempt-/Appa-Listen genutzt)
  local FULL_H = 516
  local collapsed = false
  local content = { btnAim, btnPred, btnNpc, btnShield, btnClash, btnExempt, btnAppa, btnAppaGo, btnSafe, btnRot1, btnRot2, btnRot3, btnRot4, btnAppaLoad, status }
  local function setCollapsed(v)
    collapsed = v
    for _, c in ipairs(content) do c.Visible = not v end
    if v and openList then openList:Destroy(); openList = nil end
    main.Size = UDim2.fromOffset(240, v and 30 or FULL_H)
    collapseBtn.Text = v and "+" or "\xe2\x80\x93"
  end
  collapseBtn.MouseButton1Click:Connect(function() setCollapsed(not collapsed) end)

  btnExempt.BackgroundColor3 = Color3.fromRGB(40, 36, 58)
  btnAppa.BackgroundColor3   = Color3.fromRGB(40, 36, 58)
  for _, rb in ipairs(rotBtns) do rb.BackgroundColor3 = Color3.fromRGB(34, 44, 40); rb.TextSize = 12 end

  btnPred.BackgroundColor3 = Color3.fromRGB(40, 36, 58)
  local function render()
    btnAim.Text = g.SB_AIM and "SILENT-AIM: AN  [F]" or "SILENT-AIM: AUS  [F]"
    btnAim.BackgroundColor3 = g.SB_AIM and Color3.fromRGB(200,130,40) or Color3.fromRGB(70,62,96)
    if g.SB_AIM_PRED then
      local det = tonumber(g.SB_AIM_DETECTED) or 0
      if det > 0 then
        btnPred.Text = "Vorhalt: AN  (" .. tostring(g.SB_AIM_DETSPELL) .. " " .. det .. ")"
      else
        btnPred.Text = "Vorhalt: AN  (auto-Speed)"
      end
      btnPred.BackgroundColor3 = Color3.fromRGB(60,90,110)
    else
      btnPred.Text = "Vorhalt: AUS (direkt)"
      btnPred.BackgroundColor3 = Color3.fromRGB(46,42,62)
    end
    btnNpc.Text = g.SB_AIM_NPC and "NPC-Aim: AN" or "NPC-Aim: AUS"
    btnNpc.BackgroundColor3 = g.SB_AIM_NPC and Color3.fromRGB(150,90,40) or Color3.fromRGB(46,42,62)
    btnShield.Text = g.SB_SHIELD and "AUTO-SHIELD: AN  [H]" or "AUTO-SHIELD: AUS  [H]"
    btnShield.BackgroundColor3 = g.SB_SHIELD and Color3.fromRGB(56,120,170) or Color3.fromRGB(70,62,96)
    btnClash.Text = g.SB_CLASH and "AUTO-CLASH: AN  [P]" or "AUTO-CLASH: AUS  [P]"
    btnClash.BackgroundColor3 = g.SB_CLASH and Color3.fromRGB(150,60,150) or Color3.fromRGB(70,62,96)
    local ne = 0; for _ in pairs(g.SB_AIM_EXEMPT) do ne = ne + 1 end
    btnExempt.Text = "Aim-Ausnahmen: " .. ne .. "  \xe2\x96\xbc"
    btnAppa.Text = "Appa-Ziel: " .. tostring(g.SB_APPA_TARGET or "-") .. "  \xe2\x96\xbc"
    btnAppaGo.Text = "\xe2\x86\x92 APPARATE  [T]"
    btnAppaGo.BackgroundColor3 = Color3.fromRGB(60, 120, 150)
    btnSafe.Text = g.SB_SAFE and "SAFE COMBAT: AN" or "SAFE COMBAT: AUS"
    btnSafe.BackgroundColor3 = g.SB_SAFE and Color3.fromRGB(56,150,78) or Color3.fromRGB(70,62,96)
    for i, rb in ipairs(rotBtns) do
      rb.Text = i .. ": " .. tostring(g.SB_SAFE_ROT[i]) .. "  \xe2\x96\xbc"
    end
    btnAppaLoad.Text = g.SB_APPA_PENDING and "APPA GELADEN - jetzt casten!" or "APPA LADEN  [G]"
    btnAppaLoad.BackgroundColor3 = g.SB_APPA_PENDING and Color3.fromRGB(150,110,40) or Color3.fromRGB(60,120,150)
  end

  -- Dropdown (scrollbare Liste ueber dem Button)
  local function makeDropdown(ddBtn, setter)
    ddBtn.MouseButton1Click:Connect(function()
      if openList then openList:Destroy(); openList = nil end
      local list = getSpellList()
      local sf = Instance.new("ScrollingFrame")
      sf.Size = UDim2.fromOffset(ddBtn.AbsoluteSize.X, 160)
      sf.Position = UDim2.fromOffset(ddBtn.AbsolutePosition.X, ddBtn.AbsolutePosition.Y + ddBtn.AbsoluteSize.Y + 2)
      sf.BackgroundColor3 = Color3.fromRGB(30, 27, 44); sf.BorderSizePixel = 0
      sf.ScrollBarThickness = 5; sf.CanvasSize = UDim2.fromOffset(0, #list * 24)
      sf.ZIndex = 20; sf.Parent = gui
      Instance.new("UICorner", sf).CornerRadius = UDim.new(0, 6)
      local lay = Instance.new("UIListLayout", sf); lay.SortOrder = Enum.SortOrder.LayoutOrder
      for _, name in ipairs(list) do
        local it = Instance.new("TextButton")
        it.Size = UDim2.new(1, 0, 0, 24); it.BackgroundColor3 = Color3.fromRGB(38, 34, 54)
        it.BorderSizePixel = 0; it.Font = Enum.Font.Gotham; it.TextSize = 12
        it.TextColor3 = Color3.fromRGB(220, 214, 240); it.Text = name; it.ZIndex = 21; it.Parent = sf
        it.MouseButton1Click:Connect(function()
          setter(name); render()
          if openList then openList:Destroy(); openList = nil end
        end)
      end
      openList = sf
    end)
  end
  for i, rb in ipairs(rotBtns) do
    makeDropdown(rb, function(n) g.SB_SAFE_ROT[i] = n end)
  end

  -- Spieler-Liste: Klick schaltet Aim-Ausnahme fuer den Spieler um (Haekchen = ausgenommen)
  btnExempt.MouseButton1Click:Connect(function()
    -- Toggle: war die Ausnahmeliste offen -> zuklappen und raus
    if openList then
      local wasExempt = openList:GetAttribute("isExempt") == true
      openList:Destroy(); openList = nil
      if wasExempt then return end
    end
    local sf = Instance.new("ScrollingFrame")
    sf:SetAttribute("isExempt", true)
    sf.Size = UDim2.fromOffset(btnExempt.AbsoluteSize.X, 170)
    sf.Position = UDim2.fromOffset(btnExempt.AbsolutePosition.X, btnExempt.AbsolutePosition.Y - 172)
    sf.BackgroundColor3 = Color3.fromRGB(30, 27, 44); sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 5; sf.ZIndex = 20; sf.Parent = gui
    Instance.new("UICorner", sf).CornerRadius = UDim.new(0, 6)
    local lay = Instance.new("UIListLayout", sf); lay.SortOrder = Enum.SortOrder.LayoutOrder
    local others = {}
    for _, pl in ipairs(Players:GetPlayers()) do if pl ~= lp then others[#others + 1] = pl end end
    table.sort(others, function(a, b) return a.Name:lower() < b.Name:lower() end)
    sf.CanvasSize = UDim2.fromOffset(0, #others * 24)
    for _, pl in ipairs(others) do
      local it = Instance.new("TextButton")
      it.Size = UDim2.new(1, 0, 0, 24); it.BorderSizePixel = 0
      it.Font = Enum.Font.Gotham; it.TextSize = 12; it.ZIndex = 21; it.Parent = sf
      local function paint()
        local ex = g.SB_AIM_EXEMPT[pl.Name] == true
        it.Text = (ex and "\xe2\x9c\x93 " or "   ") .. pl.Name
        it.BackgroundColor3 = ex and Color3.fromRGB(56, 110, 70) or Color3.fromRGB(38, 34, 54)
        it.TextColor3 = ex and Color3.fromRGB(210, 255, 220) or Color3.fromRGB(220, 214, 240)
      end
      paint()
      it.MouseButton1Click:Connect(function()
        if g.SB_AIM_EXEMPT[pl.Name] then g.SB_AIM_EXEMPT[pl.Name] = nil else g.SB_AIM_EXEMPT[pl.Name] = true end
        paint(); render()
      end)
    end
    openList = sf
  end)

  -- Appa-Ziel waehlen (Einzelauswahl, einklappbar)
  btnAppa.MouseButton1Click:Connect(function()
    if openList then
      local wasAppa = openList:GetAttribute("isAppa") == true
      openList:Destroy(); openList = nil
      if wasAppa then return end
    end
    local sf = Instance.new("ScrollingFrame")
    sf:SetAttribute("isAppa", true)
    sf.Size = UDim2.fromOffset(btnAppa.AbsoluteSize.X, 170)
    sf.Position = UDim2.fromOffset(btnAppa.AbsolutePosition.X, btnAppa.AbsolutePosition.Y - 172)
    sf.BackgroundColor3 = Color3.fromRGB(30, 27, 44); sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 5; sf.ZIndex = 20; sf.Parent = gui
    Instance.new("UICorner", sf).CornerRadius = UDim.new(0, 6)
    local lay = Instance.new("UIListLayout", sf); lay.SortOrder = Enum.SortOrder.LayoutOrder
    local others = {}
    for _, pl in ipairs(Players:GetPlayers()) do if pl ~= lp then others[#others + 1] = pl end end
    table.sort(others, function(a, b) return a.Name:lower() < b.Name:lower() end)
    sf.CanvasSize = UDim2.fromOffset(0, #others * 24)
    for _, pl in ipairs(others) do
      local it = Instance.new("TextButton")
      it.Size = UDim2.new(1, 0, 0, 24); it.BackgroundColor3 = Color3.fromRGB(38, 34, 54)
      it.BorderSizePixel = 0; it.Font = Enum.Font.Gotham; it.TextSize = 12
      it.TextColor3 = Color3.fromRGB(220, 214, 240); it.Text = pl.Name; it.ZIndex = 21; it.Parent = sf
      it.MouseButton1Click:Connect(function()
        g.SB_APPA_TARGET = pl.Name; render()
        if openList then openList:Destroy(); openList = nil end
      end)
    end
    openList = sf
  end)
  btnAppaGo.MouseButton1Click:Connect(function()
    local ok, err = apparateTo(g.SB_APPA_TARGET)
    if not ok then g.SB_STATUS = "Appa: " .. tostring(err) end
    render()
  end)
  btnAppaLoad.MouseButton1Click:Connect(function()
    g.SB_APPA_PENDING = true      -- naechster Klick castet appa; danach nichts nachladen
    startSelector()
    render()
  end)

  btnSafe.MouseButton1Click:Connect(function()
    g.SB_SAFE = not g.SB_SAFE
    if g.SB_SAFE then startSelector() end   -- Click-Cast-Rotation
    render()
  end)
  btnAim.MouseButton1Click:Connect(function()
    g.SB_AIM = not g.SB_AIM
    if g.SB_AIM then startSelector(); startAim() end
    render()
  end)
  btnPred.MouseButton1Click:Connect(function()
    g.SB_AIM_PRED = not g.SB_AIM_PRED
    render()
  end)
  btnNpc.MouseButton1Click:Connect(function()
    g.SB_AIM_NPC = not g.SB_AIM_NPC
    render()
  end)
  btnShield.MouseButton1Click:Connect(function()
    g.SB_SHIELD = not g.SB_SHIELD
    if g.SB_SHIELD then hookShield() end
    render()
  end)
  btnClash.MouseButton1Click:Connect(function()
    g.SB_CLASH = not g.SB_CLASH
    if g.SB_CLASH then startClashAuto() end
    render()
  end)

  table.insert(g.SB_CONNS, UIS.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.F then
      g.SB_AIM = not g.SB_AIM; if g.SB_AIM then startSelector(); startAim() end; render()
    elseif i.KeyCode == Enum.KeyCode.H then
      g.SB_SHIELD = not g.SB_SHIELD; if g.SB_SHIELD then hookShield() end; render()
    elseif i.KeyCode == Enum.KeyCode.P then
      g.SB_CLASH = not g.SB_CLASH; if g.SB_CLASH then startClashAuto() end; render()
    elseif i.KeyCode == Enum.KeyCode.T then
      apparateTo(g.SB_APPA_TARGET)
    elseif i.KeyCode == Enum.KeyCode.G then
      g.SB_APPA_PENDING = true; startSelector(); render()   -- APPA LADEN
    end
  end))

  task.spawn(function()
    while gui.Parent do
      render()
      if g.SB_APPA_PENDING then
        status.Text = "APPA bereit - Klick zum Casten"
      elseif g.SB_AIM or g.SB_CLASH or g.SB_SAFE then
        if g.SB_STATUS then status.Text = tostring(g.SB_STATUS)
        elseif g.SB_CLASH and lp:GetAttribute("Client_IsClashing") == true then status.Text = "Clash aktiv - Hits: " .. tostring(g.SB_CLASH_HITS or 0)
        elseif g.SB_SAFE then status.Text = "Safe: naechster -> " .. tostring(g.SB_SAFE_ROT[g.SB_ROT_IDX] or "?")
        elseif g.SB_AIM then status.Text = "Silent-Aim: " .. (g.SB_AIM_TARGET and ("-> " .. tostring(g.SB_AIM_TARGET)) or "(Cursor)")
        else status.Text = "Auto-Clash scharf" end
      else
        status.Text = "F Aim | H Shield | P Clash | T Appa | G Appa-Load"
      end
      task.wait(0.15)
    end
  end)

  -- Dragging
  local dragging, dragStart, startPos
  header.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      dragging = true; dragStart = i.Position; startPos = main.Position
    end
  end)
  table.insert(g.SB_CONNS, UIS.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
      local d = i.Position - dragStart
      main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
  end))
  table.insert(g.SB_CONNS, UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
  end))

  render()
  return gui
end

mountGui()
return "Spellbound GUI geladen"
