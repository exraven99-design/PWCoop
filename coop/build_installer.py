"""Сборка PWCoop: хелпер (PyInstaller, onedir) -> payload -> установщик (PyInstaller, onedir) -> zip.
Запуск: python coop/build_installer.py   (результат: dist_installer/PWCoop_Setup_<версия>.zip и папка dist_installer/PWCoop_Setup)
Меньше ложных срабатываний антивирусов: onedir (без распаковки во временную папку), без UPX, с описанием версии в exe.
Источники берутся из установленной у разработчика игры; UE4SS-settings.ini — с отключённой GUI-консолью."""
import os
import re
import shutil
import subprocess
import sys

VERSION = "0.2.0.0"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WIN64 = os.environ.get("PW_WIN64", r"C:\Program Files (x86)\Steam\steamapps\common\Project Wingman\ProjectWingman\Binaries\Win64")   # папка Win64 игры с установленным UE4SS и модом
BUILD = os.path.join(ROOT, "build_installer")
PAY = os.path.join(BUILD, "payload")
OUT = os.path.join(ROOT, "dist_installer")


def run(*a):
    print(">", " ".join(a), flush=True)
    subprocess.run(list(a), check=True)


def version_file(path, internal, desc):
    vt = tuple(int(x) for x in VERSION.split("."))
    txt = f"""VSVersionInfo(
  ffi=FixedFileInfo(filevers={vt}, prodvers={vt}, mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)),
  kids=[
    StringFileInfo([StringTable('040904B0', [
      StringStruct('CompanyName', 'PWCoop (fan mod)'),
      StringStruct('FileDescription', '{desc}'),
      StringStruct('FileVersion', '{VERSION}'),
      StringStruct('InternalName', '{internal}'),
      StringStruct('OriginalFilename', '{internal}.exe'),
      StringStruct('ProductName', 'PWCoop co-op for Project Wingman'),
      StringStruct('ProductVersion', '{VERSION}')])]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ])
"""
    open(path, "w", encoding="utf-8").write(txt)


def main():
    shutil.rmtree(BUILD, ignore_errors=True)
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(PAY)
    # 1. демон (папка с exe и библиотеками)
    hv = os.path.join(BUILD, "helper_version.txt")
    version_file(hv, "pwcoop_helper", "PWCoop Steam helper (co-op for Project Wingman)")
    run(sys.executable, "-m", "PyInstaller", "--noconfirm", "--onedir", "--noconsole", "--noupx", "--name", "pwcoop_helper",
        "--version-file", hv, "--distpath", os.path.join(BUILD, "helper_dist"), "--workpath", os.path.join(BUILD, "work_h"),
        "--specpath", BUILD, os.path.join(HERE, "steam_helper.py"))
    # 2. payload
    u = os.path.join(PAY, "ue4ss")
    os.makedirs(u)
    for f in ("UE4SS.dll", "dwmapi.dll"):
        shutil.copy2(os.path.join(WIN64, f), u)
    ini = open(os.path.join(WIN64, "UE4SS-settings.ini"), encoding="utf-8-sig").read()
    ini = re.sub(r"(?m)^(GuiConsoleEnabled\s*=\s*)\d", r"\g<1>0", ini)
    ini = re.sub(r"(?m)^(GuiConsoleVisible\s*=\s*)\d", r"\g<1>0", ini)
    open(os.path.join(u, "UE4SS-settings.ini"), "w", encoding="utf-8").write(ini)
    mod = os.path.join(PAY, "Mods", "PWCoop")
    shutil.copytree(os.path.join(ROOT, "Mods", "PWCoop", "Scripts"), os.path.join(mod, "Scripts"))
    shutil.copytree(os.path.join(BUILD, "helper_dist", "pwcoop_helper"), os.path.join(mod, "helper"))
    # 3. установщик (папка) и zip
    iv = os.path.join(BUILD, "installer_version.txt")
    version_file(iv, "PWCoop_Setup", "PWCoop installer (co-op for Project Wingman)")
    run(sys.executable, "-m", "PyInstaller", "--noconfirm", "--onedir", "--console", "--noupx", "--name", "PWCoop_Setup",
        "--version-file", iv, "--distpath", OUT, "--workpath", os.path.join(BUILD, "work_i"), "--specpath", BUILD,
        "--add-data", PAY + os.pathsep + "payload", os.path.join(HERE, "installer.py"))
    zpath = shutil.make_archive(os.path.join(OUT, "PWCoop_Setup_" + VERSION.rsplit(".", 1)[0]), "zip", OUT, "PWCoop_Setup")
    print("\nГотово:", os.path.join(OUT, "PWCoop_Setup", "PWCoop_Setup.exe"), "\nZip:", zpath)


if __name__ == "__main__":
    main()
