"""Additive status scope and health reason from real shell renderers."""
import json
import shlex
import subprocess
import unittest
from test_dns import ROOT, BUSYBOX


class DNSStatusTests(unittest.TestCase):
    def shell(self, setup, command):
        files = ['common.sh', 'status.sh', 'health.sh']
        script = '\n'.join('. '+shlex.quote(str(ROOT/'src/usr/lib/home-gateway'/f)) for f in files)
        result = subprocess.run([BUSYBOX, 'ash', '-c', script+'\n'+setup+'\n'+command],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_status_preserves_dns_scope_and_unknown_egress(self):
        data = json.loads(self.shell('''HG_REDMI_DNS_STATE=OK
HG_REDMI_DNS_REASON=answer
HG_REDMI_DNS_PORT=2004
HG_REDMI_DNS_CHECKED_AT=12345
HG_REDMI_DNS_SOURCE=live_probe''', 'hg_status_print_json'))
        self.assertEqual(data['redmi']['dns'], dict(state='OK', reason='answer',
            port=2004, checked_at=12345, source='live_probe', scope='profile_resolver'))
        self.assertEqual(data['redmi']['egress']['state'], 'UNKNOWN')

    def test_health_distinguishes_dns_failure_from_policy_ready(self):
        setup = 'HG_HEALTH_REDMI_STATE=DEGRADED; HG_REDMI_DNS_STATE=DOWN'
        self.assertEqual(self.shell(setup, 'hg_health_reason_redmi'), 'redmi_dns_failed')

    def test_kill_switch_failure_remains_first_reason(self):
        setup = 'HG_HEALTH_REDMI_STATE=DEGRADED; HG_REDMI_DNS_STATE=DOWN; HG_REDMI_KILLSWITCH_STATE=DOWN'
        self.assertEqual(self.shell(setup, 'hg_health_reason_redmi'), 'redmi_kill_switch_down')


if __name__ == '__main__':
    unittest.main()
