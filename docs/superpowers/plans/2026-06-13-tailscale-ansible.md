# Tailscale Ansible Role + WireGuard Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unused `githubixx.ansible_role_wireguard` dependency with `artis3n.tailscale`, run on all 3 nodes for tailnet SSH access and exit-node advertising.

**Architecture:** A new dedicated ansible playbook (`tailscale.yml`) applies the `artis3n.tailscale` role to the `homelab` host group. Authentication uses a Tailscale OAuth client secret prompted at runtime (`vars_prompt`, never stored); nodes are tagged `tag:homelab`. `tailscale up` flags enable SSH and exit-node advertising. k3s networking is untouched. IP forwarding (exit-node prereq) is already handled by `cluster-prepare.yml`.

**Tech Stack:** Ansible, ansible-galaxy, `artis3n.tailscale` v5.0.1, go-task, yamllint, sops (unchanged).

**Spec:** `docs/superpowers/specs/2026-06-13-tailscale-ansible-design.md`

**Note on verification:** This is infra/config work — no unit-test framework. Verification = yamllint, `ansible-playbook --syntax-check`, galaxy dependency resolution, and a live apply against the 3 nodes. Live apply (Task 5) requires a Tailscale OAuth client secret (plus a one-time `tag:homelab` ACL/OAuth setup) and is the only step touching real nodes.

---

## File Structure

- `requirements.yml` (modify) — swap wireguard role → tailscale role.
- `bootstrap/ansible/playbooks/tailscale.yml` (create) — the playbook applying the role.
- `.taskfiles/ansible.yml` (modify) — add `tailscale` task target.

No new variables files (OAuth client secret is prompted, not stored). No changes to inventory, group_vars, or k3s config.

---

## Task 1: Swap the role dependency in requirements.yml

**Files:**
- Modify: `requirements.yml:18-20`

- [ ] **Step 1: Replace the wireguard role entry with the tailscale role**

In `requirements.yml`, under the `roles:` list, the current entry is:

```yaml
  - name: githubixx.ansible_role_wireguard
    src: https://github.com/githubixx/ansible-role-wireguard.git
    version: 19.1.0
```

Replace it with:

```yaml
  - name: artis3n.tailscale
    src: https://github.com/artis3n/ansible-role-tailscale.git
    version: v5.0.1
```

Leave the `xanmanning.k3s` role entry above it unchanged.

- [ ] **Step 2: Verify the file parses as valid YAML**

Run: `mise exec -- python3 -c "import yaml; yaml.safe_load(open('requirements.yml'))"`
Expected: no output, exit 0.

- [ ] **Step 3: Verify galaxy resolves the new role and drops the old**

Run: `mise exec -- ansible-galaxy install -r requirements.yml --force 2>&1 | tail -20`
Expected: output includes `artis3n.tailscale` being installed at v5.0.1; no `githubixx` / `wireguard` line. Exit 0.

- [ ] **Step 4: Confirm the wireguard role is no longer referenced anywhere**

Run: `grep -rni 'wireguard\|githubixx' bootstrap/ requirements.yml; echo "exit=$?"`
Expected: `exit=1` (no matches).

- [ ] **Step 5: Commit**

```bash
git add requirements.yml
git commit -m "build(ansible): replace wireguard role with artis3n.tailscale

- drop unused githubixx.ansible_role_wireguard (never invoked)
- add artis3n.tailscale v5.0.1"
```

---

## Task 2: Create the tailscale playbook

**Files:**
- Create: `bootstrap/ansible/playbooks/tailscale.yml`

- [ ] **Step 1: Write the playbook**

Create `bootstrap/ansible/playbooks/tailscale.yml` with exactly this content:

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
    - role: artis3n.tailscale
      vars:
        tailscale_args: "--ssh --advertise-exit-node --hostname={{ inventory_hostname }}"
        tailscale_tags:
          - homelab
        tailscale_oauth_ephemeral: false
        tailscale_oauth_preauthorized: true
        state: latest
```

Notes for the implementer:
- `homelab` is the host group containing node0/1/2 (see `inventory.yaml`). Other playbooks (`cluster-reboot.yml`, `cluster-installation.yml`) use the same group.
- `become: false` matches the repo convention — `ansible_user` is already `root`.
- `vars_prompt` runs at play start; `private: true` hides input and keeps it out of logs. The `artis3n.tailscale` role reads the `tailscale_authkey` variable automatically, so it is NOT repeated under the role's `vars:`.
- Authentication is via a **Tailscale OAuth client secret** (`tskey-client-...`). The role auto-detects the `tskey-client-` prefix and exchanges it for an ephemeral key at `tailscale up` time.
- `tailscale_tags: [homelab]` is **required** with OAuth — the role fails fast if an OAuth secret is supplied without tags. It becomes `--advertise-tags=tag:homelab`. `tag:homelab` must exist in the tailnet ACL `tagOwners`, and the OAuth client must be scoped to it.
- `tailscale_oauth_ephemeral: false` — nodes are always-on and must persist (not auto-deregister when briefly offline).
- `tailscale_oauth_preauthorized: true` — nodes join without a manual device-approval click.
- `--advertise-exit-node` requires IP forwarding, already set by `cluster-prepare.yml` (`net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`). Do not add a forwarding task here.

- [ ] **Step 2: Lint the playbook**

Run: `mise exec -- pre-commit run yamllint --files bootstrap/ansible/playbooks/tailscale.yml`
Expected: `Passed`. If it fails on indentation/truthy/comments, fix per `.yamllint.yaml` (2-space indent, `true/false/on` only for booleans).

- [ ] **Step 3: Syntax-check the playbook**

Run: `mise exec -- ansible-playbook bootstrap/ansible/playbooks/tailscale.yml --syntax-check`
Expected: `playbook: bootstrap/ansible/playbooks/tailscale.yml`, exit 0. (Requires Task 1's `ansible-galaxy install` to have run so the role is present locally.)

- [ ] **Step 4: Commit**

```bash
git add bootstrap/ansible/playbooks/tailscale.yml
git commit -m "feat(ansible): add tailscale playbook

- apply artis3n.tailscale to homelab nodes
- ssh + exit-node advertising, hostname from inventory
- authkey prompted at runtime, never stored"
```

---

## Task 3: Add the taskfile target

**Files:**
- Modify: `.taskfiles/ansible.yml`

- [ ] **Step 1: Add the tailscale task**

In `.taskfiles/ansible.yml`, after the existing `install:` task block (and before `nuke:`), add:

```yaml
  tailscale:
    desc: Install / configure Tailscale on the nodes
    cmds:
      - ansible-playbook {{.ANSIBLE_PLAYBOOK_DIR}}/tailscale.yml
```

Match the existing 2-space indentation of the other task keys (`init`, `list`, `prepare`, `install`, `nuke`).

- [ ] **Step 2: Lint the taskfile**

Run: `mise exec -- pre-commit run yamllint --files .taskfiles/ansible.yml`
Expected: `Passed`.

- [ ] **Step 3: Verify task is registered**

Run: `mise exec -- task --list 2>&1 | grep tailscale`
Expected: a line like `* ansible:tailscale: Install / configure Tailscale on the nodes`.

- [ ] **Step 4: Commit**

```bash
git add .taskfiles/ansible.yml
git commit -m "build(task): add ansible:tailscale target"
```

---

## Task 4: Full pre-commit + dry-run validation

**Files:** none (validation only)

- [ ] **Step 1: Run the full pre-commit suite on changed files**

Run: `mise exec -- pre-commit run --files requirements.yml bootstrap/ansible/playbooks/tailscale.yml .taskfiles/ansible.yml 2>&1 | tail -30`
Expected: all hooks `Passed` (or `Skipped` for terraform hooks — no .tf changed). No `Failed`. If `end-of-file-fixer` / `trailing-whitespace` auto-fix anything, re-stage and amend the relevant commit.

- [ ] **Step 2: Confirm galaxy state is clean end-to-end**

Run: `mise exec -- task ansible:init 2>&1 | tail -15`
Expected: installs `artis3n.tailscale` v5.0.1 + collections, no wireguard, exit 0.

- [ ] **Step 3: Connectivity check to nodes (no changes)**

Run: `mise exec -- ansible homelab -m ping 2>&1`
Expected: `node0`, `node1`, `node2` each `SUCCESS` with `"ping": "pong"`. Confirms sops/age key + SSH work before the live apply. (If sops fails, the age key must be at `~/.config/sops/age/keys.txt`.)

---

## Task 5: Live apply (manual, requires OAuth client + tailnet ACL setup)

**Files:** none (live infrastructure change)

This is the only task that changes the real nodes. It uses a Tailscale OAuth
client (not a static auth key).

- [ ] **Step 0: One-time tailnet ACL + OAuth setup (console)**

In login.tailscale.com:
1. ACL policy → add `tag:homelab` to `tagOwners` (owner = your user/group):
   ```json
   "tagOwners": { "tag:homelab": ["autogroup:admin"] }
   ```
2. (Optional, to skip per-node exit-node approval) add an autoApprover:
   ```json
   "autoApprovers": { "exitNode": ["tag:homelab"] }
   ```
3. Trust credentials → Generate OAuth client. Scope: **Keys / `auth_keys` →
   Write** (the minimal scope — not `devices:core`), tag `tag:homelab`. Copy
   the client secret (`tskey-client-...`).

- [ ] **Step 1: Apply the playbook**

Run: `mise exec -- task ansible:tailscale`
When prompted `Tailscale OAuth client secret (tskey-client-...):`, paste the
secret (input hidden).
Expected: play runs against node0/1/2, role tasks `ok`/`changed`, `failed=0` in the recap.

- [ ] **Step 2: Verify tailscale is up on all nodes with SSH + exit-node + tag**

Run:
```bash
for h in node0 node1 node2; do
  echo "=== $h ==="
  ssh root@$h.cluster.kaminek.me 'tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); s=d[\"Self\"]; print(\"Online:\",s[\"Online\"],\"ExitNodeOption:\",s.get(\"ExitNodeOption\"),\"Tags:\",s.get(\"Tags\"))"'
done
```
Expected: each node prints `Online: True ExitNodeOption: True Tags: ['tag:homelab']`.

- [ ] **Step 3: Verify Tailscale SSH reachability**

Run: `tailscale status` from your laptop (must be on the same tailnet), confirm node0/1/2 appear. Then `ssh root@node0` over the tailnet name.
Expected: nodes listed; SSH succeeds via Tailscale SSH.

- [ ] **Step 4: Confirm exit nodes are approved**

If the `autoApprovers.exitNode` entry from Step 0 was added, the nodes are
already approved — confirm in login.tailscale.com → Machines (exit-node badge).
Otherwise, for each node: Edit route settings → enable **Use as exit node**.

- [ ] **Step 5: Verify exit-node routing from a client**

Run (from a tailnet client): `tailscale up --exit-node=node0` then `curl -s https://api.ipify.org`
Expected: returns node0's public egress IP. Reset with `tailscale up --exit-node=`.

- [ ] **Step 6: Confirm k3s unaffected**

Run: `kubectl get nodes -o wide`
Expected: 3 nodes still `Ready`, INTERNAL-IP still `10.10.0.1x`. No change to cluster networking.

> Branch already pushed and PR #323 opened during Tasks 1–4. After the live
> apply verifies, merge the PR.

---

## Self-Review Notes

- **Spec coverage:** requirements.yml swap (Task 1), playbook with prompt + `--ssh --advertise-exit-node --hostname` (Task 2), taskfile target (Task 3), forwarding-prereq honored by NOT adding a forwarding task (Task 2 note), console approval + exit-node verification (Task 5). All spec sections mapped.
- **No stored secret:** confirmed — OAuth client secret only via `vars_prompt`, no group_vars/sops file created.
- **Variable name consistency:** `tailscale_authkey` (prompt name) matches the role's expected var (it accepts both static auth keys and OAuth client secrets, detected by prefix); `tailscale_tags`/`tailscale_oauth_ephemeral`/`tailscale_oauth_preauthorized`/`tailscale_args`/`state` match the role's `defaults/main.yml`.

## Unresolved Questions

- None blocking. The OAuth client and `tag:homelab` ACL `tagOwners` are a one-time console/ACL setup at Task 5 Step 0.
