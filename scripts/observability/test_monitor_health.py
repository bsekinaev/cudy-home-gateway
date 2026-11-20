"""Observation envelope from production health adapter with fixed status fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class MonitorHealthTests(unittest.TestCase):
    def collect(self, extra='', env_extra=None):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HG_LIBDIR=str(ROOT/'src/usr/lib/home-gateway'),
                       HG_MONITOR_CONFIG_DIR=tmp, HG_MONITOR_GENERATED_DIR=tmp,
                       HG_MONITOR_INCARNATION='11111111-1111-1111-1111-111111111111',
                       HG_MONITOR_SEQUENCE='7', HG_MONITOR_ACTIVE='1')
            env.update(env_extra or {})
            code = r''' . "$HG_LIBDIR/common.sh"
. "$HG_LIBDIR/health.sh"
hg_status_collect() {
 HG_NETWORK_WAN_STATE=OK; HG_DNS_STATE=OK; HG_VPN_MAIN_STATE=OK
 HG_TORRENT_STATE=OK; HG_REDMI_STATE=OK; HG_ASATA_STATE=OK; HG_TAILSCALE_STATE=OK
 HG_NETWORK_DIRECT_STATE=OK; HG_NETWORK_DIRECT_SOURCE=live_probe
 HG_VPN_EGRESS_STATE=OK; HG_VPN_EGRESS_SOURCE=live_probe
 HG_TORRENT_EGRESS_STATE=OK; HG_TORRENT_EGRESS_SOURCE=live_probe
 HG_NETWORK_DIRECT_PROBE_ATTEMPTS=1; HG_VPN_EGRESS_PROBE_ATTEMPTS=1
 HG_REDMI_DNS_STATE=OK
 HG_NETWORK_WAN_INTERFACE=wan; HG_NETWORK_WAN_DEVICE=eth1; HG_NETWORK_WAN_IPV4=192.0.2.2
''' + extra + r'''
}
hg_health_print_json
'''
            r = subprocess.run(['sh','-c',code],env=env,text=True,capture_output=True,timeout=5)
            self.assertIn(r.returncode,(0,1),r.stderr)
            return json.loads(r.stdout)

    def test_live_observations_have_fresh_unique_identity(self):
        h=self.collect()
        o=h['observation']
        self.assertEqual(o['schema_version'],1)
        self.assertEqual(o['sequence'],7)
        self.assertEqual(o['incarnation'],'11111111-1111-1111-1111-111111111111')
        self.assertGreaterEqual(o['finished_uptime'],o['started_uptime'])
        self.assertEqual(len(o['context']),64)
        for c in h['components'].values():
            s=c['sample']; self.assertTrue(s['valid']); self.assertEqual(s['boot_id'],o['boot_id'])
            self.assertEqual(s['context'],o['context'])
            self.assertGreater(s['expires_uptime'],s['checked_uptime'])

    def test_cached_evidence_preserves_identity_across_worker_sequence(self):
        setup='HG_VPN_EGRESS_SOURCE=cache; HG_VPN_EGRESS_CHECKED_AT=$(($(date +%s)/60*60)); HG_VPN_EGRESS_PROBE_ATTEMPTS=0'
        a=self.collect(setup); b=self.collect(setup,{'HG_MONITOR_SEQUENCE':'8'})
        self.assertEqual(a['components']['main']['sample']['id'],b['components']['main']['sample']['id'])

    def test_old_cache_does_not_provide_valid_vote(self):
        h=self.collect('HG_VPN_EGRESS_SOURCE=cache; HG_VPN_EGRESS_CHECKED_AT=1; HG_VPN_EGRESS_PROBE_ATTEMPTS=0')
        self.assertFalse(h['components']['main']['sample']['valid'])

    def test_active_monitor_forces_fresh_external_checks(self):
        h=self.collect('HG_DNS_STATE=DOWN; [ "$HG_EGRESS_CACHE_TTL:$HG_MAIN_EGRESS_CACHE_TTL:$HG_TORRENT_EGRESS_CACHE_TTL" = 0:0:0 ] || HG_DNS_STATE=OK')
        self.assertEqual(h['components']['dns']['state'],'DOWN')

    def test_clock_not_trusted_from_plausible_date_alone(self):
        self.assertFalse(self.collect()['observation']['wall_time_trusted'])

    def test_no_external_attempt_does_not_confirm_egress_failure(self):
        h=self.collect('HG_VPN_MAIN_STATE=DEGRADED; HG_VPN_EGRESS_STATE=UNKNOWN; HG_VPN_EGRESS_PROBE_ATTEMPTS=0')
        self.assertEqual(h['components']['main']['state'],'UNKNOWN')

    def test_wan_external_failure_is_separate_from_link_up(self):
        h=self.collect('HG_NETWORK_DIRECT_STATE=UNKNOWN; HG_NETWORK_DIRECT_PROBE_ATTEMPTS=1')
        self.assertEqual(h['components']['wan']['state'],'DEGRADED')
        self.assertEqual(h['components']['wan']['reason'],'wan_egress_unconfirmed')

    def test_missing_direct_probe_is_unknown(self):
        h=self.collect('HG_NETWORK_DIRECT_STATE=UNKNOWN; HG_NETWORK_DIRECT_PROBE_ATTEMPTS=0')
        self.assertEqual(h['components']['wan']['state'],'UNKNOWN')

if __name__=='__main__': unittest.main()
