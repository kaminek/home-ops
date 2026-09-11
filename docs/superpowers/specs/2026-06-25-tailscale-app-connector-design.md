# Tailscale App Connector for k3s API access — Design

Date: 2026-06-25

## Problem

The k3s API (`https://cluster.kaminek.me:6443`) is protected by a source-IP
allowlist containing only the 3 k8s node IPs. Reaching it from a laptop today
requires routing all laptop traffic through a Tailscale exit node running on one
of those nodes — too broad (captures every connection).

Goal: route **only** traffic destined for `cluster.kaminek.me` through the
tailnet so it egresses from a node IP (in the allowlist), while all other
laptop traffic flows normally.

## Solution

Tailscale **App Connector**, deployed in-cluster via the **Tailscale Kubernetes
Operator**. The operator manages a connector pod that advertises the domain
`cluster.kaminek.me` to the tailnet. Tailnet clients (laptop) intercept DNS for
that domain and route matching traffic through the connector pod, which egresses
(SNAT) from its node IP — already in the API allowlist.

Because the connector runs on the very nodes whose IPs are allowlisted, the
egress source IP satisfies the allowlist with no firewall change. NAT vs
hostNetwork is irrelevant: single node = single IP.

## Architecture

```
Laptop (tailnet client)
   │  DNS cluster.kaminek.me  → tailnet app-connector route intercepts
   │  traffic :6443
   ▼
Connector pod (ns: tailscale, scheduled on a node)
   │  egress SNAT → node IP  (∈ allowlist ✓)
   ▼
k3s API  https://cluster.kaminek.me:6443
```

## Components

1. **HelmRepository** `tailscale` (flux-system) →
   `https://pkgs.tailscale.com/helmcharts`
2. **HelmRelease** `tailscale-operator` in ns `tailscale`
3. **Connector** CR (`tailscale.com/v1alpha1`) with `spec.appConnector`
   advertising domain `cluster.kaminek.me`
4. **SOPS secret** `operator-oauth` — Tailscale OAuth client id/secret consumed
   by the operator
5. **Tailnet ACL (clickops, out-of-repo)** — tags + app-connector definition +
   autoApprovers

## File layout (Flux pattern, mirrors networking/external-dns)

```
cluster/apps/tailscale/
  kustomization.yaml            # namespaces + operator/ks.yaml
  namespaces.yaml               # ns tailscale (prune:false)
  tailscale-operator/
    ks.yaml                     # Flux Kustomization, targetNamespace tailscale, sops
    app/
      kustomization.yaml        # secret + helm-release + connector
      secret.sops.yaml          # operator-oauth (client_id/client_secret)
      helm-release.yaml         # tailscale-operator chart
      connector.yaml            # Connector CR, appConnector
```

Register:
- `cluster/flux/repositories/helm/kustomization.yaml` += `./tailscale.yaml`
- `cluster/flux/repositories/helm/tailscale.yaml` (new HelmRepository)
- `cluster/apps/kustomization.yaml` (or top-level apps aggregator) += tailscale

## Helm values (operator)

- `oauth.clientId` / `oauth.clientSecret` via existing Secret `operator-oauth`
  (chart default secret name) — set `oauthSecretVolume`/`installCRDs: true`.
- `apiServerProxyConfig.mode: "false"` (not using API-server proxy; we want app
  connector egress, not the operator's kube-apiserver proxy).
- Operator default tag: `tag:k8s-operator`.

## Connector CR

```yaml
apiVersion: tailscale.com/v1alpha1
kind: Connector
metadata:
  name: k3s-api
spec:
  hostname: k3s-api-connector
  tags:
    - tag:connector
  appConnector:
    routes:
      - cluster.kaminek.me
```

## Tailnet ACL (paste in admin console)

Add (merge into existing policy):

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": ["autogroup:admin"],
    "tag:connector":    ["tag:k8s-operator"]
  },
  "autoApprovers": {
    "routes": {},
    "exitNode": [],
    // app connector domains auto-approved for the connector tag
    "appConnectors": [
      { "name": "k3s-api", "connectors": ["tag:connector"], "domains": ["cluster.kaminek.me"] }
    ]
  },
  // grant laptop user access through the app connector
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:connector:*"] }
  ]
}
```

(Exact `appConnectors`/`autoApprovers` schema verified against current Tailscale
docs at implementation time.)

## OAuth client (admin console)

Create OAuth client, scopes `devices:write` (+ `auth_keys` write as required by
operator), tag it `tag:k8s-operator`. Put id/secret into `secret.sops.yaml`.

## Data flow / verification

1. Flux applies operator + Connector → connector device appears in admin console,
   tagged `tag:connector`, app connector active for `cluster.kaminek.me`.
2. On laptop (tailnet up): `tailscale status` shows app connector route.
3. `dig cluster.kaminek.me` from laptop resolves via tailnet; `curl -k
   https://cluster.kaminek.me:6443/version` succeeds → egress IP = node IP.
4. `kubectl --server https://cluster.kaminek.me:6443 get --raw /healthz` → ok.

## Error handling / risks

- **OAuth scope wrong** → operator pod CrashLoop / auth errors in logs. Fix scope.
- **ACL missing app-connector approval** → connector advertises but route not
  approved; laptop won't route. Fix ACL `autoApprovers.appConnectors`.
- **DNS**: `cluster.kaminek.me` must keep resolving to node IP(s) (external-dns
  default-target) so the connector advertises the right backend.
- **Egress not node IP** (if cilium masquerade disabled) → fallback
  `Connector` pod hostNetwork or ProxyClass. Default cilium SNAT expected fine.
- **Operator CRDs**: chart installs `Connector`/`ProxyClass` CRDs; ensure
  `install.crds`/`installCRDs` set.

## Out of scope

- Tailnet ACL-as-code (managed clickops).
- Firewall changes (allowlist unchanged — node IPs already trusted).
- Exposing other cluster services via tailnet (only k3s API domain).

## Unresolved questions

1. Confirm operator chart's exact OAuth secret key names + values schema for the
   running chart version (verify at implementation).
2. Confirm whether `apiServerProxyConfig` should stay disabled or be reused — the
   operator's built-in kube-apiserver proxy could be an *alternative* to the app
   connector. (Design keeps app connector per user request; note the alt.)
