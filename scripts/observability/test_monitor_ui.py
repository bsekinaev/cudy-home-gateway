"""Read-only history requests through the actual Telegram poller and CLI."""
import json, os, shlex, subprocess, tempfile, time, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class MonitorUITests(unittest.TestCase):
 def render(self,text,user=111):
  with tempfile.TemporaryDirectory() as d:
   b=Path(d); (b/'secrets').mkdir(); (b/'runtime').mkdir()
   (b/'secrets/telegram.user_id').write_text('111\n'); (b/'secrets/telegram.chat_id').write_text('222\n')
   (b/'updates').write_text(json.dumps({'ok':True,'result':[{'update_id':1,'message':{'from':{'id':user},'chat':{'id':222},'text':text,'date':int(time.time())}}]}))
   bridge=b/'gateway'; bridge.write_text('#!/bin/sh\n'+'echo "$*" >> "$HG_UI_BASE/calls"\n'+
    'case "$1 $2" in\n"telegram get-updates") cat "$HG_UI_BASE/updates";;\n"history day"|"history week") echo "История: покрытие 60 с; пропуск 120 с";;\n"telegram send-message") echo \'{"ok":true,"result":{"message_id":9}}\';;\n"actions cancel") echo "{}";;\n*) exit 97;; esac\n')
   env=dict(os.environ, HG_UI_BASE=d,HG_TELEGRAM_SECRETS_DIR=str(b/'secrets'),HG_TELEGRAM_RUNTIME_DIR=str(b/'runtime'))
   r=subprocess.run(['ucode',str(ROOT/'src/usr/lib/home-gateway/telegram-poller.uc'),str(bridge),'once'],env=env,text=True,capture_output=True,timeout=5)
   self.assertEqual(r.returncode,0,r.stderr)
   return (b/'calls').read_text()
 def test_day_and_week_are_query_only(self):
  for cmd,period in [('/summary','day'),('/history','week')]:
   with self.subTest(cmd=cmd):
    calls=self.render(cmd); self.assertIn('history '+period,calls)
    self.assertIn('История: покрытие',calls); self.assertNotIn('incidents tick',calls); self.assertNotIn('status --json',calls)
 def test_unauthorized_cannot_read_history(self):
  calls=self.render('/history',999); self.assertNotIn('history week',calls); self.assertNotIn('send-message',calls)
 def test_cli_rejects_arbitrary_period(self):
  r=subprocess.run(['sh',str(ROOT/'src/usr/bin/gateway'),'history','../secret'],env=dict(os.environ,HG_LIBDIR=str(ROOT/'src/usr/lib/home-gateway')),capture_output=True,text=True)
  self.assertEqual(r.returncode,2)
if __name__=='__main__': unittest.main()
