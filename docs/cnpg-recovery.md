# CNPG Recovery Procedures

## Backup Architecture

```
PostgreSQL → WAL Archive → S3 (continuous)
                ↓
          Base Backup → S3 (daily 3 AM)
```

- **WAL archiving**: Continuous, enables Point-in-Time Recovery (PITR)
- **Base backups**: Daily full backup
- **Retention**: 30 days
- **Encryption**: AES-256 client-side

## List Available Backups

```bash
# List backups
kubectl get backups -n database

# Check backup status
kubectl get backup -n database -o wide

# View scheduled backup status
kubectl get scheduledbackup -n database
```

## Recovery Scenarios

### 1. Recover to Latest (Full Restore)

Create a new cluster from the latest backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-restored
  namespace: database
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4-28

  storage:
    size: 10Gi
    storageClass: openebs-hostpath

  bootstrap:
    recovery:
      source: main-backup

  externalClusters:
    - name: main-backup
      barmanObjectStore:
        destinationPath: s3://cnpg/main
        endpointURL: https://47dc2e8ccaf9538255dd55cb3fc09e7c.r2.cloudflarestorage.com
        s3Credentials:
          accessKeyId:
            name: cnpg-backup-secret
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: cnpg-backup-secret
            key: SECRET_ACCESS_KEY
        wal:
          compression: gzip
          encryption: AES256
```

### 2. Point-in-Time Recovery (PITR)

Recover to a specific timestamp:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: main-restored
  namespace: database
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4-28

  storage:
    size: 10Gi
    storageClass: openebs-hostpath

  bootstrap:
    recovery:
      source: main-backup
      recoveryTarget:
        targetTime: "2025-01-15 10:30:00.000000+00"  # UTC timestamp

  externalClusters:
    - name: main-backup
      barmanObjectStore:
        destinationPath: s3://cnpg/main
        endpointURL: https://47dc2e8ccaf9538255dd55cb3fc09e7c.r2.cloudflarestorage.com
        s3Credentials:
          accessKeyId:
            name: cnpg-backup-secret
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: cnpg-backup-secret
            key: SECRET_ACCESS_KEY
        wal:
          compression: gzip
          encryption: AES256
```

### 3. Recover to Specific Transaction ID

```yaml
bootstrap:
  recovery:
    source: main-backup
    recoveryTarget:
      targetXID: "12345678"
```

### 4. Recover to Named Restore Point

```yaml
bootstrap:
  recovery:
    source: main-backup
    recoveryTarget:
      targetName: "before-migration"
```

## Recovery Steps

### Step 1: Verify Backups Exist

```bash
# Check S3 bucket contents
aws s3 ls s3://cnpg/main/ --endpoint-url https://47dc2e8ccaf9538255dd55cb3fc09e7c.r2.cloudflarestorage.com

# Or use rclone
rclone ls r2:cnpg/main/
```

### Step 2: Create Recovery Cluster

```bash
# Apply recovery manifest
kubectl apply -f recovery-cluster.yaml

# Watch recovery progress
kubectl get cluster -n database -w

# Check pods
kubectl get pods -n database -l cnpg.io/cluster=main-restored
```

### Step 3: Verify Data

```bash
# Connect to restored cluster
kubectl exec -it main-restored-1 -n database -- psql -U postgres

# Check databases
\l

# Check tables
\dt
```

### Step 4: Switch Applications

Option A: Rename clusters (downtime)
```bash
# Scale down apps
kubectl scale deployment vaultwarden -n utilities --replicas=0

# Delete old cluster
kubectl delete cluster main -n database

# Rename restored cluster (edit metadata.name)
kubectl get cluster main-restored -n database -o yaml | \
  sed 's/main-restored/main/g' | kubectl apply -f -
```

Option B: Update connection strings (minimal downtime)
```bash
# Update secrets to point to new cluster
# main-restored-rw.database.svc instead of main-rw.database.svc
```

## Manual Backup

Trigger an immediate backup:

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: main-manual-$(date +%Y%m%d-%H%M%S)
  namespace: database
spec:
  method: barmanObjectStore
  cluster:
    name: main
EOF
```

## Verify Backup Health

```bash
# Check cluster backup status
kubectl get cluster main -n database -o jsonpath='{.status.lastSuccessfulBackup}'

# Check WAL archiving
kubectl get cluster main -n database -o jsonpath='{.status.currentWALArchiveStatus}'

# View backup logs
kubectl logs -n database -l cnpg.io/cluster=main -c postgres | grep -i backup
```

## Disaster Recovery Checklist

- [ ] Backup secret exists and is accessible
- [ ] S3 bucket is accessible
- [ ] Latest backup is < 24 hours old
- [ ] WAL archiving is working (no gaps)
- [ ] Test recovery quarterly

## Common Issues

### Backup Not Running

```bash
# Check scheduled backup
kubectl describe scheduledbackup main-daily -n database

# Check operator logs
kubectl logs -n database -l app.kubernetes.io/name=cloudnative-pg
```

### WAL Archiving Delayed

```bash
# Check WAL status
kubectl get cluster main -n database -o yaml | grep -A5 walArchive
```

### S3 Permission Denied

```bash
# Verify credentials
kubectl get secret cnpg-backup-secret -n database -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d

# Test S3 access from pod
kubectl exec -it main-1 -n database -- env | grep AWS
```
