import unittest
from build_kit import _core, _allowed, MONITOR_BASELINE, MONITOR_FORMAT, ALLOWED

class MonitorScopeTests(unittest.TestCase):
    def manifest(self):
        return dict(format=MONITOR_FORMAT, profile='VM_ONLY', production_apply=False,
                    source_commit='1'*40, baseline_commit=MONITOR_BASELINE, source_fixture=True,
                    parent=dict(format='HG_OWNER_UPDATE_V2'), bootstrap={}, inventories={},
                    changed=[], controls={}, files=[])

    def test_monitor_is_explicit_and_closed(self):
        m=self.manifest()
        _core(m, 'vm')
        self.assertEqual(_allowed(m['format']), {'usr/bin/gateway'} | {
            'usr/lib/home-gateway/'+name for name in ('health.sh','network.sh','vpn.sh','incidents.uc',
                'notifications.uc','telegram-poller.uc','torrent.sh')})
        self.assertNotIn('usr/lib/home-gateway/torrent.sh', ALLOWED)
        self.assertNotIn('usr/lib/home-gateway/incidents.uc', ALLOWED)
        self.assertNotIn('usr/lib/home-gateway/new.uc', _allowed(m['format']))
        self.assertNotIn('etc/init.d/home-gateway-telegram', _allowed(m['format']))

    def test_monitor_requires_installed_v2_baseline(self):
        for key, value in [('baseline_commit','2'*40), ('parent',dict(format='HG_OWNER_UPDATE_V1')),
                           ('format','HG_OWNER_MONITOR_V4')]:
            m=self.manifest(); m[key]=value
            with self.assertRaises(ValueError): _core(m, 'vm')
        with self.assertRaises(ValueError): _allowed('HG_OWNER_MONITOR_V4')

if __name__ == '__main__': unittest.main()
