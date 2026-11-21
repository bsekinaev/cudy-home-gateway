"""Execute the read-only WAN collector with fixed ubus/ip transcripts."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
COLLECTOR=ROOT/'scripts/observability/router-wan-probe.uc'
SOURCE='1'*40

@unittest.skipUnless(os.name!='nt' and shutil.which('ucode'),'POSIX ucode runtime required; Windows transport tested separately')
class WanProbeTests(unittest.TestCase):
    def run_probe(self, wan=None, lan=None, route='default via 192.0.2.1 dev eth1', raw=None):
        if wan is None: wan={'up':True,'proto':'dhcp','l3_device':'eth1','ipv4-address':[{'address':'192.0.2.2','mask':24}],'dns-server':['192.0.2.1'],'password':'DO_NOT_DISCLOSE'}
        if lan is None: lan={'up':True,'ipv4-address':[{'address':'192.168.1.1','mask':24}]}
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp)
            (base/'wan').write_text(raw if raw is not None else json.dumps(wan))
            (base/'lan').write_text(json.dumps(lan))
            (base/'route').write_text(route)
            (base/'calls').write_text('')
            for tool in ('ubus','ip'):
                path=base/tool
                path.write_text('#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\nb=Path(os.environ["HG_WAN_TEST"])\nwith (b/"calls").open("a") as f:f.write(" ".join(sys.argv)+"\\n")\nname="route" if Path(sys.argv[0]).name=="ip" else "lan" if "network.interface.lan" in sys.argv else "wan"\nprint((b/name).read_text())\n')
                path.chmod(0o755)
            env=dict(os.environ,PATH=tmp+os.pathsep+os.environ['PATH'],HG_WAN_TEST=tmp)
            r=subprocess.run(['ucode',str(COLLECTOR),SOURCE],env=env,text=True,capture_output=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            lines=r.stdout.splitlines()
            self.assertEqual(lines[0],'HG_WAN_READINESS_V1')
            data=json.loads(lines[1]);self.assertEqual(len(lines),2)
            self.assertEqual(data['source_commit'],SOURCE)
            self.assertNotIn('DO_NOT_DISCLOSE',r.stdout)
            self.assertNotRegex(r.stdout,r'\b(?:\d{1,3}\.){3}\d{1,3}\b')
            self.assertEqual(r.stderr,'')
            calls=(base/'calls').read_text()
            self.assertNotRegex(calls,r'uci|ifup|ifdown|restart|gateway|curl')
            return data

    def test_dhcp_address_route_are_separate_from_internet(self):
        r=self.run_probe()
        self.assertEqual(r['interface_state'],'UP')
        self.assertEqual(r['ipv4_address_state'],'PRESENT')
        self.assertEqual(r['ipv4_route_state'],'PRESENT')
        self.assertEqual(r['gateway_state'],'PRESENT')
        self.assertEqual(r['subnet_overlap'],'NO')
        self.assertEqual(r['dns_state'],'UNVERIFIED')
        self.assertEqual(r['internet_state'],'UNVERIFIED')

    def test_static_private_address_is_not_failure(self):
        r=self.run_probe(wan={'up':True,'proto':'static','l3_device':'eth1','ipv4-address':[{'address':'10.0.0.2','mask':24}]},route='default via 10.0.0.1 dev eth1')
        self.assertEqual(r['protocol'],'static');self.assertEqual(r['ipv4_address_scope'],'PRIVATE')
        self.assertEqual(r['ipv4_local_path_state'],'READY')

    def test_pppoe_device_route_without_via_is_valid(self):
        r=self.run_probe(wan={'up':True,'proto':'pppoe','l3_device':'pppoe-wan','ipv4-address':[{'address':'198.51.100.2','mask':32}]},route='default dev pppoe-wan scope link')
        self.assertEqual(r['ipv4_route_state'],'PRESENT')
        self.assertEqual(r['gateway_state'],'NOT_REQUIRED')
        self.assertEqual(r['ipv4_local_path_state'],'READY')

    def test_missing_route_does_not_become_ready(self):
        r=self.run_probe(route='')
        self.assertEqual(r['ipv4_route_state'],'MISSING');self.assertNotEqual(r['ipv4_local_path_state'],'READY')

    def test_unknown_protocol_not_ready_despite_address_and_route(self):
        r=self.run_probe(wan={'up':True,'proto':'mystery','l3_device':'eth1','ipv4-address':[{'address':'192.0.2.2','mask':24}]})
        self.assertEqual(r['protocol'],'OTHER');self.assertEqual(r['ipv4_local_path_state'],'UNSUPPORTED')

    def test_ipv6_only_explicitly_outside_ipv4_scope(self):
        r=self.run_probe(wan={'up':True,'proto':'dhcp','l3_device':'eth1','ipv6-address':[{'address':'2001:db8::1','mask':64}]},route='')
        self.assertEqual(r['ipv4_address_state'],'MISSING');self.assertEqual(r['ipv6_address_state'],'PRESENT')
        self.assertNotEqual(r['ipv4_local_path_state'],'READY')

    def test_partial_subnet_intersection_detected(self):
        r=self.run_probe(wan={'up':True,'proto':'dhcp','l3_device':'eth1','ipv4-address':[{'address':'192.168.0.2','mask':23}]},route='default via 192.168.0.1 dev eth1')
        self.assertEqual(r['subnet_overlap'],'YES');self.assertEqual(r['ipv4_local_path_state'],'CONFLICT')

    def test_all_lan_addresses_considered(self):
        r=self.run_probe(lan={'up':True,'ipv4-address':[{'address':'10.0.0.1','mask':24},{'address':'192.0.2.1','mask':24}]})
        self.assertEqual(r['subnet_overlap'],'YES')

    def test_missing_lan_is_unknown_not_no_overlap(self):
        r=self.run_probe(lan={})
        self.assertEqual(r['subnet_overlap'],'UNKNOWN');self.assertNotEqual(r['ipv4_local_path_state'],'READY')

    def test_malformed_and_oversized_input_is_unknown(self):
        for raw in ('{broken','[]','{"up":true,'+' '*33000+'"proto":"dhcp"}'):
            with self.subTest(raw=raw[:16]):
                r=self.run_probe(raw=raw)
                self.assertEqual(r['interface_state'],'UNKNOWN');self.assertNotEqual(r['ipv4_local_path_state'],'READY')

    def test_invalid_address_prefix_device_and_route_fail_closed(self):
        cases=[({'address':'999.0.0.2','mask':24},'eth1'),({'address':'192.0.2.2','mask':33},'eth1'),({'address':'192.0.2.2','mask':24},'eth1;echo DO_NOT_DISCLOSE')]
        for addr,dev in cases:
            with self.subTest(addr=addr,dev=dev):
                r=self.run_probe(wan={'up':True,'proto':'dhcp','l3_device':dev,'ipv4-address':[addr]})
                self.assertNotEqual(r['ipv4_local_path_state'],'READY')
        self.assertEqual(self.run_probe(route='default via 999.1.1.1 dev eth1')['ipv4_route_state'],'UNKNOWN')
        self.assertEqual(self.run_probe(route='default via 192.0.2.1 dev other')['ipv4_route_state'],'MISSING')

    def test_static_network_broadcast_hosts_are_not_ready_but_31_is_valid(self):
        for addr,prefix in [('10.0.0.0',24),('10.0.0.255',24),('10.0.0.0',31),('10.0.0.1',31)]:
            with self.subTest(addr=addr,prefix=prefix):
                r=self.run_probe(wan={'up':True,'proto':'static','l3_device':'eth1','ipv4-address':[{'address':addr,'mask':prefix}]},route='default via 10.0.0.1 dev eth1')
                self.assertEqual(r['ipv4_local_path_state']=='READY',prefix==31)

    def test_down_interface_does_not_become_ready(self):
        r=self.run_probe(wan={'up':False,'proto':'dhcp','l3_device':'eth1','ipv4-address':[{'address':'192.0.2.2','mask':24}]})
        self.assertEqual(r['interface_state'],'DOWN');self.assertNotEqual(r['ipv4_local_path_state'],'READY')

if __name__=='__main__':unittest.main()
