# Tailscale Ansible Role + WireGuard Removal — Design

**Date:** 2026-06-13
**Status:** Approved (pending spec review)

## Goal

Replace the unused WireGuard mesh role with the `artis3n.tailscale` Ansible
role, providing Tailscale on all cluster nodes for **remote admin access
only**. k3s networking is untouched — cluster/etcd traffic stays on the
UpCloud private network (10.10.0.x).

## Context / Findings

- `githubixx.ansible_role_wireguard` is declared in `requirements.yml` (lines
  19–20) but **never invoked** by any playbook. WireGuard is not running on any
  node (`wg-quick@wg0` inactive, no `wg0` interface). Dead dependency.
- Tailscale has **no first-party Ansible role**. `artis3n.tailscale` (725k
  downloads) is the de-facto community standard. Pin to **v5.0.1**.
- Repo secret convention: sops + age, `community.sops` collection. age key now
  present at `~/.config/sops/age/keys.txt`.
- Node `ansible_user` is `root` — no `become` escalation needed for install.

## Changes

### 1. `requirements.yml`

- **Remove** `githubixx.ansible_role_wireguard` (lines 19–20).
- **Add** under `roles:`
  ```yaml
  - name: artis3n.tailscale
    src: https://github.com/artis3n/ansible-role-tailscale.git
    version: v5.0.1
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
  roles:
    - role: artis3n.tailscale
      vars:
        tailscale_authkey: "{{ tailscale_authkey }}"
        tailscale_args: "--ssh --hostname={{ inventory_hostname }}"
        state: latest
```

- `--ssh` enables Tailscale SSH (admin access goal).
- `--hostname` makes tailnet device names match inventory hostnames.

### 3. Auth key secret (sops-encrypted)

New group_vars file `bootstrap/ansible/inventory/group_vars/homelab/tailscale.sops.yml`:

```yaml
tailscale_authkey: <reusable-or-ephemeral-key>
```

Encrypted via existing `.sops.yaml` rule (`ansible/.*\.sops\.ya?ml` → age key).
Key generated in the Tailscale admin console (reusable, optionally tagged).

### 4. Taskfile target `.taskfiles/ansible.yml`

```yaml
  tailscale:
    desc: Install / configure Tailscale on nodes
    cmds:
      - ansible-playbook {{.ANSIBLE_PLAYBOOK_DIR}}/tailscale.yml
```

## Out of Scope (YAGNI)

- Routing k3s/etcd traffic over the tailnet.
- Subnet router / exit node.
- OAuth client + ACL tag automation (sops static key is sufficient for admin
  access; can revisit if fleet grows).
- Removing/uninstalling anything WireGuard from nodes — nothing was ever
  installed, so only the dead `requirements.yml` entry needs removal.

## Verification

1. `task ansible:init` — galaxy resolves `artis3n.tailscale` v5.0.1, no
   wireguard role pulled.
2. `sops -d` the new tailscale.sops.yml round-trips.
3. `task ansible:tailscale` — role completes, `tailscale status` shows all 3
   nodes online on the tailnet, `tailscale up --ssh` active.
4. SSH a node via its tailnet IP/hostname succeeds.
5. k3s unaffected: `kubectl get nodes` still Ready, internal IPs still
   10.10.0.x.

## Unresolved Questions

- None blocking. Auth key (reusable vs ephemeral, tagged or not) is a console
  choice at apply time; design supports any via the single sops var.
