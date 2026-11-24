"""Build an immutable, owner-run Telegram-call inspection package from committed sources."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import zipfile
ROOT=Path(__file__).resolve().parents[2]

def build(output,ref='HEAD'):
    source=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','--verify','--end-of-options',ref+'^{commit}']).decode('ascii').strip()
    def committed(name):return subprocess.check_output(['git','-C',str(ROOT),'show',source+':scripts/observability/'+name])
    collector=committed('router-call-probe.uc')
    if b'\r' in collector or b'HG_CALL_UCODE_EOF' in collector:raise ValueError('Invalid collector transport boundary')
    script=(b'#!/bin/sh\nset -eu\nucode - '+source.encode()+b" <<'HG_CALL_UCODE_EOF'\n"+collector+b'\nHG_CALL_UCODE_EOF\nexit 0\n')
    pin=hashlib.sha256(script).hexdigest()
    runner=committed('check-call.ps1.in').decode('utf-8-sig').replace('@@SOURCE@@',source).replace('@@SCRIPT_SHA@@',pin)
    if '@@' in runner:raise ValueError('Unfilled launcher template')
    output=Path(output);archive=output.with_suffix('.zip')
    if archive.exists() or output.exists():raise FileExistsError(output)
    output.mkdir(parents=True)
    (output/'router-call-probe.sh').write_bytes(script)
    (output/'check-call.ps1').write_text(runner,encoding='utf-8-sig',newline='\n')
    (output/'SOURCE.txt').write_text(source+'\n',encoding='ascii',newline='\n')
    (output/'CHECK-CALLS.cmd').write_bytes(b'@echo off\r\ncd /d "%~dp0"\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-call.ps1"\r\npause\r\n')
    (output/'README-RU.md').write_text('# Диагностика звонков Telegram\n\nЗапустите CHECK-CALLS.cmd. Подключение берётся из сохранённого owner-session.json обновления CUDY-Update-20261121-1fc822c; сеанс в пакет не включён.\nИнструмент читает выбранные параметры UDP, безопасную проекцию Xray-конфигурации и количество правил перехвата PassWall2.\nНе меняет настройки и правила, не перезапускает службы, не отключает Kill Switch, не выполняет сетевых проб или звонков.\nОграничение команды на роутере — 60 секунд; обычное чтение значительно быстрее.\nОтчёт CUDY-Calls-Readiness-*.txt сохраняется в домашней папке Windows. Пришлите только этот отчёт.\nАдреса, MAC, пароли, UUID, ключи, имена узлов, полные конфиги и содержимое owner-session.json в отчёт не включаются.\nREADABLE означает прочитанную конфигурацию, а не доказанный маршрут звонка или активный UDP listener.\nНеизвестные параметры явно отмечены UNKNOWN. Правила не меняются даже при найденной проблеме.\n',encoding='utf-8',newline='\n')
    (output/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in sorted(output.iterdir())),encoding='ascii',newline='\n')
    with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(output.iterdir()):z.write(p,p.name)
    return archive

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--ref',default='HEAD');a=p.parse_args();print(build(a.output,a.ref))
