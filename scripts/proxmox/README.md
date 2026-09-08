# Proxmox Factory and Offline Guests

Owner-operated provisioning for Proxmox VE 9, tested on 9.2.11 on 2026-09-07.
Run `provision.py` on the hypervisor using an existing, verified SSH connection.
Python 3 standard library handles JSON and argv; Bash handles guest installation.
No OpenTofu provider, API token, state backend, or host package upgrade is required.

## Boundaries

- Both profiles use KVM VMs. Untrusted sandboxes do not share the hypervisor kernel
  as LXC would. LXC support is intentionally not part of this first implementation.
- Factory: trusted operator account, unique SSH key, DHCP NIC, rootless Podman,
  pinned Elixir/OTP and source commit, SQLite, fresh Arbor identities. Guest firewall
  allows inbound SSH only (plus DHCP/ICMP); access dev HTTP using SSH forwards.
- Sandbox: **no virtual NIC from its first boot**, no guest agent, passthrough,
  shared host filesystem, sudo, or SSH service. Loopback is available inside the VM.
  It cannot download packages; the initial image supplies only basic Linux tools.
- Console is deliberately an out-of-band channel. The agent receives a guest
  password plus a 24-hour PVE login with only `VM.Console` and `VM.Audit` on its VM.
  It must never receive the owner's hypervisor root key. This is guest network
  isolation, not protection against an operator relaying data through the console.
- Provisioning copies no OAuth tokens, `.env`, existing private keys, cluster
  cookies, or personal memory stores. Provider authentication is a separate
  operator step; explicitly authorized API keys may be installed individually.
- This is operator tooling, **not** an authorization API for arbitrary agents.
  An Arbor-facing provision action with task-scoped authorization is follow-up work.

## Deploy the Tools

Replace `PVE_HOST` with your host; it must already be in your SSH known-hosts file.
Run these from the repository on your operator machine:

```bash
ssh -o StrictHostKeyChecking=yes root@PVE_HOST 'install -d -m 0700 /root/arbor-provision'
scp -o StrictHostKeyChecking=yes scripts/proxmox/*.py scripts/proxmox/*.sh root@PVE_HOST:/root/arbor-provision/
ssh root@PVE_HOST 'python3 /root/arbor-provision/provision.py inventory'
```

Inventory persists privately at `/var/lib/private/arbor-vms/inventory.json`.
It is an infrastructure map: keep it in ignored/private storage, not a public repo.
The script uses `local-zfs` for disks and the standard `local` ISO directory;
it does not modify shared storage, management bridges, or backups. On hosts with
a relocated `local` storage path, adapt `ISO_ROOT` before use.

## Factory

Generate a **new** operator key per guest; do not overwrite an existing key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/arbor-factory-01
scp ~/.ssh/arbor-factory-01.pub root@PVE_HOST:/root/arbor-provision/factory.pub
ssh root@PVE_HOST 'python3 /root/arbor-provision/provision.py create --profile factory --vmid 9100 --name arbor-factory-01 --cores 16 --memory 49152 --disk 160 --ssh-public-key /root/arbor-provision/factory.pub --dry-run'
# Review the plan, then repeat without --dry-run.
ssh root@PVE_HOST 'python3 /root/arbor-provision/provision.py start 9100'
ssh root@PVE_HOST 'qm guest cmd 9100 network-get-interfaces'
```

On networks with a MAC allowlist, inspect `qm config 9100` and approve `net0`'s MAC
before starting. There is no automatic allowlist bypass or new NAT route. If the
initial system setup failed before access was allowed, retry the root-owned
`/usr/local/lib/arbor-provision/factory-system.sh` inside the guest. Its network
preflight distinguishes this from missing packages. The original cloud-init error
remains historical evidence; use the retry log, system-ready marker, and actual
tool checks to establish recovery, not the generic cloud-init final message.

Pin the first guest SSH host key via the hypervisor's guest agent or console.
Then, inside the guest as `arbor`:

```bash
/usr/local/lib/arbor-provision/factory-user.sh REPO_HTTP_URL FULL_COMMIT_SHA
```

The URL may be internal HTTP or public HTTPS; no embedded credentials are accepted.
A full SHA prevents a moving branch from silently becoming the baseline. Re-running
refuses a dirty checkout or a different revision. A failed clone/build is preserved,
not reset. The installer honors the pinned repo's `.tool-versions` through mise.

The seed also installs `factory-runtime.sh`, independently of the pinned source:

```bash
bash /usr/local/lib/arbor-provision/factory-runtime.sh worker
bash /usr/local/lib/arbor-provision/factory-runtime.sh baseline
bash /usr/local/lib/arbor-provision/factory-runtime.sh start
cd ~/code/arbor
./bin/mix arbor.login xai
./bin/mix arbor.login status
./bin/mix arbor.doctor --validation
```

`worker` installs the checksum-pinned Grok 0.2.118 Linux binary; coding plans select
`grok-4.6`. The system installer includes bubblewrap for Grok's Linux sandbox;
installation and OAuth alone do not prove that a restricted ACP session can start.
The digest was observed from xAI's official HTTPS download, not a vendor
signature. `baseline` pulls the exact reviewed Containerfile base, builds, then
activates the operator-owned dependency baseline. It never skips build failures.
`start` initializes a loopback node address and local model default if absent; it
does not dispatch an LLM call or join another installation's cluster. An already
running node requires an explicit `./bin/mix arbor.restart` after activation.

Finish coordinator creation, caller registration/grants, provider login and exact
plan readiness using [Software Factory](../../docs/arbor/SOFTWARE_FACTORY.md) and
[Coding Task Dispatch](../../docs/arbor/CODING_TASK_DISPATCH.md). A booted daemon is
not a ready factory. The binding council has separate provider requirements; see
[Council Setup](../../docs/arbor/COUNCIL_SETUP.md). Missing credentials are blockers,
not a reason to waive review or reuse another installation's refresh tokens.
For the stock three-provider council, log in separately to OpenAI on the guest
using an SSH-forwarded loopback callback. Install the explicitly authorized Ollama
API key privately and use `ARBOR_OLLAMA_CHAT_BASE_URL=https://ollama.com` so cloud
reviewers do not redirect embeddings off-host. Recheck exact-plan readiness and
live provider requests; a discoverable adapter is not proof of authentication.

Forward guest ports instead of exposing development endpoints to the LAN:

```bash
ssh -i ~/.ssh/arbor-factory-01 -L 14000:127.0.0.1:4000 -L 14001:127.0.0.1:4001 arbor@GUEST_IP
```

For programmatic ExMCP clients, reuse a connection and call
`ExMCP.Client.disconnect(client)` before `ExMCP.Client.stop(client)` when finished.
The pinned dependency's `stop/1` alone does not close its stdio transport and left
SSH signing proxies running during this qualification. Explicit disconnect then
stop was verified to reap the extra guest process. Keep signer private keys on
the guest; launch its signing proxy over SSH rather than copying the key locally.

## Offline Sandbox

```bash
ssh root@PVE_HOST 'python3 /root/arbor-provision/provision.py create --profile sandbox --vmid 9101 --name arbor-sandbox-01 --cores 2 --memory 2048 --disk 16'
ssh root@PVE_HOST 'python3 /root/arbor-provision/provision.py start 9101'
ssh root@PVE_HOST 'python3 /root/arbor-provision/provision.py console-login 9101'
ssh root@PVE_HOST 'python3 /root/arbor-provision/provision.py verify-console 9101'
```

Credentials are mode `0600` at `/var/lib/private/arbor-vms/9101/login.json`.
Transfer that file privately to the intended agent. It contains a guest login and
PVE-realm console login, **not** SSH access to the hypervisor. Use the Proxmox HTTPS
UI's VM console with a verified CA/certificate. The console role cannot add NICs,
change hardware, power guests, read host storage, or open the host console.
The account expires after 24 hours; extension/revocation remains owner-controlled.

An owner can verify guest isolation over serial without exposing passwords in
commands or output (operator machine requires Expect and jq):

```bash
expect scripts/proxmox/verify-sandbox.exp PVE_HOST 9101 PRIVATE_LOGIN_JSON
```

This asserts real login, non-root UID, only loopback, no route, IPv4/IPv6 outbound
`ENETUNREACH`, and no sudo. It exits nonzero on failed assertions or timeout.
`verify-console` logs in over certificate-verified HTTPS as the restricted PVE
user, reads only its VM, and checks host-storage access is denied.

## Lifecycle and Verification

`create` is create-only, not a destructive reconcile: any occupied VM/LXC ID or
existing state directory causes a refusal. A host-local flock serializes commands
from these scripts. Proxmox itself arbitrates concurrent creates by other tools.
Ownership UUIDs bind subsequent operations; configuration changes that add sandbox
network/passthrough cause refusal before `start` or console operations. Ordinary PVE
administrators remain trusted and can override configuration outside these tools.
Resources are left stopped unless explicitly started, with autostart disabled.

`status VMID` reports desired profile, creation state, actual config and runtime.
`shutdown VMID` requests graceful shutdown. There is deliberately no automated
delete: inspect interrupted disks/ISO/state and revoke the console account before
an owner-approved destroy. Retain work/evidence first. Seed images contain password
hashes and are private; login files must never enter images, commits or task logs.

```bash
python3 -m unittest discover -s scripts/proxmox -v
for script in scripts/proxmox/*.sh; do bash -n "$script" || exit; done
shellcheck scripts/proxmox/*.sh
```

Provisioning packages follow Debian's signed repositories; this is not a fully
reproducible OS build. Image digest, Git SHA, toolchain pins, installed-package list,
and Arbor's separate validation baseline document identify what was actually used.

References: [Proxmox Cloud-Init](https://pve.proxmox.com/wiki/Cloud-Init_Support),
[Debian cloud images](https://cloud.debian.org/images/cloud/),
[mise installation](https://mise.jdx.dev/installing-mise.html),
[official Grok CLI](https://docs.x.ai/build/overview).
