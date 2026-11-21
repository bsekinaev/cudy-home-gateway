"""Build an immutable, owner-run WAN inspection package from committed sources."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import zipfile
ROOT=Path(__file__).resolve().parents[2]

def build(output,ref='HEAD'):
    source=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','--verify','--end-of-options',ref+'^{commit}']).decode('ascii').strip()
    def committed(name):return subprocess.check_output(['git','-C',str(ROOT),'show',source+':scripts/observability/'+name])
    collector=committed('router-wan-probe.uc')
    if b'\r' in collector or b'HG_WAN_UCODE_EOF' in collector:raise ValueError('Invalid collector transport boundary')
    script=(b'#!/bin/sh\nset -eu\nucode - '+source.encode()+b" <<'HG_WAN_UCODE_EOF'\n"+collector+b'\nHG_WAN_UCODE_EOF\nexit 0\n')
    pin=hashlib.sha256(script).hexdigest()
    runner=committed('check-wan.ps1.in').decode('utf-8-sig').replace('@@SOURCE@@',source).replace('@@SCRIPT_SHA@@',pin)
    if '@@' in runner:raise ValueError('Unfilled launcher template')
    output=Path(output);archive=output.with_suffix('.zip')
    if archive.exists() or output.exists():raise FileExistsError(output)
    output.mkdir(parents=True)
    (output/'router-wan-probe.sh').write_bytes(script)
    (output/'check-wan.ps1').write_text(runner,encoding='utf-8-sig',newline='\n')
    (output/'SOURCE.txt').write_text(source+'\n',encoding='ascii',newline='\n')
    (output/'CHECK-WAN.cmd').write_bytes(b'@echo off\r\ncd /d "%~dp0"\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-wan.ps1"\r\npause\r\n')
    (output/'README-RU.md').write_text('# Диагностика WAN без установки\n\nЗапустите CHECK-WAN.cmd на компьютере с сохранённой папкой CUDY-Update-20261121-1fc822c.\nДля SSH используется только адрес и порт из её owner-session.json; сеанс в пакет не включён.\nДля другого расположения: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\check-wan.ps1 -SessionFile <путь к owner-session.json>.\n\nПроверяются фактический IPv4-адрес/маршрут WAN и пересечение с LAN, отдельно DHCP/static/PPPoE.\nМаршрут PPPoE без via допустим. Частный адрес за другим роутером сам по себе не ошибка.\nREADY относится только к локальному IPv4-пути, а не к интернету, DNS, VPN или физическому кабелю.\nYES в пересечении подсетей требует разбора настроек перед переносом. UNKNOWN означает нехватку данных.\nIPv6 отмечается только как наличие адреса; IPv6-маршрутизация не проверяется.\n\nНет установки, изменения настроек, перезапуска служб или внешних сетевых проб.\nСетевые интерфейсы не переключаются. Агент к роутеру не подключается.\nКоманды на роутере ограничены 20 секундами; SSH отдельно ожидает соединения/ответа.\nОтчёт CUDY-WAN-Readiness-*.txt сохраняется в домашней папке Windows и не содержит IP, MAC, паролей или полной конфигурации.\nПосле проверки пришлите этот отчёт. Содержимое owner-session.json и резервные копии не отправляйте.\n',encoding='utf-8',newline='\n')
    (output/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in sorted(output.iterdir())),encoding='ascii',newline='\n')
    with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(output.iterdir()):z.write(p,p.name)
    return archive

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--ref',default='HEAD');a=p.parse_args();print(build(a.output,a.ref))
