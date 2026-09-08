"""Run without Proxmox/root/network: python3 -m unittest discover -s scripts/proxmox."""
import argparse
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import provision


class ProvisionTest(unittest.TestCase):
    def args(self, **overrides):
        values = dict(vmid=900, name='arbor-test', profile='sandbox', cores=4,
                      memory=8192, disk=32, storage='local-zfs', bridge='vmbr0',
                      ssh_public_key=None, dry_run=False)
        return argparse.Namespace(**(values | overrides))

    def test_invalid_arguments_are_rejected(self):
        for overrides in ({'vmid': 99}, {'name': 'x;id'}, {'storage': '../other'},
                          {'bridge': 'a,b'}, {'cores': 0}, {'disk': 513},
                          {'profile': 'factory'}, {'ssh_public_key': 'ambient-key'}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                provision.validate(self.args(**overrides))

    def test_security_offline_vm_has_no_network_or_passthrough(self):
        command = provision.vm_command(self.args(), Path('/image'), Path('/seed.iso'), 'owner')
        self.assertNotIn('--net0', command)
        self.assertEqual(command[command.index('--agent') + 1], '0')
        self.assertNotIn('--args', command)
        self.assertNotIn('--virtiofs0', command)

    def test_security_rejects_network_and_other_backdoors_before_start(self):
        for key in ['net0', 'net7', 'args', 'hostpci0', 'usb0', 'virtiofs0', 'hookscript']:
            with self.subTest(key=key), self.assertRaises(ValueError):
                provision.assert_offline({key: 'something'})
        with self.assertRaises(ValueError):
            provision.assert_offline({'agent': '1'})
        provision.assert_offline({'agent': '0', 'serial0': 'socket'})

    def test_security_sandbox_no_privilege_or_network_bootstrap(self):
        config = provision.cloud_config('sandbox', 'box', password_hash='$6$hash')
        self.assertFalse(config['ssh_pwauth'])
        self.assertFalse(config['package_update'])
        self.assertEqual(config['write_files'], [])
        user = config['users'][0]
        self.assertNotIn('sudo', user)
        self.assertNotIn('ssh_authorized_keys', user)
        self.assertEqual(user['passwd'], '$6$hash')

    def test_factory_separates_operator_access_from_offline_profile(self):
        args = self.args(profile='factory', ssh_public_key='/key.pub')
        command = provision.vm_command(args, Path('/image'), Path('/seed.iso'), 'owner')
        self.assertIn('--net0', command)
        config = provision.cloud_config('factory', 'factory', key='ssh-ed25519 AAAA')
        self.assertTrue(config['users'][0]['lock_passwd'])
        self.assertEqual(len(config['write_files']), 3)

    def test_security_occupied_vm_id_never_mutates_existing_guest(self):
        for kind in ['qemu', 'lxc']:
            with patch.object(provision, 'api', return_value=[{'vmid': 900, 'type': kind}]), \
                    patch.object(provision, 'run') as run, self.assertRaises(ValueError):
                provision.create(self.args())
            run.assert_not_called()

    def test_security_foreign_ownership_denies_control(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(provision, 'STATE', Path(tmp)):
            directory = Path(tmp) / '900'
            directory.mkdir()
            provision.save(directory / 'state.json', {'owner': 'ours', 'profile': 'sandbox'})
            with patch.object(provision, 'api', return_value={'description': 'someone else'}), \
                    self.assertRaises(ValueError):
                provision.owned(900)

    def test_state_and_credentials_are_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'login.json'
            provision.save(path, {'password': 'test-only'})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_security_console_role_cannot_gain_host_or_network_authority(self):
        self.assertIsNone(provision.console_role([]))
        for privileges in ['VM.Audit,VM.Console,VM.Config.Network', 'Sys.Console', 'Administrator']:
            with self.subTest(privileges=privileges), self.assertRaises(ValueError):
                provision.console_role([{'roleid': 'ArborSandboxConsole', 'privs': privileges}])
        self.assertIsNotNone(provision.console_role([
            {'roleid': 'ArborSandboxConsole', 'privs': 'VM.Console,VM.Audit'}]))


if __name__ == '__main__':
    unittest.main()
