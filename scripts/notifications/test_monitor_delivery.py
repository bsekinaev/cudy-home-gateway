"""Monitor delivery contracts exercise real ucode and the synthetic curl adapter."""
import json
import time
import unittest
import test_notifications as fixtures

class MonitorDeliveryTests(unittest.TestCase):
    setUp = fixtures.DispatcherTests.setUp
    run_cli = fixtures.DispatcherTests.run_cli
    event = fixtures.DispatcherTests.event
    journal = fixtures.DispatcherTests.journal
    queue = fixtures.DispatcherTests.queue
    calls = fixtures.DispatcherTests.calls
    responses = fixtures.DispatcherTests.responses

    def monitor(self):
        self.env['HG_MONITOR_ACTIVE'] = '1'

    def modern_event(self, kind='OPEN', at=100, component='main', **fields):
        event = self.event(kind, at, component, component + '-' + 'a'*32 + '-' + 'b'*32 + '-1')
        event.update(fields)
        return event

    def test_new_ids_preserve_legacy_projection_and_dedup(self):
        self.journal([self.modern_event()])
        self.run_cli('dispatch')
        self.run_cli('sync')
        self.run_cli('compact')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.queue()[0]['status'], 'SENT')

    def test_monitor_dispatches_only_four_components_and_transitions(self):
        self.monitor()
        events = [self.modern_event(component=c) for c in ('torrent', 'asata', 'tailscale')]
        events += [self.modern_event('STATE_CHANGED', 101), self.modern_event()]
        self.journal(events)
        self.run_cli('dispatch')
        self.run_cli('dispatch')
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(len(self.queue()), 5)
        self.assertTrue(all(x.get('attempts', 0)==0 for x in self.queue() if x['event']=='STATE_CHANGED' or x['component'] in ('torrent','asata','tailscale')))

    def test_monitor_preset_preserves_pause_and_limits_categories(self):
        policy = dict(schema_version=1, enabled=False, mute_until=int(time.time())+600,
                      delivery_not_before=int(time.time())+900, categories={'asata': True})
        path = self.base / 'state/notification-policy.json'
        path.write_text(json.dumps(policy))
        result = self.run_cli('configure', 'monitoring')
        after = json.loads(path.read_text())
        self.assertTrue(after['enabled'])
        self.assertEqual(after['mute_until'], policy['mute_until'])
        self.assertEqual(after['delivery_not_before'], policy['delivery_not_before'])
        self.assertEqual({c for c,v in after['categories'].items() if v}, {'wan','dns','main','redmi'})
        self.assertIn(str(policy['mute_until']), result.stdout)

    def test_recovery_uses_observed_duration_and_safe_text(self):
        self.monitor()
        self.journal([self.modern_event(), self.modern_event('RECOVERED',130,
                     observed_duration_seconds=12, opened_at=100)])
        self.run_cli('dispatch')
        text = self.calls()[0]['payload']['text']
        self.assertIn('Основной VPN', text)
        self.assertIn('12 с.', text)
        self.assertIn('UTC', text)
        self.assertIn('Задержка доставки:', text)
        self.assertNotIn('NEVER_LEAK_REASON',text)
        self.assertEqual([x['status'] for x in self.queue()], ['COALESCED','SENT'])

    def test_unknown_cross_boot_duration_is_never_zero(self):
        self.monitor()
        self.journal([self.modern_event('RECOVERED',130,
                     observed_duration_seconds=None, duration_unknown=True)])
        self.run_cli('dispatch')
        text = self.calls()[0]['payload']['text']
        self.assertIn('неизвестна',text)
        self.assertNotIn('Длительность: 0 с.',text)

    def test_changed_context_is_not_reported_as_old_provider_recovery(self):
        self.monitor()
        self.journal([self.modern_event('RECOVERED',130, context_changed=True,
                     wall_time_trusted=False, observed_duration_seconds=30)])
        self.run_cli('dispatch')
        text=self.calls()[0]['payload']['text']
        self.assertIn('контекст подключения изменился',text)
        self.assertNotIn('работа восстановлена',text)
        self.assertIn('время не подтверждено',text)

    def test_clock_rollback_coalesces_unsent_failure_by_incident_identity(self):
        self.monitor()
        self.journal([self.modern_event('OPEN',100),self.modern_event('RECOVERED',50,
                     opened_at=100, observed_duration_seconds=20)])
        self.run_cli('dispatch')
        self.assertEqual([x['status'] for x in self.queue()],['COALESCED','SENT'])
        self.assertEqual(len(self.calls()),1)

    def test_non_alerting_events_do_not_block_queue_forever(self):
        self.monitor()
        self.journal([self.modern_event('STATE_CHANGED',101),self.modern_event(component='torrent')])
        self.run_cli('dispatch')
        self.assertEqual([x['status'] for x in self.queue()],['COALESCED','COALESCED'])
        self.assertEqual(self.calls(),[])

if __name__ == '__main__': unittest.main()
