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
g.SB_CURSE, g.SB_COMBO, g.SB_AIM, g.SB_SHIELD, g.SB_CLASH = false, false, false, false, false
g.SB_SAFE, g.SB_APPA_PENDING = false, false
g.SB_CURSE_LOOP, g.SB_AIM_LOOP, g.SB_CLASH_LOOP = false, false, false
if g.SB_CONNS then
  for _, c in ipairs(g.SB_CONNS) do pcall(function() c:Disconnect() end) end
end
g.SB_CONNS = {}
-- Shield-Listener bleibt idempotent ueber SB_SHIELD_HOOKED (nicht doppelt legen).

g.SB_SPELL       = g.SB_SPELL       or "avada kedavra"
g.SB_COMBO_SPELL = g.SB_COMBO_SPELL or "stupefy"
g.SB_AIM_FOV     = g.SB_AIM_FOV     or 140
g.SB_AIM_RANGE   = g.SB_AIM_RANGE   or 500
g.SB_AIM_EXEMPT  = g.SB_AIM_EXEMPT  or {}   -- [Name]=true -> von Silent-Aim ausgenommen
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

local function startSelector()
  if g.SB_CURSE_LOOP then return end
  g.SB_CURSE_LOOP = true
  task.spawn(function()
    local okM, pm = pcall(function() return require(RS.shared.modules.PlayerMouse) end)
    local u13 = okM and pm and pm:GetMouse() or nil
    local setLoadedSpell, state, fireSpell
    local prevLoaded, casts = nil, 0
    local rotIdx = 1
    local nextAcquire, nextTry = 0, 0
    while g.SB_CURSE or g.SB_AIM or g.SB_SAFE or g.SB_APPA_PENDING do
      pcall(function()
        local char = lp.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local wand = char and char:FindFirstChildWhichIsA("Tool")
        if not (char and hum and hum.Health > 0 and wand) then       -- keine Wand -> kein getgc (Anti-Lag)
          setLoadedSpell, state, fireSpell, prevLoaded = nil, nil, nil, nil
          g.SB_LOADED, g.SB_STATUS = nil, "keine Wand in der Hand"
          return
        end
        if not setLoadedSpell or not state or not state.equipped then  -- getgc gedrosselt
          if os.clock() < nextAcquire then g.SB_STATUS = "warte auf Wand..."; return end
          nextAcquire = os.clock() + 1.5
          setLoadedSpell, state, fireSpell = acquire()
          if not (setLoadedSpell and state and state.equipped) then g.SB_STATUS = "lade Wand..."; return end
        end
        g.SB_STATUS = nil
        -- Safe Combat rotiert durch SAFE_ROT; sonst der fixe Auto-Spell
        local ROT = g.SB_SAFE_ROT
        -- Prioritaet: appa-Zwischenladung > Safe-Rotation > fixer Auto-Spell
        local SPELL
        if g.SB_APPA_PENDING then SPELL = APPA_NAME
        elseif g.SB_SAFE then SPELL = ROT[rotIdx]
        else SPELL = g.SB_SPELL or "avada kedavra" end
        if state.loadedSpell == SPELL then
          prevLoaded = SPELL          -- liegt bereit -> dein Klick feuert ihn (no-CD)
        else
          if os.clock() < nextTry then return end
          local justFired = (prevLoaded == SPELL)   -- wurde gerade gefeuert (unloaded)
          local wasAppa   = (SPELL == APPA_NAME)
          if prevLoaded then
            casts = casts + 1; prevLoaded = nil
            if wasAppa then g.SB_APPA_PENDING = false        -- appa verbraucht -> wieder normal laden
            elseif g.SB_SAFE then rotIdx = rotIdx % #ROT + 1 end
          end
          -- COMBO nur im reinen Auto-Spell-Modus (nicht safe, nicht appa)
          if justFired and not wasAppa and not g.SB_SAFE and g.SB_COMBO and fireSpell and g.SB_COMBO_SPELL and g.SB_COMBO_SPELL ~= SPELL then
            local tgt = (u13 and u13.Hit and u13.Hit.Position)
            state.casts = 0
            setLoadedSpell(g.SB_COMBO_SPELL, true)
            task.wait(0.1)
            if state.loadedSpell == g.SB_COMBO_SPELL then
              state.casts = 0
              pcall(fireSpell, tgt)
              g.SB_COMBO_CASTS = (tonumber(g.SB_COMBO_CASTS) or 0) + 1
              task.wait(0.05)
            end
          end
          -- naechsten Spell bestimmen (appa hat Vorrang, sonst Rotation/Auto-Spell)
          local NEXT
          if g.SB_APPA_PENDING then NEXT = APPA_NAME
          elseif g.SB_SAFE then NEXT = ROT[rotIdx]
          else NEXT = g.SB_SPELL or "avada kedavra" end
          state.casts = 0
          setLoadedSpell(NEXT, true)
          if state.loadedSpell == NEXT then prevLoaded, nextTry = NEXT, 0
          else nextTry = os.clock() + 0.4 end
        end
        g.SB_LOADED, g.SB_CASTS = state.loadedSpell, casts
      end)
      task.wait(0.05)
    end
    g.SB_CURSE_LOOP = false
    g.SB_LOADED, g.SB_STATUS = nil, nil
  end)
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
    local cam = workspace.CurrentCamera
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not (cam and myHRP) then rawset(u13, "Hit", nil); return end
    local mp = UIS:GetMouseLocation()
    local bestPos, bestScreen, bestName
    for _, pl in ipairs(Players:GetPlayers()) do
      if pl ~= lp and pl.Character and not (g.SB_AIM_EXEMPT and g.SB_AIM_EXEMPT[pl.Name]) then
        local h  = pl.Character:FindFirstChild("HumanoidRootPart")
        local hu = pl.Character:FindFirstChildOfClass("Humanoid")
        if h and hu and hu.Health > 0 then
          local sp, onScreen = cam:WorldToViewportPoint(h.Position)
          if onScreen and sp.Z > 0 then
            local sd = (Vector2.new(sp.X, sp.Y) - Vector2.new(mp.X, mp.Y)).Magnitude
            local wd = (h.Position - myHRP.Position).Magnitude
            if sd <= g.SB_AIM_FOV and wd <= g.SB_AIM_RANGE and (not bestScreen or sd < bestScreen) then
              bestPos, bestScreen, bestName = h.Position, sd, pl.Name
            end
          end
        end
      end
    end
    if bestPos then rawset(u13, "Hit", CFrame.new(bestPos)); g.SB_AIM_TARGET = bestName
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
  main.Size = UDim2.fromOffset(240, 594)
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

  local btnAuto  = mkButton(38, 34)   -- AUTO-SPELL toggle (G)
  local ddAuto   = mkButton(76, 28)   -- Auto-Spell auswaehlen
  local btnCombo = mkButton(108, 34)  -- COMBO toggle
  local ddCombo  = mkButton(146, 28)  -- Combo-Spell auswaehlen
  local btnAim   = mkButton(178, 34)  -- SILENT-AIM toggle (F)
  local btnShield= mkButton(216, 34)  -- AUTO-SHIELD toggle (H)
  local btnClash = mkButton(254, 34)  -- AUTO-CLASH toggle (P)
  local btnExempt= mkButton(292, 28)  -- Silent-Aim Ausnahmen (Whitelist)
  local btnAppa  = mkButton(324, 28)  -- Apparate-Ziel waehlen (TP mit Taste T)
  local btnAppaGo= mkButton(356, 30)  -- Apparate JETZT (Button + Taste T)
  local btnSafe  = mkButton(390, 30)  -- SAFE COMBAT toggle (B) - ersetzt Auto-Spell
  local btnRot1  = mkButton(422, 24)  -- Rotation Slot 1
  local btnRot2  = mkButton(448, 24)  -- Rotation Slot 2
  local btnRot3  = mkButton(474, 24)  -- Rotation Slot 3
  local btnRot4  = mkButton(500, 24)  -- Rotation Slot 4
  local rotBtns  = { btnRot1, btnRot2, btnRot3, btnRot4 }
  local btnAppaLoad = mkButton(528, 30)  -- appa in die Hand laden (dann selbst casten)

  local status = Instance.new("TextLabel")
  status.Size = UDim2.new(1, -20, 0, 20); status.Position = UDim2.fromOffset(10, 562)
  status.BackgroundTransparency = 1; status.Font = Enum.Font.Gotham; status.TextSize = 12
  status.TextColor3 = Color3.fromRGB(170, 160, 200); status.TextXAlignment = Enum.TextXAlignment.Left
  status.Text = "bereit"; status.Parent = main

  -- Ein-/Ausklappen (Header bleibt sichtbar; Hotkeys laufen unabhaengig weiter)
  local openList   -- offenes Dropdown (von Spell-/Exempt-/Appa-Listen genutzt)
  local FULL_H = 594
  local collapsed = false
  local content = { btnAuto, ddAuto, btnCombo, ddCombo, btnAim, btnShield, btnClash, btnExempt, btnAppa, btnAppaGo, btnSafe, btnRot1, btnRot2, btnRot3, btnRot4, btnAppaLoad, status }
  local function setCollapsed(v)
    collapsed = v
    for _, c in ipairs(content) do c.Visible = not v end
    if v and openList then openList:Destroy(); openList = nil end
    main.Size = UDim2.fromOffset(240, v and 30 or FULL_H)
    collapseBtn.Text = v and "+" or "\xe2\x80\x93"
  end
  collapseBtn.MouseButton1Click:Connect(function() setCollapsed(not collapsed) end)

  ddAuto.BackgroundColor3   = Color3.fromRGB(40, 36, 58)
  ddCombo.BackgroundColor3  = Color3.fromRGB(40, 36, 58)
  btnExempt.BackgroundColor3 = Color3.fromRGB(40, 36, 58)
  btnAppa.BackgroundColor3   = Color3.fromRGB(40, 36, 58)
  for _, rb in ipairs(rotBtns) do rb.BackgroundColor3 = Color3.fromRGB(34, 44, 40); rb.TextSize = 12 end

  local function render()
    btnAuto.Text = g.SB_CURSE and "AUTO-SPELL: AN" or "AUTO-SPELL: AUS"
    btnAuto.BackgroundColor3 = g.SB_CURSE and Color3.fromRGB(56,150,78) or Color3.fromRGB(150,56,62)
    ddAuto.Text = "Spell: " .. tostring(g.SB_SPELL) .. "  \xe2\x96\xbc"
    btnCombo.Text = g.SB_COMBO and "COMBO: AN" or "COMBO: AUS"
    btnCombo.BackgroundColor3 = g.SB_COMBO and Color3.fromRGB(150,110,40) or Color3.fromRGB(70,62,96)
    ddCombo.Text = "Combo: " .. tostring(g.SB_COMBO_SPELL) .. "  \xe2\x96\xbc"
    btnAim.Text = g.SB_AIM and "SILENT-AIM: AN  [F]" or "SILENT-AIM: AUS  [F]"
    btnAim.BackgroundColor3 = g.SB_AIM and Color3.fromRGB(200,130,40) or Color3.fromRGB(70,62,96)
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
    btnAppaLoad.Text = g.SB_APPA_PENDING and "APPA GELADEN - jetzt casten!" or "APPA LADEN"
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
  makeDropdown(ddAuto,  function(n) g.SB_SPELL = n end)
  makeDropdown(ddCombo, function(n) g.SB_COMBO_SPELL = n end)
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
    g.SB_APPA_PENDING = true      -- laedt appa in die Hand; nach dem Cast wieder normal
    startSelector()               -- Loop laeuft (auch ohne Auto-Spell/Safe)
    render()
  end)

  btnAuto.MouseButton1Click:Connect(function()
    g.SB_CURSE = not g.SB_CURSE
    if g.SB_CURSE then g.SB_SAFE = false; startSelector() end
    render()
  end)
  btnSafe.MouseButton1Click:Connect(function()
    g.SB_SAFE = not g.SB_SAFE
    if g.SB_SAFE then g.SB_CURSE = false; startSelector() end   -- ersetzt Auto-Spell
    render()
  end)
  btnCombo.MouseButton1Click:Connect(function()
    g.SB_COMBO = not g.SB_COMBO
    if g.SB_COMBO then g.SB_CURSE = true; startSelector() end   -- Combo braucht den Auto-Spell-Loop
    render()
  end)
  btnAim.MouseButton1Click:Connect(function()
    g.SB_AIM = not g.SB_AIM
    if g.SB_AIM then if not g.SB_SAFE then g.SB_CURSE = true end; startSelector(); startAim() end
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
      g.SB_AIM = not g.SB_AIM; if g.SB_AIM then if not g.SB_SAFE then g.SB_CURSE = true end; startSelector(); startAim() end; render()
    elseif i.KeyCode == Enum.KeyCode.H then
      g.SB_SHIELD = not g.SB_SHIELD; if g.SB_SHIELD then hookShield() end; render()
    elseif i.KeyCode == Enum.KeyCode.P then
      g.SB_CLASH = not g.SB_CLASH; if g.SB_CLASH then startClashAuto() end; render()
    elseif i.KeyCode == Enum.KeyCode.T then
      apparateTo(g.SB_APPA_TARGET)
    end
  end))

  task.spawn(function()
    while gui.Parent do
      render()
      if g.SB_CURSE or g.SB_AIM or g.SB_CLASH or g.SB_SAFE then
        if g.SB_STATUS then status.Text = tostring(g.SB_STATUS)
        elseif g.SB_CLASH and lp:GetAttribute("Client_IsClashing") == true then status.Text = "Clash aktiv - Hits: " .. tostring(g.SB_CLASH_HITS or 0)
        elseif g.SB_SAFE then status.Text = "Safe Combat: " .. tostring(g.SB_LOADED or "...")
        elseif g.SB_AIM then status.Text = "Silent-Aim: " .. (g.SB_AIM_TARGET and ("-> " .. tostring(g.SB_AIM_TARGET)) or "(Cursor)")
        elseif g.SB_CURSE then status.Text = "geladen: " .. tostring(g.SB_LOADED or "...")
        else status.Text = "Auto-Clash scharf" end
      else
        status.Text = "F Aim | H Shield | P Clash | T Appa"
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
