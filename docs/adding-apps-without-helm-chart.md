# Adding Apps Without a Helm Chart

Use bjw-s app-template to deploy container images that don't have an official Helm chart.

## Directory Structure

```
cluster/apps/<namespace>/<app-name>/
├── ks.yaml                     # Flux Kustomization
└── app/
    ├── kustomization.yaml      # Kustomize resources
    ├── helm-release.yaml       # HelmRelease using app-template
    └── resources/              # Optional: config files
        └── config.yaml
```

## Files

### ks.yaml

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app-name>
  namespace: flux-system
spec:
  targetNamespace: <namespace>
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./cluster/apps/<namespace>/<app-name>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-ops
  wait: false
  interval: 30m
  timeout: 5m
```

### app/kustomization.yaml

Without config file:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helm-release.yaml
```

With config file (configMapGenerator):
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helm-release.yaml
configMapGenerator:
  - name: <app-name>-configmap
    files:
      - config.yaml=./resources/config.yaml
generatorOptions:
  disableNameSuffixHash: true
  annotations:
    kustomize.toolkit.fluxcd.io/substitute: disabled
```

### app/helm-release.yaml

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app <app-name>
spec:
  releaseName: *app
  chart:
    spec:
      chart: app-template
      version: 4.5.0
      sourceRef:
        kind: HelmRepository
        name: bjw-s
        namespace: flux-system
  interval: 30m
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
  values:
    controllers:
      <app-name>:
        replicas: 1
        annotations:
          reloader.stakater.com/auto: "true"  # Only if using configmap
        pod:
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            runAsGroup: 1000
            fsGroup: 1000
            fsGroupChangePolicy: OnRootMismatch
        containers:
          app:
            image:
              repository: <image-repo>
              tag: <image-tag>
            env:
              TZ: Europe/Paris
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities:
                drop: ["ALL"]
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: &port 8080
                  initialDelaySeconds: 0
                  periodSeconds: 10
                  timeoutSeconds: 1
                  failureThreshold: 3
              readiness: *probes
            resources:
              requests:
                cpu: 10m
                memory: 64Mi
              limits:
                memory: 256Mi
    service:
      app:
        controller: <app-name>
        ports:
          http:
            port: *port
    ingress:
      main:
        enabled: true
        className: external
        annotations:
          external-dns.alpha.kubernetes.io/hostname: <app-name>.kaminek.me
          cert-manager.io/cluster-issuer: letsencrypt-production
          nginx.ingress.kubernetes.io/auth-url: "https://oauth.kaminek.me/oauth2/auth"
          nginx.ingress.kubernetes.io/auth-signin: "https://oauth.kaminek.me/oauth2/start?rd=$scheme://$host$request_uri"
          gatus.home-operations.com/enabled: "false"
          hajimari.io/enable: "true"
          hajimari.io/icon: <mdi-icon>
          hajimari.io/group: <group>
          hajimari.io/appName: <display-name>
        hosts:
          - host: &uri <app-name>.kaminek.me
            paths:
              - path: /
                pathType: Prefix
                service:
                  identifier: app
                  port: http
        tls:
          - hosts:
              - *uri
            secretName: <app-name>-tls
    persistence:
      config:
        type: configMap
        name: <app-name>-configmap
        globalMounts:
          - path: /path/to/config.yaml
            subPath: config.yaml
            readOnly: true
```

## Add to Namespace Kustomization

Edit `cluster/apps/<namespace>/kustomization.yaml`:

```yaml
resources:
  - namespace.yaml
  - existing-app/ks.yaml
  - <app-name>/ks.yaml  # Add new app
```

## Common Patterns

### With Persistence (PVC)

```yaml
persistence:
  data:
    existingClaim: <app-name>-data
    globalMounts:
      - path: /data
```

### With StatefulSet (for SQLite/data)

```yaml
controllers:
  <app-name>:
    type: statefulset
    statefulset:
      volumeClaimTemplates:
        - name: data
          storageClass: openebs-hostpath
          accessMode: ReadWriteOnce
          size: 1Gi
          globalMounts:
            - path: /data
```

### Without OAuth (public endpoint)

Remove these annotations:
```yaml
nginx.ingress.kubernetes.io/auth-url: ...
nginx.ingress.kubernetes.io/auth-signin: ...
```

### Large File Uploads

```yaml
annotations:
  nginx.ingress.kubernetes.io/proxy-body-size: "100m"
```

## Checklist

- [ ] Create directory structure
- [ ] Add ks.yaml with correct sourceRef (home-ops)
- [ ] Add kustomization.yaml
- [ ] Add helm-release.yaml
- [ ] Add to namespace kustomization.yaml
- [ ] Add reloader annotation if using configmap
- [ ] Commit and push
