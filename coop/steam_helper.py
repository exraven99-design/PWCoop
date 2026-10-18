"""Steam-демон co-op для Project Wingman: общается со Steam через steam_api64.dll игры (плоский C-API, ctypes).
Не требует компиляции и не трогает процесс игры (плагины Advanced Sessions из Lua роняли игру).

Команды:
  python steam_helper.py friends [--out friends.txt]   # разовый список друзей
  python steam_helper.py selftest                      # проверка API без отправки чего-либо друзьям
  python steam_helper.py daemon --dir <Mods/PWCoop/io> # фоновый режим: друзья, приглашения, P2P, обмен файлами с Lua
  python steam_helper.py daemon --dir <...> --loopback # самопроверка на одном ПК (призрак = свой самолёт +400 м)

Обмен с Lua-модом (папка --dir):
  out.txt     Lua -> демон: последняя строка состояния своего самолёта (как в проверенном мосте)
  in.txt      демон -> Lua: последняя строка состояния напарника (атомарная замена файла)
  cmd.txt     Lua -> демон: команды, по строке: invite <steamid> | accept | decline | leave
  status.txt  демон -> Lua: key=value (me_id, me_name, state, peer_id, peer_name, ping_ms, rx_age, invite_from, invite_name)
  friends.txt демон -> Lua: steamid<TAB>имя<TAB>статус<TAB>appid<TAB>pwcoop(0/1), раз в 10 с

P2P: ISteamNetworkingMessages (relay Steam, без IP/портов).
  канал 0 — состояние (ненадёжно, ~30 Гц), канал 1 — управление (надёжно):
  HELLO <имя> | INVITE <имя> | ACCEPT | DECLINE | BYE | PING <t> | PONG <t>
"""
import argparse
import ctypes
import os
import sys
import tempfile
import time

APPID = 895870
DLL_REL = os.path.join("Engine", "Binaries", "ThirdParty", "Steamworks", "Steamv151", "Win64", "steam_api64.dll")
DLL = os.path.join(r"C:\Program Files (x86)\Steam\steamapps\common\Project Wingman", DLL_REL)     # по умолчанию (разработка); при --dir вычисляется
K_FRIEND_FLAG_IMMEDIATE = 0x04
STATES = {0: "offline", 1: "online", 2: "busy", 3: "away", 4: "snooze", 5: "trade", 6: "play"}

# флаги отправки ISteamNetworkingMessages
SEND_UNRELIABLE = 0
SEND_RELIABLE = 8
SEND_AUTORESTART = 32
CH_STATE, CH_CTRL, CH_AI = 0, 1, 2     # CH_AI: снапшоты подвижных врагов хоста (надёжный канал, ~4 Гц)

# идентификаторы колбэков
CB_SESSION_REQUEST = 1251     # SteamNetworkingMessagesSessionRequest_t
CB_SESSION_FAILED = 1252      # SteamNetworkingMessagesSessionFailed_t
CB_RICH_JOIN = 337            # GameRichPresenceJoinRequested_t

IDENT_SIZE = 136              # SteamNetworkingIdentity: int eType, int cbSize, union[128]
IDENT_TYPE_STEAMID = 16


class FriendGameInfo(ctypes.Structure):
    _fields_ = [("gameID", ctypes.c_uint64), ("gameIP", ctypes.c_uint32), ("gamePort", ctypes.c_uint16),
                ("queryPort", ctypes.c_uint16), ("lobby", ctypes.c_uint64)]


class CallbackMsg(ctypes.Structure):
    _fields_ = [("hSteamUser", ctypes.c_int32), ("iCallback", ctypes.c_int32),
                ("pubParam", ctypes.c_void_p), ("cubParam", ctypes.c_int32)]


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class Steam:
    def __init__(self, manual_dispatch=False):
        tmp = tempfile.mkdtemp(prefix="pw_steam_")      # steam_appid.txt во временной папке, игру не трогаем
        with open(os.path.join(tmp, "steam_appid.txt"), "w") as f:
            f.write(str(APPID))
        os.chdir(tmp)
        os.environ["SteamAppId"] = str(APPID)
        os.environ["SteamGameId"] = str(APPID)
        d = self.d = ctypes.CDLL(DLL)
        self._proto()
        if not d.SteamAPI_Init():
            raise SystemExit("SteamAPI_Init не удалось: запущен ли Steam-клиент и есть ли у аккаунта эта игра?")
        self.manual = manual_dispatch
        if manual_dispatch:
            d.SteamAPI_ManualDispatch_Init()
            self.pipe = d.SteamAPI_GetHSteamPipe()
        self.fr = ctypes.c_void_p(d.SteamAPI_SteamFriends_v017())
        self.user = ctypes.c_void_p(d.SteamAPI_SteamUser_v021())
        self.msgs = ctypes.c_void_p(d.SteamAPI_SteamNetworkingMessages_SteamAPI_v002())
        self.utils = ctypes.c_void_p(d.SteamAPI_SteamNetworkingUtils_SteamAPI_v003())
        self.me = d.SteamAPI_ISteamUser_GetSteamID(self.user)
        self.my_name = d.SteamAPI_ISteamFriends_GetPersonaName(self.fr).decode("utf-8", "replace")

    def _proto(self):
        d, vp, u64, ci, cb, cs = self.d, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_int, ctypes.c_bool, ctypes.c_char_p
        def P(name, res, *args):
            fn = getattr(d, name)
            fn.restype = res
            fn.argtypes = list(args)
        P("SteamAPI_Init", cb)
        P("SteamAPI_Shutdown", None)
        P("SteamAPI_RunCallbacks", None)
        P("SteamAPI_ManualDispatch_Init", None)
        P("SteamAPI_GetHSteamPipe", ctypes.c_int32)
        P("SteamAPI_ManualDispatch_RunFrame", None, ctypes.c_int32)
        P("SteamAPI_ManualDispatch_GetNextCallback", cb, ctypes.c_int32, ctypes.POINTER(CallbackMsg))
        P("SteamAPI_ManualDispatch_FreeLastCallback", None, ctypes.c_int32)
        P("SteamAPI_SteamFriends_v017", vp)
        P("SteamAPI_SteamUser_v021", vp)
        P("SteamAPI_SteamNetworkingMessages_SteamAPI_v002", vp)
        P("SteamAPI_SteamNetworkingUtils_SteamAPI_v003", vp)
        P("SteamAPI_ISteamUser_GetSteamID", u64, vp)
        P("SteamAPI_ISteamFriends_GetPersonaName", cs, vp)
        P("SteamAPI_ISteamFriends_GetFriendCount", ci, vp, ci)
        P("SteamAPI_ISteamFriends_GetFriendByIndex", u64, vp, ci, ci)
        P("SteamAPI_ISteamFriends_GetFriendPersonaName", cs, vp, u64)
        P("SteamAPI_ISteamFriends_GetFriendPersonaState", ci, vp, u64)
        P("SteamAPI_ISteamFriends_GetFriendGamePlayed", cb, vp, u64, ctypes.POINTER(FriendGameInfo))
        P("SteamAPI_ISteamFriends_SetRichPresence", cb, vp, cs, cs)
        P("SteamAPI_ISteamFriends_GetFriendRichPresence", cs, vp, u64, cs)
        P("SteamAPI_ISteamFriends_InviteUserToGame", cb, vp, u64, cs)
        P("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", None, vp)
        P("SteamAPI_SteamNetworkingIdentity_SetSteamID64", None, vp, u64)
        P("SteamAPI_SteamNetworkingIdentity_GetSteamID64", u64, vp)
        P("SteamAPI_ISteamNetworkingMessages_SendMessageToUser", ci, vp, vp, vp, ctypes.c_uint32, ci, ci)
        P("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", ci, vp, ci, ctypes.POINTER(vp), ci)
        P("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", cb, vp, vp)
        P("SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", cb, vp, vp)
        P("SteamAPI_SteamNetworkingMessage_t_Release", None, vp)

    # ---------- друзья ----------
    def friends(self):
        d, fr = self.d, self.fr
        rows = []
        for i in range(d.SteamAPI_ISteamFriends_GetFriendCount(fr, K_FRIEND_FLAG_IMMEDIATE)):
            sid = d.SteamAPI_ISteamFriends_GetFriendByIndex(fr, i, K_FRIEND_FLAG_IMMEDIATE)
            name = (d.SteamAPI_ISteamFriends_GetFriendPersonaName(fr, sid) or b"").decode("utf-8", "replace")
            st = d.SteamAPI_ISteamFriends_GetFriendPersonaState(fr, sid)
            info = FriendGameInfo()
            playing = d.SteamAPI_ISteamFriends_GetFriendGamePlayed(fr, sid, ctypes.byref(info))
            app = (info.gameID & 0xFFFFFF) if playing else 0
            rp = d.SteamAPI_ISteamFriends_GetFriendRichPresence(fr, sid, b"pwcoop") or b""
            rows.append((sid, name, STATES.get(st, str(st)), app, 1 if rp == b"1" else 0))
        return rows

    def name_of(self, sid):
        n = self.d.SteamAPI_ISteamFriends_GetFriendPersonaName(self.fr, sid)
        return (n or b"").decode("utf-8", "replace")

    def set_presence(self, key, value):
        return self.d.SteamAPI_ISteamFriends_SetRichPresence(self.fr, key.encode(), value.encode())

    def invite_native(self, sid, connect):
        return self.d.SteamAPI_ISteamFriends_InviteUserToGame(self.fr, sid, connect.encode())

    # ---------- P2P ----------
    def ident(self, sid):
        buf = ctypes.create_string_buffer(IDENT_SIZE)
        self.d.SteamAPI_SteamNetworkingIdentity_SetSteamID64(buf, sid)
        return buf

    def send(self, sid, channel, data, reliable):
        flags = (SEND_RELIABLE if reliable else SEND_UNRELIABLE) | SEND_AUTORESTART
        b = data.encode("utf-8") if isinstance(data, str) else data
        return self.d.SteamAPI_ISteamNetworkingMessages_SendMessageToUser(
            self.msgs, self.ident(sid), b, len(b), flags, channel)

    def receive(self, channel, maxn=64):
        """-> [(steamid, bytes)]; память сообщений освобождается Release."""
        arr = (ctypes.c_void_p * maxn)()
        n = self.d.SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(self.msgs, channel, arr, maxn)
        out = []
        for i in range(max(0, n)):
            p = arr[i]
            if not p:
                continue
            pdata = ctypes.c_void_p.from_address(p).value          # m_pData @0
            size = ctypes.c_int.from_address(p + 8).value           # m_cbSize @8
            sid = self.d.SteamAPI_SteamNetworkingIdentity_GetSteamID64(ctypes.c_void_p(p + 16))  # m_identityPeer @16
            data = ctypes.string_at(pdata, size) if pdata and size > 0 else b""
            out.append((sid, data))
            self.d.SteamAPI_SteamNetworkingMessage_t_Release(ctypes.c_void_p(p))
        return out

    def accept(self, ident_ptr):
        return self.d.SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(self.msgs, ident_ptr)

    def close(self, sid):
        return self.d.SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser(self.msgs, self.ident(sid))

    def callbacks(self):
        """Ручная диспетчеризация: -> [(id, bytes параметра)]."""
        if not self.manual:
            self.d.SteamAPI_RunCallbacks()
            return []
        d, out = self.d, []
        d.SteamAPI_ManualDispatch_RunFrame(self.pipe)
        msg = CallbackMsg()
        while d.SteamAPI_ManualDispatch_GetNextCallback(self.pipe, ctypes.byref(msg)):
            data = ctypes.string_at(msg.pubParam, msg.cubParam) if msg.pubParam and msg.cubParam > 0 else b""
            out.append((msg.iCallback, data, msg.pubParam))
            if msg.iCallback == CB_SESSION_REQUEST and msg.pubParam:
                # запрос сессии: identity лежит в начале структуры колбэка; принимаем только от того, кого ждём
                out[-1] = (msg.iCallback, data, ctypes.c_void_p(msg.pubParam))
                self.on_session_request(ctypes.c_void_p(msg.pubParam))
            d.SteamAPI_ManualDispatch_FreeLastCallback(self.pipe)
        return out

    def on_session_request(self, ident_ptr):   # переопределяется демоном
        pass

    def shutdown(self):
        self.d.SteamAPI_Shutdown()


# ---------------- файловый обмен с Lua ----------------
def read_line(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.readline().strip() or None
    except OSError:
        return None


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    for _ in range(10):                      # Lua может держать файл на чтение
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.003)


def take_commands(path):
    """Забирает команды из cmd.txt (переименование -> чтение -> удаление своей копии)."""
    if not os.path.exists(path):
        return []
    work = path + ".work"
    try:
        os.replace(path, work)
    except OSError:
        return []
    try:
        with open(work, "r", encoding="utf-8") as f:
            cmds = [l.strip() for l in f if l.strip()]
    finally:
        try:
            os.remove(work)
        except OSError:
            pass
    return cmds


class Daemon:
    def __init__(self, io_dir, loopback=False, watch_game=False):
        self.loopback = loopback
        self.watch_game = watch_game
        self.pflags = {}               # SET-флаги партнёра (ready, sel ...) -> значение
        self.role = ""                 # host (пригласил) | guest (принял) | loopback (самопроверка)
        self.last_ai = None
        self.t_watch = 0.0
        self.t_start = time.time()
        self.seen_game = False
        self.gone_since = None
        self.dir = os.path.abspath(io_dir)
        os.makedirs(self.dir, exist_ok=True)
        self.p = {k: os.path.join(self.dir, k + ".txt") for k in ("out", "in", "cmd", "status", "friends", "ai_out", "ai_in")}
        self.s = Steam(manual_dispatch=True)
        self.s.on_session_request = self.on_session_request
        self.s.d.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(self.s.utils)
        self.state = "idle"            # idle | inviting | invited | connected
        self.peer = 0
        self.invite_from = 0
        self.last_rx = 0.0
        self.ping_ms = -1
        self.last_out = None
        self.t_friends = 0.0
        self.t_ping = 0.0
        self.t_status = 0.0
        self.t_invite = 0.0
        log(f"демон: я {self.s.my_name} ({self.s.me}); обмен: {self.dir}")
        if loopback:
            # самопроверка на одном ПК: «напарник» = я сам, смещённый на 400 м вбок (Steam не используется)
            self.state, self.peer = "connected", self.s.me
            self.role = "loopback"
            # смещение призрака в метрах: первое число в Mods\PWCoop\loopback.txt (по умолчанию 400 м)
            self.lb_off = 40000
            try:
                with open(os.path.join(self.dir, os.pardir, "loopback.txt"), encoding="utf-8-sig") as fh:
                    self.lb_off = int(float(fh.read().split()[0]) * 100)
            except Exception:
                pass
            log(f"РЕЖИМ LOOPBACK: призрак = свой самолёт со смещением {self.lb_off // 100} м")
        self.s.set_presence("pwcoop", "1")
        self.s.set_presence("status", "Project Wingman — co-op")

    # принимаем сессию только от напарника или того, кто нас приглашает/кого мы пригласили
    def on_session_request(self, ident_ptr):
        sid = self.s.d.SteamAPI_SteamNetworkingIdentity_GetSteamID64(ident_ptr)
        if sid in (self.peer, self.invite_from) or self.state in ("idle", "inviting"):
            self.s.accept(ident_ptr)
            log(f"P2P: принята сессия от {self.s.name_of(sid)} ({sid})")
        else:
            log(f"P2P: отклонена сессия от {sid}")

    def ctrl(self, sid, text):
        r = self.s.send(sid, CH_CTRL, text, reliable=True)
        log(f"-> {sid} {text.split(' ')[0]} (EResult {r})")
        return r

    def handle_cmd(self, c):
        parts = c.split()
        if not parts:
            return
        op = parts[0].lower()
        if op == "invite" and len(parts) > 1:
            sid = int(parts[1])
            self.peer, self.state, self.t_invite = sid, "inviting", time.time()
            self.ctrl(sid, f"INVITE {self.s.my_name}")
            ok = self.s.invite_native(sid, f"+pwcoop {self.s.me}")     # штатное уведомление Steam
            log(f"приглашение {self.s.name_of(sid)}: P2P отправлено, Steam-уведомление: {ok}")
        elif op == "accept" and self.state == "invited" and self.invite_from:
            self.peer, self.state = self.invite_from, "connected"
            self.role = "guest"                    # принял приглашение — мир хоста главный
            self.ctrl(self.peer, "ACCEPT")
            self.ctrl(self.peer, f"HELLO {self.s.my_name}")
            self.invite_from = 0
        elif op == "decline" and self.invite_from:
            self.ctrl(self.invite_from, "DECLINE")
            self.invite_from, self.state = 0, "idle"
        elif op == "set" and len(parts) >= 2:
            # общий обмен флагами: ready 0/1, sel <режим> <id миссии> и т.п. (надёжно, партнёру)
            key = parts[1]
            val = " ".join(parts[2:])
            if self.loopback:
                if key != "ready":                           # готовность «партнёра» в самопроверке — вручную (F4 в ангаре)
                    self.pflags[key] = val.strip()           # остальное: «партнёр» = я сам
            elif self.peer and self.state == "connected":
                self.ctrl(self.peer, f"SET {key} {val}")
        elif op == "leave" and self.peer:
            self.ctrl(self.peer, "BYE")
            self.s.close(self.peer)
            self.peer, self.state, self.role, self.pflags = 0, "idle", "", {}
        else:
            log(f"команда пропущена: {c} (состояние {self.state})")

    def handle_ctrl(self, sid, text):
        cmd, _, arg = text.partition(" ")
        if cmd == "INVITE":
            if self.state == "connected":
                self.ctrl(sid, "DECLINE")          # уже в сессии
                return
            self.invite_from, self.state = sid, "invited"
            log(f"ПРИГЛАШЕНИЕ от {arg or self.s.name_of(sid)} ({sid})")
        elif cmd == "ACCEPT" and self.state == "inviting" and sid == self.peer:
            self.state = "connected"
            self.role = "host"                     # пригласил — хост
            self.ctrl(sid, f"HELLO {self.s.my_name}")
            log(f"{self.s.name_of(sid)} принял приглашение")
        elif cmd == "DECLINE" and sid == self.peer and self.state == "inviting":
            self.peer, self.state, self.role, self.pflags = 0, "idle", "", {}
            log("приглашение отклонено")
        elif cmd == "BYE" and sid == self.peer:
            self.peer, self.state, self.role, self.pflags = 0, "idle", "", {}
            log("напарник вышел")
        elif cmd == "SET" and sid == self.peer:
            k, _, v = arg.partition(" ")
            if k:
                self.pflags[k] = v.strip()
        elif cmd == "PING":
            self.s.send(sid, CH_CTRL, "PONG " + arg, reliable=False)
        elif cmd == "PONG":
            try:
                self.ping_ms = int((time.time() - float(arg)) * 1000)
            except ValueError:
                pass
        elif cmd == "HELLO":
            log(f"HELLO от {arg} ({sid})")

    def write_status(self):
        peer_name = self.s.name_of(self.peer) if self.peer else ""
        inv_name = self.s.name_of(self.invite_from) if self.invite_from else ""
        rx_age = round(time.time() - self.last_rx, 1) if self.last_rx else -1
        txt = (f"me_id={self.s.me}\nme_name={self.s.my_name}\nstate={self.state}\npeer_id={self.peer}\n"
               f"peer_name={peer_name}\nping_ms={self.ping_ms}\nrx_age={rx_age}\n"
               f"invite_from={self.invite_from}\ninvite_name={inv_name}\nrole={self.role}\nt={time.time():.1f}\n"
               + "".join(f"p_{k}={v}\n" for k, v in self.pflags.items()))
        write_atomic(self.p["status"], txt)

    def write_friends(self):
        rows = self.s.friends()
        lines = [f"{sid}\t{name}\t{st}\t{app}\t{pw}" for sid, name, st, app, pw in rows]
        write_atomic(self.p["friends"], "\n".join(lines) + "\n")

    def loop(self):
        try:
            while True:
                now = time.time()
                self.s.callbacks()
                for c in take_commands(self.p["cmd"]):
                    self.handle_cmd(c)
                for sid, data in self.s.receive(CH_CTRL):
                    self.handle_ctrl(sid, data.decode("utf-8", "replace").strip())
                for sid, data in self.s.receive(CH_STATE):
                    if sid == self.peer and self.state == "connected":
                        self.last_rx = now
                        write_atomic(self.p["in"], data.decode("utf-8", "replace").strip() + "\n")
                # снапшоты врагов хоста: хост -> гость (надёжно); у гостя кладём в ai_in.txt
                for sid, data in self.s.receive(CH_AI):
                    if sid == self.peer and self.state == "connected" and self.role == "guest":
                        write_atomic(self.p["ai_in"], data.decode("utf-8", "replace").strip() + "\n")
                if self.role in ("host", "loopback"):
                    ai = read_line(self.p["ai_out"])
                    if ai and ai != self.last_ai:
                        self.last_ai = ai
                        if self.role == "loopback":
                            write_atomic(self.p["ai_in"], ai + "\n")              # самопроверка: сами себе
                        elif self.state == "connected" and self.peer:
                            self.s.send(self.peer, CH_AI, ai, reliable=True)
                if self.loopback:
                    line = read_line(self.p["out"])
                    if line and line != self.last_out:
                        self.last_out = line
                        v = line.split(",")
                        if len(v) >= 10:
                            v[3] = str(int(float(v[3])) + self.lb_off)          # y своего самолёта
                            if len(v) >= 23:
                                v[14] = str(int(float(v[14])) + self.lb_off)    # y точки пуска ракеты
                            if len(v) >= 26 and v[25] != "-":             # траектории ракет: id;x;y;z;...
                                ents = []
                                for e in v[25].split("|"):
                                    q = e.split(";")
                                    if len(q) >= 3:
                                        q[2] = str(int(float(q[2])) + self.lb_off)
                                    ents.append(";".join(q))
                                v[25] = "|".join(ents)
                            self.last_rx = now
                            write_atomic(self.p["in"], ",".join(v) + "\n")
                elif self.state == "connected" and self.peer:
                    line = read_line(self.p["out"])
                    if line and line != self.last_out:
                        self.last_out = line
                        self.s.send(self.peer, CH_STATE, line, reliable=False)
                    if now - self.t_ping > 2:
                        self.t_ping = now
                        self.s.send(self.peer, CH_CTRL, f"PING {now:.3f}", reliable=False)
                if self.state == "inviting" and now - self.t_invite > 60:
                    log("приглашение не принято за 60 с — отмена")
                    self.peer, self.state, self.role, self.pflags = 0, "idle", "", {}
                if self.watch_game and now - self.t_watch > 5:
                    self.t_watch = now
                    if game_running():
                        self.seen_game, self.gone_since = True, None
                    else:
                        self.gone_since = self.gone_since or now
                        # игра закрыта (или так и не появилась за 2 минуты) — выходим
                        if (self.seen_game and now - self.gone_since > 15) or (not self.seen_game and now - self.t_start > 120):
                            log("игра не запущена — демон завершается")
                            break
                if now - self.t_friends > 10:
                    self.t_friends = now
                    self.write_friends()
                if now - self.t_status > 0.25:
                    self.t_status = now
                    self.write_status()
                time.sleep(0.01)                 # ~100 Гц цикл
        except KeyboardInterrupt:
            pass
        finally:
            if self.peer:
                self.ctrl(self.peer, "BYE")
            self.s.set_presence("pwcoop", "")
            self.s.shutdown()
            log("демон остановлен")


def single_instance():
    """Один демон на ПК (именованный мьютекс Windows); False — уже запущен."""
    h = ctypes.windll.kernel32.CreateMutexW(None, False, "Global\\PWCoopHelperMutex")
    return ctypes.windll.kernel32.GetLastError() != 183


def game_running():
    import psutil
    for pr in psutil.process_iter(["name"]):
        if (pr.info.get("name") or "").lower() == "projectwingman-win64-shipping.exe":
            return True
    return False


def main():
    global DLL
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["friends", "selftest", "daemon"])
    ap.add_argument("--out", default="")
    ap.add_argument("--dir", default="")
    ap.add_argument("--loopback", action="store_true", help="самопроверка на одном ПК")
    ap.add_argument("--watch-game", action="store_true", help="выйти, когда игра закрылась (запуск из мода)")
    a = ap.parse_args()
    out = os.path.abspath(a.out) if a.out else ""
    io_dir = os.path.abspath(a.dir) if a.dir else ""

    if a.cmd == "daemon":
        if not io_dir:
            raise SystemExit("нужен --dir")
        if sys.stdout is None:                       # сборка без консоли: пишем лог в файл рядом с обменом
            os.makedirs(io_dir, exist_ok=True)
            sys.stdout = sys.stderr = open(os.path.join(io_dir, "helper.log"), "a", encoding="utf-8", buffering=1)
        if not single_instance():
            log("демон уже запущен — выход")
            return 0
        # корень игры: io -> PWCoop -> Mods -> Win64 -> Binaries -> ProjectWingman -> <игра>
        root = os.path.abspath(os.path.join(io_dir, *[os.pardir] * 6))
        cand = os.path.join(root, DLL_REL)
        if os.path.exists(cand):
            DLL = cand
        log("steam_api64.dll:", DLL)
        Daemon(io_dir, loopback=a.loopback, watch_game=a.watch_game).loop()
        return 0

    s = Steam(manual_dispatch=(a.cmd == "selftest"))
    for _ in range(30):            # состояния друзей приходят асинхронно
        s.callbacks()
        time.sleep(0.1)
    rows = s.friends()
    log(f"я: {s.my_name} ({s.me}); друзей: {len(rows)}; онлайн: {sum(1 for r in rows if r[2] != 'offline')}; "
        f"в Project Wingman: {sum(1 for r in rows if r[3] == APPID)}; с модом (pwcoop): {sum(r[4] for r in rows)}")
    if a.cmd == "friends":
        for sid, name, st, app, pw in sorted(rows, key=lambda r: (r[2] == "offline", r[1].lower())):
            if st != "offline" or app:
                mark = " <== Project Wingman" if app == APPID else (f" (appid {app})" if app else "")
                print(f"  {name} [{sid}] {st}{mark}{' [мод]' if pw else ''}")
        if out:
            with open(out, "w", encoding="utf-8") as f:
                for r in rows:
                    f.write("\t".join(map(str, r)) + "\n")
            log("список записан:", out)
    else:
        # selftest: проверяем P2P-инфраструктуру без отправки друзьям
        s.d.SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(s.utils)
        buf = s.ident(s.me)
        back = s.d.SteamAPI_SteamNetworkingIdentity_GetSteamID64(buf)
        log(f"identity SteamID64 туда-обратно: {'OK' if back == s.me else 'ОШИБКА'} ({back})")
        got0, got1 = s.receive(CH_STATE), s.receive(CH_CTRL)
        log(f"приём на каналах 0/1 без ошибок: {len(got0)}/{len(got1)} сообщений")
        cbs = s.callbacks()
        log(f"ручная диспетчеризация колбэков: OK ({len(cbs)} в очереди)")
    s.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
