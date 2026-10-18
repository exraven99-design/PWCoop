-- PWCoop UI: кнопка «ДОБАВИТЬ ДРУГА» на любой странице меню/ангара, список друзей, приглашение/принятие,
-- плашка напарника; 8 языков игры. Без LoopAsync: обновление из post-хука ReceiveTick текущей пешки меню
-- (MenuActor_V2, HangarActor, BP_StagingActor, BP_MissionSelectPawn, BP_PlayerBriefingPawn, DebriefActor).
-- Запасные клавиши: F7 — открыть/закрыть список друзей, F8 — принять приглашение, F9 — отклонить/выйти из сессии.
local IO = "Mods/PWCoop/io/"
local BTN_CLASS = "/Game/ProjectWingman/Blueprints/UIWidgets/Menus/MainMenu/UI_Button_VerticalMenuButton.UI_Button_VerticalMenuButton_C"
local X, Y0, W, H, GAP = 1480, 40, 385, 56, 62     -- правый верх канвы 1920x1080 (проверено на главном меню)
local MAX_FRIENDS = 9
local UI_DT = 0.1

local function L(m) print("[PWCoop UI] " .. m .. "\n") end
local function S(f) local ok, v = pcall(f) if ok then return v end return nil end

-- ===================== локализация =====================
local T = {
    en = {add = "ADD FRIEND", sent = "INVITE SENT: ", accept = "ACCEPT: ", decline = "DECLINE", wing = "WINGMAN: ",
          leave = "LEAVE CO-OP", off = "CO-OP: RUN start_coop.bat", none = "NO FRIENDS", online = "ONLINE",
          offline = "OFFLINE", ingame = "IN GAME", mod = "CO-OP", close = "CLOSE",
          ready = "READY TO LAUNCH", waiting = "WAITING FOR PARTNER", pready = "PARTNER READY", pwait = "PARTNER NOT READY",
          wready = "WINGMAN READY", wnot = "WINGMAN NOT READY",
          hsel = "HOST: ", hfree = "FREE FLIGHT", hsame = "SAME AS YOURS", hdiff = "PICK THE SAME"},
    ru = {add = "ДОБАВИТЬ ДРУГА", sent = "ПРИГЛАШЁН: ", accept = "ПРИНЯТЬ: ", decline = "ОТКЛОНИТЬ", wing = "НАПАРНИК: ",
          leave = "ВЫЙТИ ИЗ КООПА", off = "КООП: ЗАПУСТИ start_coop.bat", none = "НЕТ ДРУЗЕЙ", online = "В СЕТИ",
          offline = "НЕ В СЕТИ", ingame = "В ИГРЕ", mod = "КООП", close = "ЗАКРЫТЬ",
          ready = "ГОТОВ К ВЫЛЕТУ", waiting = "ЖДЁМ НАПАРНИКА", pready = "НАПАРНИК ГОТОВ", pwait = "НАПАРНИК НЕ ГОТОВ", wready = "НАПАРНИК ГОТОВ", wnot = "НАПАРНИК НЕ ГОТОВ", hsel = "ХОСТ: ", hfree = "СВОБОДНЫЙ ПОЛЁТ", hsame = "СОВПАДАЕТ", hdiff = "ВЫБЕРИ ТО ЖЕ"},
    de = {add = "FREUND HINZUFÜGEN", sent = "EINGELADEN: ", accept = "ANNEHMEN: ", decline = "ABLEHNEN", wing = "FLÜGELMANN: ",
          leave = "KOOP VERLASSEN", off = "KOOP: start_coop.bat STARTEN", none = "KEINE FREUNDE", online = "ONLINE",
          offline = "OFFLINE", ingame = "IM SPIEL", mod = "KOOP", close = "SCHLIESSEN"},
    fr = {add = "AJOUTER UN AMI", sent = "INVITÉ : ", accept = "ACCEPTER : ", decline = "REFUSER", wing = "AILIER : ",
          leave = "QUITTER LA COOP", off = "COOP : LANCER start_coop.bat", none = "AUCUN AMI", online = "EN LIGNE",
          offline = "HORS LIGNE", ingame = "EN JEU", mod = "COOP", close = "FERMER"},
    es = {add = "AÑADIR AMIGO", sent = "INVITADO: ", accept = "ACEPTAR: ", decline = "RECHAZAR", wing = "ESCOLTA: ",
          leave = "SALIR DEL COOP", off = "COOP: EJECUTA start_coop.bat", none = "SIN AMIGOS", online = "CONECTADO",
          offline = "DESCONECTADO", ingame = "EN JUEGO", mod = "COOP", close = "CERRAR"},
    ja = {add = "フレンドを追加", sent = "招待済み: ", accept = "承諾: ", decline = "拒否", wing = "僚機: ",
          leave = "協力プレイを終了", off = "協力: start_coop.bat を起動", none = "フレンドなし", online = "オンライン",
          offline = "オフライン", ingame = "プレイ中", mod = "協力", close = "閉じる"},
    ko = {add = "친구 추가", sent = "초대함: ", accept = "수락: ", decline = "거절", wing = "윙맨: ",
          leave = "협동 종료", off = "협동: start_coop.bat 실행", none = "친구 없음", online = "온라인",
          offline = "오프라인", ingame = "게임 중", mod = "협동", close = "닫기"},
    zh = {add = "添加好友", sent = "已邀请: ", accept = "接受: ", decline = "拒绝", wing = "僚机: ",
          leave = "退出合作", off = "合作: 请运行 start_coop.bat", none = "没有好友", online = "在线",
          offline = "离线", ingame = "游戏中", mod = "合作", close = "关闭"},
}
local LANG = nil

local function LangFromText(t)
    if not t or t == "" then return nil end
    if t:find("[\208\209]") then return "ru" end
    if t:find("\227[\129-\131]") then return "ja" end
    if t:find("[\234-\237]") then return "ko" end
    if t:find("[\228-\233]") then return "zh" end
    local u = t:upper()
    if u:find("EINSTELL") then return "de" end
    if u:find("PARAM") or u:find("OPTIONS") then return "fr" end
    if u:find("AJUSTES") or u:find("CONFIGURACI") or u:find("OPCIONES") then return "es" end
    return "en"
end

local function LangFromIni()
    local base = os.getenv("LOCALAPPDATA")
    local f = base and io.open(base .. "/ProjectWingman/Saved/Config/WindowsNoEditor/GameUserSettings.ini", "r")
    if not f then return "en" end
    local code
    for line in f:lines() do
        local c = line:match("^%s*Culture%s*=%s*([%w%-_]+)")
        if c then code = c break end
    end
    f:close()
    local short = code and code:lower():match("^(%a+)") or "en"
    return T[short] and short or "en"
end

local function Txt(key) return (T[LANG or "en"] or T.en)[key] or T.en[key] end

-- ===================== файлы демона =====================
local function ReadKV(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local t = {}
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = v end
    end
    f:close()
    return t
end

local function ReadFriends()
    local f = io.open(IO .. "friends.txt", "r")
    if not f then return {} end
    local list = {}
    for line in f:lines() do
        local sid, name, st, app, pw = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(%d+)\t?(%d*)")
        if sid then list[#list + 1] = {sid = sid, name = name, st = st, app = tonumber(app) or 0, pw = pw == "1"} end
    end
    f:close()
    -- сначала с модом, потом играющие в PW, потом онлайн, потом офлайн; внутри — по имени
    local function rank(x) return (x.pw and 0) or (x.app == 895870 and 1) or (x.st ~= "offline" and 2) or 3 end
    table.sort(list, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

local function Cmd(line)
    local f = io.open(IO .. "cmd.txt", "a")
    if f then f:write(line .. "\n") f:close() end
    L("команда демону: " .. line)
end

-- ===================== виджеты =====================
local inst, btnClass, wbl = nil, nil, nil
local page = {key = nil, canvas = nil, main = nil, list = {}}
local panelOpen = false
local status = {}
local friends = {}
local lastUI, lastFiles = 0, 0
local pressedPrev = {}

local function Instance()
    if inst and S(function() return inst:IsValid() end) then return inst end
    inst = FindFirstOf("WingmanInstance_C")
    return inst
end

local function ButtonClass()
    if btnClass and S(function() return btnClass:IsValid() end) then return btnClass end
    btnClass = StaticFindObject(BTN_CLASS)
    if not (btnClass and S(function() return btnClass:IsValid() end)) then
        local ok, c = pcall(LoadAsset, BTN_CLASS)
        btnClass = ok and c or nil
    end
    return btnClass
end

local function CurrentPage()
    local i = Instance()
    if not i then return nil end
    local comp = S(function() return i.GlobalUIPrimary end)
    local w = comp and S(function() return comp:GetUserWidgetObject() end)
    if w and S(function() return w:IsValid() end) then return w end
    local w2 = S(function() return i.Global2DUIPrimary end)
    if w2 and S(function() return w2:IsValid() end) then return w2 end
end

local function FindCanvas(w)
    local cur = S(function() return w.WidgetTree.RootWidget end)
    for _ = 1, 8 do
        if not cur then return nil end
        local c = S(function() return cur:GetClass():GetFName():ToString() end)
        if c == "CanvasPanel" then return cur end
        cur = S(function() return cur:GetChildAt(0) end)
    end
end

local function NewButton(canvas, text, x, y, w, h)
    local cls = ButtonClass()
    if not cls then return nil end
    wbl = wbl or StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local pc = FindFirstOf("PlayerController")
    local b = S(function() return wbl:Create(page.widget, cls, pc) end)
    if not (b and S(function() return b:IsValid() end)) then return nil end
    pcall(function() b.ButtonText:SetText(FText(text)) end)
    local slot = S(function() return canvas:AddChildToCanvas(b) end)
    if slot then
        pcall(function() slot:SetPosition({X = x, Y = y}) end)
        pcall(function() slot:SetSize({X = w or W, Y = h or H}) end)
    end
    pcall(function() b:SetVisibility(0) end)
    pcall(function() b:SetRenderOpacity(1.0) end)
    pcall(function() b:ReAnim() end)
    return b
end

local function SetText(b, text)
    if b and S(function() return b:IsValid() end) then pcall(function() b.ButtonText:SetText(FText(text)) end) end
end

local function Remove(b)
    if b and S(function() return b:IsValid() end) then pcall(function() b:RemoveFromParent() end) end
end

local function ClearList()
    for _, it in ipairs(page.list) do Remove(it.btn) end
    page.list = {}
    if page.listBg then Remove(page.listBg) page.listBg = nil end
end

-- нажатие = переход «нажата -> отпущена» (опрос только наших кнопок)
local function Clicked(id, b)
    local now = b and (S(function() return b.Button_96:IsPressed() end) or S(function() return b:IsPressed() end)) or false
    local was = pressedPrev[id]
    pressedPrev[id] = now
    return was and not now
end

-- ===================== логика =====================
local function DaemonAlive()
    local t = tonumber(status.t or "")
    return t and (os.time() - t) < 5
end

local function MainText()
    if not DaemonAlive() then return Txt("off") end
    if status.state == "connected" then return Txt("wing") .. (status.peer_name or "") .. (status.ping_ms and status.ping_ms ~= "-1" and ("  " .. status.ping_ms .. " MS") or "") end
    if status.state == "inviting" then return Txt("sent") .. (status.peer_name or "") end
    if status.state == "invited" then return Txt("accept") .. (status.invite_name or "") end
    return panelOpen and Txt("close") or Txt("add")
end

local function MainY() return Y0 end
-- список друзей ложится поверх кнопки готовности (со своей подложкой): открыт список — кнопки готовности не видно
local function ListY() return Y0 + GAP end

-- тёмная подложка под список (в ангаре список ложится на текст игры и сливается с ним)
local function ListBackground(count)
    if GAME_STATE ~= "hangar" or not page.canvas then return end
    local bc = StaticFindObject("/Script/UMG.Border")
    local ok, b = pcall(function() return StaticConstructObject(bc, page.widget) end)
    if not (ok and b and S(function() return b:IsValid() end)) then return end
    pcall(function() b:SetBrushColor({R = 0, G = 0, B = 0, A = 0.9}) end)
    local slot = S(function() return page.canvas:AddChildToCanvas(b) end)
    if slot then
        pcall(function() slot:SetPosition({X = X - 12, Y = ListY() - 10}) end)
        pcall(function() slot:SetSize({X = W + 24, Y = count * GAP + 12}) end)
    end
    page.listBg = b
end

local function BuildList()
    ClearList()
    if not page.canvas then return end
    local nItems = (status.state == "invited" or status.state == "connected" or status.state == "inviting" or #friends == 0) and 1 or math.min(MAX_FRIENDS, #friends)
    ListBackground(nItems)
    local y = ListY()
    if status.state == "invited" then
        local b = NewButton(page.canvas, Txt("decline"), X, y)
        page.list[#page.list + 1] = {btn = b, action = "decline"}
        return
    end
    if status.state == "connected" or status.state == "inviting" then
        local b = NewButton(page.canvas, Txt("leave"), X, y)
        page.list[#page.list + 1] = {btn = b, action = "leave"}
        return
    end
    if #friends == 0 then
        page.list[#page.list + 1] = {btn = NewButton(page.canvas, Txt("none"), X, y), action = nil}
        return
    end
    for i = 1, math.min(MAX_FRIENDS, #friends) do
        local fr = friends[i]
        local tag = fr.pw and Txt("mod") or (fr.app == 895870 and Txt("ingame")) or (fr.st ~= "offline" and Txt("online")) or Txt("offline")
        local b = NewButton(page.canvas, fr.name .. "  [" .. tag .. "]", X, y)
        page.list[#page.list + 1] = {btn = b, action = "invite " .. fr.sid}
        y = y + GAP
    end
end

local function OnMainClick()
    if not DaemonAlive() then return end
    if status.state == "invited" then Cmd("accept") panelOpen = false ClearList() return end
    panelOpen = not panelOpen
    if panelOpen then friends = ReadFriends() BuildList() else ClearList() end
end

-- ===================== барьер «Launch» в ангаре =====================
-- В коопе штатная кнопка вылета (HangarStatic.SortieButton) выключена; вместо неё наша «ГОТОВ К ВЫЛЕТУ».
-- Вылет (Sortie) запускается у обоих, только когда оба нажали «готов»; состояние партнёра приходит как status.p_ready.
local hangarPawn = nil
local myReady, fired, gateDisabled = false, false, false
local testPeerReady = false      -- F4: имитация «партнёр подтвердил» (проверка без друга)
-- Прямоугольник виджета в канве: из CanvasPanelSlot (если родитель — канва)
local function SlotRect(w)
    local slot = S(function() return w.Slot end)
    local cls = slot and S(function() return slot:GetClass():GetFName():ToString() end)
    if cls == "CanvasPanelSlot" then
        local pos = S(function() return slot:GetPosition() end)
        local size = S(function() return slot:GetSize() end)
        if pos and size then return pos.X, pos.Y, size.X, size.Y, cls end
    end
    return nil, nil, nil, nil, cls
end

local sbLogged = false
-- звук нажатия: штатная кнопка играет его через WingmanFunctionLibrary:WingmanPlayUISound(индекс 0..5); какой индекс = «подтверждение»,
-- не известно — по умолчанию 1 (скажи, если звук другой, переберём)
local CLICK_SOUND = 1
local function PlayClick(ctx)
    local lib = FindFirstOf("WingmanFunctionLibrary_C") or S(function() return FindObject("WingmanFunctionLibrary_C", "Default__WingmanFunctionLibrary_C") end)
    if not (lib and S(function() return lib:IsValid() end)) then L("звук: WingmanFunctionLibrary не найдена") return end
    local ok, e = pcall(function() lib:WingmanPlayUISound(CLICK_SOUND, ctx) end)
    if not ok then L("звук: WingmanPlayUISound ошибка: " .. tostring(e)) end
end
local gateBtn, gateBox, sbPrevVis = nil, nil, nil
local gateAdjusted = false     -- наша кнопка LAUNCH (живёт в том же VerticalBox, что и штатная)

-- кнопка без добавления в канву (её кладём в контейнер сами)
local function MakeButton(text)
    local cls = ButtonClass()
    if not cls then return nil end
    wbl = wbl or StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local pc = FindFirstOf("PlayerController")
    local b = S(function() return wbl:Create(page.widget, cls, pc) end)
    if not (b and S(function() return b:IsValid() end)) then return nil end
    pcall(function() b.ButtonText:SetText(FText(text)) end)
    pcall(function() b.ButtonText:SetJustification(1) end)
    pcall(function() b:SetVisibility(0) end)
    pcall(function() b:SetRenderOpacity(1.0) end)
    pcall(function() b:ReAnim() end)
    return b
end

-- копия штатной кнопки Launch: UButton с тем же стилем (WidgetStyle) и текстом того же шрифта по центру
local function MakeLaunchButton(hs, sb, word)
    local btnC, tbC = StaticFindObject("/Script/UMG.Button"), StaticFindObject("/Script/UMG.TextBlock")
    local okb, b = pcall(function() return StaticConstructObject(btnC, hs) end)
    local okt, tb = pcall(function() return StaticConstructObject(tbC, hs) end)
    if not (okb and okt and b and tb and S(function() return b:IsValid() end) and S(function() return tb:IsValid() end)) then return nil end
    pcall(function() b:SetStyle(sb.WidgetStyle) end)
    -- SetStyle целиком на структуре не применяется (кнопка остаётся серой) — копируем кисти по одной
    do
        local ws, ows = S(function() return b.WidgetStyle end), S(function() return sb.WidgetStyle end)
        local okN = 0
        if ws and ows then
            for _, n in ipairs({"Normal", "Hovered", "Pressed", "Disabled", "NormalPadding", "PressedPadding"}) do
                if pcall(function() ws[n] = ows[n] end) then okN = okN + 1 end
            end
        end
        pcall(function() b:SetStyle(ws) end)
        -- на случай, если кисти не скопировались: серую заливку делаем почти прозрачной
        pcall(function() b:SetBackgroundColor({R = 0, G = 0, B = 0, A = 0.15}) end)
        L("ангар: стиль штатной кнопки скопирован по частям: " .. okN .. " из 6")
    end
    local tpl = S(function() return hs.SortieLaunchButton end)
    local tf = tpl and S(function() return tpl.Font end)
    local nf = S(function() return tb.Font end)
    if tf and nf then
        pcall(function() nf.FontObject = tf.FontObject end)
        pcall(function() nf.Size = tf.Size end)
        pcall(function() nf.TypefaceFontName = tf.TypefaceFontName end)
        pcall(function() nf.LetterSpacing = tf.LetterSpacing end)
        pcall(function() tb:SetFont(nf) end)
    end
    if tpl then pcall(function() tb:SetColorAndOpacity(tpl.ColorAndOpacity) end) end
    pcall(function() tb:SetText(FText(word)) end)
    pcall(function() tb:SetJustification(1) end)          -- по центру
    local okc, cslot = pcall(function() return b:AddChild(tb) end)
    if okc and cslot then
        pcall(function() cslot:SetHorizontalAlignment(2) end)     -- по центру кнопки (0 Fill, 1 Left, 2 Center, 3 Right)
        pcall(function() cslot:SetVerticalAlignment(2) end)
    end
    if not okc then L("ангар: UButton:AddChild не сработал — запасная кнопка") return nil end
    L("ангар: создана копия кнопки Launch (UButton со стилем штатной)")
    return b
end

-- ===== наша кнопка LAUNCH =====
-- Раньше «копия UButton» вставлялась в колонку ангара ровно на место штатной (размер/позиция идеальны), но была серой без рамки.
-- Теперь тот же UButton (прозрачный) лежит в двух Border: внешний = тонкая светлая рамка, внутренний = тёмный фон. Наведение — оранжевая
-- рамка, звук — штатный UI-звук (S_UISelect), текст по центру шрифтом штатной кнопки.
local UISND = "/Game/Assets/Audio/UI/UI_New/S_UISelect_Cue.S_UISelect_Cue"
local gateOuter, gateInner, gateHover = nil, nil, false
local UISND2 = "/Game/Assets/Audio/UI/UI_New/S_UISelect.S_UISelect"
local sndLogged = 0
local sndMode = nil            -- какой способ воспроизведения сработал (запоминаем)
local function PlayUI(ctx)
    local lib = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local snd = StaticFindObject(UISND) or S(function() return LoadAsset(UISND) end)
    local snd2 = StaticFindObject(UISND2) or S(function() return LoadAsset(UISND2) end)
    local pc = FindFirstOf("PlayerController")
    if not lib then return end
    local tries = {}
    for _, sd in ipairs({snd, snd2}) do
        if sd then
            for _, cx in ipairs({pc, ctx}) do
                if cx then
                    tries[#tries + 1] = function() lib:PlaySound2D(cx, sd, 1.0, 1.0, 0.0) end
                    tries[#tries + 1] = function() lib:PlaySound2D(cx, sd, 1.0, 1.0, 0.0, nil, nil, true) end
                    tries[#tries + 1] = function() lib:SpawnSound2D(cx, sd, 1.0, 1.0, 0.0, nil, false, true) end
                end
            end
        end
    end
    local start = sndMode or 1
    for i = start, #tries do
        local ok = pcall(tries[i])
        if ok then
            if sndMode ~= i then sndMode = i L("звук: сработал способ №" .. i .. " из " .. #tries) end
            return
        end
        if sndMode then break end
    end
    if sndLogged < 2 then sndLogged = sndLogged + 1 L("звук: ни один способ не сработал (" .. #tries .. " попыток)") end
end

local FRAME, FRAME_HOT = {R = 0.8, G = 0.8, B = 0.8, A = 1}, {R = 1.0, G = 0.6, B = 0.1, A = 1}

local function MakeLaunchBox(hs, sb, word)
    local function New(path)
        local cls = StaticFindObject(path)
        local ok, o = pcall(function() return StaticConstructObject(cls, hs) end)
        if ok and o and S(function() return o:IsValid() end) then return o end
    end
    local outer, inner, btn, tb = New("/Script/UMG.Border"), New("/Script/UMG.Border"), New("/Script/UMG.Button"), New("/Script/UMG.TextBlock")
    if not (outer and inner and btn and tb) then return nil end
    pcall(function() outer:SetBrushColor(FRAME) end)
    pcall(function() outer:SetPadding({Left = 1, Top = 1, Right = 1, Bottom = 1}) end)
    pcall(function() inner:SetBrushColor({R = 0, G = 0, B = 0, A = 0.85}) end)
    pcall(function() inner:SetPadding({Left = 0, Top = 0, Right = 0, Bottom = 0}) end)
    pcall(function() btn:SetBackgroundColor({R = 0, G = 0, B = 0, A = 0}) end)     -- серая заливка стиля по умолчанию не нужна
    local tpl = S(function() return hs.SortieLaunchButton end)
    local tf = tpl and S(function() return tpl.Font end)
    local nf = S(function() return tb.Font end)
    if tf and nf then
        pcall(function() nf.FontObject = tf.FontObject end)
        pcall(function() nf.Size = tf.Size end)
        pcall(function() nf.TypefaceFontName = tf.TypefaceFontName end)
        pcall(function() nf.LetterSpacing = tf.LetterSpacing end)
        pcall(function() tb:SetFont(nf) end)
    end
    -- цвет текста — как у BACK (белый), а не оранжевый шаблон Launch
    local back = S(function() return hs.BackToMenu:GetChildAt(0) end)
    local bc = back and S(function() return back.ColorAndOpacity end)
    if bc then pcall(function() tb:SetColorAndOpacity(bc) end) elseif tpl then pcall(function() tb:SetColorAndOpacity(tpl.ColorAndOpacity) end) end
    pcall(function() tb:SetText(FText(word)) end)
    pcall(function() tb:SetJustification(1) end)
    local okc, cslot = pcall(function() return btn:AddChild(tb) end)
    if okc and cslot then
        pcall(function() cslot:SetHorizontalAlignment(2) end)
        pcall(function() cslot:SetVerticalAlignment(2) end)
    end
    local ok1 = pcall(function() inner:AddChild(btn) end)
    local ok2 = pcall(function() outer:AddChild(inner) end)
    if not (okc and ok1 and ok2) then return nil end
    return outer, inner, btn
end

local function HangarGate()
    local hp = hangarPawn
    local hs = hp and S(function() return hp:IsValid() and hp.WidgetRef end)
    local sb = hs and S(function() return hs.SortieButton end)
    if status.state ~= "connected" or not DaemonAlive() then
        if page.launch then Remove(page.launch) page.launch = nil end
        if gateOuter then Remove(gateOuter) gateOuter, gateInner, gateBtn = nil, nil, nil end
        if sb and gateDisabled then
            pcall(function() sb:SetIsEnabled(true) end)
            pcall(function() sb:SetVisibility(sbPrevVis or 0) end)
            gateDisabled = false
        end
        myReady, fired = false, false
        return
    end
    if not (sb and page.canvas) then return end
    pcall(function() sb:SetIsEnabled(false) end)
    gateDisabled = true
    if not (page.launch and S(function() return page.launch:IsValid() end)) then
        page.launch = NewButton(page.canvas, Txt("wnot"), X, Y0 + GAP)          -- статус партнёра под его плашкой (только показ)
    end
    local box = S(function() return sb:GetParent() end)
    if not gateOuter or not S(function() return gateOuter:IsValid() end) then
        gateOuter, gateInner, gateBtn = nil, nil, nil
        local word = S(function() return hs.SortieLaunchButton:GetText():ToString() end) or "LAUNCH"
        local o, i, b = MakeLaunchBox(hs, sb, word)
        if o and box then
            gateOuter, gateInner, gateBtn = o, i, b
            -- вставка после штатной: всё, что ниже штатной в колонке, временно снимается и ставится обратно после нашей
            local sbName = S(function() return sb:GetFullName() end)
            local n = S(function() return box:GetChildrenCount() end) or 0
            local idx = nil
            for k = 0, n - 1 do
                local c = S(function() return box:GetChildAt(k) end)
                if c and S(function() return c:GetFullName() end) == sbName then idx = k break end
            end
            local tail = {}
            if idx then
                for k = idx + 1, n - 1 do
                    local c = S(function() return box:GetChildAt(k) end)
                    local sl = c and S(function() return c.Slot end)
                    if c and sl then
                        tail[#tail + 1] = {c = c, ha = S(function() return sl.HorizontalAlignment end), va = S(function() return sl.VerticalAlignment end),
                            pad = S(function() return sl.Padding end), size = S(function() return sl.Size end)}
                    end
                end
                for _, t in ipairs(tail) do pcall(function() t.c:RemoveFromParent() end) end
            end
            local ok, slot = pcall(function() return box:AddChildToVerticalBox(gateOuter) end)
            local ss = S(function() return sb.Slot end)
            if ok and slot and ss then
                pcall(function() slot:SetHorizontalAlignment(ss.HorizontalAlignment) end)
                pcall(function() slot:SetVerticalAlignment(ss.VerticalAlignment) end)
                pcall(function() slot:SetPadding(ss.Padding) end)
                pcall(function() slot:SetSize(ss.Size) end)
            end
            for _, t in ipairs(tail) do
                local ok2, sl2 = pcall(function() return box:AddChildToVerticalBox(t.c) end)
                if ok2 and sl2 then
                    if t.ha ~= nil then pcall(function() sl2:SetHorizontalAlignment(t.ha) end) end
                    if t.va ~= nil then pcall(function() sl2:SetVerticalAlignment(t.va) end) end
                    if t.pad then pcall(function() sl2:SetPadding(t.pad) end) end
                    if t.size then pcall(function() sl2:SetSize(t.size) end) end
                end
            end
            L("ангар: LAUNCH (рамка + кнопка) вставлен после штатной (индекс " .. tostring(idx) .. " из " .. n .. "), переставлено " .. #tail)
        else
            L("ангар: не удалось собрать кнопку LAUNCH")
        end
    end
    local vis = S(function() return sb:GetVisibility() end)
    if vis ~= 1 then sbPrevVis = vis end
    pcall(function() sb:SetVisibility(1) end)                  -- штатная свёрнута, наша занимает её место
    page.launchBtn = gateBtn
    local peerReady = status.p_ready == "1" or testPeerReady
    local GREEN, AMBER, WHITE = {R = 0.25, G = 1.0, B = 0.35, A = 1}, {R = 1.0, G = 0.75, B = 0.1, A = 1}, {R = 1, G = 1, B = 1, A = 1}
    SetText(page.launch, peerReady and Txt("wready") or Txt("wnot"))
    pcall(function() page.launch:SetColorAndOpacity(peerReady and GREEN or WHITE) end)
    if gateBtn then
        -- наведение: звук и оранжевая рамка; состояние готовности красит текст/кнопку
        local hovered = S(function() return gateBtn:IsHovered() end) == true
        if hovered ~= gateHover then
            gateHover = hovered
            if hovered then PlayUI(hs) end
        end
        local hot = hovered or myReady
        pcall(function() gateOuter:SetBrushColor(hot and FRAME_HOT or FRAME) end)
        pcall(function() gateInner:SetBrushColor(hot and {R = 0.45, G = 0.22, B = 0.0, A = 0.95} or {R = 0, G = 0, B = 0, A = 0.85}) end)
        pcall(function() gateBtn:SetColorAndOpacity(hot and FRAME_HOT or (peerReady and GREEN or WHITE)) end)
    end
    -- блок данных миссии игры («Reconnaissance data») опускаем под наши плашки: данных может быть много
    pcall(function() hs.ReconData:SetRenderTranslation({X = 0, Y = 170}) end)
    if gateBtn and Clicked("launchBtn", gateBtn) then
        PlayUI(hs)
        myReady, fired = not myReady, false
        Cmd("set ready " .. (myReady and 1 or 0))
    end
    -- запуск: оба нажали «готов», либо партнёр уже запустил вылет (go) — тогда идём за ним, даже если свою готовность сняли
    -- go = метка времени запуска партнёра (os.time); свежая — до 25 с, иначе это старый сигнал
    local goT = tonumber(status.p_go or "")
    local partnerGo = goT ~= nil and goT > 1000 and math.abs(os.time() - goT) < 25
    if ((myReady and peerReady) or partnerGo) and not fired then
        fired = true
        Cmd("set go " .. os.time())
        L("барьер: " .. (partnerGo and "партнёр уже запустил вылет" or "оба готовы") .. " — запускаю вылет")
        pcall(function() sb:SetIsEnabled(true) end)
        local ok, e = pcall(function() hs:Sortie() end)
        if not ok then
            L("Sortie() не сработал (" .. tostring(e) .. "), пробую HangarActor:StartMission()")
            pcall(function() hp:StartMission() end)
        end
    end
end

local lastState = nil
local function UITick()
    local now = os.clock()
    if now - lastUI < UI_DT then return end
    lastUI = now
    -- файлы демона раз в 0.5 с
    if now - lastFiles > 0.5 then
        lastFiles = now
        status = ReadKV(IO .. "status.txt")
        if panelOpen and status.state == "idle" then
            local fl = ReadFriends()
            if #fl ~= #friends then friends = fl BuildList() else friends = fl end
        end
    end
    -- текущая страница
    local w = CurrentPage()
    if not w then return end
    local key = S(function() return w:GetFullName() end)
    if key ~= page.key or not (page.main and S(function() return page.main:IsValid() end) and S(function() return page.main:GetParent() end)) then
        page = {key = key, widget = w, canvas = FindCanvas(w), main = nil, list = {}}
        if not page.canvas then return end
        if not LANG then
            -- язык по тексту живой кнопки главного меню, иначе из конфига
            LANG = LangFromText(S(function() return w.VerticalScrollBox:GetChildAt(0).ButtonText:GetText():ToString() end)) or LangFromIni()
            L("язык интерфейса: " .. LANG)
        end
        page.main = NewButton(page.canvas, MainText(), X, MainY())
        if panelOpen then friends = ReadFriends() BuildList() end
        L("кнопка добавлена на страницу " .. tostring(key and key:match("[^%.]+$")))
    end
    SetText(page.main, MainText())
    -- смена состояния сессии перестраивает список
    if status.state ~= lastState then
        lastState = status.state
        if status.state == "invited" then panelOpen = true end
        if panelOpen then friends = ReadFriends() BuildList() end
    end
    -- плашка «выбор хоста» (у гостя): режим/миссия хоста, зелёная — совпадает с нашим выбором, жёлтая — выбери то же
    do
        local show = status.state == "connected" and DaemonAlive() and status.role ~= "host" and status.p_sel and status.p_sel ~= ""
        if not show then
            if page.selLabel then Remove(page.selLabel) page.selLabel = nil end
        else
            local ff, id, name = status.p_sel:match("^(%d)%s+(%S+)%s*(.*)$")
            if ff then
                if not (page.selLabel and S(function() return page.selLabel:IsValid() end)) then
                    page.selLabel = NewButton(page.canvas, "…", X, GAME_STATE == "hangar" and (Y0 + GAP * 2) or (Y0 + GAP))
                end
                local same = COOP_SEL and COOP_SEL.id == id and COOP_SEL.ff == (ff == "1")
                local title = (ff == "1") and Txt("hfree") or ((name ~= "" and name or id):upper())
                SetText(page.selLabel, Txt("hsel") .. title .. "  [" .. (same and Txt("hsame") or Txt("hdiff")) .. "]")
                local col = same and {R = 0.25, G = 1.0, B = 0.35, A = 1} or {R = 1.0, G = 0.75, B = 0.1, A = 1}
                pcall(function() page.selLabel:SetColorAndOpacity(col) end)
            end
        end
    end
    if GAME_STATE == "hangar" then
        local okG, eG = pcall(HangarGate)
        if not okG then L("ошибка барьера: " .. tostring(eG)) end
    end
    if Clicked("main", page.main) then OnMainClick() end
    for i, it in ipairs(page.list) do
        if it.action and Clicked("l" .. i, it.btn) then
            Cmd(it.action)
            panelOpen = it.action:find("^invite") ~= nil
            ClearList()
            break
        end
    end
end

-- ===================== регистрация хуков по пешкам меню =====================
local hookedClasses = {}
local UI_STATES = {menu = true, hangar = true, staging = true, select = true, briefing = true, debrief = true}

local prevState, leftFlightAt = nil, nil
local function AnnounceFollow(state)
    -- вышли из полёта: куда попали, туда зовём партнёра (retry — снова полёт, hangar — ангар, menu — главное меню)
    if prevState == "flight" and state ~= "flight" then leftFlightAt = os.time() end
    if state == "loading" or state == "boot" then prevState = state ~= "loading" and state or prevState return end
    if leftFlightAt and os.time() - leftFlightAt < 60 and status.state == "connected" and DaemonAlive() then
        local kind = (state == "flight" and "retry") or (state == "hangar" and "hangar") or (state == "menu" and "menu")
        local fresh = FOLLOW_DONE and math.abs(os.time() - FOLLOW_DONE) < 60        -- сами идём за партнёром — не эхо
        if kind and not fresh then
            Cmd("set follow " .. kind .. " " .. os.time())
            L("объявил партнёру выбор: " .. kind)
        end
        leftFlightAt = nil
    end
    prevState = state
end

function UI_OnState(state, pawn)
    pcall(AnnounceFollow, state)
    -- новый заход в ангар или выход из него: готовность (своя и имитация F4) сбрасывается, партнёру уходит «не готов»
    local wasFired = fired
    if myReady or testPeerReady or fired then
        Cmd("set ready 0")
        Cmd("set go 0")
    end
    if state == "hangar" then hangarPawn = pawn end
    myReady, fired, testPeerReady = false, false, false
    -- вылет в обход нашего барьера (клавиатура/геймпад/штатная кнопка): зовём партнёра за собой, если он ждёт в ангаре
    if state == "flight" and not wasFired and status.state == "connected" and DaemonAlive() then
        Cmd("set go " .. os.time())
        L("вылет без барьера — шлю партнёру сигнал go")
    end
    if not UI_STATES[state] or not pawn then return end
    local full = S(function() return pawn:GetClass():GetFullName() end)
    local path = full and (full:match("^%S+%s+(.+)$") or full)
    if not path or hookedClasses[path] then return end
    hookedClasses[path] = true
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function()
            local ok, e = pcall(RegisterHook, path .. ":ReceiveTick", function() end, function()
                if not UI_STATES[GAME_STATE] then return end
                local ok2, e2 = pcall(UITick)
                if not ok2 then L("ошибка UITick: " .. tostring(e2)) end
            end)
            L("хук UI на " .. path:match("[^%.]+$") .. ": " .. (ok and "OK" or tostring(e)))
        end)
    end)
end

-- запасные клавиши (работают и без кликов мышью)
RegisterKeyBind(Key.F4, function() ExecuteInGameThread(function() testPeerReady = not testPeerReady L("F4: имитация «партнёр готов» = " .. tostring(testPeerReady)) end) end)
RegisterKeyBind(Key.F7, function() ExecuteInGameThread(function() pcall(OnMainClick) end) end)
RegisterKeyBind(Key.F8, function() ExecuteInGameThread(function() if status.state == "invited" then Cmd("accept") end end) end)
RegisterKeyBind(Key.F9, function() ExecuteInGameThread(function()
    if status.state == "invited" then Cmd("decline") elseif status.state == "connected" or status.state == "inviting" then Cmd("leave") end
end) end)
L("загружен (F7 — друзья, F8 — принять, F9 — отклонить/выйти)")
