"""Native-only macOS qualification; owned synthetic files, no Arbor runtime.
Usage: python3 qualify.py /absolute/launcher /absolute/compiled-probe
The same production agent-read/agent-write modes execute a hostile native
fixture, bypassing only BEAM's intentionally narrower executable allowlist.
"""
import hashlib, json, os, pathlib, struct, subprocess, sys, tempfile
launcher, probe = map(lambda p: pathlib.Path(p).resolve(), sys.argv[1:])

def invoke(mode, exe, args, cwd):
    stat, directory = exe.stat(), cwd.stat()
    digest = hashlib.sha256(exe.read_bytes()).hexdigest()
    argv = [str(launcher), mode, '5000', '65536', str(stat.st_dev), str(stat.st_ino),
            str(stat.st_size), str(int(stat.st_mtime)), str(int(stat.st_ctime)),
            str(stat.st_mode), digest, str(exe), str(directory.st_dev),
            str(directory.st_ino), str(cwd), '--', str(exe), *args]
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env={})
    output, terminal, error = b'', None, None
    def frame(tag):
        p.stdin.write(struct.pack('!I', 1) + bytes([tag])); p.stdin.flush()
    while True:
        n = p.stdout.read(4)
        if not n: break
        packet = p.stdout.read(struct.unpack('!I', n)[0])
        if packet[0] == 1: frame(10); frame(13)
        elif packet[0] == 2: output += packet[1:]
        elif packet[0] == 3:
            terminal = {'reason': packet[1], 'exit_code': struct.unpack('!I', packet[2:6])[0]}
            break
        elif packet[0] == 4: error = packet[1:].decode('utf-8', 'replace'); break
    p.stdin.close(); p.wait(timeout=10)
    return {'mode': mode, 'output': output.decode('utf-8', 'replace'),
            'terminal': terminal, 'error': error, 'launcher_exit': p.returncode}

with tempfile.TemporaryDirectory(prefix='arbor-native-containment-') as tmp:
    root = pathlib.Path(tmp).resolve(); cwd = root / 'work'; cwd.mkdir()
    (cwd/'input').write_text('synthetic'); (root/'outside').write_text('synthetic')
    (cwd/'.ssh').mkdir(); (cwd/'.ssh'/'id_ed25519').write_text('synthetic')
    (cwd/'escape').symlink_to(root/'outside')
    (cwd/'protected-link').symlink_to(cwd/'.ssh'/'id_ed25519')
    alias_path = cwd/'.SSH'/'ID_ED25519'
    same_inode_alias = alias_path.exists() and alias_path.stat().st_ino == (cwd/'.ssh'/'id_ed25519').stat().st_ino
    if not same_inode_alias:
        raise RuntimeError('qualification requires an actual case-insensitive alias fixture')
    cases = [('read', 'input', 'allowed'), ('write','output','allowed'),
             ('read', str(root/'outside'), 'denied'), ('write',str(root/'outside-new'),'denied'),
             ('read','.ssh/id_ed25519','denied'), ('read','escape','denied'),
             ('read','.SSH/ID_ED25519','denied'), ('read','protected-link','denied'),
             ('socket','unused','denied'), ('unix_socket','probe.sock','denied'),
             ('exec','unused','denied'), ('fork','unused','denied'),
             ('env','ARBOR_SYNTHETIC_CREDENTIAL','denied')]
    rows = []
    for operation, target, expected in cases:
        r = invoke('agent-write', probe, [operation,target], cwd)
        r.update(operation=operation, target=target if not target.startswith('/') else 'outside', expected=expected)
        r['passed'] = r['terminal'] == {'reason':0, 'exit_code':0} and r['output'] == expected+'\n'
        rows.append(r)
    readonly = invoke('agent-read', probe, ['write','readonly-output'], cwd)
    readonly.update(operation='readonly_write', expected='denied')
    readonly['passed'] = readonly['terminal'] == {'reason':0, 'exit_code':0} and readonly['output'] == 'denied\n'
    rows.append(readonly)
    for exe, args, expected in [(pathlib.Path('/bin/cat'), ['input'],'synthetic'),
                                (pathlib.Path('/usr/bin/touch'), ['real-touch'],'')]:
        r = invoke('agent-write', exe, args, cwd)
        r.update(operation=exe.name, expected=expected)
        r['passed'] = r['terminal'] == {'reason':0,'exit_code':0} and r['output'] == expected
        rows.append(r)
    print(json.dumps({'platform':os.uname().release, 'case_alias_same_inode':same_inode_alias,
        'launcher_sha256':hashlib.sha256(launcher.read_bytes()).hexdigest(),
        'probe_sha256':hashlib.sha256(probe.read_bytes()).hexdigest(),
        'rows':rows,'passed':all(r['passed'] for r in rows)}, indent=2))
    sys.exit(0 if all(r['passed'] for r in rows) else 1)
