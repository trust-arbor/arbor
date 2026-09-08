#!/usr/bin/env python3
"""Owner-operated Proxmox VM provisioning. No third-party Python dependencies."""

import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import uuid
import time
import urllib.error
import urllib.parse
import urllib.request


STATE = Path('/var/lib/private/arbor-vms')
ISO_ROOT = Path('/var/lib/vz/template/iso')
IMAGE_URL = ('https://cloud.debian.org/images/cloud/bookworm/20260907-2594/'
             'debian-12-genericcloud-amd64-20260907-2594.qcow2')
IMAGE_SHA512 = ('2bc4bad1dafce08937f04760d86fb735a35ca862c322a2c0018e86124bbac0d24f'
                'c276047559b11e31b51caf73a5d295e3259a0aef69506af6ec62ae0a71ab81')


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          stdout=subprocess.PIPE, **kwargs).stdout


def api(path):
    return json.loads(run('pvesh', 'get', path, '--output-format', 'json'))


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def numeric(value):
    if not re.fullmatch(r'[1-9][0-9]*', value):
        raise argparse.ArgumentTypeError('expected a positive decimal integer')
    return int(value)


def validate(args):
    if not 100 <= args.vmid <= 999999999:
        raise ValueError('VM ID must be between 100 and 999999999')
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', args.name):
        raise ValueError('name must be a lowercase DNS label')
    for name in (args.storage, args.bridge):
        if not re.fullmatch(r'[a-zA-Z][a-zA-Z0-9_-]{0,63}', name):
            raise ValueError('invalid storage or bridge name')
    if not (1 <= args.cores <= 48 and 1024 <= args.memory <= 131072
            and 8 <= args.disk <= 512):
        raise ValueError('outside reviewed bounds: 1-48 CPUs, 1-128 GiB RAM, 8-512 GiB disk')
    if args.profile == 'factory' and not args.ssh_public_key:
        raise ValueError('factory requires --ssh-public-key (never a private key)')
    if args.profile == 'sandbox' and args.ssh_public_key:
        raise ValueError('offline sandboxes use guest-local console credentials, not SSH')


def public_key(path):
    key = Path(path).read_text().strip()
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/]+={0,3}(?: [^\r\n]+)?', key):
        raise ValueError('expected one unadorned Ed25519 public key')
    run('ssh-keygen', '-lf', path)
    return key


def cloud_config(profile, name, key=None, password_hash=None):
    user = {'name': 'arbor' if profile == 'factory' else 'sandbox',
            'shell': '/bin/bash', 'lock_passwd': profile == 'factory'}
    commands = []
    files = []
    if profile == 'factory':
        user.update(ssh_authorized_keys=[key], sudo=['ALL=(ALL) NOPASSWD:ALL'])
        for filename in ('factory-system.sh', 'factory-user.sh', 'factory-runtime.sh'):
            files.append({'path': '/usr/local/lib/arbor-provision/' + filename,
                          'permissions': '0755', 'encoding': 'b64',
                          'content': base64.b64encode(
                              Path(__file__).with_name(filename).read_bytes()).decode()})
        commands.append(['/bin/bash', '/usr/local/lib/arbor-provision/factory-system.sh'])
    else:
        user['passwd'] = password_hash
        # No sudo, guest agent, passthrough, shared mounts, or host credentials.
        commands += [['systemctl', 'disable', '--now', 'ssh.service', 'ssh.socket'],
                     ['sh', '-c', 'ip -j address > /var/log/arbor-offline-addresses.json; '
                      'ip -j route > /var/log/arbor-offline-routes.json'],
                     ['sh', '-c', 'test "$(ls /sys/class/net)" = lo']]
    return {'hostname': name, 'manage_etc_hosts': True, 'users': [user],
            'disable_root': True, 'ssh_pwauth': False, 'ssh_deletekeys': True,
            'package_update': False, 'package_upgrade': False,
            'write_files': files, 'runcmd': commands,
            'final_message': 'Arbor guest initialization finished; inspect cloud-init status.'}


def vm_command(args, image, iso, owner):
    command = ['qm', 'create', str(args.vmid), '--name', args.name,
               '--description', 'arbor-provision-v1:' + owner,
               '--tags', 'arbor-managed;' + args.profile, '--ostype', 'l26',
               '--cores', str(args.cores), '--memory', str(args.memory),
               '--balloon', '0', '--cpu', 'host', '--scsihw', 'virtio-scsi-single',
               '--scsi0', f'{args.storage}:0,import-from={image},discard=on',
               '--ide2', f'local:iso/{iso.name},media=cdrom',
               '--boot', 'order=scsi0', '--serial0', 'socket', '--vga', 'serial0',
               '--onboot', '0', '--agent', '1' if args.profile == 'factory' else '0']
    if args.profile == 'factory':
        command += ['--net0', f'virtio,bridge={args.bridge},firewall=1']
    return command


def assert_offline(config):
    forbidden = [key for key in config if re.fullmatch(
        r'(net|hostpci|usb|virtiofs|ivshmem)\d*|args|hookscript', key)]
    if forbidden:
        raise ValueError('sandbox isolation violation: ' + ', '.join(forbidden))
    if str(config.get('agent', '0')) not in ('0', 'enabled=0'):
        raise ValueError('sandbox guest agent must remain disabled')


def owned(vmid):
    state = json.loads((STATE / str(vmid) / 'state.json').read_text())
    config = api(f'/nodes/{os.uname().nodename}/qemu/{vmid}/config')
    if config.get('description', '').strip() != 'arbor-provision-v1:' + state['owner']:
        raise ValueError('VM ownership marker mismatch; refusing operation')
    if state['profile'] == 'sandbox':
        assert_offline(config)
    return state, config


def console_role(roles):
    role = next((r for r in roles if r['roleid'] == 'ArborSandboxConsole'), None)
    if role and set(role['privs'].split(',')) != {'VM.Audit', 'VM.Console'}:
        raise ValueError('existing console role has unexpected privileges')
    return role


def console_login(vmid):
    state, _ = owned(vmid)
    if state['profile'] != 'sandbox':
        raise ValueError('console-only accounts are for offline sandboxes')
    directory = STATE / str(vmid)
    login = json.loads((directory / 'login.json').read_text())
    user = f'arbor-sandbox-{vmid}@pve'
    marker = 'arbor-provision-v1:' + state['owner']
    existing = next((u for u in api('/access/users') if u['userid'] == user), None)
    if existing and (existing.get('comment') != marker or 'console_password' not in login):
        raise ValueError('console account already exists without matching owned state')
    if not console_role(api('/access/roles')):
        run('pveum', 'role', 'add', 'ArborSandboxConsole', '--privs', 'VM.Audit VM.Console')
    if 'console_password' not in login:
        login.update(console_user=user, console_password=secrets.token_urlsafe(24),
                     console_expires=int(time.time()) + 86400)
        save(directory / 'login.json', login)
    if login['console_expires'] <= time.time():
        raise ValueError('console lease expired; operator must explicitly review any extension')
    if not existing:
        run('pveum', 'user', 'add', user, '--comment', marker,
            '--expire', login['console_expires'], '--enable', '1')
    # pveum reads non-TTY passwords from stdin. Never put them in argv or stdout.
    run('pveum', 'passwd', user, input=(login['console_password'] + '\n') * 2)
    run('pveum', 'acl', 'modify', f'/vms/{vmid}', '--users', user,
        '--roles', 'ArborSandboxConsole', '--propagate', '0')
    permissions = json.loads(run('pveum', 'user', 'permissions', user, '--output-format', 'json'))
    if (set(permissions) != {f'/vms/{vmid}'}
            or set(permissions[f'/vms/{vmid}']) != {'VM.Audit', 'VM.Console'}):
        raise ValueError('console user has unexpected effective permissions; do not delegate this login')
    print(f'Console login saved privately at {directory / "login.json"}; expires in 24h from creation.')


def verify_console(vmid):
    state, _ = owned(vmid)
    login = json.loads((STATE / str(vmid) / 'login.json').read_text())
    context = ssl.create_default_context(cafile='/etc/pve/pve-root-ca.pem')
    base = 'https://' + state['node'] + ':8006/api2/json'
    request = urllib.request.Request(base + '/access/ticket', data=urllib.parse.urlencode(
        {'username': login['console_user'], 'password': login['console_password']}).encode())
    with urllib.request.urlopen(request, context=context, timeout=15) as response:
        auth = json.load(response)['data']
    headers = {'Cookie': 'PVEAuthCookie=' + auth['ticket']}
    request = urllib.request.Request(base + f'/nodes/{state["node"]}/qemu/{vmid}/config', headers=headers)
    with urllib.request.urlopen(request, context=context, timeout=15) as response:
        assert_offline(json.load(response)['data'])
    # Read-only negative probe, never attempt to attach a NIC to test denial.
    request = urllib.request.Request(base + f'/nodes/{state["node"]}/storage/local/content', headers=headers)
    try:
        urllib.request.urlopen(request, context=context, timeout=15).close()
    except urllib.error.HTTPError as error:
        if error.code != 403:
            raise
    else:
        raise ValueError('sandbox console account can read host storage')
    print('Console API login passed; own VM readable, host storage denied (403).')


def digest_file(path):
    digest = hashlib.sha512()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def image_path():
    path = STATE / ('debian-' + IMAGE_SHA512[:16] + '.qcow2')
    if not path.exists():
        partial = path.with_suffix('.partial')
        run('curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
            '--retry', '3', '--max-time', '1800', '--output', partial, IMAGE_URL)
        if digest_file(partial) != IMAGE_SHA512:
            raise ValueError('cloud image digest mismatch; nothing will boot')
        partial.replace(path)
    if digest_file(path) != IMAGE_SHA512:
        raise ValueError('cached image digest mismatch')
    return path


def create(args):
    validate(args)
    key = public_key(args.ssh_public_key) if args.ssh_public_key else None
    if args.dry_run:
        print(json.dumps({'profile': args.profile, 'vmid': args.vmid, 'name': args.name,
                          'cores': args.cores, 'memory_mib': args.memory, 'disk_gib': args.disk,
                          'network': 'DHCP on ' + args.bridge if key else 'NO VIRTUAL NIC',
                          'image_url': IMAGE_URL, 'image_sha512': IMAGE_SHA512}, indent=2))
        return
    guests = api('/cluster/resources')
    if any(str(guest.get('vmid')) == str(args.vmid) for guest in guests):
        raise ValueError('VM ID occupied (VM or LXC); will not replace or reuse it')
    directory = STATE / str(args.vmid)
    if directory.exists():
        raise ValueError('previous state exists; inspect it instead of repeating create')
    node = os.uname().nodename
    storage = api(f'/nodes/{node}/storage/{args.storage}/status')
    if not storage.get('active') or storage['avail'] < args.disk * 1024**3:
        raise ValueError('storage unavailable or insufficient free space')
    host = api(f'/nodes/{node}/status')
    if host['memory']['available'] < (args.memory + 4096) * 1024**2:
        raise ValueError('insufficient available host RAM (4 GiB reserve required)')
    if key and not any(n['iface'] == args.bridge and n.get('active')
                       for n in api(f'/nodes/{node}/network')):
        raise ValueError('factory bridge is not active')
    image = image_path()
    directory.mkdir(mode=0o700)
    owner = str(uuid.uuid4())
    state = {'schema': 1, 'owner': owner, 'vmid': args.vmid, 'node': node,
             'name': args.name, 'profile': args.profile, 'phase': 'preparing',
             'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'image_url': IMAGE_URL, 'image_sha512': IMAGE_SHA512}
    save(directory / 'state.json', state)
    password_hash = None
    if not key:
        password = secrets.token_urlsafe(24)
        password_hash = run('openssl', 'passwd', '-6', '-stdin', input=password + '\n').strip()
        save(directory / 'login.json', {'username': 'sandbox', 'password': password,
                                      'vmid': args.vmid, 'transport': 'serial console only'})
    seed = directory / 'seed'
    seed.mkdir(mode=0o700)
    (seed / 'user-data').write_text('#cloud-config\n' + json.dumps(
        cloud_config(args.profile, args.name, key, password_hash)))
    (seed / 'meta-data').write_text(json.dumps({'instance-id': owner, 'local-hostname': args.name}))
    network = ({'version': 2, 'ethernets': {'factory': {'match': {'name': 'en*'},
                'dhcp4': True, 'dhcp6': False}}} if key else {'version': 2, 'ethernets': {}})
    (seed / 'network-config').write_text(json.dumps(network))
    ISO_ROOT.mkdir(parents=True, exist_ok=True)
    iso = ISO_ROOT / f'arbor-{args.vmid}-{owner}.iso'
    run('genisoimage', '-quiet', '-output', iso, '-volid', 'cidata', '-joliet', '-rock',
        'user-data', 'meta-data', 'network-config', cwd=seed)
    iso.chmod(0o600)
    state['seed_iso'] = str(iso)
    save(directory / 'state.json', state)
    # No rollback deletion: interrupted imports remain identifiable to the owner.
    run(*vm_command(args, image, iso, owner))
    run('qm', 'resize', args.vmid, 'scsi0', f'{args.disk}G')
    owned(args.vmid)
    state['phase'] = 'created'
    save(directory / 'state.json', state)
    print(json.dumps(state, indent=2))
    print('Created stopped. Use start, then inspect cloud-init; creation is not readiness.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('inventory')
    new = sub.add_parser('create')
    new.add_argument('--profile', choices=['factory', 'sandbox'], required=True)
    new.add_argument('--vmid', type=numeric, required=True)
    new.add_argument('--name', required=True)
    new.add_argument('--cores', type=numeric, default=4)
    new.add_argument('--memory', type=numeric, default=8192)
    new.add_argument('--disk', type=numeric, default=32)
    new.add_argument('--storage', default='local-zfs')
    new.add_argument('--bridge', default='vmbr0')
    new.add_argument('--ssh-public-key')
    new.add_argument('--dry-run', action='store_true')
    for command in ('status', 'start', 'shutdown', 'console', 'console-login', 'verify-console'):
        child = sub.add_parser(command)
        child.add_argument('vmid', type=numeric)
    args = parser.parse_args()
    if args.command == 'create' and args.dry_run:
        create(args)
        return
    if os.geteuid() != 0:
        parser.error('run on the Proxmox host as its operator (root)')
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    if STATE.is_symlink() or STATE.stat().st_uid != 0 or STATE.stat().st_mode & 0o077:
        raise ValueError('state root must be root-owned, private, and not a symlink')
    with (STATE / 'provision.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.command == 'inventory':
            node = os.uname().nodename
            report = {'version': run('pveversion'), 'node': api(f'/nodes/{node}/status'),
                      'resources': api('/cluster/resources'),
                      'network': api(f'/nodes/{node}/network'),
                      'disks': json.loads(run('lsblk', '--json', '-o', 'NAME,SIZE,TYPE,MOUNTPOINTS,MODEL'))}
            save(STATE / 'inventory.json', report)
            print(json.dumps(report, indent=2))
        elif args.command == 'create':
            create(args)
        elif args.command == 'console-login':
            console_login(args.vmid)
        elif args.command == 'verify-console':
            verify_console(args.vmid)
        else:
            state, config = owned(args.vmid)
            if args.command == 'status':
                print(json.dumps({'state': state, 'config': config,
                                  'runtime': api(f'/nodes/{state["node"]}/qemu/{args.vmid}/status/current')},
                                 indent=2))
            elif args.command == 'console':
                # exec closes the owner lock; callers must hold their own restricted
                # Proxmox console permission. This script is not an agent auth API.
                os.execvp('qm', ['qm', 'terminal', str(args.vmid)])
            else:
                print(run('qm', args.command, args.vmid))


if __name__ == '__main__':
    try:
        main()
    except BlockingIOError:
        sys.exit('Another provisioning operation holds the host lock. Inspect status and retry after it finishes.')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
