# Vault + CSI Secrets Store — Kubernetes Deployment Guide

**Organization:** Infinia Technology  
**Vault URL:** https://vault.iamsaif.ai  
**Prepared by:** Navneet Shahi  
**Date:** April 2026

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Part A — One-Time Vault Setup (Prod Cluster)](#3-part-a--one-time-vault-setup-prod-cluster)
4. [Part B — New Cluster Onboarding (Dev/Staging)](#4-part-b--new-cluster-onboarding-devstaging)
5. [Part C — Deploying a New Application](#5-part-c--deploying-a-new-application)
6. [Part D — ArgoCD GitOps Setup](#6-part-d--argocd-gitops-setup)
7. [AI Prompt — Generate Kubernetes YAML](#7-ai-prompt--generate-kubernetes-yaml)
8. [Troubleshooting Reference](#8-troubleshooting-reference)

---

## 1. Architecture Overview

```
Developer pushes code
        ↓
GitHub Actions CI
  - Builds Docker image
  - Pushes to GHCR (ghcr.io/infinia-technology/)
  - Updates image tag in k8s/base/*.yaml
        ↓
ArgoCD detects git change
  - Syncs k8s/overlays/prod  →  Prod Cluster
  - Syncs k8s/overlays/dev   →  Dev Cluster
        ↓
Pod starts → CSI Driver mounts Vault secrets
  - Vault authenticates pod via Kubernetes Auth
  - Secrets injected as K8s Secret objects
  - Pod reads secrets via envFrom
```

**Key Components:**

| Component | Location | Purpose |
|---|---|---|
| HashiCorp Vault | Prod Cluster (vault namespace) | Central secret store |
| Secrets Store CSI Driver | Every cluster (secrets-store namespace) | Mounts Vault secrets into pods |
| Vault CSI Provider | Every cluster (secrets-store namespace) | Bridges CSI driver to Vault |
| ArgoCD | Prod Cluster (argocd namespace) | GitOps continuous delivery |
| GHCR | ghcr.io/infinia-technology/ | Container image registry |

---

## 2. Prerequisites

- `kubectl` configured for the target cluster
- `helm` v3+
- `vault` CLI (optional, can use UI)
- Access to https://vault.iamsaif.ai
- GitHub repo: https://github.com/Infinia-Technology/RecruitPro

**Add Helm repos:**

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

---

## 3. Part A — One-Time Vault Setup (Prod Cluster)

> Already completed for the current prod cluster. Only needed for a brand new Vault installation.

### 3.1 Install Vault

```bash
helm install vault hashicorp/vault \
  -n vault --create-namespace \
  --set "server.enabled=true" \
  --set "injector.enabled=true" \
  --set "csi.enabled=true"
```

### 3.2 Initialize and Unseal

```bash
kubectl exec -it vault-0 -n vault -- vault operator init
# Save the 5 unseal keys and root token securely

kubectl exec -it vault-0 -n vault -- vault operator unseal <key1>
kubectl exec -it vault-0 -n vault -- vault operator unseal <key2>
kubectl exec -it vault-0 -n vault -- vault operator unseal <key3>
```

### 3.3 Enable KV Secrets Engine

```bash
kubectl exec -it vault-0 -n vault -- vault secrets enable -path=secret kv-v2
```

### 3.4 Create ACL Policies

```bash
# App policy
kubectl exec -it vault-0 -n vault -- vault policy write <app-name> - <<EOF
path "secret/data/<app-name>" {
  capabilities = ["read"]
}
EOF

# GHCR policy (shared)
kubectl exec -it vault-0 -n vault -- vault policy write ghcr-policy - <<EOF
path "secret/data/ghcr" {
  capabilities = ["read"]
}
EOF
```

### 3.5 Enable Kubernetes Auth for Prod

```bash
kubectl exec -it vault-0 -n vault -- vault auth enable kubernetes

kubectl exec -it vault-0 -n vault -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local"

kubectl exec -it vault-0 -n vault -- vault write auth/kubernetes/role/<app-name> \
  bound_service_account_names=<service-account> \
  bound_service_account_namespaces=<namespace> \
  policies="<app-name>,ghcr-policy" \
  alias_name_source=serviceaccount_name \
  ttl=1h
```

### 3.6 Store Secrets

```bash
vault kv put secret/<app-name> \
  KEY1="value1" \
  KEY2="value2"

vault kv put secret/ghcr \
  dockerconfigjson='{"auths":{"ghcr.io":{"username":"Infinia-Technology","password":"<PAT>"}}}'
```

---

## 4. Part B — New Cluster Onboarding (Dev/Staging)

> Follow these steps every time you add a new cluster.

### 4.1 Install CSI Secrets Store Driver

```bash
helm install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  -n secrets-store --create-namespace \
  --set syncSecret.enabled=true
```

Verify (all pods should show 3/3 Running):

```bash
kubectl get pods -n secrets-store -l app=secrets-store-csi-driver
```

### 4.2 Install Vault CSI Provider

```bash
helm install vault-csi hashicorp/vault \
  -n secrets-store \
  --set "injector.enabled=false" \
  --set "csi.enabled=true" \
  --set "server.enabled=false"
```

Verify (should show 2/2 Running on each node):

```bash
kubectl get pods -n secrets-store -l app.kubernetes.io/name=vault-csi-provider
```

### 4.3 Prepare Vault Service Account on New Cluster

```bash
kubectl create namespace vault
kubectl create serviceaccount vault -n vault

kubectl create clusterrolebinding vault-server-binding \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault
```

### 4.4 Gather Cluster Information

```bash
# 1. API Server URL
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'

# 2. CA Certificate
kubectl get configmap kube-root-ca.crt -n kube-system \
  -o jsonpath='{.data.ca\.crt}'

# 3. Long-lived reviewer token (1 year)
kubectl create token vault -n vault --duration=8760h
```

> Save all three values — needed for Vault configuration.

### 4.5 Register New Cluster in Vault

Run from **prod cluster** (Mac terminal with prod kubeconfig):

```bash
# Step 1 — Enable new auth method (replace 'dev' with env name)
kubectl exec -it vault-0 -n vault -- vault auth enable \
  -path=kubernetes-<env> kubernetes

# Step 2 — Configure with cluster details
kubectl exec -it vault-0 -n vault -- vault write auth/kubernetes-<env>/config \
  kubernetes_host="https://<CLUSTER_API_SERVER>" \
  kubernetes_ca_cert="<CA_CERT>" \
  token_reviewer_jwt="<REVIEWER_TOKEN>" \
  disable_iss_validation=true \
  disable_local_ca_jwt=true

# Step 3 — Create role for the application
kubectl exec -it vault-0 -n vault -- vault write auth/kubernetes-<env>/role/<app-name> \
  bound_service_account_names=<service-account> \
  bound_service_account_namespaces=<namespace> \
  policies="<app-name>,ghcr-policy" \
  alias_name_source=serviceaccount_name \
  ttl=1h
```

> **Important:** Use `alias_name_source=serviceaccount_name` — NOT the default UID, which changes when the SA is recreated by ArgoCD.

> **Important:** Always provide `kubernetes_ca_cert` explicitly. Without it, Vault cannot verify the cluster's TLS and TokenReview will fail with 403.

---

## 5. Part C — Deploying a New Application

### 5.1 Repository Structure (Kustomize)

```
k8s/
├── base/                         # Shared across all environments
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccount.yaml
│   ├── configmap.yaml
│   ├── <app>-deployment.yaml
│   ├── <app>-service.yaml
│   └── <app>-pvc.yaml (if needed)
└── overlays/
    ├── prod/                     # Uses vault auth path: kubernetes
    │   ├── kustomization.yaml
    │   ├── secret-provider-class.yaml
    │   └── ghcr-secret-provider-class.yaml
    └── dev/                      # Uses vault auth path: kubernetes-dev
        ├── kustomization.yaml
        ├── secret-provider-class.yaml
        └── ghcr-secret-provider-class.yaml
```

### 5.2 SecretProviderClass

**Prod** (`k8s/overlays/prod/secret-provider-class.yaml`):

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-<app-name>
  namespace: <namespace>
spec:
  provider: vault
  secretObjects:
    - secretName: <app-name>-secret
      type: Opaque
      data:
        - key: MY_KEY
          objectName: MY_KEY
  parameters:
    vaultAddress: "https://vault.iamsaif.ai"
    roleName: "<app-name>"
    vaultKubernetesMountPath: "kubernetes"
    objects: |
      - objectName: "MY_KEY"
        secretPath: "secret/data/<app-name>"
        secretKey: "MY_KEY"
```

**Dev** (`k8s/overlays/dev/secret-provider-class.yaml`):

Same as above, only change:

```yaml
    vaultKubernetesMountPath: "kubernetes-dev"
```

> **Critical:** Use `vaultKubernetesMountPath` — NOT `kubernetesMountPath`. The wrong key is silently ignored and defaults to `kubernetes/`.

### 5.3 Deployment with Vault CSI Volume

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app-name>
  namespace: <namespace>
spec:
  replicas: 2
  selector:
    matchLabels:
      app: <app-name>
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: <app-name>
    spec:
      serviceAccountName: <service-account>
      imagePullSecrets:
        - name: ghcr-credentials
      containers:
        - name: <app-name>
          image: ghcr.io/infinia-technology/<app-name>:latest
          imagePullPolicy: Always
          ports:
            - containerPort: <PORT>
          envFrom:
            - configMapRef:
                name: <app-name>-config
            - secretRef:
                name: <app-name>-secret
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /health
              port: <PORT>
            initialDelaySeconds: 30
            periodSeconds: 15
          readinessProbe:
            httpGet:
              path: /health
              port: <PORT>
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: vault-secrets
              mountPath: /mnt/vault-secrets
              readOnly: true
            - name: vault-ghcr-secrets
              mountPath: /mnt/vault-ghcr-secrets
              readOnly: true
      volumes:
        - name: vault-secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "vault-<app-name>"
        - name: vault-ghcr-secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "vault-ghcr"
```

> **Critical:** The CSI volume MUST be mounted in the pod. The K8s Secret object (`<app-name>-secret`) is only created when a pod mounts the CSI volume — it is NOT created at apply time.

### 5.4 Kustomization Files

**Base** (`k8s/base/kustomization.yaml`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - serviceaccount.yaml
  - configmap.yaml
  - <app>-deployment.yaml
  - <app>-service.yaml
```

**Overlay** (`k8s/overlays/prod/kustomization.yaml` and `k8s/overlays/dev/kustomization.yaml`):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base
  - secret-provider-class.yaml
  - ghcr-secret-provider-class.yaml
```

---

## 6. Part D — ArgoCD GitOps Setup

### 6.1 ArgoCD Application Manifests

**Prod** (`argocd/application.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/Infinia-Technology/<repo>.git
    targetRevision: main
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Dev** (`argocd/application-dev.yaml`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <app-name>-dev
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/Infinia-Technology/<repo>.git
    targetRevision: main
    path: k8s/overlays/dev
  destination:
    server: https://<DEV_CLUSTER_API_SERVER>
    namespace: <namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### 6.2 Apply and Sync

```bash
kubectl apply -f argocd/application.yaml
kubectl apply -f argocd/application-dev.yaml

argocd app sync <app-name>
argocd app sync <app-name>-dev
```

---

## 7. AI Prompt — Generate Kubernetes YAML

Copy and fill in the following prompt to generate a complete set of manifests for any new application:

---

Generate a complete set of Kubernetes manifests for a new application using Vault CSI Secrets Store with Kustomize overlays for prod and dev clusters.

Application details:
- App name: [APP_NAME]
- Namespace: [NAMESPACE]
- Container image: ghcr.io/infinia-technology/[APP_NAME]:latest
- Container port: [PORT]
- Service account name: [SERVICE_ACCOUNT_NAME]
- Secrets needed from Vault path secret/data/[APP_NAME]: [COMMA_SEPARATED_SECRET_KEYS]
- Non-secret config env vars: [KEY=VALUE pairs]
- Replicas: [NUMBER]
- CPU request/limit: [e.g. 500m / 1000m]
- Memory request/limit: [e.g. 512Mi / 1Gi]
- Needs persistent storage: [yes/no — if yes, specify size and mount path]
- Health check endpoint: [e.g. /health or /live]

Infrastructure settings (do not change these):
- Vault address: https://vault.iamsaif.ai
- Prod Vault Kubernetes auth path: kubernetes
- Dev Vault Kubernetes auth path: kubernetes-dev
- GHCR credentials secret: ghcr-credentials
- Kustomize structure: k8s/base/ for shared resources, k8s/overlays/prod/ and k8s/overlays/dev/ for environment-specific

Generate the following files:
1. k8s/base/namespace.yaml
2. k8s/base/serviceaccount.yaml
3. k8s/base/configmap.yaml
4. k8s/base/[app]-deployment.yaml
5. k8s/base/[app]-service.yaml
6. k8s/base/kustomization.yaml
7. k8s/overlays/prod/secret-provider-class.yaml
8. k8s/overlays/prod/ghcr-secret-provider-class.yaml
9. k8s/overlays/prod/kustomization.yaml
10. k8s/overlays/dev/secret-provider-class.yaml
11. k8s/overlays/dev/ghcr-secret-provider-class.yaml
12. k8s/overlays/dev/kustomization.yaml
13. argocd/application.yaml
14. argocd/application-dev.yaml

Rules to follow:
- Use vaultKubernetesMountPath (not kubernetesMountPath) in SecretProviderClass parameters
- Mount both vault-secrets and vault-ghcr-secrets CSI volumes in the deployment
- Use envFrom.secretRef to inject secrets and envFrom.configMapRef for config
- The ghcr-secret-provider-class must be mounted in the pod to bootstrap ghcr-credentials
- Use alias_name_source=serviceaccount_name in all Vault role commands
- Provide the Vault CLI commands to create the policy and role for both prod and dev

---

## 8. Troubleshooting Reference

| Error | Cause | Fix |
|---|---|---|
| `permission denied` on `auth/kubernetes/login` | Wrong auth path in SecretProviderClass | Set `vaultKubernetesMountPath: "kubernetes-dev"` for dev |
| `permission denied` on `auth/kubernetes-dev/login` | CA cert missing or wrong reviewer JWT | Re-run step 4.5 with correct CA cert and dev token |
| `secret "X" not found` | SecretProviderClass not yet synced | Delete old SPC, let ArgoCD recreate, then restart pod |
| `ModuleNotFoundError: psycopg2` | DATABASE_URL uses wrong scheme | Use `postgresql+asyncpg://` prefix in Vault secret |
| `ImagePullBackOff` | `ghcr-credentials` not created | Mount `vault-ghcr` CSI volume in backend deployment |
| `SharedResourceWarning` in ArgoCD | Two apps managing same resource | Ensure both apps have unique names, delete duplicate app |
| `RepeatedResourceWarning` in ArgoCD | Duplicate resource in multiple YAML files | Remove duplicate file |
| CSI driver install fails on kube-system | Insufficient cluster permissions | Install in `secrets-store` namespace with `--create-namespace` |
| TokenReview fails (403) after correct config | `disable_local_ca_jwt` not set | Add `disable_local_ca_jwt=true` to Vault auth config |
| CA cert not persisting in Vault config | Config written without cert | Always include `kubernetes_ca_cert` in vault write command |

### Quick Debug Commands

```bash
# Check pod mount errors
kubectl describe pod <pod-name> -n <namespace> | grep -A5 Events

# Check CSI provider logs on the cluster
kubectl logs -n secrets-store \
  -l app.kubernetes.io/name=vault-csi-provider --tail=30

# Verify SecretProviderClass auth path
kubectl get secretproviderclass <name> -n <namespace> \
  -o yaml | grep -i vault

# Test Vault login manually from the cluster
TOKEN=$(kubectl create token <service-account> -n <namespace> --duration=1h)
curl -sk -X POST https://vault.iamsaif.ai/v1/auth/kubernetes-dev/login \
  -H "Content-Type: application/json" \
  -d "{\"role\":\"<role>\",\"jwt\":\"$TOKEN\"}"

# Read a K8s secret value
kubectl get secret <secret-name> -n <namespace> \
  -o jsonpath='{.data.<key>}' | base64 -d

# Enable Vault audit logging
kubectl exec -it vault-0 -n vault -- \
  vault audit enable file file_path=/tmp/audit.log

# Tail Vault audit log
kubectl exec -it vault-0 -n vault -- tail -5 /tmp/audit.log

# Verify Vault auth config
kubectl exec -it vault-0 -n vault -- \
  vault read auth/kubernetes-dev/config

# Verify Vault role
kubectl exec -it vault-0 -n vault -- \
  vault read auth/kubernetes-dev/role/<role-name>
```
