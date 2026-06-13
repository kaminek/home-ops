# Tailscale Ansible Role + WireGuard Removal — Design

**Date:** 2026-06-13
**Status:** Approved (pending spec review)

## Goal

Replace the unused WireGuard mesh role with the `artis3n.tailscale.machine`
Ansible role (from the `artis3n.tailscale` collection), running on all 3 nodes
to:
- reach and SSH the nodes over the tailnet (Tailscale SSH);
- advertise each node as an **exit node**.

k3s networking is untouched — cluster/etcd traffic stays on the UpCloud
private network (10.10.0.x).

## Context / Findings

- `githubixx.ansible_role_wireguard` is declared in `requirements.yml` (lines
  19–20) but **never invoked** by any playbook. WireGuard is not running on any
  node (`wg-quick@wg0` inactive, no `wg0` interface). Dead dependency.
- Tailscale has **no first-party Ansible role**. The `artis3n` project is the
  de-facto community standard. The standalone role (`artis3n.tailscale`
  v5.0.1) is abandoned and **breaks on ansible-core ≥ 2.19** (a `meta:
  end_role` task with a string `when:` violates strict boolean conditionals;
  it also relies on the deprecated `INJECT_FACTS_AS_VARS`). Use the successor
  **collection `artis3n.tailscale` v1.2.1**, role `artis3n.tailscale.machine`,
  which fixes both (no migration-notice task, uses `ansible_facts.*`). Same
  variable interface — drop-in.
- Repo secret convention: sops + age, `community.sops` collection. age key now
  present at `~/.config/sops/age/keys.txt`.
- Node `ansible_user` is `root` — no `become` escalation needed for install.

## Changes

### 1. `requirements.yml`

- **Remove** `githubixx.ansible_role_wireguard`.
- **Add** under `collections:` (it is a collection, not a standalone role):
  ```yaml
  - name: artis3n.tailscale
    version: 1.2.1
  ```

### 2. New playbook `bootstrap/ansible/playbooks/tailscale.yml`

Dedicated playbook, run on demand (decoupled from node prep).

```yaml
---
- hosts:
    - homelab
  become: false
  gather_facts: true
  any_errors_fatal: true
  vars_prompt:
    - name: tailscale_authkey
      prompt: Tailscale OAuth client secret (tskey-client-...)
      private: true
  roles:
    - role: artis3n.tailscale.machine
      vars:
        tailscale_args: "--ssh --advertise-exit-node --hostname={{ inventory_hostname }}"
        tailscale_tags:
          - homelab
        tailscale_oauth_ephemeral: false
        tailscale_oauth_preauthorized: true
        state: latest
```

- `--ssh` enables Tailscale SSH (admin access goal).
- `--advertise-exit-node` offers each node as an exit node.
- `--hostname` makes tailnet device names match inventory hostnames.
- `tailscale_authkey` is set play-wide by `vars_prompt`; the role detects an
  OAuth client secret (prefix `tskey-client-`) automatically and exchanges it
  for an ephemeral auth key at `tailscale up` time.
- `tailscale_tags: [homelab]` → role advertises `--advertise-tags=tag:homelab`.
  **Required** with OAuth (the role fails fast if an OAuth key is given without
  tags).
- `tailscale_oauth_ephemeral: false` — nodes are always-on; they must persist
  on the tailnet, not auto-deregister when briefly offline.
- `tailscale_oauth_preauthorized: true` — nodes join without a manual device
  approval click in the console.

**Prerequisite:** exit-node routing needs IPv4/IPv6 forwarding enabled.
`cluster-prepare.yml` already sets `net.ipv4.ip_forward=1` and
`net.ipv6.conf.all.forwarding=1`, so node prep must have run before this
playbook. (This playbook does not set forwarding itself.)

### 3. Credential — OAuth client secret, prompted at runtime (no stored secret)

Authentication uses a **Tailscale OAuth client** (Settings → OAuth clients),
not a static auth key. The client secret (`tskey-client-...`) is prompted at
runtime via `vars_prompt` (`private: true` keeps it off-screen and out of
logs). No sops file, no secret in git.

Why OAuth over a static auth key: the OAuth client secret does **not expire**
(static auth keys cap at 90 days). The role mints a short-lived ephemeral key
from the client secret per run, so there is no long-lived join token to rotate.

This is operationally cheap: the secret is only needed at `tailscale up` time
(node join). Once a node authenticates, it stays on the tailnet via its own
persistent node key across reboots — so re-entry is only required when adding
or re-joining a node, not for normal operation.

**Tailnet prerequisite (one-time, console/ACL):**
- Define `tag:homelab` in the ACL policy `tagOwners`.
- Create an OAuth client with the minimal **`auth_keys` (write)** scope for
  `tag:homelab`. (Not `devices:core` — `auth_keys` is the dedicated
  key-minting scope and is all the role needs.)
- (Optional) Add an `autoApprovers.exitNode` entry for `tag:homelab` so the
  advertised exit nodes are approved automatically — otherwise each node must
  be enabled as an exit node manually in Machines → Edit route settings.

### 4. Taskfile target `.taskfiles/ansible.yml`

```yaml
  tailscale:
    desc: Install / configure Tailscale on nodes
    cmds:
      - ansible-playbook {{.ANSIBLE_PLAYBOOK_DIR}}/tailscale.yml
```

## Out of Scope (YAGNI)

- Routing k3s/etcd traffic over the tailnet.
- Subnet router (advertising the cluster/pod CIDRs). Exit node only.
- Setting IP forwarding in this playbook (handled by `cluster-prepare.yml`).
- Managing the tailnet ACL policy / OAuth client / `tagOwners` in this repo —
  these are one-time console/ACL setup steps, done outside ansible.
- Storing the OAuth client secret in repo (sops or otherwise) — prompted at
  runtime instead.
- Removing/uninstalling anything WireGuard from nodes — nothing was ever
  installed, so only the dead `requirements.yml` entry needs removal.

## Verification

1. `task ansible:init` — galaxy installs the `artis3n.tailscale` collection
   v1.2.1, no wireguard role pulled.
2. `task ansible:tailscale` — prompts for the OAuth client secret, role
   completes, `tailscale status` shows all 3 nodes online on the tailnet
   tagged `tag:homelab` with SSH and exit-node advertised (`tailscale status
   --json` → `ExitNodeOption: true`).
3. SSH a node via its tailnet IP/hostname succeeds.
4. Exit node routing: once approved (auto via `autoApprovers` or manually), a
   client `tailscale up --exit-node=<node>` routes egress through it.
5. k3s unaffected: `kubectl get nodes` still Ready, internal IPs still
   10.10.0.x.

## Unresolved Questions

- None blocking. The OAuth client + `tag:homelab` `tagOwners` are created once
  in the Tailscale console/ACL before the first apply; exit-node approval is
  either automatic (`autoApprovers.exitNode` for `tag:homelab`) or a manual
  per-node console step.
