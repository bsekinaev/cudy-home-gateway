"""Production ucode history and freshness contract; run in Linux/ucode container."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / 'src/usr/lib/home-gateway/incidents.uc'


class MonitorHistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        (self.base / 'state').mkdir()
        (self.base / 'runtime').mkdir()
        self.gateway = self.base / 'gateway'
        self.gateway.write_text('#!/bin/sh\ncat "$HG_TEST_HEALTH"\n')
        self.env = dict(os.environ, HG_NOTIFICATION_STATE_DIR=str(self.base / 'state'),
                        HG_NOTIFICATION_RUNTIME_DIR=str(self.base / 'runtime'),
                        HG_TEST_HEALTH=str(self.base / 'health.json'), HG_MONITOR_INCARNATION='cccccccc-cccc-cccc-cccc-cccccccccccc')

    def call(self, mode, *args, ok=True):
        p = subprocess.run(['ucode', str(ENGINE), str(self.gateway), mode, *args],
                           env=self.env, capture_output=True, text=True, timeout=10)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p

    def tick(self, uptime, state='DOWN', identity=None, boot='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', context='ctx1',
             valid=True, expires=None, incarnation='cccccccc-cccc-cccc-cccc-cccccccccccc', trusted=True, epoch=None):
        self.sequence=getattr(self,'sequence',0)+1
        sample = dict(id=identity or f'{boot}:{uptime}', boot_id=boot, context=context,
                      checked_uptime=uptime, expires_uptime=expires if expires is not None else uptime + 60,
                      valid=valid, source='fixture')
        health = dict(schema_version=1, generated_at={'epoch': epoch or 1800000000 + uptime},
                      observation=dict(schema_version=1, boot_id=boot, context=context,
                                       incarnation=incarnation, sequence=self.sequence,
                                       started_uptime=uptime, finished_uptime=uptime,
                                       wall_time_trusted=trusted),
                      components={'main': dict(state=state, reason='fixture', sample=sample)})
        self.env.update(HG_HISTORY_QUERY_BOOT_ID=boot, HG_HISTORY_QUERY_UPTIME=str(uptime),
                        HG_HISTORY_QUERY_EPOCH=str(epoch or 1800000000 + uptime))
        (self.base / 'health.json').write_text(json.dumps(health))
        return self.call('tick')

    def status(self):
        return json.loads(self.call('json').stdout)

    def summary(self, period='day'):
        return json.loads(self.call('history-json', period).stdout)

    def test_three_unique_failures_two_unique_successes_and_unknown(self):
        for t in (10, 20, 30): self.tick(t)
        self.assertEqual(self.status()['active_count'], 1)
        self.tick(40, 'OK')
        self.tick(50, 'UNKNOWN')
        self.tick(60, 'OK')
        self.assertEqual(self.status()['active_count'], 1)
        self.tick(70, 'OK')
        self.assertEqual(self.status()['active_count'], 0)

    def test_duplicate_stale_and_missing_envelope_never_vote(self):
        for t in (10, 20, 30): self.tick(t, identity='cached')
        self.assertEqual(self.status()['active_count'], 0)
        for t in (40, 50, 60): self.tick(t, expires=t-1)
        self.assertEqual(self.status()['active_count'], 0)
        (self.base / 'health.json').write_text(json.dumps(dict(schema_version=1, components={'main': {'state': 'DOWN'}})))
        for _ in range(3): self.call('tick')
        self.assertEqual(self.status()['active_count'], 0)

    def test_boot_context_worker_restart_clear_pending(self):
        self.tick(10); self.tick(20)
        self.tick(30, context='ctx2')
        self.assertEqual(self.status()['runtime']['candidates']['main']['count'], 1)
        self.tick(40, context='ctx2', incarnation='dddddddd-dddd-dddd-dddd-dddddddddddd')
        self.assertEqual(self.status()['runtime']['candidates']['main']['count'], 1)
        self.tick(5, boot='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', context='ctx2', incarnation='dddddddd-dddd-dddd-dddd-dddddddddddd')
        self.assertEqual(self.status()['active_count'], 0)

    def test_uptime_coverage_and_expired_gap(self):
        self.tick(10, 'OK', expires=20)
        self.tick(40, 'DOWN')
        c = self.summary()['components']['main']
        self.assertEqual(c['ok_seconds'], 10)
        self.assertEqual(c['unknown_seconds'], 20)
        self.assertEqual(c['unobserved_seconds'], 86400-30)

    def test_queries_are_read_only_and_need_no_health(self):
        self.tick(10)
        before = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in self.base.rglob('*.json')}
        self.gateway.unlink()
        self.summary('week'); self.call('history', 'day')
        after = {str(p): (p.read_bytes(), p.stat().st_mtime_ns) for p in self.base.rglob('*.json')}
        self.assertEqual(before, after)

    def test_checkpoint_restart_and_partial_or_corrupt_files(self):
        self.tick(10, 'OK'); self.tick(920, 'OK')
        ram = self.base / 'runtime/monitor-history.json'
        expected = self.summary()['components']['main']['covered_seconds']
        ram.unlink()
        self.assertEqual(self.summary()['components']['main']['covered_seconds'], expected)
        (self.base / 'state/monitor-history.json.tmp.123').write_text('{broken')
        self.assertEqual(self.summary()['components']['main']['covered_seconds'], expected)
        ram.write_text('{broken')
        self.assertEqual(self.summary()['components']['main']['covered_seconds'], expected)
        (self.base / 'state/monitor-history.json').write_text('{broken')
        self.assertEqual(self.summary()['components']['main']['covered_seconds'], 0)

    def test_reboot_gap_is_not_downtime_and_unknown_wall_time(self):
        self.tick(10, 'OK', trusted=False); self.tick(20, 'OK', trusted=False)
        self.tick(1, 'DOWN', boot='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', trusted=False)
        s = self.summary()
        self.assertFalse(s['wall_time_trusted'])
        self.assertEqual(s['components']['main']['down_seconds'], 0)
        self.assertEqual(s['reboot_gaps'], 1)

    def test_seven_day_detail_thirty_day_daily_retention(self):
        self.tick(10, 'OK')
        for day in range(1, 34): self.tick(day * 86400, 'OK')
        h = json.loads((self.base / 'runtime/monitor-history.json').read_text())
        self.assertLessEqual(len(h['daily']), 30)
        self.assertTrue(all(h['last']['epoch']-r['end_epoch'] <= 604800 for r in h['records']))

    def test_storage_cap_marks_truncation(self):
        self.tick(10, 'OK')
        path = self.base / 'runtime/monitor-history.json'
        h = json.loads(path.read_text())
        row = dict(boot_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', end_uptime=10, end_epoch=1800000010,
                   seconds=10, components={name: dict(state='UNKNOWN', covered_seconds=0, unknown_seconds=10)
                       for name in ('wan', 'dns', 'main', 'torrent', 'redmi', 'asata', 'tailscale')}, padding='x'*10000)
        h['records'] = [row] * 250
        path.write_text(json.dumps(h))
        self.tick(20, 'OK')
        self.assertLessEqual(path.stat().st_size, 2097152)
        self.assertTrue(self.summary()['truncated'])

    def test_cached_read_preserves_pending_but_never_adds_vote(self):
        self.tick(10); self.tick(10); self.tick(20)
        self.assertEqual(self.status()['active_count'], 0)
        self.tick(20); self.tick(30)
        self.assertEqual(self.status()['active_count'], 1)

    def test_disk_failure_keeps_ram_and_incident_journal(self):
        target = self.base / 'state/monitor-history.json'
        target.mkdir()
        # First flush fails, but candidate state and observations still persist.
        self.tick_failure(10)
        self.tick_failure(20)
        self.tick_failure(30)
        self.assertEqual(self.status()['active_count'], 1)
        self.assertTrue(self.summary()['truncated'])
        self.assertTrue((self.base / 'state/incidents.jsonl').exists())

    def tick_failure(self, uptime):
        # Reuse fixture construction while allowing only the expected storage error.
        original = self.call
        def call(mode, *args, **kwargs):
            p = original(mode, *args, ok=False)
            self.assertEqual(p.returncode, 75, p.stderr)
            return p
        self.call = call
        try:
            self.tick(uptime)
        finally:
            self.call = original

    def test_midnight_daily_split_and_unconfirmed_clock_label(self):
        epoch = 1800057590  # ten seconds before a UTC boundary
        epoch = epoch // 86400 * 86400 + 86390
        self.tick(10, 'OK', epoch=epoch, trusted=False)
        self.tick(40, 'OK', epoch=epoch+30, trusted=False)
        h = self.summary()
        self.assertEqual(h['wall_time_quality'], 'unconfirmed')
        self.assertEqual(len(h['daily']), 2)
        totals = [d['components']['main']['ok_seconds'] for d in h['daily']]
        self.assertEqual(totals, [10, 20])

    def test_clock_jump_uses_uptime_coverage_without_false_daily_total(self):
        self.tick(10, 'OK', epoch=1800000010)
        self.tick(40, 'OK', epoch=1800100000)
        h = self.summary()
        self.assertEqual(h['components']['main']['ok_seconds'], 30)
        self.assertEqual(h['daily'], [])

    def test_daily_cap_is_separate_and_explicit(self):
        self.tick(10)
        path = self.base / 'runtime/monitor-history.json'
        h = json.loads(path.read_text())
        day = h['last']['epoch'] // 86400
        h['daily'] = [dict(day=day, padding='x'*20000, components={}) for _ in range(40)]
        path.write_text(json.dumps(h))
        self.tick(20)
        h = json.loads(path.read_text())
        self.assertLess(len(json.dumps(h['daily'])), 524288)
        self.assertTrue(h['truncated'])

    def test_stable_intervals_compact_and_clip_at_seven_days(self):
        # 7+ days with fresh evidence spanning the fixture schedule; no fictitious probe execution.
        for t in range(0, 9*86400, 12*3600):
            self.tick(t+1, 'OK', expires=t+12*3600+1)
        path = self.base / 'runtime/monitor-history.json'
        h = json.loads(path.read_text())
        self.assertEqual(len(h['records']), 1)
        self.assertEqual(h['records'][0]['seconds'], 604800)
        self.assertLess(path.stat().st_size, 20000)
        self.assertFalse(h['truncated'])
        self.assertEqual(self.summary('week')['components']['main']['covered_seconds'], 604800)

    def journal(self):
        return [json.loads(line) for line in (self.base / 'state/incidents.jsonl').read_text().splitlines()]

    def test_event_elapsed_monotonic_and_id_survives_wall_clock_rollback(self):
        for t in (10, 20, 30): self.tick(t, epoch=1800000000-t)
        for t in (40, 50): self.tick(t, 'OK', epoch=1800000000-t)
        opened, recovered = self.journal()
        self.assertRegex(opened['incident_id'], r'^main-8[0-9]{148}$')
        self.assertEqual(opened['opened_uptime'], 10)
        self.assertEqual(recovered['observed_duration_seconds'], 40)
        self.assertIsNone(recovered['duration_seconds'])
        self.assertFalse(recovered['context_changed'])

    def test_event_recovery_after_reboot_has_no_elapsed_duration(self):
        for t in (10, 20, 30): self.tick(t)
        for t in (1, 2): self.tick(t, 'OK', boot='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
        self.assertIsNone(self.journal()[-1]['observed_duration_seconds'])

    def test_context_change_survives_replay_and_return_to_original_context(self):
        for t in (10, 20, 30): self.tick(t)
        self.tick(40, 'UNKNOWN', context='new_provider')
        for t in (50, 60): self.tick(t, 'OK')
        self.assertTrue(self.journal()[-1]['context_changed'])

    def test_structurally_corrupt_records_are_explicitly_discarded(self):
        self.tick(10)
        path = self.base / 'runtime/monitor-history.json'
        h = json.loads(path.read_text())
        h['records'] = [None, {'seconds': 'broken'}, {'boot_id': h['last']['boot_id'], 'end_uptime': 10,
            'seconds': 10, 'components': {'main': {'covered_seconds': -10}}}]
        h['daily'] = [None, {'day': 'bad'}]
        path.write_text(json.dumps(h))
        summary = self.summary()
        self.assertEqual(summary['components']['main']['covered_seconds'], 0)
        self.assertTrue(summary['truncated'])

    def test_stopped_collector_tail_is_unobserved_and_window_moves(self):
        self.tick(10, 'OK'); self.tick(40, 'OK')
        self.env['HG_HISTORY_QUERY_UPTIME'] = '86500'
        self.env['HG_HISTORY_QUERY_EPOCH'] = str(1800086500)
        summary = self.summary()
        self.assertEqual(summary['period_end'], 'query_time')
        self.assertEqual(summary['snapshot_age_seconds'], 86460)
        self.assertEqual(summary['latest_sample']['uptime'], 40)
        self.assertEqual(summary['components']['main']['covered_seconds'], 0)
        self.assertEqual(summary['components']['main']['unobserved_seconds'], 86400)

    def test_query_after_reboot_never_extrapolates_coverage(self):
        self.tick(10, 'OK'); self.tick(40, 'OK')
        self.env.update(HG_HISTORY_QUERY_BOOT_ID='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
                        HG_HISTORY_QUERY_UPTIME='5', HG_HISTORY_QUERY_EPOCH=str(1800000100))
        summary = self.summary()
        self.assertEqual(summary['snapshot_age_seconds'], 60)
        self.assertEqual(summary['components']['main']['covered_seconds'], 30)
        self.assertEqual(summary['components']['main']['unobserved_seconds'], 86370)
        self.env['HG_HISTORY_QUERY_EPOCH'] = str(1800100000)
        self.assertEqual(self.summary()['components']['main']['covered_seconds'], 0)

    def test_corrupt_ram_fallback_marks_coverage_incomplete(self):
        self.tick(10, 'OK'); self.tick(920, 'OK')
        (self.base / 'runtime/monitor-history.json').write_text('{broken')
        summary = self.summary()
        self.assertTrue(summary['truncated'])
        self.assertEqual(summary['recovery'], 'runtime_checkpoint_unreadable')
        self.assertEqual(summary['snapshot_age_seconds'], 0)


    def test_history_retains_confirmed_events_after_delivery_journal_compaction(self):
        for t in (10,20,30): self.tick(t)
        for t in (40,50): self.tick(t,'OK')
        (self.base/'state/incidents.jsonl').unlink()
        data=self.summary()
        self.assertEqual([e['event'] for e in data['events']],['OPEN','RECOVERED'])
        self.assertEqual(data['incident_counts']['opened'],1)
        self.assertEqual(data['incident_counts']['recovered'],1)
        self.assertEqual(data['events'][-1]['observed_duration_seconds'],40)

    def test_missing_observation_breaks_confirmation_and_marks_history_gap(self):
        self.tick(10)
        self.sequence+=1  # Worker attempted a cycle which produced no health result.
        self.tick(30)
        self.tick(40)
        self.assertEqual(self.status()['active_count'],0)
        self.tick(50)
        self.assertEqual(self.status()['active_count'],1)
        self.assertGreaterEqual(self.summary()['observation_gaps'],1)

    def test_replayed_complete_frame_is_ignored_without_reset_or_false_gap(self):
        self.tick(10)
        self.call('tick')
        self.tick(20); self.tick(30)
        self.assertEqual(self.status()['active_count'],1)
        self.assertEqual(self.summary()['observation_gaps'],0)

if __name__ == '__main__':
    unittest.main()
