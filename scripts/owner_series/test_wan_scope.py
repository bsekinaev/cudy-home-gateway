import unittest

from build_kit import _allowed, _core


class WanScopeTests(unittest.TestCase):
    def manifest(self):
        return dict(format='HG_OWNER_WAN_V4', profile='VM_ONLY', production_apply=False,
                    source_commit='1'*40,
                    baseline_commit='1fc822c3bddc1021a1d641c7d7cce71fab7332b8',
                    source_fixture=False, parent=dict(format='HG_OWNER_MONITOR_V3'),
                    bootstrap={}, inventories={}, changed=[], controls={}, files=[])

    def test_exact_baseline_and_closed_runtime_scope(self):
        m = self.manifest()
        _core(m, 'vm')
        self.assertEqual(_allowed(m['format']), {'usr/lib/home-gateway/'+name for name in
                         ('network.sh', 'health.sh', 'vpn.sh', 'torrent.sh')})

    def test_reject_wrong_baseline_parent_or_owner_before_acceptance(self):
        for field, value in [('baseline_commit', '2'*40),
                             ('parent', dict(format='HG_OWNER_UPDATE_V2'))]:
            m = self.manifest(); m[field] = value
            with self.assertRaises(ValueError):
                _core(m, 'vm')
        m = self.manifest(); m.update(profile='OWNER_MANUAL', production_apply=True)
        with self.assertRaises(ValueError):
            _core(m, 'owner')

    def test_old_formats_do_not_admit_monitor_parent(self):
        for format in ('HG_OWNER_UPDATE_V2', 'HG_OWNER_MONITOR_V3'):
            m = self.manifest(); m['format'] = format
            with self.assertRaises(ValueError):
                _core(m, 'vm')
