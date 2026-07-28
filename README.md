# wsl-bootstrap

Ansible provisioning for a pair of openSUSE distributions running under WSL2 on Windows. One distribution is a general purpose workstation, the other hosts a single node RKE2 cluster, and both are installed and configured from Windows by a single PowerShell script.

Both distributions are created without ever being launched interactively, so the vendor first boot experience never runs and the managed user is created directly by Ansible.

## What gets built

| Play | Inventory group | Distribution image | Registered name | Purpose |
| --- | --- | --- | --- | --- |
| `playbooks/workstation.yml` | `workstation` | `openSUSE-Tumbleweed` | `openSUSE-Tumbleweed` | Daily driver shell, development and Kubernetes client tooling. Set as the default WSL distribution. |
| `playbooks/orchestrator.yml` | `orchestrator` | `openSUSE-Leap-16.0` | `openSUSE-Leap` | Single node RKE2 control plane with GPU support. |

`site.yml` imports both plays. Each distribution provisions itself, so a run always selects one of them with `--limit workstation` or `--limit orchestrator`.

## Requirements

- Windows 10 or 11 with WSL2 installed and a release of `wsl.exe` that supports `--name` and `--no-launch`. Check with `wsl --version`.
- Neither `openSUSE-Tumbleweed` nor `openSUSE-Leap` already registered. Verify with `wsl --list --verbose`.
- An internet connection, since the distributions are downloaded and provisioning installs packages from upstream repositories.
- For the `nvidia-stack` and GPU related parts of `rke2` on the orchestrator, an NVIDIA GPU with a current Windows driver.

## Quick start

From a Windows PowerShell prompt in the repository root:

```powershell
.\bootstrap.ps1
```

The script installs both distributions and provisions them with the full default role set. It refuses to do anything at all if either distribution name is already registered, so an existing environment is never replaced silently. To rebuild from scratch, remove them first:

```powershell
wsl --unregister openSUSE-Tumbleweed
wsl --unregister openSUSE-Leap
```

### Bootstrap parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `-RepositoryPath` | Script directory | Path to this repository. It is used as the working directory for Ansible inside each distribution. |
| `-OrchestratorTags` | `core, user, ssh, nvidia-stack, podman, rke2, cleanup` | Roles to apply to the `orchestrator` group. |
| `-WorkstationTags` | `core, user, ssh, git, dotfiles, kubernetes, cleanup` | Roles to apply to the `workstation` group. |

For example, to build a workstation with only the shell environment and leave Ansible installed for later runs:

```powershell
.\bootstrap.ps1 -WorkstationTags core, user, ssh, git, dotfiles
```

### What the bootstrap does

1. Checks prerequisites and refuses to continue when either distribution is already registered.
2. Installs the workstation, then the orchestrator, both with `--no-launch`.
3. Sets the workstation as the default WSL distribution.
4. Provisions the orchestrator first, so its control plane exists before the workstation is configured, then provisions the workstation.

For each distribution, provisioning installs `ansible-core` (plus `libexpat1` on Leap), installs the collections from `requirements.yml`, runs `site.yml` as root limited to that distribution's inventory group, and terminates the distribution so the new WSL configuration is picked up on the next launch.

## Recommended Windows host settings

`%USERPROFILE%\.wslconfig` configures the virtual machine that backs every WSL2 distribution on the machine. It is global rather than per distribution, so the bootstrap deliberately does not write it. The settings below are worth applying by hand, particularly the two idle timeouts, which are what keep the orchestrator's cluster alive once you close your last shell.

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

| Setting | Effect |
| --- | --- |
| `instanceIdleTimeout=-1` | Never shuts a distribution down for being idle. Without it the orchestrator stops once its last process exits, taking RKE2 with it. |
| `vmIdleTimeout=-1` | Never shuts down the virtual machine hosting the distributions, for the same reason. |
| `telemetry=false` | Disables WSL telemetry. |
| `dnsTunneling=true` | Resolves DNS through Windows instead of a NAT proxy. This is already the default and is listed only to make the intent explicit. |
| `networkingMode=mirrored` | Mirrors the Windows network interfaces into WSL, so services bind against the host directly rather than through NAT. |
| `autoMemoryReclaim=gradual` | Reclaims cached memory slowly, rather than dropping caches as soon as they are freed. |

Run `wsl --shutdown` after editing the file, since the settings are only read when the virtual machine starts.

A few caveats are worth knowing. `vmIdleTimeout`, `dnsTunneling` and `networkingMode` require Windows 11, the latter two on 22H2 or newer. `instanceIdleTimeout` and `telemetry` are both accepted by WSL but are absent from the published settings reference. Under mirrored networking, Linux services bind against ports that Windows also uses, so a clash with a Windows listener becomes possible and `[experimental] ignoredPorts` exists to carve out exceptions; the SSH aliases are unaffected, because loopback is always reachable in that mode.

## Repository layout

```
ansible.cfg          Inventory and role search paths
bootstrap.ps1        Windows entry point
site.yml             Ansible entry point, imports both plays
requirements.yml     Ansible collection requirements
inventory/           Inventory and the variables for each distribution
playbooks/           One playbook per distribution
roles/               Roles, grouped by scope
tasks/               Shared task files included by more than one role
```

Roles live under `roles/<scope>/<name>`, where the scope is `common` for roles used by both plays, or `workstation` and `orchestrator` for roles specific to one. Every role declares its variables in `meta/argument_specs.yml`, which is validated on each run.

`inventory/hosts.yml` defines one host per distribution, `wsl-workstation` and `wsl-orchestrator`, each in a group named after its role. Both are reached over the local connection, because a distribution provisions itself rather than being provisioned from elsewhere. The inventory exists to name the two targets and to give `inventory/group_vars/` somewhere to attach.

The files in `tasks/` are shared helpers rather than roles. They wrap the parts of provisioning that more than one role repeats: adding Zypper repositories, installing packages, deploying profile scripts, enabling systemd services, and resolving Windows host identity. Helpers used by a single role live in that role's own `tasks/` directory instead.

## Roles and tags

`common/core` and `common/user` are tagged `always` and run on every invocation. Every other role is gated behind `never` plus its own tag, so it only runs when that tag is named explicitly.

| Tag | Role | Applies to | Description |
| --- | --- | --- | --- |
| `core` | `common/core` | both | Repositories, distribution upgrade, baseline packages, passwordless wheel sudo, static systemd units. |
| `user` | `common/user` | both | Creates the managed user and group, sets the WSL default user, applies locale, keymap and timezone. |
| `ssh` | `common/ssh` | both | Generates an ed25519 identity, configures key only SSH access, optionally exports the identity to Windows. |
| `nvidia-stack` | `common/nvidia-stack` | orchestrator | NVIDIA container toolkit, CDI device generation, GPU visibility checks, DRM udev rules. |
| `podman` | `common/podman` | orchestrator | Rootless Podman with subordinate ID ranges and a user socket. |
| `git` | `workstation/git` | workstation | Git and the GitHub CLI. |
| `dotfiles` | `workstation/dotfiles` | workstation | Modern shell utilities and the managed dotfiles installer. Requires the `git` tag and a zsh shell. |
| `kubernetes` | `workstation/kubernetes` | workstation | `kubectl` and Helm from the upstream Kubernetes repository. |
| `rke2` | `orchestrator/rke2` | orchestrator | RKE2 with Cilium, optional GPU Operator, and readiness checks. |
| `cleanup` | `common/cleanup` | both | Removes Ansible and its provisioning state. Always runs last. |

The `rke2` role deploys the GPU Operator only when the `nvidia-stack` tag is also present, and `workstation/dotfiles` fails early if the `git` tag is missing.

Because `cleanup` uninstalls Ansible, omit it whenever you intend to re-run a playbook against the same distribution.

## Configuration

Distribution level variables are set in `inventory/group_vars/workstation.yml` and `inventory/group_vars/orchestrator.yml`. Role defaults fill in anything not supplied.

### Managed user

```yaml
user:
  account: name:uid:gid:shell-package
  editor: nano
```

`user.account` is optional. When it is empty or omitted, the account is derived from the Windows user name as `<username>:1000:1000:zsh`, lowercased and stripped of whitespace. The workstation group also reads an optional `workstation_account` variable, so the account can be overridden without editing the inventory:

```bash
sudo env ANSIBLE_CONFIG=./ansible.cfg ansible-playbook site.yml --limit workstation --tags core,user -e workstation_account=dev:1000:1000:bash
```

The managed user is added to `wheel`, granted passwordless sudo, has its password removed, and becomes the WSL default user. `user.locale`, `user.keymap` and `user.timezone` default to `C.UTF-8`, `gb` and `Europe/Dublin`.

### Core

```yaml
core:
  wheel: true          # passwordless wheel sudo and no root password
  repositories: []     # extra Zypper repositories
  packages: []         # extra packages alongside the baseline
```

### SSH

```yaml
ssh:
  key:
    name: id_workstation      # identity file name under ~/.ssh
  service:
    port: 22223               # sshd port
    group: ssh-users          # group permitted to log in
  export:
    enabled: true             # copy the identity to Windows and register a Host entry
    alias: workstation        # Host alias, defaults to the WSL distribution name
    hostname: localhost       # address Windows uses to reach the distribution
```

The orchestrator listens on `22222` and the workstation on `22223`. WSL2 runs every distribution in one virtual machine sharing a single network namespace, so each distribution needs its own port.

### Other roles

```yaml
nvidia_stack:
  experimental: false         # use the experimental NVIDIA repository

kubernetes:
  version: v1.36              # upstream Kubernetes repository version

rke2:
  version: v1.36              # RKE2 channel or version
  gpu_operator_version: v26.3.3
  kubeconfig_sync: true       # copy the kubeconfig to the Windows profile
```

## SSH access from Windows

When `ssh.export.enabled` is set, the role copies the generated key pair into `%USERPROFILE%\.ssh` and registers a matching `Host` block in the Windows OpenSSH client configuration. The block is written above any existing entries, since OpenSSH uses the first matching value for each setting.

```
ssh orchestrator
ssh workstation
```

Each entry pins `IdentityFile` and `IdentitiesOnly`, so the correct key is offered regardless of what else is loaded in an agent. Password and keyboard interactive authentication are disabled inside the distributions, and only members of the SSH access group may log in.

## Kubernetes access from Windows

With `rke2.kubeconfig_sync` enabled, a systemd path unit watches the generated kubeconfig and copies it to `%USERPROFILE%\.kube\config`, so `kubectl` and Helm on Windows target the cluster without further configuration. The cluster certificate covers `localhost` and `127.0.0.1`, and the API server is reachable on port `6443`.

Inside the orchestrator, a profile script exports `KUBECONFIG` along with the containerd and crictl settings needed to inspect the node directly.

## Running Ansible directly

The plays can be run from inside a distribution, which is useful for applying a single role to an existing installation. Run them as root from the repository directory:

```bash
sudo zypper --non-interactive install ansible-core
cd /mnt/c/path/to/wsl-bootstrap
sudo ansible-galaxy collection install --requirements-file requirements.yml
sudo env ANSIBLE_CONFIG=./ansible.cfg ansible-playbook site.yml --limit workstation --tags core,user,ssh
```

`ANSIBLE_CONFIG` is not decoration. A checkout under `/mnt/c` is reached through a DrvFs mount, which is world writable, and Ansible deliberately ignores an `ansible.cfg` it discovers in a world writable working directory. Without it the inventory and the role search path are never loaded, and the run fails on the first role it cannot find. A checkout on the Linux filesystem does not need it. `bootstrap.ps1` sets the variable for the same reason.

The `--limit` is equally load bearing, because `site.yml` imports both plays and each one provisions the machine it runs on. Running a single playbook directly has the same effect and does not need the limit:

```bash
sudo env ANSIBLE_CONFIG=./ansible.cfg ansible-playbook playbooks/workstation.yml --tags core,user,ssh
```

Remember that `core` and `user` always run, so a targeted invocation still validates the base system and the managed account. The plays are idempotent and safe to re-run.

## Notes

- Provisioning runs entirely as root. Windows executables are invoked through WSL interoperability to resolve the Windows user name and profile path, and `common/core` verifies that interoperability is working before anything depends on it.
- The distributions are terminated at the end of the bootstrap. Configuration written to `/etc/wsl.conf`, including the default user, takes effect from the next launch.
- Applying `nvidia-stack` requires a working GPU. The role verifies that `nvidia-smi` reports a device and that a CDI specification is generated, and fails early if either check does not pass.
