import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / 'src/usr/lib/home-gateway/vpn-candidate.uc'


class CandidateConfigTests(unittest.TestCase):
    def setUp(self):
        self.node = {
            'type': 'Xray', 'protocol': 'vless', 'transport': 'xhttp',
            'address': 'vpn.example.net', 'port': '443',
            'uuid': '12345678-1234-1234-1234-123456789abc',
            'tls': '1', 'tls_allowInsecure': '0', 'tls_serverName': 'vpn.example.net',
            'xhttp_path': '/vpn'
        }

    def render(self, port='51082'):
        return subprocess.run(
            ['ucode', str(RENDERER), port], input=json.dumps(self.node),
            text=True, capture_output=True, timeout=5,
        )

    def test_config_has_one_loopback_listener_and_one_tls_outbound(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual(len(config['inbounds']), 1)
        self.assertEqual(config['inbounds'][0]['listen'], '127.0.0.1')
        self.assertEqual(config['inbounds'][0]['port'], 51082)
        self.assertFalse(config['inbounds'][0]['settings']['udp'])
        self.assertEqual(len(config['outbounds']), 1)
        stream = config['outbounds'][0]['streamSettings']
        self.assertEqual(stream['security'], 'tls')
        self.assertFalse(stream['tlsSettings']['allowInsecure'])

    def test_insecure_tls_and_production_port_are_rejected_without_config(self):
        self.assertEqual(self.render('1082').stdout, '')
        self.node['tls_allowInsecure'] = '1'
        result = self.render()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertNotIn(self.node['uuid'], result.stderr)

    def test_reality_grpc_credentials_and_transport(self):
        self.node.update(transport='grpc', reality='1', fingerprint='chrome',
                         reality_publicKey='a' * 43, reality_shortId='12ab',
                         grpc_serviceName='vpn', grpc_mode='multi')
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        stream = json.loads(result.stdout)['outbounds'][0]['streamSettings']
        self.assertEqual(stream['security'], 'reality')
        self.assertEqual(stream['realitySettings']['shortId'], '12ab')
        self.assertTrue(stream['grpcSettings']['multiMode'])

    def test_reality_raw_vision_and_invalid_short_id(self):
        self.node.pop('xhttp_path')
        self.node.update(transport='raw', reality='1', fingerprint='firefox',
                         reality_publicKey='a' * 43, reality_shortId='12ab',
                         flow='xtls-rprx-vision')
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        outbound = json.loads(result.stdout)['outbounds'][0]
        self.assertEqual(outbound['streamSettings']['network'], 'raw')
        self.assertEqual(outbound['settings']['vnext'][0]['users'][0]['flow'],
                         'xtls-rprx-vision')
        self.node['reality_shortId'] = 'abc'
        self.assertEqual(self.render().returncode, 2)

    def test_unknown_transport_and_advanced_xhttp_are_rejected(self):
        self.node['xhttp_extra'] = '{}'
        self.assertEqual(self.render().returncode, 2)
        self.node['transport'] = 'custom'
        self.assertEqual(self.render().returncode, 2)


if __name__ == '__main__':
    unittest.main()
