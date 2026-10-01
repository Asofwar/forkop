"""Exercise the actual ucode compiler, including refusal of unsafe policies."""
import copy
import json
import os
from pathlib import Path
import subprocess

work = Path(os.environ['GUARD_TEST_DIR'])
library = os.environ['FORKOP_LIB']
module = os.environ['GUARD_MODULE']
ruleset = work / 'domains.json'
ruleset.write_text(json.dumps({'version': 3, 'rules': [{'domain_suffix': ['listed.test']}]}), encoding='utf-8')
nft = '''table inet ForkopTable {
set forkop_interfaces { type ifname; elements = { "lo" }; }
set localv4 { type ipv4_addr; flags interval; elements = { 127.0.0.0/8 }; }
set localv6 { type ipv6_addr; flags interval; elements = { ::1 }; }
set forkop_rule_main_subnets { type ipv4_addr; flags interval; elements = { 203.0.113.0/24 }; }
set forkop_rule_main_subnets6 { type ipv6_addr; flags interval; elements = { 2001:db8:2::/64 }; }
set forkop_rule_Zapret_subnets { type ipv4_addr; flags interval; elements = { 198.51.100.0/24 }; }
chain priority_rules {
iifname @forkop_interfaces ip daddr @forkop_rule_Zapret_subnets counter packets 1 bytes 10 accept
iifname @forkop_interfaces ip daddr @forkop_rule_main_subnets meta mark set 0x04000000 counter packets 2 bytes 20 accept
iifname @forkop_interfaces ip6 daddr @forkop_rule_main_subnets6 meta mark set 0x04000000 counter packets 0 bytes 0 accept
}
}'''
fixture = {
    'sections': [{'.name': 'main', 'action': 'connection', 'enabled': '1'}, {'.name': 'Zapret', 'action': 'zapret'}],
    'interfaces': ['lo'], 'nft': nft,
    'config': {
        'outbounds': [{'type': 'direct', 'tag': 'direct-out'}, {'type': 'direct', 'tag': 'main-vpn', 'bind_interface': 'wg-test'},
                      {'type': 'selector', 'tag': 'main-out', 'outbounds': ['main-vpn']}],
        'route': {'rule_set': [{'type': 'local', 'tag': 'list', 'format': 'source', 'path': str(ruleset)}], 'rules': [
            {'action': 'route', 'inbound': ['tproxy-in'], 'outbound': 'Zapret-out', 'domain_suffix': ['video.test'], 'source_ip_cidr': ['192.0.2.1', '2001:db8:1::1']},
            {'action': 'route', 'inbound': ['tproxy-in'], 'outbound': 'main-out', 'domain_suffix': ['openai.test', 'video.test']},
            {'action': 'route', 'inbound': ['tproxy-in'], 'outbound': 'main-out', 'rule_set': 'list'},
        ]},
    },
}


def compile_case(value, success=True):
    path = work / 'fixture.json'
    path.write_text(json.dumps(value), encoding='utf-8')
    p = subprocess.run(['ucode', '-L', library, module, 'compile-fixture', str(path)], capture_output=True, text=True)
    assert (p.returncode == 0) == success, p.stderr
    return json.loads(p.stdout) if success else p.stderr


plan = compile_case(fixture)
assert plan['marks'][0] == {'mark': 0x28010000, 'interface': 'wg-test'}
assert len(plan['dns']['profiles']) == 2
assert 'server=/openai.test/\n' in plan['dns']['profiles'][0]['config']
assert 'server=/listed.test/\n' in plan['dns']['profiles'][0]['config']
assert 'server=/video.test/\n' in plan['dns']['profiles'][0]['config']
assert 'server=/video.test/#\n' in plan['dns']['profiles'][1]['config']
assert '@forkop_rule_main_subnets counter reject' in plan['nft']
assert '@forkop_rule_Zapret_subnets counter return' in plan['nft']
assert 'meta mark set' not in plan['nft'], plan['nft']
assert 'type filter hook forward priority -10' in plan['nft']
assert 'oifname != "wg-test" counter reject' in plan['nft']
assert 'ip saddr { 192.0.2.1 } udp dport 53 redirect to :18054' in plan['nft']
assert 'ip6 daddr fc00::/18 counter reject' in plan['nft']

unsafe = copy.deepcopy(fixture)
unsafe['config']['outbounds'][-1]['outbounds'].append('direct-out')
assert 'direct WAN path' in compile_case(unsafe, False)
unsafe = copy.deepcopy(fixture)
unsafe['config']['route']['rules'][1]['domain_regex'] = ['.*openai.*']
assert 'regex/keyword' in compile_case(unsafe, False)
unsafe = copy.deepcopy(fixture)
unsafe['config']['route']['rules'][0]['ip_cidr'] = ['198.51.100.0/24']
assert 'server=/video.test/#\n' in compile_case(unsafe)['dns']['profiles'][1]['config']
unsafe['config']['route']['rules'][0]['port'] = [443]
assert 'extra condition' in compile_case(unsafe, False)
unsafe = copy.deepcopy(fixture)
unsafe['config']['outbounds'][-1]['outbounds'] = ['main-out']
assert 'cyclic' in compile_case(unsafe, False)

# Exact exceptions must not exempt their subdomains.
exact = copy.deepcopy(fixture)
exact['config']['route']['rules'].insert(0, {'action': 'route', 'inbound': ['tproxy-in'], 'outbound': 'bypass-out', 'domain': 'login.openai.test'})
data = compile_case(exact)['dns']['profiles'][0]['config']
assert 'server=/login.openai.test/#\n' in data
assert 'server=/*.login.openai.test/\n' in data
assert 'nftset=/login.openai.test/4#inet#ForkopVpnGuard#dns_except_04' in data

dot = copy.deepcopy(fixture)
dot['config']['route']['rules'].append({'action': 'route', 'outbound': 'main-out', 'domain_suffix': ['.ua']})
data = compile_case(dot)['dns']['profiles'][0]['config']
assert 'server=/ua/#\n' in data and 'server=/*.ua/\n' in data

# Shutdown checkpoints retain only unexpired addresses from the same policy.
learned = copy.deepcopy(fixture)
learned['now'] = 1000
learned['learned'] = {'time': 900, 'dns': plan['dns'], 'sets': {'dns_except_14': [
    {'ip': '203.0.113.1', 'until': 1100}, {'ip': '203.0.113.2', 'until': 999},
    {'ip': '203.0.113.3; accept', 'until': 1100}]}}
restored = compile_case(learned)['nft']
assert '203.0.113.1 timeout 100s' in restored
assert '203.0.113.2 timeout' not in restored and '; accept' not in restored
learned['learned']['dns']['domains'] += 1
assert '203.0.113.1 timeout' not in compile_case(learned)['nft']

(work / 'guard.nft').write_text(plan['nft'], encoding='utf-8')
for profile in plan['dns']['profiles']:
    (work / f"dns-{profile['mask']}.conf").write_text(profile['config'], encoding='utf-8')
print('PASS: actual ucode compiler; source-specific Zapret exception; domain list; IPv4/IPv6 guard; exact/suffix priority; unsafe direct/regex/compound/cycle refusal')

# Optional real nft parser in an isolated Linux network namespace.
if os.environ.get('FORKOP_GUARD_KERNEL_TEST') == '1':
    subprocess.run(['unshare', '-n', 'nft', '-c', '-f', str(work / 'guard.nft')], check=True)
    print('PASS: kernel nft validation in an isolated network namespace')
