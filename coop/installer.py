"""Установщик PWCoop (co-op мод для Project Wingman). Собирается в PWCoop_Setup.exe (build_installer.py).

Что делает:
  1. находит папку игры через Steam (или спрашивает путь);
  2. ставит UE4SS (UE4SS.dll, dwmapi.dll, настройки), если его ещё нет;
  3. копирует мод Mods\\PWCoop (Lua + steam-демон pwcoop_helper.exe) и включает его в mods.txt.
Запуск с --uninstall удаляет мод (UE4SS остаётся).
"""
import os
import re
import shutil
import sys

import psutil

GAME_DIR = "Project Wingman"
WIN64 = os.path.join("ProjectWingman", "Binaries", "Win64")
EXE = "ProjectWingman-Win64-Shipping.exe"


def say(*a):
    print(*a, flush=True)


def payload_dir():
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, "payload")


def steam_libraries():
    """Папки steamapps\\common всех библиотек Steam."""
    libs = []
    steam = None
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            steam = winreg.QueryValueEx(k, "SteamPath")[0]
    except Exception:
        pass
    for root in filter(None, [steam, r"C:\Program Files (x86)\Steam", r"C:\Program Files\Steam"]):
        libs.append(os.path.join(root, "steamapps", "common"))
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        try:
            txt = open(vdf, encoding="utf-8", errors="replace").read()
            for m in re.finditer(r'"path"\s+"([^"]+)"', txt):
                libs.append(os.path.join(m.group(1).replace("\\\\", "\\"), "steamapps", "common"))
        except OSError:
            pass
    seen, out = set(), []
    for p in libs:
        if p.lower() not in seen:
            seen.add(p.lower())
            out.append(p)
    return out


def find_game():
    for lib in steam_libraries():
        g = os.path.join(lib, GAME_DIR)
        if os.path.exists(os.path.join(g, WIN64, EXE)):
            return g
    return None


def ask_game():
    while True:
        p = input("Папка игры не найдена. Укажи путь к папке «Project Wingman» (пусто — выход): ").strip().strip('"')
        if not p:
            return None
        if os.path.exists(os.path.join(p, WIN64, EXE)):
            return p
        say("  там нет ProjectWingman-Win64-Shipping.exe, попробуй ещё раз")


def game_running():
    return any((p.info.get("name") or "").lower() == EXE.lower() for p in psutil.process_iter(["name"]))


def set_mod_enabled(mods_txt, enabled):
    lines = []
    if os.path.exists(mods_txt):
        lines = open(mods_txt, encoding="utf-8-sig").read().splitlines()
    out, found = [], False
    for ln in lines:
        if re.match(r"^\s*PWCoop\s*:", ln):
            found = True
            if enabled:
                out.append("PWCoop : 1")
            continue
        out.append(ln)
    if enabled and not found:
        # до встроенной строки Keybinds (она должна быть последней)
        i = next((n for n, ln in enumerate(out) if re.match(r"^\s*Keybinds\s*:", ln)), len(out))
        out.insert(i, "PWCoop : 1")
    if enabled and not any(re.match(r"^\s*Keybinds\s*:", ln) for ln in out):
        out.append("Keybinds : 1")
    open(mods_txt, "w", encoding="utf-8").write("\n".join(out) + "\n")


def install(game):
    win64 = os.path.join(game, WIN64)
    pl = payload_dir()
    # UE4SS: не трогаем, если уже стоит
    if os.path.exists(os.path.join(win64, "UE4SS.dll")):
        say("UE4SS уже установлен — оставляю как есть")
    else:
        if os.path.exists(os.path.join(win64, "dwmapi.dll")):
            say("ВНИМАНИЕ: в папке игры уже есть другой dwmapi.dll — не перезаписываю, UE4SS может не загрузиться")
        else:
            shutil.copy2(os.path.join(pl, "ue4ss", "dwmapi.dll"), win64)
        shutil.copy2(os.path.join(pl, "ue4ss", "UE4SS.dll"), win64)
        if not os.path.exists(os.path.join(win64, "UE4SS-settings.ini")):
            shutil.copy2(os.path.join(pl, "ue4ss", "UE4SS-settings.ini"), win64)
        say("UE4SS установлен")
    mods = os.path.join(win64, "Mods")
    dst = os.path.join(mods, "PWCoop")
    os.makedirs(os.path.join(dst, "io"), exist_ok=True)
    for sub in ("Scripts", "helper"):
        t = os.path.join(dst, sub)
        if os.path.exists(t):
            shutil.rmtree(t)
        shutil.copytree(os.path.join(pl, "Mods", "PWCoop", sub), t)
    for f in os.listdir(os.path.join(dst, "io")):          # старые файлы обмена не нужны
        try:
            os.remove(os.path.join(dst, "io", f))
        except OSError:
            pass
    os.makedirs(mods, exist_ok=True)
    set_mod_enabled(os.path.join(mods, "mods.txt"), True)
    say("Мод PWCoop установлен и включён.")


def uninstall(game):
    win64 = os.path.join(game, WIN64)
    shutil.rmtree(os.path.join(win64, "Mods", "PWCoop"), ignore_errors=True)
    mt = os.path.join(win64, "Mods", "mods.txt")
    if os.path.exists(mt):
        set_mod_enabled(mt, False)
    say("Мод PWCoop удалён (UE4SS оставлен).")


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    say("=== PWCoop — co-op мод для Project Wingman ===")
    game = find_game() or ask_game()
    if not game:
        return 1
    say("Игра:", game)
    if game_running():
        say("Игра запущена — закрой её и запусти установщик снова.")
        input("Enter — выход")
        return 1
    try:
        if "--uninstall" in sys.argv:
            uninstall(game)
        else:
            install(game)
            say("\nГотово. Запусти игру через Steam: кнопка «ДОБАВИТЬ ДРУГА» появится справа сверху.")
    except Exception as e:                       # не молчим об ошибках
        say("ОШИБКА:", repr(e))
        input("Enter — выход")
        return 1
    input("Enter — выход")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
