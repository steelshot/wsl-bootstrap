# wsl-bootstrap

Ansible provisioning for a single openSUSE Tumbleweed distribution running under WSL2 on Windows. It provides a development environment,
a single node RKE2 cluster and rootless Podman, with GPU support, and is installed and configured from Windows by one PowerShell script.

The distribution is created without ever being launched interactively, and the managed user is created directly by Ansible.

## What gets built

`site.yml` imports `playbooks/tumbleweed.yml`, which runs against the `tumbleweed` inventory group. The distribution keeps the name that `wsl --install`
gives it, `openSUSE-Tumbleweed`, and is set as the default WSL distribution.

## Requirements

- Windows 10 or 11 with WSL2 installed and a release of `wsl.exe` that supports `--no-launch`. Check with `wsl --version`.
- `openSUSE-Tumbleweed` not already registered when installing, and registered when updating. Verify with `wsl --list --verbose`.
- An internet connection for the distribution download and the packages installed during provisioning.
- For the `nvidia-stack` and GPU related parts of `rke2`, an NVIDIA GPU with a current Windows driver.

## Quick start

From a Windows PowerShell prompt in the repository root:

```powershell
.\bootstrap.ps1
```

The script installs the distribution and provisions it with the full default role set. It refuses to continue when the distribution is already
registered. To rebuild from scratch, tear it down first, which also removes the files it left on Windows:

```powershell
.\bootstrap.ps1 -Teardown
```

To upgrade an installed distribution instead, see [Updating](#updating).

### Bootstrap parameters

| Parameter         | Default                 | Description                                                                                 |
|-------------------|-------------------------|---------------------------------------------------------------------------------------------|
| `-RepositoryPath` | Script directory        | Path to this repository, used as the working directory for Ansible inside the distribution. |
| `-Tags`           | All roles but `cleanup` | Roles to apply.                                                                             |
| `-Update`         | Off                     | Provision the registered distribution again instead of installing it.                       |
| `-Cleanup`        | Off                     | Remove Ansible and its provisioning state as the last step.                                 |
| `-Teardown`       | Off                     | Unregister the distribution and remove the files it created on Windows.                     |
| `-DryRun`         | Off                     | With `-Teardown`, list what would be removed without removing anything.                     |

The default tags are `core`, `user`, `ssh`, `nvidia-stack`, `podman`, `rke2`, `git`, `dotfiles` and `kubernetes`. For example, to build only the shell
environment:

```powershell
.\bootstrap.ps1 -Tags core, user, ssh, git, dotfiles
```

### What the bootstrap does

1. Checks prerequisites and refuses to continue when the distribution is already registered.
2. Installs the distribution with `--no-launch` and sets it as the default WSL distribution.
3. Installs `ansible-core` and the collections from `requirements.yml`.
4. Runs `site.yml` as root, limited to the `tumbleweed` group.
5. Terminates the distribution, so that configuration such as the default user takes effect on the next launch.

Ansible is left installed unless `-Cleanup` is given. It is reinstalled by the next run.

## Updating

`.\bootstrap.ps1 -Update` runs the playbook again against the registered distribution. It does not terminate the distribution, so running sessions
survive. Restart it with `wsl --terminate openSUSE-Tumbleweed` to apply changes to `/etc/wsl.conf`.

The steps fall into two kinds:

- One-shot steps run once and are skipped afterwards, so a rerun cannot overwrite settings changed since. These are the locale, keymap and timezone setup
  and the removal of the root and user passwords, which are recorded as markers under `/var/lib/wsl-bootstrap`, and the dotfiles installer, which runs
  only while `~/.zshenv` does not exist.
- Everything else converges on every run and upgrades what it manages. `system/core` runs a `dist-upgrade`, which also upgrades the packages the other
  roles install.

RKE2, the GPU Operator and `kubectl` follow the newest release by default:

- `rke2.version` defaults to `latest`, which resolves through the RKE2 release channels to the newest release that is not a release candidate. A channel
  such as `stable` or `v1.36`, or an exact version such as `v1.37.1+rke2r1`, overrides it. A rerun upgrades RKE2 when the resolved version is newer than
  the installed one and restarts `rke2-server`. It refuses to downgrade, and to advance more than one Kubernetes minor version at a time. `rke2-server`
  is also restarted when `config.yaml` or the containerd template changes.
- `rke2.gpu_operator_version` defaults to `latest`, which resolves to the newest chart in the NVIDIA Helm repository that has no pre-release suffix. An
  exact chart version overrides it. The version is written into the `HelmChart` manifest, and the RKE2 Helm controller applies the upgrade.
- `kubernetes.version` defaults to `latest`, which resolves to the minor of the newest stable Kubernetes release (`https://dl.k8s.io/release/stable.txt`) and
  points the `kubectl` repository at it. A minor such as `v1.37` overrides it. A rerun upgrades `kubectl` and Helm, and `kubectl` supports a cluster one
  minor version older or newer than itself.

Before RKE2 is upgraded, an etcd snapshot of the installed version is saved as `pre-upgrade-<version>` in `/var/lib/rancher/rke2/server/db/snapshots`, and
only the newest three are kept. A fresh install, a rerun with nothing to upgrade, and a node whose `rke2-server` is stopped take no snapshot. The role never
downgrades, so recovery is manual. Pin `rke2.version` to the old version first so that a rerun does not upgrade again, then in the distribution:

```bash
sudo systemctl stop rke2-server
curl -sfL https://get.rke2.io | sudo env INSTALL_RKE2_VERSION=<old version> INSTALL_RKE2_METHOD=tar sh -
sudo rke2 server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/rke2/server/db/snapshots/<snapshot>
sudo systemctl start rke2-server
```

## Removing the distribution

`.\bootstrap.ps1 -Teardown` unregisters `openSUSE-Tumbleweed`, which permanently deletes its filesystem, and removes what the bootstrap created on the
Windows host:

- The exported SSH key pair and `Host` entry under `%USERPROFILE%\.ssh\wsl`, the `Include wsl/*.conf` line once no entry remains, and the matching host
  keys in `known_hosts`.
- The Podman connection registered for the distribution.
- The `rke2` cluster, user and context in `%USERPROFILE%\.kube\config`. Other clusters in the file are kept, and the file itself is removed only when nothing
  else remains in it. This needs `kubectl.exe`; without it the teardown prints the three commands that remove the entries.

It also works when the distribution is already gone, and cannot be combined with `-Update`, `-Cleanup` or `-Tags`. Add `-DryRun` to list what would be
removed without removing anything. `ssh-keygen` keeps the previous `known_hosts` as `known_hosts.old`.

## Recommended Windows host settings

`%USERPROFILE%\.wslconfig` configures the virtual machine that backs every WSL2 distribution on the machine. It is global rather than per distribution, and the bootstrap does not write it. Apply the
settings below by hand:

```ini
[general]
instanceIdleTimeout=-1

[wsl2]
telemetry=false
vmIdleTimeout=-1
dnsTunneling=true
networkingMode=mirrored

[experimental]
autoMemoryReclaim=gradual
```

| Setting                       | Effect                                                                                                                     |
|-------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| `instanceIdleTimeout=-1`      | Never shuts a distribution down for being idle.                                                                            |
| `vmIdleTimeout=-1`            | Never shuts down the virtual machine hosting the distributions.                                                            |
| `telemetry=false`             | Disables WSL telemetry.                                                                                                    |
| `dnsTunneling=true`           | Resolves DNS through Windows instead of a NAT proxy. Already the default.                                                  |
| `networkingMode=mirrored`     | Supports host-guest access over `127.0.0.1`. RKE2 applies a pod SNAT source-port clamp for this mode.                        |
| `autoMemoryReclaim=gradual`   | Reclaims cached memory slowly, rather than dropping caches as soon as they are freed.                                      |

Run `wsl --shutdown` after editing the file. The settings are read when the virtual machine starts.

Mirrored mode lets Windows and the distribution reach each other's services over `127.0.0.1`, including Windows-hosted model servers and the
guest Kubernetes API. `localhostForwarding` is ignored in mirrored mode; it does not need to be enabled. Use IPv4 explicitly when connecting from
Linux to Windows: mirrored mode does not support that direction over `::1`. Ports required by Linux-only services can be listed under
`[experimental] ignoredPorts` if Windows already uses them; do not list ports that need to remain accessible from Windows.

Consomme networking (formerly `virtioproxy`) is also supported. Replace the networking settings under `[wsl2]` with:

```ini
networkingMode=consomme
localhostForwarding=false
```

The `rke2` role reads the active mode with `wslinfo --networking-mode`. With consomme it checks `%USERPROFILE%\.wslconfig` and fails before installing
or upgrading RKE2 unless `localhostForwarding=false` is explicit; an omitted setting defaults to `true`. This avoids forwarding RKE2's guest-local
loopback connections to Windows. Use mirrored mode when guest access to Windows localhost services is needed. Restart WSL after changing either
setting: the file describes the next boot, whereas `wslinfo` reports the running mode.

`vmIdleTimeout`, `dnsTunneling` and `networkingMode` require Windows 11, the latter two on 22H2 or newer. See the
[WSL configuration reference](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) and
[mirrored networking guidance](https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking).

## Repository layout

```
ansible.cfg          Inventory and role search paths
bootstrap.ps1        Windows entry point
site.yml             Ansible entry point, imports the playbook
requirements.yml     Ansible collection requirements
inventory/           Inventory and group variables
playbooks/           The playbook
roles/               Roles, grouped by purpose
tasks/               Shared task files included by more than one role
```

Roles live under `roles/<group>/<name>`. The groups are `system` for the base operating system and the account, `development` for the developer tooling,
and `containers` for the GPU, Podman and Kubernetes stack. Every role declares its variables in `meta/argument_specs.yml`, which is validated on each
run.

`inventory/hosts.yml` defines one host, `wsl-tumbleweed`, in the `tumbleweed` group, reached over the local connection.

The files in `tasks/` are shared helpers rather than roles. They wrap the parts of provisioning that more than one role repeats: adding Zypper
repositories, installing packages, deploying profile scripts, enabling systemd services, running one-shot steps, and resolving Windows host identity.
Helpers used by a single role live in that role's own `tasks/` directory instead.

## Roles and tags

`system/core` and `system/user` are tagged `always` and run on every invocation. Every other role is gated behind `never` plus its own tag, so it only
runs when that tag is named explicitly. The roles run in the order below, with the developer tooling ahead of the cluster, so that a slow cluster start
cannot hold up the shell setup.

| Tag            | Role                      | Description                                                                                                |
|----------------|---------------------------|------------------------------------------------------------------------------------------------------------|
| `core`         | `system/core`             | Repositories, distribution upgrade, baseline packages, passwordless wheel sudo, static systemd units.      |
| `user`         | `system/user`             | Creates the managed user and group, sets the WSL default user, applies locale, keymap and timezone.        |
| `ssh`          | `system/ssh`              | Generates an ed25519 identity, configures key only SSH access, optionally exports the identity to Windows. |
| `git`          | `development/git`         | Git and the GitHub CLI.                                                                                    |
| `dotfiles`     | `development/dotfiles`    | Modern shell utilities and the managed dotfiles installer. Requires the `git` tag and a zsh shell.         |
| `kubernetes`   | `development/kubernetes`  | `kubectl` and Helm from the upstream Kubernetes repository.                                                |
| `nvidia-stack` | `containers/nvidia-stack` | NVIDIA container toolkit, CDI device generation, GPU visibility checks, DRM udev rules.                    |
| `podman`       | `containers/podman`       | Rootless Podman with subordinate ID ranges, a user socket, and an optional Windows connection.             |
| `rke2`         | `containers/rke2`         | RKE2 with Cilium, optional GPU Operator, version upgrades, and readiness checks.                           |
| `cleanup`      | `system/cleanup`          | Removes Ansible and its provisioning state. Opt-in, and always runs last.                                  |

The `rke2` role deploys the GPU Operator only when the `nvidia-stack` tag is also present, and `development/dotfiles` fails early if the `git` tag is missing.

In mirrored mode, the `rke2` role installs `wsl-snat-clamp.service` and starts it before `rke2-server`. WSL can drop guest traffic whose source port
falls in the Windows ephemeral range. The unit reads `/proc/sys/net/ipv4/ip_local_port_range` at startup and uses nftables to constrain TCP and UDP
pod egress masquerading to the guest range, excluding the default pod and service networks (`10.42.0.0/16` and `10.43.0.0/16`).
Cilium's `bpf.masquerade` is disabled in mirrored mode so kernel NAT can apply the clamp. In other modes BPF masquerading stays enabled, and
provisioning stops, disables and removes a previously managed clamp unit when switching away from mirrored mode.

The role also installs `rke2-killall.service`, which runs `rke2-killall.sh` when RKE2 stops. The `rke2-server` unit leaves its containers running after the
service stops, so without it a `wsl --terminate` or `wsl --shutdown` kills them outright and they can come back crash-looping. WSL gives the virtual
machine about 30 seconds to terminate, and a power loss or crash still skips the stop.

`system/core` removes the BusyBox `gzip` and `tar` applets that the Tumbleweed image ships, because they conflict with the `gzip` and `tar` packages
it installs.

`cleanup` uninstalls Ansible. It only runs when `-Cleanup` or the `cleanup` tag is given.

## Configuration

Variables are set in `inventory/group_vars/tumbleweed.yml`. Role defaults fill in anything not supplied.

### Managed user

```yaml
user:
  account: name:uid:gid:shell-package
  editor: nano
```

`user.account` is optional. When it is empty or omitted, the account is derived from the Windows username as `<username>:1000:1000:zsh`, lowercased and
stripped of whitespace. The inventory also reads an optional `workstation_account` variable, which overrides the account without editing the inventory:

```bash
sudo env ANSIBLE_CONFIG=./ansible.cfg ansible-playbook site.yml --tags core,user -e workstation_account=dev:1000:1000:bash
```

The managed user is added to `wheel`, granted passwordless sudo, has its password removed, and becomes the WSL default user. `user.locale`, `user.keymap` and `user.timezone` default to `C.UTF-8`, `gb`
and `Europe/Dublin`.

### Core

```yaml
core:
  wheel: true          # passwordless wheel sudo and no root password
  repositories: [ ]     # extra Zypper repositories
  packages: [ ]         # extra packages alongside the baseline
```

### SSH

```yaml
ssh:
  key:
    name: id_dev              # identity file name under ~/.ssh, defaults to id_<user>
  service:
    port: 21000               # sshd port, defaults to the uid prefixed with 2
    group: ssh-users          # group permitted to log in
  export:
    enabled: true             # copy the identity to Windows and register a Host entry
    alias: dev                # Host alias, defaults to the lowercased WSL distribution name
    hostname: localhost       # address Windows uses to reach the distribution
```

The inventory enables the export and leaves the rest at the defaults, so the alias is `opensuse-tumbleweed`. The SSH server listens on a port derived from
the managed user's uid as `2<uid>`, which is `21000` for uid 1000.

### Other roles

```yaml
nvidia_stack:
  experimental: false         # use the experimental NVIDIA repository

kubernetes:
  version: latest             # kubectl repository: latest, or a minor such as v1.37

rke2:
  version: latest             # RKE2 channel or exact version
  gpu_operator_version: latest  # GPU Operator chart version
  kubeconfig_sync: true       # merge the kubeconfig into the Windows profile

podman:
  export:
    enabled: false            # register the Podman connection in the Windows profile
    name: dev                 # connection name, defaults to the lowercased WSL distribution name
    default: true             # make it the default Podman connection
```

The connection is registered and removed with the Windows Podman client (`podman system connection`), which the role runs as `podman.exe` through WSL
interoperability. Podman for Windows must therefore be installed and on the Windows `PATH`, and the Podman connection store is never edited directly.

## SSH access from Windows

When `ssh.export.enabled` is set, the role copies the generated key pair into `%USERPROFILE%\.ssh\wsl` and writes the matching `Host` block beside it as `<alias>.conf`. The Windows OpenSSH client
configuration receives a single `Include wsl/*.conf` line at the top, ahead of any broader `Host` pattern.

```
ssh opensuse-tumbleweed
```

The entry pins `IdentityFile`, `IdentitiesOnly` and `AddressFamily inet`. Password and keyboard interactive authentication are disabled inside the
distribution, and only members of the SSH access group may log in.

The distribution's host keys are also recorded in `%USERPROFILE%\.ssh\known_hosts` as `[localhost]:<port>`, so the first connection does not prompt.
Provisioning replaces the entries when the distribution is rebuilt and its host keys change.

## Kubernetes access from Windows

With `rke2.kubeconfig_sync` enabled, a systemd path unit watches the generated kubeconfig and runs `/usr/local/sbin/rke2-kubeconfig-sync`, which merges it into
`%USERPROFILE%\.kube\config`. The `rke2` cluster uses `https://127.0.0.1:6443` in mirrored mode and `https://localhost:6443` with consomme, preserving
the latter's Windows localhost forwarding behaviour. `kubectl` and Helm on Windows can then target the cluster with `--context rke2`, without
further configuration. The cluster certificate covers `localhost` and `127.0.0.1`, and the API server is reachable on port `6443`.

The cluster, user and context are renamed from RKE2's `default` to `rke2`, and every other entry in the file is left as it is. A rebuilt distribution
replaces the `rke2` entries, which carry a new certificate authority. An existing current context is kept, so the merge does not switch clusters under
you. On a machine with no kubeconfig yet, `rke2` becomes the current context.

Inside the distribution, a profile script exports `KUBECONFIG` along with the containerd and crictl settings needed to inspect the node directly.

## Running Ansible directly

The playbook can be run from inside the distribution to apply a single role to an existing installation. Run it as root from the repository directory:

```bash
cd /mnt/c/path/to/wsl-bootstrap
sudo env ANSIBLE_CONFIG=./ansible.cfg ansible-playbook site.yml --tags core,user,ssh
```

`ANSIBLE_CONFIG` is required for a checkout under `/mnt/c`. A checkout on the Linux filesystem does not need it. `bootstrap.ps1` sets the variable itself.

If `-Cleanup` was used, install Ansible and the collections first:

```bash
sudo zypper --non-interactive install ansible-core
sudo ansible-galaxy collection install --requirements-file requirements.yml
```

`core` and `user` always run. The playbook can also be run directly as `playbooks/tumbleweed.yml`. Re-running it is safe, and is how the distribution is
updated.

## Notes

- Provisioning runs entirely as root. Windows executables are invoked through WSL interoperability to resolve the Windows username and profile path, and
  `system/core` verifies that interoperability is working.
- Applying `nvidia-stack` requires a working GPU. The role verifies that `nvidia-smi` reports a device and that a CDI specification is generated, and fails early if either check does not pass.
- A rebuilt distribution generates new SSH host keys. With `ssh.export.enabled`, provisioning replaces the matching `known_hosts` entries, and `-Teardown`
  removes them. If the distribution was unregistered another way and the export is disabled, remove the stale entry with
  `ssh-keygen -R "[localhost]:21000"` before connecting again.
