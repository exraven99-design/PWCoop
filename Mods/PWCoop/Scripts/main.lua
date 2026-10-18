-- PWCoop v1 — ядро co-op для Project Wingman (UE4SS Lua).
-- Принцип стабильности: НИКАКИХ опросов (LoopAsync) — во время смены уровня они роняли игру.
--   * состояние игры узнаём из события движка PlayerController:ClientRestart(NewPawn) (RPC через ProcessEvent);
--   * вся работа в полёте — в post-хуке FlyingPawn_C:ReceiveTick (вызывается только у живой пешки).
-- Обмен с Steam-демоном (coop/steam_helper.py daemon --dir Mods/PWCoop/io):
--   out.txt (мы пишем своё состояние), in.txt (состояние напарника), status.txt (сессия), cmd.txt (команды UI).
-- Формат строки: seq,ts,x,y,z,pitch,yaw,roll,fwd,hp, gc,mc,mts,mx,my,mz,mp,myw,mr,mspd,mpath, bspd,bpath, mesh
local IO = "Mods/PWCoop/io/"
local OUT, IN, STATUS = IO .. "out.txt", IO .. "in.txt", IO .. "status.txt"

-- автозапуск Steam-демона из установленного пакета (без bat): скрытый процесс, один экземпляр (мьютекс),
-- сам завершается после закрытия игры. Если exe нет (режим разработки через start_coop.bat) — пропускаем.
local HELPER = "Mods\\PWCoop\\helper\\pwcoop_helper.exe"
pcall(function()
    local f = io.open(HELPER, "rb")
    if not f then return end
    f:close()
    -- файл Mods\PWCoop\loopback.txt включает самопроверку без друга (призрак = свой самолёт +400 м); для игры вдвоём удалить
    local lb = io.open("Mods\\PWCoop\\loopback.txt", "rb")
    if lb then lb:close() end
    os.execute('start "" /B "' .. HELPER .. '" daemon --dir "Mods\\PWCoop\\io" --watch-game' .. (lb and " --loopback" or ""))
    if lb then print("[PWCoop] ВНИМАНИЕ: включён режим loopback (loopback.txt)\n") end
    print("[PWCoop] демон запущен из пакета\n")
end)

local DELAY = 0.15          -- задержка показа призрака (запас на джиттер), с
local MAX_EXTRAP = 0.25     -- максимум экстраполяции, с
local SEND_DT = 1 / 30      -- отправка своего состояния
local READ_DT = 1 / 50      -- чтение in.txt
local STATUS_DT = 0.5       -- чтение status.txt
local GHOST_TIMEOUT = 5     -- нет данных дольше — убираем призрака, с
local AMMO_KEY = "WeaponAmmo_13_5462C65D40E2CA635C8CC18ACF26D88E"
local AIRUNIT = "/Game/ProjectWingman/Blueprints/GameUnit/Air/AirUnit_Fighter.AirUnit_Fighter_C"
-- штатный союзный ведомый (есть в миссиях, напр. C_M08): подпись/цвет союзника заложены в самом классе
-- Призрак — цель для врагов (они реагируют на него как на игрока). Плата: наши ракеты тоже могут его захватить.
-- false — как раньше: не цель ни для кого (враги его игнорируют).
local GHOST_TARGETTABLE = true
local WINGMAN_BP ="/Game/ProjectWingman/Blueprints/GameUnit/Air/AirUnit_Fighter_Wingman"
local WINGMAN_C = WINGMAN_BP .. "." .. "AirUnit_Fighter_Wingman_C"

local function L(m) print("[PWCoop] " .. m .. "\n") end
local function S(f) local ok, v = pcall(f) if ok then return v end return nil end
local errCount = {}
local function Err(tag, e)
    errCount[tag] = (errCount[tag] or 0) + 1
    if errCount[tag] <= 5 then L("ошибка " .. tag .. ": " .. tostring(e)) end
end

-- ===================== состояние игры (по ClientRestart) =====================
local STATEMAP = {
    MenuActor_V2_C = "menu", LoadPawn_C = "loading", BP_PlayerBriefingPawn_C = "briefing",
    BP_StagingActor_C = "staging", HangarActor_C = "hangar", BP_MissionSelectPawn_C = "select",
    FlyingPawn_C = "flight", DebriefActor_C = "debrief",
}
GAME_STATE = "boot"            -- глобально: читается модулем UI (шаг 3)

-- ===================== полётное состояние =====================
local F = {}                   -- всё, что относится к текущему полёту; сбрасывается при смене пешки
local function ResetFlight()
    F = {
        seq = 0, lastIn = -1, lastSend = -1, lastRead = -1, lastStatus = -1,
        buf = {}, offset = nil, offN = 0, lastRt = nil, lastRx = nil,
        ghost = nil, visual = nil, visMesh = nil, lastSpawn = -10, visYaw = 0,
        gc = 0, mc = 0, mEv = nil, bpath = nil, bspd = nil, needBullet = false,
        knownM = nil, prevIdx = nil, prevAmmo = nil, lastPoll = 0, scanUntil = 0,
        lastGc = nil, lastMc = nil, events = {}, gmFly = {}, ghostMissiles = {},
        status = {}, myMesh = nil,
        sidBase = (os.time() % 100000) * 1000,      -- уникальные id ракет между полётами
    }
end
ResetFlight()

local gs = nil
local function GS() gs = gs or StaticFindObject("/Script/Engine.Default__GameplayStatics") return gs end
local function Origin(p) local o = GS():GetWorldOriginLocation(p) return o.X, o.Y, o.Z end
local function Now(p) return GS():GetTimeSeconds(p) end
local function ClassPathOf(obj)
    local full = obj:GetClass():GetFullName()
    return full:match("^%S+%s+(.+)$") or full
end
-- путь меша ракеты (kind "m") или бомбы (kind "b"); nil, если ещё не задан
local function MeshOf(m, kind)
    return S(function()
        local c = kind == "b" and m.Bomb or m.StaticMesh
        return c.StaticMesh:GetFullName():match("^%S+%s+(.+)$")
    end)
end
local function AngLerp(a, b, t) local d = (b - a + 180) % 360 - 180 return a + d * t end

-- ===================== файлы =====================
local function ReadStatus()
    local f = io.open(STATUS, "r")
    if not f then return {} end
    local t = {}
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = v end
    end
    f:close()
    return t
end
COOP_STATUS = {}               -- глобально для UI

local function WriteOut(p, now)
    local l, r = p:K2_GetActorLocation(), p:K2_GetActorRotation()
    local ox, oy, oz = Origin(p)
    F.seq = F.seq + 1
    if not F.myMesh then
        F.myMesh = S(function() return ClassPathOf(p) and p.ThirdPersonModel.SkeletalMesh:GetFullName():match("^%S+%s+(.+)$") end) or "-"
    end
    local m = F.mEv or {t = 0, x = 0, y = 0, z = 0, pitch = 0, yaw = 0, roll = 0, spd = 0, path = "-", mesh = "-"}
    -- поле 26: траектории моих ракет «id;x;y;z;pitch;yaw;alive;mesh;trail|...» (до 4 последних).
    -- Уничтоженная ракета передаётся ещё 10 пакетов с alive=0 — напарник взрывает её в последней точке.
    local parts = {}
    local list = F.myMissiles or {}
    for i = #list, 1, -1 do
        local mm = list[i]
        local alive = mm.ref and S(function() return mm.ref:IsValid() end)
        if alive then
            local ml, mr = S(function() return mm.ref:K2_GetActorLocation() end), S(function() return mm.ref:K2_GetActorRotation() end)
            if ml and mr then
                mm.last = {ml.X + ox, ml.Y + oy, ml.Z + oz, mr.Pitch, mr.Yaw}
                -- застывшая «пущенная» ракета (без движения > 1.5 с) — не настоящая, молча забываем
                local ddx, ddy, ddz = ml.X - (mm.px or 1e12), ml.Y - (mm.py or 0), ml.Z - (mm.pz or 0)
                if ddx * ddx + ddy * ddy + ddz * ddz > 100 ^ 2 then
                    mm.px, mm.py, mm.pz, mm.still = ml.X, ml.Y, ml.Z, nil
                else
                    mm.still = mm.still or now
                    if mm.ready and now - mm.still > 1.5 then mm.drop = true end
                end
                if not mm.ready then
                    -- «висящая» ракета-заглушка на пилоне (перезарядка) не показывается: ждём настоящего пуска
                    local launched = S(function()
                        if mm.kind == "b" then return mm.ref.IsReleased end
                        return mm.ref.s_launched
                    end)
                    local dx, dy, dz = ml.X - l.X, ml.Y - l.Y, ml.Z - l.Z
                    local far = dx * dx + dy * dy + dz * dz > (mm.kind == "b" and 2000 or 6000) ^ 2
                    -- «далеко от самолёта» годится лишь как запасной признак (бомбы / флаг не читается):
                    -- у заглушек, спавнящихся вдали, он давал зависшие призраки
                    -- настоящая ракета отрывается от самолёта (>30 м); заглушка на пилоне с флагом s_launched летит вместе с ним
                    local away = dx * dx + dy * dy + dz * dz > 3000 ^ 2
                    if (launched == true and away) or (far and (mm.kind == "b" or launched == nil)) then
                        mm.ready = true
                        L("ракета #" .. mm.id .. " пущена (" .. mm.cls .. ", s_launched=" .. tostring(launched) .. ", от самолёта " .. string.format("%.0f", math.sqrt(dx * dx + dy * dy + dz * dz) / 100) .. " м)")
                    end
                end
                -- меш/след настоящей ракеты: в момент детекта они ещё «по умолчанию» (модель выбирается позже)
                if mm.ready and now - (mm.metaT or -1) > 0.3 then
                    mm.metaT = now
                    local nm = MeshOf(mm.ref, mm.kind)
                    if nm then mm.mesh = nm end
                    local tr = mm.kind ~= "b" and S(function() return mm.ref.ParticleSystem.Template:GetFullName():match("^%S+%s+(.+)$") end)
                    if tr then mm.trail = tr end
                end
            else
                alive = false
            end
        end
        if not alive then
            mm.ref = nil
            mm.deadSent = mm.deadSent + 1
        end
        if mm.drop or mm.deadSent > 10 or (not alive and not mm.ready) then
            table.remove(list, i)               -- заглушка исчезла, не взлетев: молча забываем
        elseif mm.ready and mm.last and #parts < 4 then
            local q = mm.last
            parts[#parts + 1] = string.format("%d;%.0f;%.0f;%.0f;%.1f;%.1f;%d;%s;%s;%s", mm.id, q[1], q[2], q[3], q[4], q[5],
                alive and 1 or 0, mm.mesh or "-", mm.trail or "-", mm.kind or "m")
        end
    end
    local msl = #parts > 0 and table.concat(parts, "|") or "-"
    -- поле 27: уничтожения вражеских юнитов «id;владелец;класс;команда;x;y;z|...» (повторяются 6 с — канал ненадёжный)
    local evp = {}
    local kl = F.kills or {}
    for i = #kl, 1, -1 do
        local k = kl[i]
        if now - k.t > 6 then table.remove(kl, i)
        else evp[#evp + 1] = string.format("%d;%s;%s;%d;%.0f;%.0f;%.0f", k.id, tostring(COOP_STATUS.me_id or 0), k.cls, k.team, k.x, k.y, k.z) end
    end
    local kev = #evp > 0 and table.concat(evp, "|") or "-"
    local f = io.open(OUT, "w")
    if not f then return end
    -- поле 25: путь меша ракеты (настоящая модель у напарника); поле 26: траектории ракет
    f:write(string.format("%d,%.4f,%.0f,%.0f,%.0f,%.2f,%.2f,%.2f,%.0f,%.0f,%d,%d,%.4f,%.0f,%.0f,%.0f,%.2f,%.2f,%.2f,%.0f,%s,%.0f,%s,%s,%s,%s,%s,%.1f,%s,%.2f,%d\n",
        F.seq, now, l.X + ox, l.Y + oy, l.Z + oz, r.Pitch, r.Yaw, r.Roll,
        p["p_Current forward speed"] or 0, p.g_Health or 0,
        F.gc, F.mc, m.t, m.x, m.y, m.z, m.pitch, m.yaw, m.roll, m.spd, m.path,
        F.bspd or 0, F.bpath or "-", F.myMesh or "-", m.mesh or "-", msl, kev, F.gdAccum or 0,
        ((F.seq % 10 == 0) and F.myLayout) or "-", S(function() return p.a_AfterburnerFloat end) or 0,
        ((S(function() return p.g_IsDestroyed end) == true or (p.g_Health or 100) <= 0) and 1 or 0)))
    f:close()
end

local function ReadIn()
    local f = io.open(IN, "r")
    if not f then return nil end
    local line = f:read("l")
    f:close()
    if not line then return nil end
    local raw = {}
    for v in line:gmatch("[^,]+") do raw[#raw + 1] = v end
    local function N(i) return tonumber(raw[i]) end        -- по индексу поля (строковые поля не сдвигают числа)
    if #raw < 10 or N(1) == F.lastIn then return nil end
    F.lastIn = N(1)
    local st = {t = N(2), x = N(3), y = N(4), z = N(5), pitch = N(6), yaw = N(7), roll = N(8), fwd = N(9) or 0, hp = N(10),
        gc = N(11) or 0, mc = N(12) or 0}
    if not (st.t and st.x and st.y and st.z) then return nil end
    if #raw >= 23 then
        st.m = {t = N(13), x = N(14), y = N(15), z = N(16), pitch = N(17), yaw = N(18), roll = N(19), spd = N(20), path = raw[21]}
        st.bspd, st.bpath = N(22), raw[23]
    end
    st.mesh = raw[24]
    st.layout, st.ab = raw[29], N(30)
    st.dead = N(31) == 1
    st.gd = N(28)              -- поле 28: накопленный урон по призраку на стороне напарника (его враги бьют «меня»)
    if st.m then st.m.mesh = raw[25] end
    -- поле 27: уничтожения юнитов напарника
    st.kills = {}
    if raw[27] and raw[27] ~= "-" then
        for e in raw[27]:gmatch("[^|]+") do
            local id, owner, cls, team, x, y, z = e:match("^(%d+);([^;]*);([^;]*);(%-?%d+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+)$")
            if id then
                st.kills[#st.kills + 1] = {id = tonumber(id), owner = owner, cls = cls, team = tonumber(team),
                    x = tonumber(x), y = tonumber(y), z = tonumber(z)}
            end
        end
    end
    -- поле 26: ракеты
    st.ms = {}
    if raw[26] and raw[26] ~= "-" then
        for e in raw[26]:gmatch("[^|]+") do
            local id, x, y, z, pp, yw, al, mesh, trail, kind = e:match("^(%d+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);(%d);([^;]*);([^;]*);?(.*)$")
            if id then
                st.ms[tonumber(id)] = {x = tonumber(x), y = tonumber(y), z = tonumber(z), pitch = tonumber(pp), yaw = tonumber(yw),
                    alive = al == "1", mesh = mesh, trail = trail, kind = kind}
            end
        end
    end
    return st
end

-- ===================== призрак напарника =====================
local function LoadMesh(path)
    if not path or path == "-" then return nil end
    local m = StaticFindObject(path)
    if m and S(function() return m:IsValid() end) then return m end
    local ok, a = pcall(LoadAsset, path)
    if ok and a and S(function() return a:IsValid() end) then return a end
end

-- визуал = SkeletalMeshActor с моделью самолёта НАПАРНИКА (путь меша приходит в пакете); запасной — своя модель
local function SpawnVisual(p, loc, meshPath)
    local mesh = LoadMesh(meshPath)
    local tpm = p.ThirdPersonModel
    if not mesh then mesh = S(function() return tpm.SkeletalMesh end) end
    if not mesh then return nil end
    local g = p:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.SkeletalMeshActor"), loc, {Pitch = 0, Yaw = 0, Roll = 0})
    if not g or not g:IsValid() then return nil end
    local comp = g.SkeletalMeshComponent
    pcall(function() comp:SetMobility(2) end)
    pcall(function() comp:SetSkeletalMesh(mesh, true) end)
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetVisibility(true, true) end)
    pcall(function()
        local wr, ar = tpm:K2_GetComponentRotation(), p:K2_GetActorRotation()
        F.visYaw = (wr.Yaw - ar.Yaw + 180) % 360 - 180
    end)
    F.visMesh = meshPath
    return g
end

-- носитель радара/HUD = настоящий AirUnit_Fighter: союзник, бессмертный, без тика, без коллизии, скрыт и беззвучен
local function FindWingmanClass()
    local c = StaticFindObject(WINGMAN_C)
    if c and S(function() return c:IsValid() end) then return c end
    local ok, a = pcall(LoadAsset, WINGMAN_BP)              -- блюпринт может быть ещё не загружен в этой карте
    if ok and a and S(function() return a:IsValid() end) then
        local gc = S(function() return a.GeneratedClass end)
        if gc and S(function() return gc:IsValid() end) then return gc end
        c = StaticFindObject(WINGMAN_C)
        if c and S(function() return c:IsValid() end) then return c end
    end
end

-- GameUnit призрака: g_SelfGameUnitRef у заспавненного нами юнита пуст (nullptr), берём дочерний актор GameUnit_Air
local function GetGU(g)
    local gu = S(function() return g.g_SelfGameUnitRef end)
    if gu and S(function() return gu:IsValid() end) then return gu end
    gu = S(function() return g.GameUnit_Air:GetChildActor() end)
    if gu and S(function() return gu:IsValid() end) then return gu end
    -- запасной путь: ближайший к призраку GameUnit_Air (не чаще раза в секунду; наш самолёт далеко — призрак в 400 м)
    local clk = os.clock()
    if clk - (F.guSearchT or -10) < 1 then
        return F.guCache and S(function() return F.guCache:IsValid() end) and F.guCache or nil
    end
    F.guSearchT = clk
    local gl = S(function() return g:K2_GetActorLocation() end)
    local best, bd = nil, 3000 ^ 2
    for _, u in ipairs(S(function() return FindAllOf("GameUnit_Air_C") end) or {}) do
        local ul = S(function() return u:IsValid() and u:K2_GetActorLocation() end)
        if ul and gl then
            local d = (ul.X - gl.X) ^ 2 + (ul.Y - gl.Y) ^ 2 + (ul.Z - gl.Z) ^ 2
            if d < bd then best, bd = u, d end
        end
    end
    F.guCache = best
    return best
end

local function SpawnGhost(p, loc)
    local cls = FindWingmanClass()
    L("носитель призрака: " .. (cls and "AirUnit_Fighter_Wingman (союзник игры)" or "AirUnit_Fighter (запасной)"))
    if not cls then cls = StaticFindObject(AIRUNIT) end
    if not (cls and S(function() return cls:IsValid() end)) then return nil end
    local g = p:GetWorld():SpawnActor(cls, loc, {Pitch = 0, Yaw = 0, Roll = 0})
    if not g or not g:IsValid() then return nil end
    F.lbl = nil                -- новая метка: заново инициализировать
    F.gLastH = nil             -- новый счёт урона по призраку
    pcall(function() g.g_Team = p.g_Team end)
    pcall(function() g.BrainDead = true g.BrainDeadFor = 1e9 end)
    pcall(function() g:SetActorTickEnabled(false) end)
    pcall(function() g.g_Health = 1000000 g.OriginalHealth = 1000000 g.CanEject = false end)
    -- коллизия: по ней враги наводятся и попадают. Сфера носителя блокирует всё (пули/снаряды), но игнорирует Pawn —
    -- иначе мой самолёт будет упираться в призрака, когда летим рядом. Перемещение без sweep → в скалы/воду он не врезается.
    pcall(function() g:SetActorEnableCollision(true) end)
    pcall(function() g.Sphere:SetCollisionEnabled(3) end)
    pcall(function() g.Sphere:SetCollisionResponseToAllChannels(2) end)
    pcall(function() g.Sphere:SetCollisionResponseToChannel(2, 0) end)    -- Pawn: игнор
    pcall(function() g.Sphere:SetCollisionResponseToChannel(6, 0) end)    -- Vehicle: игнор
    pcall(function() g.Sphere:SetGenerateOverlapEvents(true) end)
    L("коллизия призрака: включена (сфера блокирует, Pawn игнорируется), состояние сферы " ..
        tostring(S(function() return g.Sphere:GetCollisionEnabled() end)))
    pcall(function()
        local gu = g.g_SelfGameUnitRef
        if gu and gu:IsValid() then
            gu.Immunity = true
            gu.g_Team = p.g_Team
            pcall(function() gu:SetTeam(p.g_Team) end)
            gu.g_Targettable = false
            pcall(function() gu:DisableTargeting() end)
        end
    end)
    -- подпись над целью: имя напарника (без него игра показывает UNKNOWN)
    local nm = COOP_STATUS.peer_name
    if not nm or nm == "" then nm = "WINGMAN" end
    pcall(function() g.UnitText = FText(nm) end)
    pcall(function() g.UnitTag = FText(nm) end)
    pcall(function()
        local gu = g.g_SelfGameUnitRef
        gu.WidgetName = FText(nm)
        gu.WidgetTag = FText(nm)
        gu.GameTag = FText(nm)
    end)
    for _, n in ipairs({"SkeletalMesh", "StaticMesh", "GearMesh", "ParticleSystem", "SmokeEmitter"}) do
        pcall(function() g[n]:SetVisibility(false, true) end)
    end
    for _, n in ipairs({"Audio", "AircraftAfterburner"}) do
        pcall(function() g[n]:Stop() end)
        pcall(function() g[n]:SetVolumeMultiplier(0.0) end)
    end
    return g
end

local function DestroyGhost()
    pcall(function() if F.ghost and F.ghost:IsValid() then F.ghost:K2_DestroyActor() end end)
    pcall(function() if F.visual and F.visual:IsValid() then F.visual:K2_DestroyActor() end end)
    F.ghost, F.visual = nil, nil
end

-- позиция призрака на момент rt (время отправителя): интерполяция или экстраполяция
local function Sample(rt)
    local buf, n = F.buf, #F.buf
    if n == 0 then return nil end
    local last = buf[n]
    if rt >= last.t then
        local age = math.min(MAX_EXTRAP, rt - last.t)
        local pr, yr = math.rad(last.pitch), math.rad(last.yaw)
        local k = last.fwd * age
        return {x = last.x + math.cos(pr) * math.cos(yr) * k, y = last.y + math.cos(pr) * math.sin(yr) * k,
                z = last.z + math.sin(pr) * k, pitch = last.pitch, yaw = last.yaw, roll = last.roll}
    end
    if rt <= buf[1].t then return buf[1] end
    for i = n - 1, 1, -1 do
        local a, b = buf[i], buf[i + 1]
        if rt >= a.t then
            local k = (rt - a.t) / math.max(1e-4, b.t - a.t)
            return {x = a.x + (b.x - a.x) * k, y = a.y + (b.y - a.y) * k, z = a.z + (b.z - a.z) * k,
                    pitch = AngLerp(a.pitch, b.pitch, k), yaw = AngLerp(a.yaw, b.yaw, k), roll = AngLerp(a.roll, b.roll, k)}
        end
    end
    return buf[1]
end

-- ===================== приём пакетов =====================
local function Receive(p, now)
    local st = ReadIn()
    if not st then return end
    F.lastRx = now
    local o = now - st.t
    F.offN = math.min(F.offN + 1, 50)                         -- среднее в начале, затем EMA ~50 пакетов
    F.offset = F.offset and (F.offset + (o - F.offset) / F.offN) or o
    F.buf[#F.buf + 1] = st
    if #F.buf > 40 then table.remove(F.buf, 1) end
    F.peerMesh = st.mesh
    F.peerHp = st.hp
    if st.layout and st.layout ~= "-" then F.peerLayout = st.layout end
    F.peerAb = st.ab
    F.peerDead = st.dead
    -- урон, нанесённый призраку у напарника, переносим на настоящий самолёт (счётчик накопленный, повторы безопасны)
    if st.gd then
        if F.lastGd == nil or st.gd < F.lastGd then F.lastGd = st.gd end        -- первый пакет/сброс у напарника
        local dmg = st.gd - F.lastGd
        -- при синхроне позиций ИИ (host/guest) партнёра бьют враги его собственного мира — перенос урона дал бы двойной урон
        local role = COOP_STATUS.role
        if role == "host" or role == "guest" then F.lastGd = st.gd dmg = 0 end
        if dmg >= 0.5 then
            F.lastGd = st.gd
            local instig = F.ghost and GetGU(F.ghost)
            local ok, err = pcall(function() p:ApplyHit(dmg, instig, 0) end)
            L("урон от врагов напарника: " .. string.format("%.1f", dmg) .. (ok and "" or (" — ошибка ApplyHit: " .. tostring(err))))
        end
    end
    -- уничтожения у напарника: ставим в очередь (дубли отсекаем по id; свои же события из loopback игнорируем)
    F.seenKills = F.seenKills or {}
    for _, k in ipairs(st.kills or {}) do
        if not F.seenKills[k.id] then
            F.seenKills[k.id] = true
            if k.owner ~= tostring(COOP_STATUS.me_id or 0) then
                F.pendKills = F.pendKills or {}
                F.pendKills[#F.pendKills + 1] = {k = k, first = now}
                L("напарник уничтожил: " .. k.cls .. " (команда " .. k.team .. ")")
            end
        end
    end
    if F.lastGc == nil then
        F.lastGc, F.lastMc = st.gc, st.mc                      -- первый пакет: только запоминаем счётчики
        return
    end
    if st.gc > F.lastGc then
        for _ = 1, math.min(5, st.gc - F.lastGc) do
            F.events[#F.events + 1] = {kind = "gun", t = st.t, path = st.bpath, spd = st.bspd}
        end
    end
    -- ракеты теперь приходят траекториями (поле 26) — отдельное событие пуска не нужно
    F.lastGc, F.lastMc = st.gc, st.mc
    if #F.events > 50 then table.remove(F.events, 1) end
end

-- ===================== свои выстрелы/пуски =====================
local function ActiveAmmo(p)
    return S(function() return p.w_WeaponInventory[p.w_ActiveWeaponIndex + 1][AMMO_KEY] end)
end

local function NewMissiles()
    local cur, fresh = {}, {}
    -- ракеты (в т.ч. подракеты залпов) и бомбы; kind: "m" ракета, "b" бомба
    for _, kc in ipairs({{"MISSILE_BASE_C", "m"}, {"BOMB_BASE_C", "b"}}) do
        local list = S(function() return FindAllOf(kc[1]) end) or {}
        for _, m in ipairs(list) do
            if S(function() return m:IsValid() end) then
                local k = m:GetFullName()
                cur[k] = true
                if F.knownM and not F.knownM[k] and not F.ghostMissiles[k] then fresh[#fresh + 1] = {m, kc[2]} end
            end
        end
    end
    F.knownM = cur
    return fresh
end

local function SenderEvents(p, now)
    -- без предзаполнения: ракеты, висящие на пилонах с начала полёта, тоже должны отслеживаться
    -- (иначе первые пуски до «перезарядки» не доходят до напарника)
    if F.knownM == nil then F.knownM = {} end
    if F.needBullet and not F.bpath then
        F.needBullet = false
        local list = S(function() return FindAllOf("CANNON_BASE_C") end) or {}
        for i = #list, 1, -1 do
            local c = list[i]
            if S(function() return c:IsValid() end) then
                F.bpath, F.bspd = ClassPathOf(c), S(function() return c.ProjectileSpeed end) or 0
                break
            end
        end
    end
    if now - F.lastPoll >= 0.1 then
        F.lastPoll = now
        local idx, ammo = S(function() return p.w_ActiveWeaponIndex end), ActiveAmmo(p)
        if ammo == nil and not F.ammoNilLogged then F.ammoNilLogged = true; L("боезапас не читается (AMMO_KEY/индекс оружия)") end
        if F.prevIdx == idx and ammo and F.prevAmmo and ammo < F.prevAmmo then
            F.scanUntil = now + 3.0
            F.pendDrops = (F.pendDrops or 0) + (F.prevAmmo - ammo)
            F.pendAt = F.pendAt or now
        end
        F.prevIdx, F.prevAmmo = idx, ammo
        if now < F.scanUntil then
            -- все новые ракеты/бомбы (залпы тоже): ведём до уничтожения и транслируем траекторию напарнику
            for _, it in ipairs(NewMissiles()) do
                local m, kind = it[1], it[2]
                local cls = tostring(ClassPathOf(m)):match("[^/]*$")
                local tm = S(function() return m.g_Team end)
                local pt = S(function() return p.g_Team end)
                -- ракеты, рождённые не у нашего самолёта (>100 м), — чужие; если они у призрака, это ракеты его
                -- носителя-ИИ (дубли «второй ракеты»): удаляем, иначе они летят и взрываются рядом с призраком
                local ml, pl = S(function() return m:K2_GetActorLocation() end), S(function() return p:K2_GetActorLocation() end)
                local far = ml and pl and ((ml.X - pl.X) ^ 2 + (ml.Y - pl.Y) ^ 2 + (ml.Z - pl.Z) ^ 2) > 10000 ^ 2
                if far then
                    local gl = F.ghost and S(function() return F.ghost:K2_GetActorLocation() end)
                    if gl and ((ml.X - gl.X) ^ 2 + (ml.Y - gl.Y) ^ 2 + (ml.Z - gl.Z) ^ 2) < 10000 ^ 2 then
                        pcall(function() m:K2_DestroyActor() end)
                        L("ракета носителя призрака удалена (" .. cls .. ")")
                    end
                -- чужие команды отбрасываем; team 0 — ракета ещё не получила команду на пилоне, берём (отсев по пуску ниже)
                elseif tm ~= nil and pt ~= nil and tm ~= pt and tm ~= 0 then
                    L("ракета пропущена (" .. cls .. ", команда " .. tostring(tm) .. ")")
                else
                    F.mc = F.mc + 1
                    F.myMissiles = F.myMissiles or {}
                    L("отслеживаю #" .. F.mc .. ": " .. cls .. " (" .. kind .. "), команда " .. tostring(tm) .. ", мой боезапас -" .. tostring(F.pendDrops))
                    F.myMissiles[#F.myMissiles + 1] = {id = F.sidBase + F.mc, ref = m, deadSent = 0, kind = kind, cls = cls,
                        mesh = MeshOf(m, kind) or "-", trail = "-", ready = false}
                    F.pendDrops, F.pendAt = 0, nil     -- расход боезапаса объяснён ракетой/бомбой
                    F.scanUntil = math.max(F.scanUntil, now + 2.0)   -- залп: следующие подракеты тоже ловим
                end
            end
        end
        -- расход боезапаса без ракеты/бомбы за 0.4 с — стрельба подвесной пушкой: шлём как выстрелы пушки
        if F.pendAt and now - F.pendAt > 0.4 then
            local n = F.pendDrops or 0
            F.pendDrops, F.pendAt = 0, nil
            if n > 0 and n <= 40 then
                F.gc = F.gc + n
                if not F.bpath then F.needBullet = true end
                if not F.podLogged then F.podLogged = true; L("расход без ракеты: считаю выстрелами подвесной пушки (" .. n .. ")") end
            end
        end
    end
end

-- ===================== события призрака =====================
local function CubeMesh()
    return StaticFindObject("/Engine/BasicShapes/Cube.Cube") or LoadAsset("/Engine/BasicShapes/Cube.Cube")
end

-- частицы игры (пути из pak): дымный след ракеты, всплеск воды, взрыв в воздухе
local FX = {
    trail = "/Game/Assets/Particles/MissileSmoke_Lite.MissileSmoke_Lite",
    water = "/Game/Assets/Particles/WaterSplash.WaterSplash",
    air = "/Game/Assets/Particles/AirExplosion.AirExplosion",
}
local fxCache = {}
local function FXT(key)
    local v = fxCache[key]
    if v ~= nil then return v or nil end
    local o = StaticFindObject(FX[key])
    if not (o and S(function() return o:IsValid() end)) then
        local ok, a = pcall(LoadAsset, FX[key])
        o = ok and a or nil
    end
    fxCache[key] = o or false
    if not o then L("частицы не найдены: " .. FX[key]) end
    return o
end

local function FXAt(p, key, x, y, z, scale)
    local t = FXT(key)
    if not t then return end
    local ok, e = pcall(function()
        GS():SpawnEmitterAtLocation(p, t, {X = x, Y = y, Z = z}, {Pitch = 0, Yaw = 0, Roll = 0},
            {X = scale or 1, Y = scale or 1, Z = scale or 1}, true, 0, true)
    end)
    if not ok then Err("fx_" .. key, e) end
end

local function SpawnFakeMissile(p, e)
    local ox, oy, oz = Origin(p)
    local a = p:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"),
        {X = e.x - ox, Y = e.y - oy, Z = e.z - oz}, {Pitch = e.pitch, Yaw = e.yaw, Roll = e.roll})
    if not a or not a:IsValid() then return end
    local comp = a.StaticMeshComponent
    pcall(function() comp:SetMobility(2) end)
    -- настоящая модель ракеты (путь меша из пакета), иначе вытянутый куб
    local mesh = e.mesh and e.mesh ~= "-" and (StaticFindObject(e.mesh) or S(function() return LoadAsset(e.mesh) end))
    if mesh and S(function() return mesh:IsValid() end) then
        pcall(function() comp:SetStaticMesh(mesh) end)
    else
        pcall(function() comp:SetStaticMesh(CubeMesh()) end)
        pcall(function() a:SetActorScale3D({X = 8, Y = 0.5, Z = 0.5}) end)
    end
    pcall(function() comp:SetCollisionEnabled(0) end)
    -- дымный след игры, прикреплённый к ракете
    local trail = FXT("trail")
    if trail then
        local ok, err = pcall(function()
            GS():SpawnEmitterAttached(trail, comp, FName("None"), {X = 0, Y = 0, Z = 0}, {Pitch = 0, Yaw = 0, Roll = 0},
                {X = 1, Y = 1, Z = 1}, 0, true, 0, true)
        end)
        if not ok then Err("fx_trail", err) end
    end
    L("ракета напарника создана: " .. tostring(e.mesh))
    local pr, yr = math.rad(e.pitch), math.rad(e.yaw)
    local t = Now(p)
    F.gmFly[#F.gmFly + 1] = {ref = a, x = e.x, y = e.y, z = e.z, dx = math.cos(pr) * math.cos(yr),
        dy = math.cos(pr) * math.sin(yr), dz = math.sin(pr), spd = math.max(e.spd or 0, 35000), t0 = t, last = t}
end

local function FlyMissiles(p)
    local now = Now(p)
    local ox, oy, oz = Origin(p)
    for i = #F.gmFly, 1, -1 do
        local m = F.gmFly[i]
        local dt = math.max(0, math.min(0.1, now - m.last))
        m.last = now
        m.x, m.y, m.z = m.x + m.dx * m.spd * dt, m.y + m.dy * m.spd * dt, m.z + m.dz * m.spd * dt
        local ok = pcall(function()
            if not m.ref:IsValid() or now - m.t0 > 8 or m.z <= 0 then error("конец") end   -- z=0: уровень моря
            m.ref:K2_SetActorLocation({X = m.x - ox, Y = m.y - oy, Z = m.z - oz}, false, {}, false)
        end)
        if not ok then
            -- конец полёта: у воды — всплеск, в воздухе — взрыв (только частицы игры, без логики ракеты)
            if m.z <= 300 then FXAt(p, "water", m.x - ox, m.y - oy, 0 - oz, 1)
            else FXAt(p, "air", m.x - ox, m.y - oy, m.z - oz, 1) end
            pcall(function() if m.ref:IsValid() then m.ref:K2_DestroyActor() end end)
            table.remove(F.gmFly, i)
        end
    end
end

local function FindClass(path)
    local c = StaticFindObject(path)
    if c and S(function() return c:IsValid() end) then return c end
    local ok, a = pcall(LoadAsset, path)
    if ok and a and S(function() return a:IsValid() end) then return a end
end

local function DoEvent(p, e)
    local holder = F.visual or F.ghost
    if not (holder and holder:IsValid()) then return end
    if e.kind == "msl" then SpawnFakeMissile(p, e) return end
    if not e.path or e.path == "-" then return end
    local cls = FindClass(e.path)
    if not cls then Err("evclass", e.path) return end
    local gl, gr = holder:K2_GetActorLocation(), holder:K2_GetActorRotation()
    local yaw = gr.Yaw - (holder == F.visual and F.visYaw or 0)
    local pr, yr = math.rad(gr.Pitch), math.rad(yaw)
    local loc = {X = gl.X + math.cos(pr) * math.cos(yr) * 1200, Y = gl.Y + math.cos(pr) * math.sin(yr) * 1200,
                 Z = gl.Z + math.sin(pr) * 1200}
    local a = p:GetWorld():SpawnActor(cls, loc, {Pitch = gr.Pitch, Yaw = yaw, Roll = gr.Roll})
    if not a or not a:IsValid() then return end
    pcall(function() a.g_Team = p.g_Team end)
    local gu = F.ghost and S(function() return F.ghost.g_SelfGameUnitRef end)
    if gu then pcall(function() a.g_Owner = gu end) end
    if e.spd and e.spd > 0 then pcall(function() a.ProjectileSpeed = e.spd end) end
end

local function ExecEvents(p, rt)
    pcall(FlyMissiles, p)
    local i = 1
    while i <= #F.events do
        local e = F.events[i]
        if rt >= e.t then
            table.remove(F.events, i)
            local ok, err = pcall(DoEvent, p, e)
            if not ok then Err("event", err) end
        else
            i = i + 1
        end
    end
end

-- метка над призраком: виджет индикатора создаётся игрой при BeginPlay, поэтому имя пишем прямо в его
-- текстовые поля (UnitName/FriendlyName) и красим как союзника; повторяем раз в 0.5 с (игра может перезаписать)
local function UpdateGhostLabel(p)
    local g = F.ghost
    if not F.lbl then F.lbl = {last = 0, dump = 0, born = os.clock(), seen = {}} end
    local gu = GetGU(g)
    if not gu then
        if not F.lbl.noGu then F.lbl.noGu = true; L("метка: GameUnit призрака не найден (ни g_SelfGameUnitRef, ни GameUnit_Air)") end
        return
    end
    if not F.lbl.gu then F.lbl.gu = true; L("метка: GameUnit найден: " .. tostring(S(function() return gu:GetFullName() end))) end
    local nm = COOP_STATUS.peer_name
    if not nm or nm == "" then nm = "WINGMAN" end
    nm = nm:upper()
    -- здоровье напарника в процентах рядом с именем (g_Health самолёта: 100 = полное)
    if F.peerHp then nm = nm .. " " .. math.max(0, math.min(100, math.floor(F.peerHp + 0.5))) .. "%" end
    -- у AirUnit есть штатный механизм подписи союзника (HasFriendText/FriendText) и признак «опознан» (g_Transponder)
    pcall(function() g.g_Transponder = true end)
    pcall(function() g.HasFriendText = true end)
    pcall(function() g.FriendText = FText(nm) end)
    pcall(function() g.UnitText = FText(nm) end)
    pcall(function() g.UnitTag = FText(nm) end)
    pcall(function() gu.WidgetName = FText(nm) end)
    pcall(function() gu.WidgetTag = FText(nm) end)
    -- и сам виджет метки (все возможные ссылки на него)
    local cands = {
        S(function() return gu.SelfWidgetRef end),
        S(function() return gu.WidgetScreen:GetUserWidgetObject() end),
        S(function() return gu.WidgetScreenSpace:GetUserWidgetObject() end),
        S(function() return gu.UsedWidgetComponent:GetUserWidgetObject() end),
    }
    -- не чаще 4 раз в секунду: виджет и штатная инициализация метки
    local lb = F.lbl
    local clk = os.clock()
    if clk - lb.last < 0.25 then return end
    -- пауза (Esc): тики не шли > 1.5 с — после возврата игра могла сбросить метку, инициализируем заново
    if lb.last > 0 and clk - lb.last > 1.5 and lb.init then
        lb.init, lb.born = false, clk - 2
        L("метка: возврат из паузы, инициализирую заново")
        lb.postPause = 10
    end
    lb.last = clk
    -- штатная инициализация юнита с «дружеским» текстом (GameUnit:Initialize(Team, Enable, HasAce, HasFriend, Ace, Friend, HVT, Attach, SeeThrough)):
    -- один раз через секунду после появления призрака, когда виджет уже создан игрой
    if not lb.init and clk - lb.born > 1.0 then
        lb.init = true
        L("метка: вызываю GameUnit:Initialize(команда " .. tostring(p.g_Team) .. ", «" .. nm .. "»)")
        local ok, e = pcall(function() gu:Initialize(p.g_Team, true, false, true, FText(""), FText(nm), false, false, false) end)
        L("метка: Initialize " .. (ok and "выполнен" or ("ошибка: " .. tostring(e))))
        pcall(function() gu:SetVisible() end)
        -- союзник: команда игрока, не цель для наших ракет, неуязвим
        pcall(function() gu.g_Team = p.g_Team end)
        pcall(function() gu:SetTeam(p.g_Team) end)
        pcall(function() gu.Immunity = false end)       -- враги должны мочь попасть: урон переносится партнёру
        for _, u in ipairs(S(function() return FindAllOf("GameUnit_Air_C") end) or {}) do
            L("метка: GameUnit_Air team=" .. tostring(S(function() return u.g_Team end)) .. " " .. tostring(S(function() return u:GetFullName():match("[^%.]*$") end)))
        end
        L("метка: команда выставлена, gu.g_Team=" .. tostring(S(function() return gu.g_Team end)))
    end
    local found = 0
    for i, w in ipairs(cands) do
        if w and S(function() return w:IsValid() end) then
            found = found + 1
            if not lb.seen[i] then
                lb.seen[i] = true
                L("метка[" .. i .. "] виджет: " .. tostring(S(function() return w:GetFullName() end)))
            end
            -- одно имя (FriendlyName); остальные текстовые поля очищаем, иначе показываются три подписи
            pcall(function() w.FriendlyName:SetText(FText(nm)) end)
            -- имя выше расстояния (иначе накладываются друг на друга)
            pcall(function() w.FriendlyName:SetRenderTranslation({X = 0, Y = -18}) end)
            for _, n in ipairs({"UnitName", "TextIndicator", "TGTText", "TGTTextMinimal"}) do
                pcall(function() w[n]:SetText(FText("")) end)
            end
            -- g_Targettable=false переводит виджет в «выключенный» вид (красный ромб, без расстояния) —
            -- возвращаем обычный вид метки
            pcall(function() w:EnabledMode() end)
            -- после паузы игра скрывает метку нецелевого юнита — принудительно показываем виджет и его компонент
            pcall(function() w:SetVisibility(3) end)
            pcall(function() gu.UsedWidgetComponent:SetVisibility(true, true) end)
            pcall(function() gu.UsedWidgetComponent:SetHiddenInGame(false, true) end)
        end
    end
    -- расстояние: игра обновляет его только у целей (g_Targettable), поэтому считаем сами
    do
        local w1 = cands[1]
        if w1 and S(function() return w1:IsValid() end) then
            local pl, gl = S(function() return p:K2_GetActorLocation() end), S(function() return g:K2_GetActorLocation() end)
            if pl and gl then
                local d = math.sqrt((pl.X - gl.X) ^ 2 + (pl.Y - gl.Y) ^ 2 + (pl.Z - gl.Z) ^ 2)
                if not GHOST_TARGETTABLE then pcall(function() w1:UpdateInfo(d / 100 / 3.28084) end) end   -- виджет ждёт метры и сам умножает на 3.28 (футы): компенсируем, чтобы на экране были метры
            end
            -- смена экземпляра виджета (пауза/возврат в игру пересоздаёт HUD) — инициализируем заново
            local wn = S(function() return w1:GetFullName() end)
            if lb.wname and wn ~= lb.wname then
                lb.init, lb.born = false, clk - 2
                L("метка: виджет пересоздан, инициализирую заново")
            end
            lb.wname = wn
        end
    end
    -- цвет союзника (виджет мог быть создан после первого вызова); метка должна оставаться видимой
    pcall(function() gu:SetWidgetColor(p.g_Team) end)
    pcall(function() gu.WidgetVisible = true end)
    pcall(function() gu.PermaDisable = false end)
    pcall(function() gu:SetVisible() end)
    -- диагностика после паузы: видимость виджета и компонента (первые 10 после возврата)
    if lb.postPause and lb.postPause > 0 then
        lb.postPause = lb.postPause - 1
        L("метка(пауза): widget vis=" .. tostring(S(function() return cands[1]:GetVisibility() end))
            .. " | comp visible=" .. tostring(S(function() return gu.UsedWidgetComponent:IsVisible() end))
            .. " | WidgetVisible=" .. tostring(S(function() return gu.WidgetVisible end))
            .. " | hidden=" .. tostring(S(function() return gu:IsHidden() end)))
    end
    -- не цель для наших ракет: только флаг g_Targettable (DisableTargeting() убирал метку через минуту — не вызываем)
    pcall(function() gu.g_Targettable = GHOST_TARGETTABLE end)
    if not lb.tgtLogged then
        lb.tgtLogged = true
        L("метка: g_Targettable=" .. tostring(S(function() return gu.g_Targettable end)) .. ", IsTargeted=" .. tostring(S(function() return gu.IsTargeted end)))
    end
    if not lb.logged then
        lb.logged = true
        L("подпись цели: валидных виджетов " .. found .. "; имя " .. nm)
    end
    if clk - lb.born < 15 and clk - lb.dump > 3 then
        lb.dump = clk
        L("метка: виджетов " .. found .. " | SelfWidgetRef valid=" .. tostring(S(function() return gu.SelfWidgetRef:IsValid() end))
            .. " | WidgetName=" .. tostring(S(function() return gu.WidgetName:ToString() end))
            .. " | FriendText=" .. tostring(S(function() return g.FriendText:ToString() end))
            .. " | HasFriendText=" .. tostring(S(function() return g.HasFriendText end))
            .. " | transponder=" .. tostring(S(function() return g.g_Transponder end))
            .. " | gu.team=" .. tostring(S(function() return gu.g_Team end)))
        for i, w in ipairs(cands) do
            if w and S(function() return w:IsValid() end) then
                local parts = {}
                for _, n in ipairs({"UnitName", "FriendlyName", "TextIndicator", "TGTText", "AceText"}) do
                    parts[#parts + 1] = n .. "=" .. tostring(S(function() return w[n]:GetText():ToString() end))
                end
                L("метка[" .. i .. "] " .. table.concat(parts, " | "))
            end
        end
    end
end

-- ракеты напарника: траектории приходят от стрелка (поле 26), показываем их с той же задержкой, что и самолёт.
-- Взрыв — там, где настоящая ракета исчезла у стрелка (вода/земля/скалы/самолёты — как у него в игре).
local function Bracket(rt)
    local buf, n = F.buf, #F.buf
    if n == 0 then return nil end
    if rt >= buf[n].t then return buf[n], buf[n], 0 end
    if rt <= buf[1].t then return buf[1], buf[1], 0 end
    for i = n - 1, 1, -1 do
        local a, b = buf[i], buf[i + 1]
        if rt >= a.t then return a, b, (rt - a.t) / math.max(1e-4, b.t - a.t) end
    end
    return buf[1], buf[1], 0
end

local function SpawnMissileVisual(p, e, lp)
    local a = p:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), lp, {Pitch = e.pitch, Yaw = e.yaw, Roll = 0})
    if not a or not a:IsValid() then return nil end
    local comp = a.StaticMeshComponent
    pcall(function() comp:SetMobility(2) end)
    local meshPath = nil
    local mesh = e.mesh and e.mesh ~= "-" and (StaticFindObject(e.mesh) or S(function() return LoadAsset(e.mesh) end))
    if mesh and S(function() return mesh:IsValid() end) then
        pcall(function() comp:SetStaticMesh(mesh) end)
        meshPath = e.mesh
    else
        pcall(function() comp:SetStaticMesh(CubeMesh()) end)
        pcall(function() a:SetActorScale3D({X = 8, Y = 0.5, Z = 0.5}) end)
    end
    pcall(function() comp:SetCollisionEnabled(0) end)
    -- след: шаблон частиц настоящей ракеты (из пакета), иначе дымный след игры; у бомб следа нет
    local trailC = nil
    if e.kind ~= "b" then
        local trail = nil
        if e.trail and e.trail ~= "-" then trail = StaticFindObject(e.trail) or S(function() return LoadAsset(e.trail) end) end
        trail = trail or FXT("trail")
        if trail then
            local ok, res = pcall(function()
                return GS():SpawnEmitterAttached(trail, comp, FName("None"), {X = 0, Y = 0, Z = 0}, {Pitch = 0, Yaw = 0, Roll = 0},
                    {X = 1, Y = 1, Z = 1}, 0, true, 0, true)
            end)
            if ok then trailC = res else Err("fx_trail", res) end
        end
    end
    return a, comp, trailC, meshPath
end

-- ракета напарника закончилась: прячем модель, гасим излучатель (шлейф дотлевает) и удаляем актор позже
local function RetireMissile(g, now)
    pcall(function() g.comp:SetVisibility(false, false) end)
    pcall(function() g.trailC:DeactivateSystem() end)
    if g.ref then
        F.dying = F.dying or {}
        F.dying[#F.dying + 1] = {ref = g.ref, t = now + 8}
    end
    g.ref, g.comp, g.trailC = nil, nil, nil
end

local function UpdateGhostMissiles(p, rt)
    local a, b, k = Bracket(rt)
    if not b or not b.ms then return end
    F.gm = F.gm or {}
    local ox, oy, oz = Origin(p)
    local now = Now(p)
    for id, eb in pairs(b.ms) do
        local g = F.gm[id]
        if not g then g = {seen = now} F.gm[id] = g end
        g.seen = now
        if not g.done then
            if eb.alive then
                local ea = a.ms and a.ms[id]
                local e = eb
                if ea and ea.alive and k > 0 then
                    e = {x = ea.x + (eb.x - ea.x) * k, y = ea.y + (eb.y - ea.y) * k, z = ea.z + (eb.z - ea.z) * k,
                         pitch = AngLerp(ea.pitch, eb.pitch, k), yaw = AngLerp(ea.yaw, eb.yaw, k), mesh = eb.mesh, trail = eb.trail, kind = eb.kind}
                end
                local lp = {X = e.x - ox, Y = e.y - oy, Z = e.z - oz}
                if e.z <= 300 and g.ref then
                    -- ракета у самой воды (≤3 м над уровнем моря): у стрелка она здесь взрывается, а актор может жить ещё
                    -- какое-то время — показываем всплеск сразу, не дожидаясь исчезновения
                    g.done = true
                    L("ракета напарника #" .. id .. ": всплеск у воды, z=" .. string.format("%.0f", e.z))
                    FXAt(p, "water", lp.X, lp.Y, lp.Z, 6)
                    FXAt(p, "air", lp.X, lp.Y, lp.Z + 100, 2.5)       -- огонь взрыва, как у стрелка
                    RetireMissile(g, now)
                elseif not (g.ref and S(function() return g.ref:IsValid() end)) then
                    g.ref, g.comp, g.trailC, g.meshPath = SpawnMissileVisual(p, e, lp)
                    L("ракета напарника #" .. id .. " (" .. tostring(e.kind) .. "): " .. tostring(e.mesh):match("[^/]*$"))
                else
                    pcall(function() g.ref:K2_SetActorLocationAndRotation(lp, {Pitch = e.pitch, Yaw = e.yaw, Roll = 0}, false, {}, false) end)
                    -- настоящая модель у стрелка выбирается уже после пуска — подменяем меш, когда он изменился
                    if eb.mesh and eb.mesh ~= "-" and eb.mesh ~= g.meshPath then
                        local mesh = StaticFindObject(eb.mesh) or S(function() return LoadAsset(eb.mesh) end)
                        if mesh and S(function() return mesh:IsValid() end) then
                            pcall(function() g.comp:SetStaticMesh(mesh) end)
                            pcall(function() g.ref:SetActorScale3D({X = 1, Y = 1, Z = 1}) end)
                            g.meshPath = eb.mesh
                            L("ракета напарника #" .. id .. ": меш -> " .. tostring(eb.mesh):match("[^/]*$"))
                        else
                            g.meshPath = eb.mesh
                        end
                    end
                end
            else
                -- у стрелка ракета исчезла: взрыв в её последней точке (у воды — всплеск)
                g.done = true
                local sc = eb.kind == "b" and 3 or 2
                L("ракета напарника #" .. id .. ": конец полёта, z=" .. string.format("%.0f", eb.z))
                if eb.z <= 1500 then
                    FXAt(p, "water", eb.x - ox, eb.y - oy, eb.z - oz, sc * 2)
                    FXAt(p, "air", eb.x - ox, eb.y - oy, eb.z - oz + 100, sc + 0.5)
                else FXAt(p, "air", eb.x - ox, eb.y - oy, eb.z - oz, sc) end
                RetireMissile(g, now)
            end
        end
    end
    -- ракеты, о которых давно нет данных, убираем молча (шлейф дотлевает)
    for id, g in pairs(F.gm) do
        if now - (g.seen or now) > 2 then
            RetireMissile(g, now)
            F.gm[id] = nil
        end
    end
    -- отложенное удаление отработавших ракет
    if F.dying then
        for i = #F.dying, 1, -1 do
            local d = F.dying[i]
            if now >= d.t then
                pcall(function() if d.ref:IsValid() then d.ref:K2_DestroyActor() end end)
                table.remove(F.dying, i)
            end
        end
    end
end

-- ===================== синхронизация уничтожения врагов =====================
-- Враги у каждого игрока свои. Уничтожение передаётся событием (класс, команда, позиция); у другого игрока
-- ближайший живой юнит того же класса и команды (в радиусе) получает смертельный ApplyHit.
-- Флаги/поля есть у всех типов: g_IsDestroyed, g_Health, g_Team, ApplyHit(урон, инициатор).
local UNIT_CLASSES = {"AirUnit_C", "ShipUnit_C", "GroundUnit_Base_C", "GroundUnit_Vehicle_Base_C"}
local KILL_RADIUS = 150000       -- см: насколько далеко ищем «того же» юнита
local NEAR_GONE = 250000         -- см: исчезнувший ближе этого к игроку считаем уничтоженным
local DUP_RADIUS = 15000         -- см (150 м): уже уничтоженный нами юнит так близко — событие считаем повтором

local function AddKill(p, rec, why)
    local ox, oy, oz = Origin(p)
    F.kills = F.kills or {}
    F.mc2 = (F.mc2 or 0) + 1
    local k = {id = F.sidBase + 500 + F.mc2, cls = rec.cls, team = rec.team, x = rec.x + ox, y = rec.y + oy, z = rec.z + oz, t = Now(p)}
    F.kills[#F.kills + 1] = k
    F.myKills = F.myKills or {}
    F.myKills[#F.myKills + 1] = k
    L("уничтожен враг: " .. rec.cls .. " (команда " .. rec.team .. ", " .. why .. ")")
end

local function ScanUnits(p, now)
    if now - (F.unitT or -1) < 0.3 then return end
    F.unitT = now
    F.unitI = (F.unitI or 0) % #UNIT_CLASSES + 1
    local group = UNIT_CLASSES[F.unitI]
    F.units = F.units or {}
    F.nokill = F.nokill or {}
    local pt = S(function() return p.g_Team end)
    local pl = S(function() return p:K2_GetActorLocation() end)
    local gname = F.ghost and S(function() return F.ghost:GetFullName() end)
    local seen = {}
    for _, u in ipairs(S(function() return FindAllOf(group) end) or {}) do
        if S(function() return u:IsValid() end) then
            local k = u:GetFullName()
            seen[k] = true
            local team = S(function() return u.g_Team end)
            if k ~= gname and team ~= nil and pt ~= nil and team ~= pt then
                local rec = F.units[k]
                if not rec then
                    rec = {group = group, cls = S(function() return u:GetClass():GetFName():ToString() end) or group, team = team}
                    F.units[k] = rec
                end
                local loc = S(function() return u:K2_GetActorLocation() end)
                if loc then rec.x, rec.y, rec.z = loc.X, loc.Y, loc.Z end
                if S(function() return u.g_IsDestroyed end) == true and not rec.sent then
                    rec.sent = true
                    if not F.nokill[k] then AddKill(p, rec, "g_IsDestroyed") end
                end
            end
        end
    end
    -- юнит исчез, не успев показать флаг, и был рядом с игроком — считаем уничтоженным
    for k, rec in pairs(F.units) do
        if rec.group == group and not seen[k] then
            F.units[k] = nil
            if not rec.sent and not F.nokill[k] and rec.x and pl then
                local d2 = (rec.x - pl.X) ^ 2 + (rec.y - pl.Y) ^ 2 + (rec.z - pl.Z) ^ 2
                if d2 < NEAR_GONE ^ 2 then AddKill(p, rec, "исчез рядом") end
            end
        end
    end
end

local function ApplyRemoteKills(p, now)
    if not F.pendKills or #F.pendKills == 0 or now - (F.killT or -1) < 0.3 then return end
    F.killT = now
    if not F.applyLogged then F.applyLogged = true; L("синхронизация: обработка очереди (" .. #F.pendKills .. ")") end
    F.nokill = F.nokill or {}
    local ox, oy, oz = Origin(p)
    for i = #F.pendKills, 1, -1 do
        local e = F.pendKills[i]
        local k = e.k
        local done, why = false, nil
        -- уже уничтожили сами этого же юнита (события пересеклись)
        for _, mk in ipairs(F.myKills or {}) do
            if mk.cls == k.cls and (mk.x - k.x) ^ 2 + (mk.y - k.y) ^ 2 + (mk.z - k.z) ^ 2 < DUP_RADIUS ^ 2 then
                done, why = true, "уже уничтожен у нас"
                break
            end
        end
        if not done then
            local best, bd = nil, KILL_RADIUS ^ 2
            local anyGone, goneD = false, nil
            for _, u in ipairs(S(function() return FindAllOf(k.cls) end) or {}) do
                if S(function() return u:IsValid() end) and S(function() return u.g_Team end) == k.team then
                    local ul = S(function() return u:K2_GetActorLocation() end)
                    if ul then
                        local d = (ul.X + ox - k.x) ^ 2 + (ul.Y + oy - k.y) ^ 2 + (ul.Z + oz - k.z) ^ 2
                        if S(function() return u.g_IsDestroyed end) == true then
                            if d < DUP_RADIUS ^ 2 and (not goneD or d < goneD) then anyGone, goneD = true, d end
                        elseif d < bd then
                            best, bd = u, d
                        end
                    end
                end
            end
            if not e.logged then
                e.logged = true
                L("синхронизация: ищу " .. k.cls .. " (команда " .. tostring(k.team) .. "), кандидат " ..
                    (best and (string.format("%.0f", math.sqrt(bd) / 100) .. " м") or "нет") .. (anyGone and ", рядом уничтоженный" or ""))
            end
            -- два юнита погибли рядом (напр. пара самолётов): труп первого не должен «съедать» событие второго.
            -- Повтор — только если труп заметно ближе живого кандидата (в 3 раза) и живой не вплотную (< 40 м)
            local preferAlive = best and (not goneD or bd < goneD * 9 or bd < 4000 ^ 2)
            if anyGone and not preferAlive then
                done, why = true, "рядом уже уничтоженный"
            elseif best then
                local instig = (F.ghost and GetGU(F.ghost)) or S(function() return p.g_SelfGameUnitRef end)
                F.nokill[best:GetFullName()] = true
                local ok, err = pcall(function() best:ApplyHit(10000000, instig) end)
                done, why = true, ok and ("ApplyHit, " .. string.format("%.0f", math.sqrt(bd) / 100) .. " м") or ("ошибка ApplyHit: " .. tostring(err))
            end
        end
        if done then
            L("синхронизация: " .. k.cls .. " — " .. why)
            table.remove(F.pendKills, i)
        elseif now - e.first > 30 then
            L("синхронизация: " .. k.cls .. " — юнит не найден за 30 с, пропускаю")
            table.remove(F.pendKills, i)
        end
    end
    -- история своих уничтожений: 30 с
    local mk = F.myKills or {}
    for i = #mk, 1, -1 do
        if now - mk[i].t > 30 then table.remove(mk, i) end
    end
end

-- GameUnit игрока (у FlyingPawn g_SelfGameUnitRef нет): t_PlayerGameUnitRef или дочерний GameUnit_Air
local function MyGUName(p)
    local gu = S(function() return p.t_PlayerGameUnitRef end)
    if not (gu and S(function() return gu:IsValid() end)) then gu = S(function() return p.GameUnit_Air:GetChildActor() end) end
    return gu and S(function() return gu:GetFullName() end)
end

-- ===================== угрозы призраку и ракеты его носителя =====================
-- 1) ракеты, у которых владелец = GameUnit призрака, пущены ИИ-носителем (он стреляет сам) — это «вторая ракета»;
--    удаляем их (настоящие ракеты напарника показываются нашими визуалами);
-- 2) врагам, которые наводят ракеты/цель на призрака, — пишем в лог (проверка «реагируют ли враги на призрака»).
local function ScanThreats(p, now)
    if now - (F.threatT or -1) < 1.0 then return end
    F.threatT = now
    if not F.ghost then return end
    local gu = GetGU(F.ghost)
    local gname = S(function() return F.ghost:GetFullName() end)
    local guname = gu and S(function() return gu:GetFullName() end)
    local pname = S(function() return p:GetFullName() end)
    local pt = S(function() return p.g_Team end)
    F.threatSeen = F.threatSeen or {}
    for _, m in ipairs(S(function() return FindAllOf("MISSILE_BASE_C") end) or {}) do
        if S(function() return m:IsValid() end) then
            local k = m:GetFullName()
            local owner = S(function() return m.g_Owner:GetFullName() end)
            if guname and owner == guname and not F.threatSeen[k] then
                F.threatSeen[k] = true
                pcall(function() m:K2_DestroyActor() end)
                L("ракета носителя призрака удалена (владелец — призрак): " .. tostring(k:match("[^%.]*$")))
            else
                local team = S(function() return m.g_Team end)
                local tgt = S(function() return m.t_Target:GetFullName() end)
                if team ~= nil and pt ~= nil and team ~= pt and tgt and not F.threatSeen[k] then
                    if tgt == guname then
                        F.threatSeen[k] = true
                        L("враг навёл ракету НА ПРИЗРАКА: " .. tostring(k:match("[^%.]*$")) .. " (команда " .. tostring(team) .. ")")
                    elseif tgt == MyGUName(p) then
                        F.threatSeen[k] = true
                        L("враг навёл ракету на МЕНЯ: " .. tostring(k:match("[^%.]*$")) .. " (команда " .. tostring(team) .. ")")
                    end
                end
            end
        end
    end
    -- вражеские самолёты: кого держат целью (TargetRef) — раз на юнит
    F.aiTgt = F.aiTgt or {}
    for _, u in ipairs(S(function() return FindAllOf("AirUnit_Fighter_C") end) or {}) do
        local team = S(function() return u.g_Team end)
        if team ~= nil and pt ~= nil and team ~= pt and S(function() return u:IsValid() end) then
            local k = u:GetFullName()
            local tgt = S(function() return u.TargetRef:GetFullName() end)
            if tgt and F.aiTgt[k] ~= tgt then
                F.aiTgt[k] = tgt
                local who = (tgt == gname or tgt == guname) and "ПРИЗРАКА" or ((tgt == pname or tgt == MyGUName(p)) and "МЕНЯ" or "другого")
                L("враг-самолёт " .. tostring(k:match("[^%.]*$")) .. " целится в " .. who)
            end
        end
    end
end

-- Регистрация призрака у GameMaster (его массивы GameUnitAirArray/TargetArray используют враги для выбора цели).
-- В логе врагов-самолётов «в ПРИЗРАКА» не было ни разу — проверяем, числится ли призрак в массивах, и добавляем.
local function EnsureGhostRegistered(p, now)
    if now - (F.regT or -10) < 5 or not F.ghost then return end
    F.regT = now
    local gu = GetGU(F.ghost)
    if not gu then return end
    local gm = FindFirstOf("GameMaster_C")
    if not (gm and S(function() return gm:IsValid() end)) then
        if not F.gmLogged then F.gmLogged = true L("GameMaster не найден") end
        return
    end
    -- связки пары AirUnit<->GameUnit: у призрака g_SelfGameUnitRef (nullptr) и gu.ParentActor, видимо, не заданы
    -- (настоящие ведомые получают их при штатном Initialize) — по ним враги/турели находят самолёт цели
    do
        local ghost = F.ghost
        local selfRef = S(function() return ghost.g_SelfGameUnitRef end)
        local selfValid = selfRef and S(function() return selfRef:IsValid() end)
        local parent = S(function() return gu.ParentActor end)
        local parentValid = parent and S(function() return parent:IsValid() end)
        local mgr = S(function() return gu.ManagerRef end)
        local mgrValid = mgr and S(function() return mgr:IsValid() end)
        if not F.linkLogged then
            F.linkLogged = true
            L("связки призрака: g_SelfGameUnitRef=" .. tostring(selfValid) .. ", gu.ParentActor=" .. tostring(parentValid) .. ", gu.ManagerRef=" .. tostring(mgrValid))
        end
        if not selfValid then
            local ok = pcall(function() ghost.g_SelfGameUnitRef = gu end)
            L("связки: g_SelfGameUnitRef := GameUnit " .. (ok and "ok" or "ошибка"))
        end
        if not parentValid then
            local ok = pcall(function() gu.ParentActor = ghost end)
            L("связки: gu.ParentActor := носитель " .. (ok and "ok" or "ошибка"))
        end
    end
    local guname = S(function() return gu:GetFullName() end)
    local function inArr(arr)
        local found, n = false, 0
        S(function() arr:ForEach(function(_, v) n = n + 1 if S(function() return v:get():GetFullName() end) == guname then found = true end end) end)
        return found, n
    end
    local fa, na = inArr(gm.GameUnitAirArray)
    local fu, nu = inArr(gm.GameUnitArray)
    local ft, nt = inArr(gm.TargetArray)
    if not F.regLogs or F.regLogs < 4 then
        F.regLogs = (F.regLogs or 0) + 1
        L("GameMaster: призрак в GameUnitAirArray=" .. tostring(fa) .. "/" .. na .. ", GameUnitArray=" .. tostring(fu) .. "/" .. nu ..
            ", TargetArray=" .. tostring(ft) .. "/" .. nt)
    end
    if not fa and not F.regDone then
        F.regDone = true
        local ok, e = pcall(function() gm:GameUnitCheckIn(gu) end)
        L("GameMaster: GameUnitCheckIn(призрак) " .. (ok and "выполнен" or ("ошибка: " .. tostring(e))))
    end
end

-- Сравнение флагов GameUnit/AirUnit призрака и настоящего ИИ-ведомого: чем призрак отличается для турелей/врагов (один раз за полёт).
local function DumpFlags(label, obj, names)
    local parts = {}
    for _, n in ipairs(names) do parts[#parts + 1] = n .. "=" .. tostring(S(function() return obj[n] end)) end
    L("флаги " .. label .. ": " .. table.concat(parts, " "))
end
local function CompareWithWingman(p, now)
    if F.cmpDone or not F.ghost or now - (F.survT0 or now) < 14 then return end
    F.cmpDone = true
    local gu = GetGU(F.ghost)
    local pt = S(function() return p.g_Team end)
    local wm, wd = nil, 1e18
    local pl = S(function() return p:K2_GetActorLocation() end)
    local gname = S(function() return F.ghost:GetFullName() end)
    for _, u in ipairs(S(function() return FindAllOf("AirUnit_Fighter_C") end) or {}) do
        if S(function() return u:IsValid() end) and S(function() return u.g_Team end) == pt and S(function() return u:GetFullName() end) ~= gname then
            local ul = S(function() return u:K2_GetActorLocation() end)
            local d = (ul and pl) and ((ul.X - pl.X) ^ 2 + (ul.Y - pl.Y) ^ 2 + (ul.Z - pl.Z) ^ 2) or 1e18
            if d < wd then wm, wd = u, d end
        end
    end
    local guN = {"g_Team", "g_Targettable", "IsTargeted", "PermaDisable", "WidgetVisible", "HasATarget", "CheckedInWithRadarSys", "LODImmunity",
        "LODSafety", "HighLODMode", "IsAttachment", "IsRegisteredFiller", "FillerID", "CinematicMode", "Immunity", "ArrayAble", "IsHVT"}
    local auN = {"g_Team", "g_Health", "g_IsDestroyed", "BrainDead", "IsTGT", "g_Transponder", "isLanded", "HasFriendText", "HideContrails", "IsBigUnit"}
    if gu then DumpFlags("GameUnit ПРИЗРАКА", gu, guN) end
    DumpFlags("AirUnit ПРИЗРАКА", F.ghost, auN)
    if wm then
        L("сравнение с ведомым: " .. tostring(S(function() return wm:GetClass():GetFName():ToString() end)))
        local wgu = GetGU(wm)
        if wgu and S(function() return wgu:IsValid() end) then DumpFlags("GameUnit ВЕДОМОГО", wgu, guN) end
        DumpFlags("AirUnit ВЕДОМОГО", wm, auN)
    else
        L("сравнение: ведомый не найден")
    end
end

-- Автоперебор гипотез «почему враги не выбирают призрака» (накопительно, раз в 40 с полёта, начиная с 20-й секунды).
-- Отличия призрака от настоящего ведомого (лог): IsTargeted true/false, LODImmunity false/true, BrainDead true/false, тик/коллизия отключены нами.
-- После какой гипотезы в логе «турели целятся … в ПРИЗРАКА» станет > 0 — та и нужна.
local function AutoHypotheses(p, now)
    if not F.ghost then return end
    local age = now - (F.survT0 or now)
    local n = F.hypN or 0
    if age < 20 + n * 40 or n >= 4 then return end
    F.hypN = n + 1
    local g = F.ghost
    local gu = GetGU(g)
    if n == 0 then
        if gu then pcall(function() gu.IsTargeted = false end) pcall(function() gu.LODImmunity = true end) end
        L("гипотеза 1 применена: GameUnit.IsTargeted=false, LODImmunity=true")
    elseif n == 1 then
        pcall(function() g:SetActorTickEnabled(true) end)
        L("гипотеза 2 применена: тик носителя включён")
    elseif n == 2 then
        pcall(function() g:SetActorEnableCollision(true) end)
        L("гипотеза 3 применена: коллизия носителя включена")
    else
        pcall(function() g.BrainDead = false end)
        L("гипотеза 4 применена: BrainDead=false (ИИ носителя включён; его ракеты удаляются)")
    end
end

-- Разведка сопел/форсажа своего самолёта (для достройки модели напарника): компоненты FlyingPawn, которых нет у голого скелета.
local function ProbeEngines(p, now)
    if F.engProbed or now - (F.survT0 or now) < 6 then return end
    F.engProbed = true
    L("сопла: a_AfterburnerFloat=" .. tostring(S(function() return p.a_AfterburnerFloat end)) ..
        ", i_ThrustInput=" .. tostring(S(function() return p.i_ThrustInput end)))
    local function Arr(name)
        local t = {}
        S(function() p[name]:ForEach(function(_, v) t[#t + 1] = v:get() end) end)
        return t
    end
    for _, aname in ipairs({"a_AfterburnersMesh", "a_AfterburnerEmissive"}) do
        local arr = Arr(aname)
        L("сопла: " .. aname .. " — " .. #arr .. " шт.")
        for i, c in ipairs(arr) do
            if i > 4 then break end
            local m = S(function() return c.StaticMesh:GetFullName() end)
            local sock = S(function() return c:GetAttachSocketName():ToString() end)
            local par = S(function() return c:GetAttachParent():GetFullName() end)
            local rl = S(function() return c.RelativeLocation end)
            local rr = S(function() return c.RelativeRotation end)
            local rs = S(function() return c.RelativeScale3D end)
            L("  [" .. i .. "] mesh=" .. tostring(m) .. " | сокет=" .. tostring(sock) .. " | родитель=" .. tostring(par and par:match("[^%.:]*$")) ..
                " | loc=" .. tostring(rl and string.format("%.0f,%.0f,%.0f", rl.X, rl.Y, rl.Z)) ..
                " rot=" .. tostring(rr and string.format("%.0f,%.0f,%.0f", rr.Pitch, rr.Yaw, rr.Roll)) ..
                " scale=" .. tostring(rs and string.format("%.2f,%.2f,%.2f", rs.X, rs.Y, rs.Z)))
        end
    end
    local parts = Arr("a_Afterburner Particle")
    L("сопла: a_Afterburner Particle — " .. #parts .. " шт.")
    for i, c in ipairs(parts) do
        if i > 4 then break end
        L("  [" .. i .. "] шаблон=" .. tostring(S(function() return c.Template:GetFullName() end)) .. " | сокет=" ..
            tostring(S(function() return c:GetAttachSocketName():ToString() end)) .. " | активен=" .. tostring(S(function() return c:IsActive() end)))
    end
    -- кости скелета, похожие на двигатели/сопла
    local tpm = S(function() return p.ThirdPersonModel end)
    local nb = tpm and S(function() return tpm:GetNumBones() end) or 0
    local names = {}
    for i = 0, nb - 1 do
        local bn = S(function() return tpm:GetBoneName(i):ToString() end)
        if bn and bn:lower():match("eng") or (bn and bn:lower():match("noz")) or (bn and bn:lower():match("burn")) or (bn and bn:lower():match("exh")) then
            names[#names + 1] = bn
        end
    end
    L("сопла: костей " .. nb .. ", похожие на двигатели: " .. table.concat(names, ","))
end

-- Разведка напарников-ботов в миссии: есть ли у игрока ИИ-ведомые (для замены ведомого другом). Раз за полёт через 8 и 40 с.
local function SurveyWingmen(p, now)
    F.survT0 = F.survT0 or now
    local age = now - F.survT0
    local stage = F.survStage or 0
    if not ((stage == 0 and age > 8) or (stage == 1 and age > 40)) then return end
    F.survStage = stage + 1
    local pt = S(function() return p.g_Team end)
    local gname = F.ghost and S(function() return F.ghost:GetFullName() end)
    local friends = {}
    for _, u in ipairs(S(function() return FindAllOf("AirUnit_Fighter_C") end) or {}) do
        if S(function() return u:IsValid() end) and S(function() return u.g_Team end) == pt then
            local k = u:GetFullName()
            if k ~= gname then
                friends[#friends + 1] = (S(function() return u:GetClass():GetFName():ToString() end) or "?") .. "@" ..
                    string.format("%.0f", math.sqrt((function() local a, b = S(function() return u:K2_GetActorLocation() end), S(function() return p:K2_GetActorLocation() end)
                        return a and b and ((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) or 0 end)()) / 100) .. "м"
            end
        end
    end
    local sp, att, lead = 0, 0, 0
    for _, s in ipairs(S(function() return FindAllOf("AirSquadronSpawner_C") end) or {}) do
        sp = sp + 1
        if S(function() return s.AttachToPlayer end) == true then att = att + 1 end
        if S(function() return s.PlayerIsLeader end) == true then lead = lead + 1 end
    end
    local inst = FindFirstOf("WingmanInstance_C")
    local lid = inst and S(function() return inst.LevelData["ID_18_1E73F8AD49BEFD832EC62A8BE3469830"]:ToString() end)
    L("разведка ведомых [" .. tostring(lid) .. ", " .. string.format("%.0f", age) .. " с]: союзных самолётов ИИ " .. #friends .. " {" ..
        table.concat(friends, ", ") .. "}; спавнеров эскадрилий " .. sp .. " (AttachToPlayer " .. att .. ", PlayerIsLeader " .. lead .. ")")
end

-- Вражеский огонь (пули/снаряды турелей, кораблей, самолётов): где он — у меня или у призрака; плюс мои потери здоровья.
local function ThreatFire(p, now)
    if now - (F.fireT or -1) < 1.0 then return end
    F.fireT = now
    -- турели/пушки/ПВО (Attachment_Base_C.t_Target): кого они держат целью — меня или призрака
    do
        local gu2 = F.ghost and GetGU(F.ghost)
        local guname = gu2 and S(function() return gu2:GetFullName() end)
        local myname = MyGUName(p)
        local pt2 = S(function() return p.g_Team end)
        local nme, ngh, noth = 0, 0, 0
        local hist = nil
        for _, a in ipairs(S(function() return FindAllOf("Attachment_Base_C") end) or {}) do
            if S(function() return a:IsValid() end) then
                local team = S(function() return a.g_OwnerRef.g_Team end)
                local tgt = S(function() return a.t_Target:GetFullName() end)
                if tgt and team ~= nil and pt2 ~= nil and team ~= pt2 then
                    if tgt == guname then ngh = ngh + 1 elseif tgt == myname then nme = nme + 1 else
                        noth = noth + 1
                        -- кого именно держат «другие» цели (класс владельца GameUnit): чем они отличаются от призрака
                        local ck = S(function() return a.t_Target.ParentActor:GetClass():GetFName():ToString() end)
                            or S(function() return a.t_Target:GetClass():GetFName():ToString() end) or "?"
                        hist = hist or {}
                        ck = ck .. ":" .. tostring(tgt:match("[^%.]*$"))
                        hist[ck] = (hist[ck] or 0) + 1
                    end
                end
            end
        end
        local sig = nme .. "/" .. ngh .. "/" .. noth
        if (nme + ngh + noth > 0) and sig ~= F.turretSig then
            F.turretSig = sig
            local hs = {}
            for k2, v2 in pairs(hist or {}) do hs[#hs + 1] = k2 .. "=" .. v2 end
            L("турели целятся: в меня " .. nme .. ", в ПРИЗРАКА " .. ngh .. ", в других " .. noth .. (#hs > 0 and (" {" .. table.concat(hs, ", ") .. "}") or "") ..
                " | призрак=" .. tostring(guname and guname:match("[^%.]*$")) .. " я=" .. tostring(myname and myname:match("[^%.]*$")))
        end
    end
    local hp = S(function() return p.g_Health end)
    if hp and F.lastMyHp and hp < F.lastMyHp - 0.4 then
        L("я получил урон: " .. string.format("%.1f", F.lastMyHp - hp) .. " (здоровье " .. string.format("%.0f", hp) .. ")")
    end
    if hp then F.lastMyHp = hp end
    if not F.ghost then return end
    local pt = S(function() return p.g_Team end)
    local pl = S(function() return p:K2_GetActorLocation() end)
    local gl = S(function() return F.ghost:K2_GetActorLocation() end)
    if not (pl and gl) then return end
    local nm, ng, dm, dg = 0, 0, 1e18, 1e18
    for _, b in ipairs(S(function() return FindAllOf("CANNON_BASE_C") end) or {}) do
        local team = S(function() return b.g_Team end)
        if team ~= nil and pt ~= nil and team ~= pt and S(function() return b:IsValid() end) then
            local bl = S(function() return b:K2_GetActorLocation() end)
            if bl then
                local a = (bl.X - pl.X) ^ 2 + (bl.Y - pl.Y) ^ 2 + (bl.Z - pl.Z) ^ 2
                local c = (bl.X - gl.X) ^ 2 + (bl.Y - gl.Y) ^ 2 + (bl.Z - gl.Z) ^ 2
                if a < 150000 ^ 2 then nm = nm + 1 end
                if c < 150000 ^ 2 then ng = ng + 1 end
                if a < dm then dm = a end
                if c < dg then dg = c end
            end
        end
    end
    if nm > 0 or ng > 0 then
        L("вражеский огонь в 1.5 км: у меня " .. nm .. " (мин " .. string.format("%.0f", math.sqrt(dm) / 100) .. " м), у призрака " .. ng ..
            " (мин " .. string.format("%.0f", math.sqrt(dg) / 100) .. " м)")
    end
end

-- ===================== синхрон позиций врагов от хоста (мягкий) =====================
-- У каждого свой мир и свой ИИ. Хост (тот, кто пригласил) шлёт снапшоты подвижных врагов (самолёты, корабли).
-- У гостя каждому присылаемому юниту подбирается пара (тот же класс/команда, ближайший свободный), и если он ушёл
-- от позиции хоста дальше SOFT_DIST, его плавно подтягивают к ней. ИИ юнита НЕ отключается: он продолжает наводиться
-- и стрелять по самому гостю; близко к позиции хоста юнит не трогаем.
local AI_CLASSES = {"AirUnit_C", "ShipUnit_C"}
local AI_RADIUS = 1500000       -- см: берём врагов в 15 км от игрока
local AI_MAX = 40               -- максимум юнитов в снапшоте
local SOFT_DIST = 15000         -- см (150 м): ближе — не трогаем
local PAIR_DIST = 1000000       -- см (10 км): дальше первичной пары не ищем
local AI_PULL = 0.3             -- доля подтяжки за кадр

local function UnitKey(u)
    local n = S(function() return u:GetFName():ToString() end)
    return n and (n:match("(%d+)$") or n) or nil
end

-- ХОСТ: снапшот подвижных врагов -> ai_out.txt (4 раза в секунду)
local function AiHostSend(p, now)
    local role = COOP_STATUS.role
    if role ~= "host" and role ~= "loopback" then return end
    if now - (F.aiSendT or -1) < 0.25 then return end
    F.aiSendT = now
    F.aiTick = (F.aiTick or 0) + 1
    local pt = S(function() return p.g_Team end)
    local pl = S(function() return p:K2_GetActorLocation() end)
    if not pl then return end
    local ox, oy, oz = Origin(p)
    local list = {}
    F.aiGroup = F.aiGroup or {}
    for ci, cname in ipairs(AI_CLASSES) do
        -- полный скан класса: самолёты каждый тик (0.25 с), корабли раз в секунду; между сканами читаем позиции кэша
        if ci == 1 or F.aiTick % 4 == 0 or not F.aiGroup[ci] then
            local g = {}
            for _, u in ipairs(S(function() return FindAllOf(cname) end) or {}) do
                if S(function() return u:IsValid() end) then
                    local team = S(function() return u.g_Team end)
                    if team ~= nil and pt ~= nil and team ~= pt then g[#g + 1] = {u = u, team = team} end
                end
            end
            F.aiGroup[ci] = g
        end
        for _, c in ipairs(F.aiGroup[ci]) do
            local u = c.u
            if S(function() return u:IsValid() end) and S(function() return u.g_IsDestroyed end) ~= true then
                local l = S(function() return u:K2_GetActorLocation() end)
                local r = S(function() return u:K2_GetActorRotation() end)
                if l and r then
                    local d2 = (l.X - pl.X) ^ 2 + (l.Y - pl.Y) ^ 2 + (l.Z - pl.Z) ^ 2
                    if d2 < AI_RADIUS ^ 2 then
                        list[#list + 1] = {d2 = d2, u = u, l = l, r = r, team = c.team}
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.d2 < b.d2 end)
    local parts = {}
    for i = 1, math.min(AI_MAX, #list) do
        local e = list[i]
        parts[#parts + 1] = string.format("%s;%s;%d;%.0f;%.0f;%.0f;%.1f;%.1f;%.1f;%.0f", UnitKey(e.u) or "0",
            S(function() return e.u:GetClass():GetFName():ToString() end) or "?", e.team,
            e.l.X + ox, e.l.Y + oy, e.l.Z + oz, e.r.Pitch, e.r.Yaw, e.r.Roll, S(function() return e.u.g_Health end) or 0)
    end
    local f = io.open(IO .. "ai_out.txt", "w")
    if not f then return end
    f:write(string.format("%.3f#%s\n", now, table.concat(parts, "|")))
    f:close()
    if now - (F.aiSendLogT or -100) > 10 then
        F.aiSendLogT = now
        L("ИИ-синхрон (хост/" .. tostring(role) .. "): в снапшоте " .. math.min(AI_MAX, #list) .. " из " .. #list .. " врагов")
    end
end

-- ГОСТЬ: приём снапшота
local function AiGuestRead(now)
    if now - (F.aiReadT or -1) < 0.1 then return end
    F.aiReadT = now
    local fh = io.open(IO .. "ai_in.txt", "r")
    if not fh then return end
    local line = fh:read("l")
    fh:close()
    if not line or line == F.aiLastLine then return end
    F.aiLastLine = line
    local ts, body = line:match("^([%-%d%.]+)#(.*)$")
    if not ts then return end
    local snap = {t = now, units = {}}
    for e in body:gmatch("[^|]+") do
        local id, cls, team, x, y, z, pi, yw, ro, hp = e:match("^([^;]+);([^;]+);(%-?%d+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+)$")
        if id then
            snap.units[id] = {id = id, cls = cls, team = tonumber(team), x = tonumber(x), y = tonumber(y), z = tonumber(z),
                pitch = tonumber(pi), yaw = tonumber(yw), roll = tonumber(ro), hp = tonumber(hp)}
        end
    end
    -- скорость по двум последним снапшотам (экстраполяция между ними)
    local prev = F.aiSnap
    if prev and now - prev.t < 3 then
        local dt = now - prev.t
        for id, e in pairs(snap.units) do
            local o = prev.units[id]
            if o and dt > 0.05 then
                e.vx, e.vy, e.vz = (e.x - o.x) / dt, (e.y - o.y) / dt, (e.z - o.z) / dt
            end
        end
    end
    F.aiSnap = snap
end

-- ГОСТЬ: пары и подтяжка
local function AiGuestApply(p, now)
    local role = COOP_STATUS.role
    if role ~= "guest" and role ~= "loopback" then return end
    AiGuestRead(now)
    local snap = F.aiSnap
    if not snap or now - snap.t > 3 then return end
    F.aiPairs = F.aiPairs or {}      -- id хоста -> полное имя локального юнита
    F.aiTaken = F.aiTaken or {}      -- полное имя локального юнита -> id хоста
    F.aiObj = F.aiObj or {}          -- полное имя -> объект (обновляется при сканах)
    local ox, oy, oz = Origin(p)
    local pt = S(function() return p.g_Team end)
    -- локальные юниты нужных классов (скан раз в секунду)
    if now - (F.aiLocalT or -10) > 1.0 then
        F.aiLocalT = now
        F.aiLocal = {}
        local classes = {}
        for _, e in pairs(snap.units) do classes[e.cls] = true end
        for cls in pairs(classes) do
            for _, u in ipairs(S(function() return FindAllOf(cls) end) or {}) do
                if S(function() return u:IsValid() end) and S(function() return u.g_Team end) ~= pt then
                    local k = S(function() return u:GetFullName() end)
                    if k then
                        F.aiObj[k] = u
                        F.aiLocal[#F.aiLocal + 1] = {k = k, cls = cls, team = S(function() return u.g_Team end)}
                    end
                end
            end
        end
    end
    local paired, total, moved = 0, 0, 0
    for id, e in pairs(snap.units) do
        total = total + 1
        local key = F.aiPairs[id]
        -- первичная пара: ближайший свободный юнит того же класса/команды
        if not key and F.aiLocal then
            local best, bd = nil, PAIR_DIST ^ 2
            for _, c in ipairs(F.aiLocal) do
                if c.cls == e.cls and c.team == e.team and not F.aiTaken[c.k] then
                    local u = F.aiObj[c.k]
                    local l = u and S(function() return u:IsValid() and u:K2_GetActorLocation() end)
                    if l then
                        local d2 = (l.X + ox - e.x) ^ 2 + (l.Y + oy - e.y) ^ 2 + (l.Z + oz - e.z) ^ 2
                        if d2 < bd then best, bd = c.k, d2 end
                    end
                end
            end
            if best then
                F.aiPairs[id] = best
                F.aiTaken[best] = id
                key = best
            end
        end
        local u = key and F.aiObj[key]
        if u and S(function() return u:IsValid() end) then
            paired = paired + 1
            local l = S(function() return u:K2_GetActorLocation() end)
            if l then
                local age = math.min(3, now - snap.t)
                local tx = e.x + (e.vx or 0) * age - ox
                local ty = e.y + (e.vy or 0) * age - oy
                local tz = e.z + (e.vz or 0) * age - oz
                local d = math.sqrt((tx - l.X) ^ 2 + (ty - l.Y) ^ 2 + (tz - l.Z) ^ 2)
                if d > SOFT_DIST then
                    local nl = {X = l.X + (tx - l.X) * AI_PULL, Y = l.Y + (ty - l.Y) * AI_PULL, Z = l.Z + (tz - l.Z) * AI_PULL}
                    local r = S(function() return u:K2_GetActorRotation() end)
                    local ok = pcall(function()
                        if r then
                            u:K2_SetActorLocationAndRotation(nl, {Pitch = AngLerp(r.Pitch, e.pitch, AI_PULL), Yaw = AngLerp(r.Yaw, e.yaw, AI_PULL),
                                Roll = AngLerp(r.Roll, e.roll, AI_PULL)}, false, {}, false)
                        else
                            u:K2_SetActorLocation(nl, false, {}, false)
                        end
                    end)
                    if ok then moved = moved + 1 end
                end
            end
        end
    end
    if now - (F.aiApplyLogT or -100) > 5 then
        F.aiApplyLogT = now
        L("ИИ-синхрон (гость/" .. tostring(role) .. "): пар " .. paired .. " из " .. total .. " в снапшоте, подтянуто " .. moved)
    end
end

-- ===================== сопла и форсаж модели напарника =====================
-- У настоящего самолёта сопла/форсаж — отдельные компоненты поверх скелета (ThirdPersonModel): статические меши
-- (a_AfterburnerEmissive — «Nozzle», a_AfterburnersMesh — пламя/ударные кольца) и частицы (a_Afterburner Particle).
-- Отправитель присылает раскладку своего самолёта (меш/шаблон + относительное положение), получатель достраивает её
-- на своей модели и по a_AfterburnerFloat включает пламя.

-- ОТПРАВИТЕЛЬ: раскладка своих компонентов (раз за полёт, после загрузки); формат «тип;путь;lx;ly;lz;pitch;yaw;roll;sx;sy;sz|…»
local function BuildMyLayout(p)
    local function Arr(name)
        local t = {}
        S(function() p[name]:ForEach(function(_, v) t[#t + 1] = v:get() end) end)
        return t
    end
    local out = {}
    local function Add(kind, c, pathFn)
        local path = S(pathFn)
        local rl, rr, rs = S(function() return c.RelativeLocation end), S(function() return c.RelativeRotation end), S(function() return c.RelativeScale3D end)
        if path and rl and rr and rs then
            path = path:match("^%S+%s+(.+)$") or path
            out[#out + 1] = string.format("%s;%s;%.1f;%.1f;%.1f;%.1f;%.1f;%.1f;%.3f;%.3f;%.3f", kind, path, rl.X, rl.Y, rl.Z, rr.Pitch, rr.Yaw, rr.Roll, rs.X, rs.Y, rs.Z)
        end
    end
    for _, c in ipairs(Arr("a_AfterburnerEmissive")) do Add("N", c, function() return c.StaticMesh:GetFullName() end) end
    for _, c in ipairs(Arr("a_AfterburnersMesh")) do Add("A", c, function() return c.StaticMesh:GetFullName() end) end
    for _, c in ipairs(Arr("a_Afterburner Particle")) do Add("P", c, function() return c.Template:GetFullName() end) end
    return #out > 0 and table.concat(out, "|") or nil
end

local function ParseLayout(str)
    local list = {}
    for e in (str or ""):gmatch("[^|]+") do
        local k, path, lx, ly, lz, pi, yw, ro, sx, sy, sz = e:match("^(%a);([^;]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+);([%-%d%.]+)$")
        if k then
            list[#list + 1] = {kind = k, path = path, loc = {X = tonumber(lx), Y = tonumber(ly), Z = tonumber(lz)},
                rot = {Pitch = tonumber(pi), Yaw = tonumber(yw), Roll = tonumber(ro)}, scale = {X = tonumber(sx), Y = tonumber(sy), Z = tonumber(sz)}}
        end
    end
    return list
end

-- ПОЛУЧАТЕЛЬ: достроить сопла на модели-призраке и вести пламя по тяге партнёра
local function UpdateEngines(p, now)
    local vis = F.visual
    if not (vis and S(function() return vis:IsValid() end) and F.peerLayout) then return end
    local skel = S(function() return vis.SkeletalMeshComponent end)
    if not skel then return end
    -- (пере)сборка при новой раскладке или новой модели
    if F.engVis ~= vis or F.engLayout ~= F.peerLayout then
        for _, e in ipairs(F.engParts or {}) do
            pcall(function() if e.actor and e.actor:IsValid() then e.actor:K2_DestroyActor() end end)
            pcall(function() if e.psc and e.psc:IsValid() then e.psc:DestroyComponent(e.psc) end end)
        end
        F.engParts, F.engVis, F.engLayout = {}, vis, F.peerLayout
        local n = 0
        for _, d in ipairs(ParseLayout(F.peerLayout)) do
            if d.kind == "P" then
                local tpl = StaticFindObject(d.path) or S(function() return LoadAsset(d.path) end)
                if tpl and S(function() return tpl:IsValid() end) then
                    local ok, psc = pcall(function()
                        return GS():SpawnEmitterAttached(tpl, skel, FName("None"), d.loc, d.rot, d.scale, 0, false, 0, false)
                    end)
                    if ok and psc then F.engParts[#F.engParts + 1] = {kind = "P", psc = psc, d = d} n = n + 1 end
                end
            else
                local mesh = StaticFindObject(d.path) or S(function() return LoadAsset(d.path) end)
                if mesh and S(function() return mesh:IsValid() end) then
                    local a = S(function() return p:GetWorld():SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), {X = 0, Y = 0, Z = 0}, {Pitch = 0, Yaw = 0, Roll = 0}) end)
                    if a and S(function() return a:IsValid() end) then
                        local comp = a.StaticMeshComponent
                        pcall(function() comp:SetMobility(2) end)
                        pcall(function() comp:SetStaticMesh(mesh) end)
                        pcall(function() comp:SetCollisionEnabled(0) end)
                        local okA = pcall(function() a:K2_AttachToComponent(skel, FName("None"), 2, 2, 2, false) end)
                        pcall(function() comp:K2_SetRelativeLocationAndRotation(d.loc, d.rot, false, {}, false) end)
                        pcall(function() comp:SetRelativeScale3D(d.scale) end)
                        F.engParts[#F.engParts + 1] = {kind = d.kind, actor = a, comp = comp, d = d}
                        n = n + 1
                        if not okA then Err("eng_attach", "K2_AttachToComponent не сработал") end
                    end
                end
            end
        end
        L("сопла напарника достроены: " .. n .. " компонентов")
    end
    -- пламя по тяге: a_AfterburnerFloat партнёра (0..1)
    local ab = F.peerAb or 0
    local on = ab > 0.05
    for _, e in ipairs(F.engParts or {}) do
        if e.kind == "A" then
            pcall(function() e.comp:SetVisibility(on, false) end)
            if on then
                local k = 0.4 + 0.6 * math.min(1, ab)
                pcall(function() e.comp:SetRelativeScale3D({X = e.d.scale.X * k, Y = e.d.scale.Y, Z = e.d.scale.Z}) end)
            end
        elseif e.kind == "P" then
            if on ~= e.on then
                e.on = on
                pcall(function() if on then e.psc:Activate(true) else e.psc:Deactivate() end end)
            end
        end
    end
end

-- Разведка меню паузы (Retry / Hangar / Quit / Resume): ищем виджет PauseUI, ставим логирующие хуки на его функции,
-- чтобы понять, какие вызовы видны снаружи (нужно для двустороннего «Retry/Hangar/Quit» между игроками).
local pauseHooked = false
local function ProbePause(p, now)
    if pauseHooked or now - (F.pauseT or -10) < 3 then return end
    F.pauseT = now
    local w = FindFirstOf("PauseUI_C")
    if not (w and S(function() return w:IsValid() end)) then return end
    local full = S(function() return w:GetClass():GetFullName() end)
    local path = full and (full:match("^%S+%s+(.+)$") or full)
    if not path then return end
    pauseHooked = true
    L("PauseUI найден: " .. path .. " | виден=" .. tostring(S(function() return w:IsVisible() end)))
    ExecuteWithDelay(500, function()
        ExecuteInGameThread(function()
            for _, fn in ipairs({"Retry", "Hangar", "Quit", "Resume", "Settings", "Confirmed", "HangarConfirm", "Hide", "UnHide", "OnButtonReleasedEvent"}) do
                local ok = pcall(RegisterHook, path .. ":" .. fn, function() end, function() L("пауза-меню: " .. fn .. "()") end)
                if not ok then L("хук PauseUI:" .. fn .. " не поставлен") end
            end
            L("хуки меню паузы поставлены")
        end)
    end)
end

-- Следование за партнёром после выхода из полёта: он нажал Retry/Hangar/Quit (мы видим это по смене состояния и сигналу
-- p_follow «вид метка_времени»), у нас вызывается та же функция меню паузы/провала (RetryUI_C или PauseUI_C).
local function DoFollow(p, now)
    if now - (F.followT or -10) < 1 then return end
    F.followT = now
    local raw = COOP_STATUS.p_follow
    if not raw then return end
    local kind, t = raw:match("^(%a+)%s+(%d+)")
    t = tonumber(t)
    if not (kind and t) or math.abs(os.time() - t) > 25 or FOLLOW_DONE == t then return end
    FOLLOW_DONE = t
    local fn = ({retry = "Retry", hangar = "Hangar", menu = "Quit"})[kind]
    if not fn then return end
    local done = false
    for _, cname in ipairs({"RetryUI_C", "PauseUI_C"}) do
        local ui = FindFirstOf(cname)
        if ui and S(function() return ui:IsValid() end) then
            local ok, e = pcall(function() ui[fn](ui) end)
            L("следую за партнёром: " .. kind .. " → " .. cname .. ":" .. fn .. "() " .. (ok and "выполнен" or ("ошибка " .. tostring(e))))
            ExecuteWithDelay(400, function()
                ExecuteInGameThread(function()
                    pcall(function() ui:Confirmed() end)
                    if kind == "hangar" then pcall(function() ui:HangarConfirm() end) end
                end)
            end)
            done = true
            break
        end
    end
    if not done then L("следую за партнёром: " .. kind .. " — меню паузы/провала не найдено") end
end

-- ===================== HUD: строка напарника справа сверху (под счётом) =====================
-- Строка = виджет игры UI_ScoreHudChild (как «PT BOAT +40»), добавленный в VertBox счёта: «ИМЯ    85%», при потере
-- здоровья 3 с дописывается «-N». Класс строки берём у настоящей строки счёта: один раз просим игру создать её
-- (AddScoreFriendly) и читаем GetClass() у последнего ребёнка VertBox.
local function UpdatePartnerRow(p, now)
    if now - (F.rowT or -1) < 0.5 then return end
    F.rowT = now
    local alive = F.ghost and F.peerHp ~= nil
    local function rowValid() return F.row and S(function() return F.row:IsValid() end) end
    if not alive then
        if rowValid() then pcall(function() F.row:RemoveFromParent() end) end
        F.row = nil
        return
    end
    -- счёт живого HUD игрока: FlyingPawn.g_WidgetReference (UI_MAIN).UI_ScoreHud_92 (FindFirstOf находил другой, неактивный)
    local hud = S(function() return p.g_WidgetReference.UI_ScoreHud_92 end)
    if not (hud and S(function() return hud:IsValid() end)) then return end
    local vb = S(function() return hud.VertBox end)
    if not vb then return end
    if not (rowValid() and S(function() return F.row:GetParent() end)) then
        -- свой TextBlock в VertBox счёта (сразу под «TOTAL SCORE»); шрифт и цвет копируем у TOTAL SCORE
        local tbc = StaticFindObject("/Script/UMG.TextBlock")
        local okc, tb = pcall(function() return StaticConstructObject(tbc, hud) end)
        if not (okc and tb and S(function() return tb:IsValid() end)) then
            if not F.rowFailLogged then F.rowFailLogged = true L("HUD: TextBlock не создан: " .. tostring(okc and "nil" or tb)) end
            return
        end
        local tpl = S(function() return hud.TextBlock_0 end)
        if tpl then
            -- шрифт как у TOTAL SCORE: копируем поля структуры по одному (SetFont(tpl.Font) целиком не применялся)
            local tf = S(function() return tpl.Font end)
            local nf = S(function() return tb.Font end)
            local fsz = tf and S(function() return tf.Size end)
            if tf and nf then
                pcall(function() nf.FontObject = tf.FontObject end)
                pcall(function() nf.Size = tf.Size end)
                pcall(function() nf.TypefaceFontName = tf.TypefaceFontName end)
                pcall(function() nf.LetterSpacing = tf.LetterSpacing end)
                pcall(function() tb:SetFont(nf) end)
            end
            L("HUD: размер шрифта шаблона " .. tostring(fsz) .. ", у строки " .. tostring(S(function() return tb.Font.Size end)))
            pcall(function() tb:SetColorAndOpacity(tpl.ColorAndOpacity) end)
        end
        -- по левому краю, как «TOTAL SCORE» (по правому он уезжал дальше правого края счёта)
        pcall(function() tb:SetJustification(0) end)
        local ok2, slot = pcall(function() return vb:AddChildToVerticalBox(tb) end)
        if ok2 and slot then pcall(function() slot:SetHorizontalAlignment(1) end) end
        F.row, F.rowHp = tb, F.peerHp
        L("HUD: строка напарника добавлена (AddChild " .. (ok2 and "ok" or tostring(slot)) .. ", шаблон шрифта " .. tostring(tpl ~= nil) .. ")")
    end
    local nm = (COOP_STATUS.peer_name and COOP_STATUS.peer_name ~= "" and COOP_STATUS.peer_name or "WINGMAN"):upper()
    local hp = math.max(0, math.min(100, math.floor(F.peerHp + 0.5)))
    if F.rowHp and hp < F.rowHp then F.rowHit, F.rowHitN = now, F.rowHp - hp end
    F.rowHp = hp
    local txt = nm .. "   " .. hp .. "%"
    if F.rowHit and now - F.rowHit < 3 then txt = txt .. "   -" .. F.rowHitN end
    pcall(function() F.row:SetText(FText(txt)) end)
end

-- ===================== кадр полёта =====================
local function FrameTick(p)
    F.pawn = p
    local now = Now(p)
    if now - F.lastStatus >= STATUS_DT or now < F.lastStatus then
        F.lastStatus = now
        COOP_STATUS = ReadStatus()
    end
    if F.ghost then pcall(UpdateGhostLabel, p) end        -- каждый кадр: игра сама переписывает подпись
    pcall(SenderEvents, p, now)
    local okU, eU = pcall(ScanUnits, p, now)
    if not okU then Err("scan_units", eU) end
    local okK, eK = pcall(ApplyRemoteKills, p, now)
    if not okK then Err("remote_kills", eK) end
    local okFo, eFo = pcall(DoFollow, p, now)
    if not okFo then Err("follow", eFo) end
    local okT, eT = pcall(ScanThreats, p, now)
    if not okT then Err("threats", eT) end
    local okF, eF = pcall(ThreatFire, p, now)
    if not okF then Err("threat_fire", eF) end
    if not F.myLayout and now - (F.survT0 or now) > 4 then
        F.myLayout = BuildMyLayout(p)
        L("раскладка сопел своего самолёта: " .. (F.myLayout and (#F.myLayout .. " байт") or "не получена"))
    end
    local okP, eP = pcall(ProbePause, p, now)
    if not okP then Err("probe_pause", eP) end
    local okE, eE = pcall(ProbeEngines, p, now)
    if not okE then Err("probe_eng", eE) end
    local okA, eA = pcall(AiHostSend, p, now)
    if not okA then Err("ai_send", eA) end
    local okB, eB = pcall(AiGuestApply, p, now)
    if not okB then Err("ai_apply", eB) end
    local okS, eS = pcall(SurveyWingmen, p, now)
    if not okS then Err("survey", eS) end
    local okC, eC = pcall(CompareWithWingman, p, now)
    if not okC then Err("compare", eC) end
    -- AutoHypotheses отключён: причина найдена (связки g_SelfGameUnitRef/ParentActor), гипотезы 1–4 включали ИИ носителя
    -- local okH, eH = pcall(AutoHypotheses, p, now)
    local okG, eG = pcall(EnsureGhostRegistered, p, now)
    if not okG then Err("ghost_reg", eG) end
    local okR, eR = pcall(UpdatePartnerRow, p, now)
    if not okR then Err("partner_row", eR) end
    if now - F.lastSend >= SEND_DT or now < F.lastSend then
        F.lastSend = now
        local ok, e = pcall(WriteOut, p, now)
        if not ok then Err("out", e) end
    end
    if now - F.lastRead >= READ_DT or now < F.lastRead then
        F.lastRead = now
        local ok, e = pcall(Receive, p, now)
        if not ok then Err("in", e) end
    end
    -- нет данных от напарника — убираем призрака
    if F.lastRx and now - F.lastRx > GHOST_TIMEOUT then
        DestroyGhost()
        F.buf, F.offset, F.offN, F.lastRt, F.lastRx = {}, nil, 0, nil, nil
        return
    end
    if not F.offset then return end
    local rt = now - F.offset - DELAY
    if F.lastRt and rt < F.lastRt and F.lastRt - rt < 1 then rt = F.lastRt end
    F.lastRt = rt
    local s = Sample(rt)
    if not s then return end
    local ox, oy, oz = Origin(p)
    local lp = {X = s.x - ox, Y = s.y - oy, Z = s.z - oz}
    -- партнёр разбился: взрыв/всплеск в последней точке, призрак и модель убираем; пока он мёртв, заново не создаём
    if F.peerDead then
        if F.ghost or F.visual then
            if s.z <= 1500 then FXAt(p, "water", lp.X, lp.Y, lp.Z, 8) FXAt(p, "air", lp.X, lp.Y, lp.Z + 100, 3)
            else FXAt(p, "air", lp.X, lp.Y, lp.Z, 4) end
            L("партнёр разбился: эффект в точке z=" .. string.format("%.0f", s.z))
            -- общий провал: погиб партнёр — игра заканчивается и у меня (критический урон), потом Retry/Hangar у обоих вместе
            if (COOP_STATUS.role == "host" or COOP_STATUS.role == "guest") and not F.deathTaken then
                F.deathTaken = true
                local gu0 = F.ghost and GetGU(F.ghost)
                L("партнёр погиб — критический урон мне (общий провал)")
                pcall(function() p:ApplyHit(100000, gu0, 0) end)
                ExecuteWithDelay(1500, function()
                    ExecuteInGameThread(function()
                        if GAME_STATE == "flight" and F.pawn and S(function() return F.pawn:IsValid() end) and S(function() return F.pawn.g_IsDestroyed end) ~= true then
                            pcall(function() F.pawn:MissionFailure(true) end)
                            L("партнёр погиб — запущен MissionFailure")
                        end
                    end)
                end)
            end
            DestroyGhost()
        end
        local okM0, eM0 = pcall(UpdateGhostMissiles, p, rt)
        return
    end
    -- создание/пересоздание
    if not (F.ghost and S(function() return F.ghost:IsValid() end)) then
        if now - F.lastSpawn < 2 then return end
        F.lastSpawn = now
        F.ghost = SpawnGhost(p, lp)
        L("призрак (носитель радара) создан: " .. tostring(F.ghost ~= nil))
    end
    if not (F.visual and S(function() return F.visual:IsValid() end)) or (F.peerMesh and F.peerMesh ~= F.visMesh) then
        pcall(function() if F.visual and F.visual:IsValid() then F.visual:K2_DestroyActor() end end)
        F.visual = SpawnVisual(p, lp, F.peerMesh)
        L("визуал создан, меш: " .. tostring(F.peerMesh))
    end
    -- перемещение; при ошибке актор пересоздаётся на следующем кадре
    if F.ghost then
        local ok = pcall(function()
            F.ghost:K2_SetActorLocationAndRotation(lp, {Pitch = s.pitch, Yaw = s.yaw, Roll = s.roll}, false, {}, false)
        end)
        if not ok then pcall(function() F.ghost:K2_DestroyActor() end) F.ghost = nil F.lastSpawn = now - 1.5 end
    end
    if F.visual then
        local ok = pcall(function()
            F.visual:K2_SetActorLocationAndRotation(lp, {Pitch = s.pitch, Yaw = s.yaw + F.visYaw, Roll = s.roll}, false, {}, false)
        end)
        if not ok then pcall(function() F.visual:K2_DestroyActor() end) F.visual = nil end
    end
    -- урон по призраку (враги бьют его у нас): считаем накопленный, здоровье возвращаем — призрак не гибнет
    if F.ghost then
        local h = S(function() return F.ghost.g_Health end)
        if h then
            if F.gLastH and h < F.gLastH then
                F.gdAccum = (F.gdAccum or 0) + (F.gLastH - h)
                L("урон по призраку: " .. string.format("%.1f", F.gLastH - h) .. " (всего " .. string.format("%.1f", F.gdAccum) .. ")")
            end
            if h < 900000 then pcall(function() F.ghost.g_Health = 1000000 end) h = 1000000 end
            F.gLastH = h
        end
    end
    local okN, eN = pcall(UpdateEngines, p, now)
    if not okN then Err("engines", eN) end
    local okM, eM = pcall(UpdateGhostMissiles, p, rt)
    if not okM then Err("missiles", eM) end
    ExecEvents(p, rt)
end

-- Самопроверка без друга: F9 в полёте «имитирует приём» — ближайший вражеский юнит (до 5 км) получает событие
-- уничтожения от «напарника» и гибнет через тот же путь, что и при игре вдвоём (ApplyRemoteKills → ApplyHit).
-- Путь отправителя проверяется обычным уничтожением врага самим: в логе «уничтожен враг: …».
local function SelfTestKill()
    local p = F.pawn
    if GAME_STATE ~= "flight" or not p then L("F9: вне полёта") return end
    local pt = S(function() return p.g_Team end)
    local pl = S(function() return p:K2_GetActorLocation() end)
    local ox, oy, oz = Origin(p)
    local best, bd, bc, bteam, bloc = nil, 500000 ^ 2, nil, nil, nil
    for _, group in ipairs(UNIT_CLASSES) do
        for _, u in ipairs(S(function() return FindAllOf(group) end) or {}) do
            local team = S(function() return u.g_Team end)
            if S(function() return u:IsValid() end) and team ~= nil and team ~= pt and S(function() return u.g_IsDestroyed end) ~= true then
                local ul = S(function() return u:K2_GetActorLocation() end)
                if ul and pl then
                    local d = (ul.X - pl.X) ^ 2 + (ul.Y - pl.Y) ^ 2 + (ul.Z - pl.Z) ^ 2
                    if d < bd then best, bd, bteam, bloc = u, d, team, ul end
                end
            end
        end
    end
    if not best then L("F9: врагов рядом (до 5 км) нет") return end
    local cls = S(function() return best:GetClass():GetFName():ToString() end)
    L("F9: имитирую приём уничтожения " .. tostring(cls) .. " в " .. string.format("%.0f", math.sqrt(bd) / 100) .. " м")
    F.pendKills = F.pendKills or {}
    F.pendKills[#F.pendKills + 1] = {first = Now(p), k = {id = -1, owner = "test", cls = cls, team = bteam,
        x = bloc.X + ox, y = bloc.Y + oy, z = bloc.Z + oz}}
end
-- Гипотезы «почему враги не выбирают призрака» — включаются вручную в бою, эффект смотреть по «турели целятся … в ПРИЗРАКА»:
--   F5: включить тик носителя призрака (SetActorTickEnabled), F6: включить коллизию носителя (SetActorEnableCollision).
pcall(RegisterKeyBind, Key.F5, function()
    ExecuteInGameThread(function()
        local g = F.ghost
        if not g then L("F5: нет призрака") return end
        local ok, e = pcall(function() g:SetActorTickEnabled(true) end)
        L("F5: тик носителя призрака включён " .. (ok and "ok" or tostring(e)))
    end)
end)
pcall(RegisterKeyBind, Key.F6, function()
    ExecuteInGameThread(function()
        local g = F.ghost
        if not g then L("F6: нет призрака") return end
        local ok, e = pcall(function() g:SetActorEnableCollision(true) end)
        L("F6: коллизия носителя призрака включена " .. (ok and "ok" or tostring(e)))
    end)
end)
-- F8: имитация попадания врага по призраку (25 урона) — проверка цепочки «урон призраку → самолёт партнёра» без врагов
pcall(RegisterKeyBind, Key.F8, function()
    ExecuteInGameThread(function()
        local ok, e = pcall(function()
            local p, g = F.pawn, F.ghost
            if GAME_STATE ~= "flight" or not p or not g then L("F8: нет призрака") return end
            local hp0 = S(function() return g.g_Health end)
            local ok2, err = pcall(function() g:ApplyHit(25, GetGU(g)) end)
            L("F8: ApplyHit(25) по призраку " .. (ok2 and "выполнен" or ("ошибка: " .. tostring(err))) ..
                ", g_Health " .. tostring(hp0) .. " -> " .. tostring(S(function() return g.g_Health end)))
        end)
        if not ok then Err("f8", e) end
    end)
end)
pcall(RegisterKeyBind, Key.F9, function() ExecuteInGameThread(function() local ok, e = pcall(SelfTestKill) if not ok then Err("f9", e) end end) end)

-- ===================== хуки полёта (регистрируются один раз на класс) =====================
local hookedTick = false
local function EnsureFlightHooks(p)
    if hookedTick then return end
    local path = ClassPathOf(p)
    local ok, e = pcall(RegisterHook, path .. ":ReceiveTick", function() end, function(self)
        if GAME_STATE ~= "flight" then return end
        local pawn = self:get()
        local ok2, e2 = pcall(FrameTick, pawn)
        if not ok2 then Err("frame", e2) end
    end)
    L("хук ReceiveTick: " .. (ok and "OK" or tostring(e)))
    local okg, eg = pcall(RegisterHook, path .. ":FireGun", function()
        if GAME_STATE ~= "flight" then return end
        F.gc = F.gc + 1
        if not F.bpath then F.needBullet = true end
    end)
    L("хук FireGun: " .. (okg and "OK" or tostring(eg)))
    hookedTick = ok
end

-- Разведка для синхрона меню/режима (этап 1): что игра хранит о выбранной миссии/режиме на каждом экране.
-- Только чтение, через 2.5 с после смены пешки (не во время загрузки уровня).
local LV = {
    id = "ID_18_1E73F8AD49BEFD832EC62A8BE3469830",
    names = "LevelName_74_144F3B4841941BE811945A95881CE825",
    mname = "MissionName_65_D33E26BB45E2D8120382D68F02E1F87C",
    campaign = "IsCampaignLevel_76_744D3A8C45F3E7F7E9DBE1802314386B",
    scenario = "IsScenario_140_3E113CED43258422C2296D9475975401",
    briefing = "HasBriefing_27_81B99C4740A065506E15AC80EC683919",
    hangar = "HangarMap_108_754F019D4A1388894A0B60A125A0D328",
}
local function ProbeInstance(state)
    local inst = FindFirstOf("WingmanInstance_C")
    if not (inst and S(function() return inst:IsValid() end)) then L("разведка[" .. state .. "]: WingmanInstance не найден") return end
    local ld = S(function() return inst.LevelData end)
    local function F2(n) return S(function() return ld[LV[n]] end) end
    local names = {}
    S(function() ld[LV.names]:ForEach(function(_, v) names[#names + 1] = v:get():ToString() end) end)
    L("разведка[" .. state .. "]: LevelData.ID=" .. tostring(S(function() return F2("id"):ToString() end))
        .. " | имена уровней=" .. table.concat(names, ",")
        .. " | миссия=" .. tostring(S(function() return F2("mname"):ToString() end))
        .. " | campaign=" .. tostring(F2("campaign")) .. " scenario=" .. tostring(F2("scenario")) .. " briefing=" .. tostring(F2("briefing"))
        .. " | FreeFlight=" .. tostring(S(function() return inst.FreeFlight end))
        .. " | C_OnScenario=" .. tostring(S(function() return inst.C_OnScenario end))
        .. " | CD_CanFreeFlight=" .. tostring(S(function() return inst.CD_CanFreeFlight end)))
    -- свой выбор (режим + миссия) — глобально для UI; хост (и loopback) шлёт его партнёру: у гостя плашка «выбор хоста»
    local ff = S(function() return inst.FreeFlight end) == true
    local id = S(function() return F2("id"):ToString() end) or "?"
    local nm = S(function() return F2("mname"):ToString() end) or id
    COOP_SEL = {ff = ff, id = id, name = nm}
    local role = COOP_STATUS and COOP_STATUS.role
    if role == "host" or role == "loopback" then
        local f = io.open(IO .. "cmd.txt", "a")
        if f then
            local clean = nm:gsub("%c", " ")
            f:write("set sel " .. (ff and 1 or 0) .. " " .. id .. " " .. clean .. "\n")
            f:close()
            L("выбор хоста отправлен: " .. (ff and "Free Flight" or "миссия") .. ", " .. nm .. " (" .. id .. ")")
        end
    end
end

-- ===================== событие смены пешки =====================
local F_loadHooked = false
local function OnClientRestart(self, newPawn)
    local p = S(function() return newPawn:get() end)
    local cls = p and S(function() return p:GetClass():GetFName():ToString() end) or "nil"
    local newState = STATEMAP[cls] or ("other:" .. cls)
    if newState ~= GAME_STATE then L("состояние: " .. GAME_STATE .. " -> " .. newState) end
    GAME_STATE = newState
    ResetFlight()              -- ссылки на акторы прошлого уровня не трогаем, просто забываем
    if newState ~= "loading" and newState ~= "boot" then
        ExecuteWithDelay(2500, function()
            ExecuteInGameThread(function()
                if GAME_STATE == newState then pcall(ProbeInstance, newState) end
            end)
        end)
    end
    -- разведка загрузки (этап «барьер готовности»): хук тика LoadPawn пишет в лог CanEndLoading/LevelToLoad раз в секунду
    if newState == "loading" and p and not F_loadHooked then
        local full = S(function() return p:GetClass():GetFullName() end)
        local path = full and (full:match("^%S+%s+(.+)$") or full)
        if path then
            F_loadHooked = true
            ExecuteWithDelay(800, function()
                ExecuteInGameThread(function()
                    local lastT = 0
                    local ok, e = pcall(RegisterHook, path .. ":ReceiveTick", function() end, function(self)
                        local t = os.clock()
                        if t - lastT < 1 then return end
                        lastT = t
                        local lp = self:get()
                        L("загрузка: CanEndLoading=" .. tostring(S(function() return lp.CanEndLoading end)) ..
                            " | LevelToLoad=" .. tostring(S(function() return lp.LoadingManagerRef.LevelToLoad:ToString() end)) ..
                            " | IntoLevel=" .. tostring(S(function() return lp.LoadingManagerRef.IntoLevel end)))
                    end)
                    L("хук разведки загрузки: " .. (ok and "OK" or tostring(e)))
                end)
            end)
        end
    end
    if newState == "flight" then os.remove(IN) end   -- данные напарника из прошлого полёта устарели
    if UI_OnState then
        local okU, eU = pcall(UI_OnState, newState, p)
        if not okU then Err("ui_state", eU) end
    end
    if newState == "flight" and not hookedTick then
        -- регистрируем хуки вне текущего ProcessEvent, с небольшой задержкой
        ExecuteWithDelay(1500, function()
            ExecuteInGameThread(function()
                if GAME_STATE ~= "flight" then return end
                local ok, e = pcall(EnsureFlightHooks, p)
                if not ok then Err("hooks", e) end
            end)
        end)
    end
end

-- модуль интерфейса (кнопка друзей, приглашения, плашка напарника)
local okUI, eUI = pcall(dofile, "Mods/PWCoop/Scripts/ui.lua")
if not okUI then L("ui.lua не загрузился: " .. tostring(eUI)) end

-- разведка паузы: кто и когда ставит/снимает паузу (для синхрона паузы между игроками)
for _, hp in ipairs({"/Script/Engine.GameplayStatics:SetGamePaused", "/Script/Engine.PlayerController:SetPause"}) do
    local ok, e = pcall(RegisterHook, hp, function(ctx, a1, a2)
        local v1 = S(function() return a1:get() end)
        local v2 = S(function() return a2:get() end)
        L("пауза: " .. hp:match("[^%.]*$") .. "(" .. tostring(v1) .. ", " .. tostring(v2) .. ") состояние=" .. tostring(GAME_STATE))
    end)
    L("хук паузы " .. hp:match("[^:]*$") .. ": " .. (ok and "OK" or tostring(e)))
end

local okR, eR = pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart", function() end, OnClientRestart)
L("PWCoop v1 загружен; хук ClientRestart: " .. (okR and "OK" or tostring(eR)))
