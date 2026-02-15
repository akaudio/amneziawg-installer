# SPDX-License-Identifier: MIT
# Author: remittor <remittor@gmail.com>
# Created: 2024
# PATCHED by: akaudio
# Patches applied:
#   1. Fixed obfuscation parameter mismatch (clients now use server params for Jc/Jmin/Jmax)
#   2. Using secrets module for crypto-safe PRNG
#   3. Added client name validation
#   4. Fixed logic: handle --make before reading config

import os
import sys
import glob
import subprocess
import optparse
import random
import datetime
import secrets
import re

g_main_config_src = '.main.config'
g_main_config_fn = None
g_main_config_type = None

g_defclient_config_fn = "_defclient.config"

parser = optparse.OptionParser("usage: %prog [options]")
parser.add_option("-t", "--tmpcfg", dest="tmpcfg", default = g_defclient_config_fn)
parser.add_option("-c", "--conf", dest="confgen", action="store_true", default = False)
parser.add_option("-q", "--qrcode", dest="qrcode", action="store_true", default = False)
parser.add_option("-a", "--add", dest="addcl", default = "")
parser.add_option("-u", "--update", dest="update", default = "")
parser.add_option("-d", "--delete", dest="delete", default = "")
parser.add_option("-i", "--ipaddr", dest="ipaddr", default = "")
parser.add_option("-p", "--port", dest="port", default = None, type = 'int')
parser.add_option("", "--make", dest="makecfg", default = "")
parser.add_option("", "--tun", dest="tun", default = "")
parser.add_option("", "--create", dest="create", action="store_true", default = False)
(opt, args) = parser.parse_args()


g_defserver_config = """
[Interface]
#_GenKeyTime = <SERVER_KEY_TIME>
PrivateKey = <SERVER_PRIVATE_KEY>
#_PublicKey = <SERVER_PUBLIC_KEY>
Address = <SERVER_ADDR>
ListenPort = <SERVER_PORT>
Jc = <JC>
Jmin = <JMIN>
Jmax = <JMAX>
S1 = <S1>
S2 = <S2>
H1 = <H1>
H2 = <H2>
H3 = <H3>
H4 = <H4>

#_Peer = <CLIENT_PUBLIC_KEY>
#_Name = <CLIENT_NAME>
#_AllowedIPs = <CLIENT_TUNNEL_IP>

PostUp = iptables -A FORWARD -i <INTERFACE> -j ACCEPT --wait 10 --wait-interval 50; iptables -t nat -A POSTROUTING -o <ADAPTER> -j MASQUERADE --wait 10 --wait-interval 50
PostDown = iptables -D FORWARD -i <INTERFACE> -j ACCEPT --wait 10 --wait-interval 50; iptables -t nat -D POSTROUTING -o <ADAPTER> -j MASQUERADE --wait 10 --wait-interval 50
"""

g_defclient_config = """
[Interface]
#_GenKeyTime = <CLIENT_KEY_TIME>
PrivateKey = <CLIENT_PRIVATE_KEY>
#_PublicKey = <CLIENT_PUBLIC_KEY>
Address = <CLIENT_TUNNEL_IP>
DNS = 1.1.1.1
Jc = <JC>
Jmin = <JMIN>
Jmax = <JMAX>
S1 = <S1>
S2 = <S2>
H1 = <H1>
H2 = <H2>
H3 = <H3>
H4 = <H4>

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY>
AllowedIPs = 0.0.0.0/0
Endpoint = <SERVER_ADDR>:<SERVER_PORT>
PersistentKeepalive = 25
"""


class IPAddr:
    def __init__(self, addr):
        if '/' in addr:
            ar = addr.split('/')
            self.ip = ar[0].strip()
            self.mask = ar[1].strip()
        else:
            self.ip = addr.strip()
            self.mask = None
        parts = self.ip.split('.')
        if len(parts) != 4:
            raise RuntimeError(f'ERROR: invalid ip address: "{addr}"')
        self.parts = [ int(x) for x in parts ]
        for x in self.parts:
            if x > 255 or x < 0:
                raise RuntimeError(f'ERROR: invalid ip address: "{addr}"')
        
    def __str__(self):
        return '.'.join([ str(x) for x in self.parts ])

    def calc_next(self):
        for i in range(len(self.parts) - 1, -1, -1):
            self.parts[i] += 1
            if self.parts[i] > 255:
                self.parts[i] = 0
                continue
            break


class ObjStorage:
    pass


def exec_cmd(cmd):
    try:
        output = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT).decode('utf-8')
    except subprocess.CalledProcessError as e:
        return e.returncode, e.output.decode('utf-8')
    return 0, output


def get_ext_ipaddr():
    rc, out = exec_cmd('curl -4 -s icanhazip.com')
    if rc != 0:
        raise RuntimeError(f'ERROR: Cannot get external IP address!')
    out = out.strip()
    if not out:
        raise RuntimeError(f'ERROR: Cannot get external IP address!')
    return out


def get_wgtool_list():
    lst = []
    for x in [ 'awg', 'wg' ]:
        rc, out = exec_cmd(f'which {x}')
        if rc == 0:
            lst.append(x)
    return lst

wgtool_list = get_wgtool_list()

if not wgtool_list:
    raise RuntimeError(f'ERROR: wg or awg not found!')

print(f'Available WireGuard tools: {", ".join(wgtool_list)}')


def genkey(wgtool = 'awg'):
    rc, out = exec_cmd(f'{wgtool} genkey')
    if rc != 0:
        raise RuntimeError(f'ERROR: Cannot generate private Key')
    priv_key = out.strip()
    if not priv_key:
        raise RuntimeError(f'ERROR: Cannot generate private Key')

    rc, out = exec_cmd(f'echo "{priv_key}" | {wgtool} pubkey')
    if rc != 0:
        raise RuntimeError(f'ERROR: Cannot generate public Key')
    pub_key = out.strip()
    if not pub_key:
        raise RuntimeError(f'ERROR: Cannot generate public Key')
    
    return priv_key, pub_key


def genpsk(wgtool = 'awg'):
    rc, out = exec_cmd(f'{wgtool} genpsk')
    if rc != 0:
        raise RuntimeError(f'ERROR: Cannot generate preshared Key')
    psk_key = out.strip()
    if not psk_key:
        raise RuntimeError(f'ERROR: Cannot generate preshared Key')    
    return psk_key


def get_main_config_path(check = False):
    global g_main_config_fn
    global g_main_config_type
    if os.path.exists(g_main_config_src):
        with open(g_main_config_src, 'r') as file:
            g_main_config_fn = file.read().strip()
    else:
        g_main_config_fn = None
        if check:
            raise RuntimeError(f'ERROR: Main config file not found!')
        return
    if not os.path.exists(g_main_config_fn):
        raise RuntimeError(f'ERROR: Main config file "{g_main_config_fn}" not found!')
    basename = os.path.basename(g_main_config_fn)
    if basename.startswith('awg'):
        g_main_config_type = 'AWG'
    elif basename.startswith('wg'):
        g_main_config_type = 'WG'
    else:
        g_main_config_type = None


def create_server_config(ipaddr, tun, port, ext_ipaddr):
    global g_main_config_fn
    global g_main_config_type
    if g_main_config_fn:
        raise RuntimeError(f'ERROR: Main config file "{g_main_config_fn}" already exists!')
    
    ipaddr = IPAddr(ipaddr)
    if not ipaddr.mask:
        raise RuntimeError(f'ERROR: Incorrect argument ipaddr = "{opt.ipaddr}"')
    
    if not tun:
        raise RuntimeError(f'ERROR: Incorrect argument tun = "{opt.tun}"')
    
    if not port:
        raise RuntimeError(f'ERROR: Incorrect argument port = "{opt.port}"')

    m_tun = tun
    m_ipaddr = ipaddr
    m_cfg_type = None
    
    for wgtool in wgtool_list:
        priv_key, pub_key = genkey(wgtool)
        if not priv_key or not pub_key:
            continue
        is_long_key = len(priv_key) == 44
        if is_long_key != (wgtool == 'awg'):
            continue
        print(f'Key length: {len(priv_key)}')
        if is_long_key:
            m_cfg_type = 'AWG'
            g_main_config_fn = f'{wgtool}{m_tun}.conf'
        else:
            m_cfg_type = 'WG'
            g_main_config_fn = f'{wgtool}{m_tun}.conf'            
        break
    
    if not m_cfg_type:
        raise RuntimeError(f'ERROR: Cannot detect config type!')
    
    g_main_config_type = m_cfg_type
    
    print(f'Generate server config "{g_main_config_fn}"')
    print(f'Config type: {m_cfg_type}')
    print(f'PrivateKey: {priv_key}')
    print(f'PublicKey: {pub_key}')

    jc = secrets.randbelow(125) + 3
    jmin = secrets.randbelow(698) + 3
    jmax = secrets.randbelow(1270 - jmin - 1) + jmin + 1

    out = g_defserver_config
    out = out.replace('<SERVER_PRIVATE_KEY>', priv_key)
    out = out.replace('<SERVER_PUBLIC_KEY>', pub_key)
    out = out.replace('<SERVER_KEY_TIME>', datetime.datetime.now().isoformat())
    out = out.replace('<SERVER_ADDR>', str(m_ipaddr))
    out = out.replace('<SERVER_PORT>', str(port))
    out = out.replace('<INTERFACE>', m_tun)
    out = out.replace('<ADAPTER>', 'ens6')
    out = out.replace('<JC>', str(jc))
    out = out.replace('<JMIN>', str(jmin))
    out = out.replace('<JMAX>', str(jmax))
    if m_cfg_type != 'AWG':
        out = out.replace('\nJc = <'  , '\n# ')
        out = out.replace('\nJmin = <', '\n# ')
        out = out.replace('\nJmax = <', '\n# ')
        out = out.replace('\nS1 = <'  , '\n# ')
        out = out.replace('\nS2 = <'  , '\n# ')
        out = out.replace('\nH1 = <'  , '\n# ')
        out = out.replace('\nH2 = <'  , '\n# ')
        out = out.replace('\nH3 = <'  , '\n# ')
        out = out.replace('\nH4 = <'  , '\n# ')
    else:
        out = out.replace('<S1>', str(secrets.randbelow(125) + 3))
        out = out.replace('<S2>', str(secrets.randbelow(125) + 3))
        out = out.replace('<H1>', str(secrets.randbelow(0x7FFFFF00 - 0x10000011 + 1) + 0x10000011))
        out = out.replace('<H2>', str(secrets.randbelow(0x7FFFFF00 - 0x10000011 + 1) + 0x10000011))
        out = out.replace('<H3>', str(secrets.randbelow(0x7FFFFF00 - 0x10000011 + 1) + 0x10000011))
        out = out.replace('<H4>', str(secrets.randbelow(0x7FFFFF00 - 0x10000011 + 1) + 0x10000011))
        
    with open(g_main_config_fn, 'w', newline = '\n') as file:
        file.write(out)
    
    print(f'{m_cfg_type} server config file "{g_main_config_fn}" created!')
    
    with open(g_main_config_src, 'w', newline = '\n') as file:
        file.write(g_main_config_fn)
    
    sys.exit(0)

# -------------------------------------------------------------------------------------

# CRITICAL FIX: Handle --make BEFORE reading config
if opt.makecfg:
    print(f'Make config "{opt.makecfg}"...')
    
    if not opt.ipaddr:
        raise RuntimeError(f'ERROR: Incorrect argument ipaddr = "{opt.ipaddr}"')
    ipaddr = IPAddr(opt.ipaddr)
    if not ipaddr.mask:
        raise RuntimeError(f'ERROR: Incorrect argument ipaddr = "{opt.ipaddr}"')
    
    if not opt.tun:
        raise RuntimeError(f'ERROR: Incorrect argument tun = "{opt.tun}"')
    
    if not opt.port:
        raise RuntimeError(f'ERROR: Incorrect argument port = "{opt.port}"')
    
    create_server_config(opt.ipaddr, opt.tun, opt.port, get_ext_ipaddr())
    # sys.exit(0) is already called inside create_server_config()

# Now load existing config for all other operations
get_main_config_path(check = True)

if opt.create:
    if os.path.exists(opt.tmpcfg):
        raise RuntimeError(f'ERROR: file "{opt.tmpcfg}" already exists!')

    print(f'Create template for client configs: "{opt.tmpcfg}"...')
    os.remove(opt.tmpcfg) if os.path.exists(opt.tmpcfg) else None
    if opt.ipaddr:
        ipaddr = opt.ipaddr
    else:
        ext_ipaddr = get_ext_ipaddr()
        print(f'External IP-Addr: "{ext_ipaddr}"')
        ipaddr = ext_ipaddr

    ipaddr = IPAddr(ipaddr)
    if ipaddr.mask:
        raise RuntimeError(f'ERROR: Incorrect argument ipaddr = "{opt.ipaddr}"')
    
    print(f'Server IP-Addr: "{ipaddr}"')
    
    out = g_defclient_config
    out = out.replace('<SERVER_ADDR>', str(ipaddr))
    if g_main_config_type != 'AWG':
        out = out.replace('\nJc = <'  , '\n# ')
        out = out.replace('\nJmin = <', '\n# ')
        out = out.replace('\nJmax = <', '\n# ')
        out = out.replace('\nS1 = <'  , '\n# ')
        out = out.replace('\nS2 = <'  , '\n# ')
        out = out.replace('\nH1 = <'  , '\n# ')
        out = out.replace('\nH2 = <'  , '\n# ')
        out = out.replace('\nH3 = <'  , '\n# ')
        out = out.replace('\nH4 = <'  , '\n# ')
        
    with open(opt.tmpcfg, 'w', newline = '\n') as file:
        file.write(out)
    
    print(f'Template "{opt.tmpcfg}" created!')
    sys.exit(0)

# -------------------------------------------------------------------------------------


srv = ObjStorage()
cfg = ObjStorage()
cfg.peer = {}

with open(g_main_config_fn, 'r') as file:
    lines = file.readlines()

comment_list = []
for ln in lines:
    ln = ln.rstrip()
    if ln.startswith('[Interface]'):
        current_section = 'server'
        continue
    if ln.startswith('[Peer]'):
        raise RuntimeError(f'ERROR: Unsupported config! Config must not contain [Peer] section!')
    if ln.startswith('#'):
        comment_list.append(ln)
        continue
    if not ln:
        continue
    if '=' not in ln:
        continue
    ar = ln.split('=', 1)
    name = ar[0].strip()
    value = ar[1].strip()

    if current_section == 'server':
        setattr(srv, name, value)

for comment in comment_list:
    if comment.startswith('#_Peer'):
        ar = comment.split('=', 1)
        value = ar[1].strip()
        peer = ObjStorage()
        peer.PublicKey = value
        cfg.peer[value] = peer
        continue

    if comment.startswith('#_Name'):
        ar = comment.split('=', 1)
        value = ar[1].strip()
        peer.Name = value
        continue

    if comment.startswith('#_AllowedIPs'):
        ar = comment.split('=', 1)
        value = ar[1].strip()
        peer.AllowedIPs = value
        continue

# -------------------------------------------------------------------------------------

if opt.addcl:
    c_name = opt.addcl.strip()
    if not re.match(r'^[a-zA-Z0-9_-]{1,63}$', c_name):
        raise RuntimeError(f'ERROR: Invalid client name: {c_name}. Use only: a-z A-Z 0-9 _ -')
    
    print(f'Add client "{c_name}"...')

    ipaddr = IPAddr(srv.Address)
    ipaddr.calc_next()
    
    for peer_name, peer in cfg.peer.items():
        if 'AllowedIPs' not in peer:
            continue
        cip = IPAddr(peer['AllowedIPs'])
        if cip.parts[3] >= ipaddr.parts[3]:
            ipaddr.parts[3] = cip.parts[3] + 1
    
    ipaddr.mask = '32'
    print(f'Client IP: {ipaddr}')

    priv_key, pub_key = genkey()
    psk = genpsk()

    srvcfg = '\n'
    srvcfg += f'[Peer]\n'
    srvcfg += f'PublicKey = {pub_key}\n'
    srvcfg += f'PresharedKey = {psk}\n'
    srvcfg += f'AllowedIPs = {ipaddr}\n'
    srvcfg += f'#_GenKeyTime = {datetime.datetime.now().isoformat()}\n'
    srvcfg += f'#_Peer = {pub_key}\n'
    srvcfg += f'#_Name = {c_name}\n'
    srvcfg += f'#_AllowedIPs = {ipaddr}\n'

    peer = ObjStorage()
    peer.Name = c_name
    peer.PublicKey = pub_key
    peer.PrivateKey = priv_key
    peer.PresharedKey = psk
    peer.AllowedIPs = str(ipaddr)
    cfg.peer[pub_key] = peer

    with open(g_main_config_fn, 'a', newline = '\n') as file:
        file.write(srvcfg)
    
    print(f'Client "{c_name}" added to server config!')

# -------------------------------------------------------------------------------------

if opt.update:
    print(f'Update peer "{opt.update}"...')
    peer_found = False
    for peer_name, peer in cfg.peer.items():
        if 'Name' not in peer:
            continue
        if peer['Name'] == opt.update:
            peer_found = True
            break
    if not peer_found:
        raise RuntimeError(f'ERROR: Peer "{opt.update}" not found!')
    
    priv_key, pub_key = genkey()
    psk = genpsk()
    
    old_pub_key = peer.PublicKey
    peer.PrivateKey = priv_key
    peer.PublicKey = pub_key
    peer.PresharedKey = psk
    
    with open(g_main_config_fn, 'r') as file:
        lines = file.readlines()
    
    new_lines = []
    peer_found = False
    for ln in lines:
        if ln.startswith('#_Peer') and old_pub_key in ln:
            peer_found = True
            new_lines.append(f'#_Peer = {pub_key}\n')
            continue
        if peer_found and ln.startswith('PublicKey'):
            new_lines.append(f'PublicKey = {pub_key}\n')
            continue
        if peer_found and ln.startswith('PresharedKey'):
            new_lines.append(f'PresharedKey = {psk}\n')
            peer_found = False
            continue
        new_lines.append(ln)
    
    with open(g_main_config_fn, 'w', newline = '\n') as file:
        file.writelines(new_lines)
    
    print(f'Peer "{opt.update}" updated!')

# -------------------------------------------------------------------------------------

if opt.delete:
    print(f'Delete peer "{opt.delete}"...')
    peer_found = False
    for peer_name, peer in cfg.peer.items():
        if 'Name' not in peer:
            continue
        if peer['Name'] == opt.delete:
            peer_found = True
            break
    if not peer_found:
        raise RuntimeError(f'ERROR: Peer "{opt.delete}" not found!')
    
    pub_key = peer.PublicKey
    
    with open(g_main_config_fn, 'r') as file:
        lines = file.readlines()
    
    new_lines = []
    skip_peer = False
    for ln in lines:
        if ln.startswith('#_Peer') and pub_key in ln:
            skip_peer = True
            continue
        if skip_peer and ln.startswith('[Peer]'):
            continue
        if skip_peer and ln.startswith('PublicKey'):
            continue
        if skip_peer and ln.startswith('PresharedKey'):
            continue
        if skip_peer and ln.startswith('AllowedIPs'):
            skip_peer = False
            continue
        if skip_peer and ln.startswith('#'):
            continue
        new_lines.append(ln)
    
    with open(g_main_config_fn, 'w', newline = '\n') as file:
        file.writelines(new_lines)
    
    del cfg.peer[pub_key]
    print(f'Peer "{opt.delete}" deleted!')

# -------------------------------------------------------------------------------------

if opt.confgen:
    if not os.path.exists(opt.tmpcfg):
        raise RuntimeError(f'ERROR: Template file "{opt.tmpcfg}" not found!')

    with open(opt.tmpcfg, 'r') as file:
        tmpcfg = file.read()

    print('Generate client configs...')
    flst = glob.glob("*.conf")
    for fn in flst:
        if fn.endswith(g_main_config_fn):
            continue
        if fn.endswith(opt.tmpcfg):
            continue
        if os.path.exists(fn):
            os.remove(fn)

    flst = glob.glob("*.png")
    for fn in flst:
        if os.path.exists(fn):
            os.remove(fn)

    random.seed()
    
    for peer_name, peer in cfg.peer.items():
        if 'Name' not in peer or 'PrivateKey' not in peer:
            print(f'Skip peer with pubkey "{peer["PublicKey"]}"')
            continue
        
        out = tmpcfg[:]
        out = out.replace('<CLIENT_PRIVATE_KEY>', peer['PrivateKey'])
        out = out.replace('<CLIENT_PUBLIC_KEY>', peer['PublicKey'])
        out = out.replace('<CLIENT_TUNNEL_IP>', peer['AllowedIPs'])
        out = out.replace('<JC>', srv['Jc'])
        out = out.replace('<JMIN>', srv['Jmin'])
        out = out.replace('<JMAX>', srv['Jmax'])
        out = out.replace('<S1>', srv['S1'])
        out = out.replace('<S2>', srv['S2'])
        out = out.replace('<H1>', srv['H1'])
        out = out.replace('<H2>', srv['H2'])
        out = out.replace('<H3>', srv['H3'])
        out = out.replace('<H4>', srv['H4'])
        out = out.replace('<SERVER_PORT>', srv['ListenPort'])
        out = out.replace('<SERVER_PUBLIC_KEY>', srv['PublicKey'])
        out = out.replace('<PRESHARED_KEY>', peer['PresharedKey'])
        fn = f'{peer["Name"]}.conf'
        with open(fn, 'w', newline = '\n') as file:
            file.write(out)

if opt.qrcode:
    print('Generate QR codes...')
    flst = glob.glob("*.png")
    for fn in flst:
        if os.path.exists(fn):
            os.remove(fn)

    try:
        import qrcode
    except:
        print('ERROR: qrcode module not found!')
        print('Install: pip install qrcode[pil]')
        sys.exit(1)

    flst = glob.glob("*.conf")
    for fn in flst:
        if fn.endswith(g_main_config_fn):
            continue
        if fn.endswith(opt.tmpcfg):
            continue
        
        print(f'Generate QR code for "{fn}"...')
        
        with open(fn, 'r') as file:
            data = file.read()
        
        qr = qrcode.QRCode(
            version=1,
            error_correction=qrcode.constants.ERROR_CORRECT_L,
            box_size=10,
            border=4,
        )
        qr.add_data(data)
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        img.save(fn.replace('.conf', '.png'))