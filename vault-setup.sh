#!/usr/bin/env bash
# =============================================================================
# vault-setup.sh — Configure Vault policy, role, and secrets for <APP_NAME>.
# =============================================================================
set -euo pipefail

VAULT_POD=vault-0
VAULT_NS=vault
APP_NAME=
NAMESPACE=
SA_NAME=
DOMAIN=

read -rsp "Vault root/admin token: " VAULT_TOKEN
echo ""

# ── Credentials ───────────────────────────────────────────────────────────────
# Replace values or leave as "generate" placeholders
KEY_1=
KEY_2=
KEY_3=
KEY_4=$(openssl rand -base64 24 | tr -d '/+=')   # auto-generated example
KEY_5=$(openssl rand -base64 32)                  # auto-generated example

# MongoDB (remove block if not needed)
MONGO_ROOT_USER=
MONGO_ROOT_PASSWORD=
MONGO_APP_USER=
MONGO_APP_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')

# MinIO (remove block if not needed)
MINIO_ROOT_USER=
MINIO_ROOT_PASSWORD=

vault_exec() {
  kubectl exec -i "$VAULT_POD" -n "$VAULT_NS" -- \
    env VAULT_TOKEN="$VAULT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
    vault "$@"
}

# ── Policy ────────────────────────────────────────────────────────────────────
echo "[1/4] Writing policy '${APP_NAME}'..."
kubectl exec -i "$VAULT_POD" -n "$VAULT_NS" -- \
  env VAULT_TOKEN="$VAULT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
  vault policy write "$APP_NAME" - <<POLICY
path "secret/data/${APP_NAME}"        { capabilities = ["read"] }
path "secret/data/${APP_NAME}-mongo"  { capabilities = ["read"] }
path "secret/data/${APP_NAME}-minio"  { capabilities = ["read"] }
path "secret/data/ghcr"               { capabilities = ["read"] }
POLICY

# ── Kubernetes auth roles ─────────────────────────────────────────────────────
echo "[2/4] Writing Vault roles..."

# Prod role
vault_exec write auth/kubernetes/role/"$APP_NAME" \
  bound_service_account_names="$SA_NAME" \
  bound_service_account_namespaces="$NAMESPACE" \
  policies="${APP_NAME}" \
  alias_name_source=serviceaccount_name \
  ttl=1h

# Dev role (remove if not needed)
vault_exec write auth/kubernetes-dev/role/"$APP_NAME" \
  bound_service_account_names="$SA_NAME" \
  bound_service_account_namespaces="$NAMESPACE" \
  policies="${APP_NAME}" \
  alias_name_source=serviceaccount_name \
  ttl=1h

# ── App secrets ───────────────────────────────────────────────────────────────
echo "[3/4] Storing secrets..."

vault_exec kv put secret/"$APP_NAME" \
  KEY_1="${KEY_1}" \
  KEY_2="${KEY_2}" \
  KEY_3="${KEY_3}" \
  KEY_4="${KEY_4}" \
  KEY_5="${KEY_5}"

# MongoDB secrets (remove block if not needed)
vault_exec kv put secret/"$APP_NAME"-mongo \
  MONGO_INITDB_ROOT_USERNAME="${MONGO_ROOT_USER}" \
  MONGO_INITDB_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD}" \
  MONGO_INITDB_DATABASE="${APP_NAME}" \
  MONGO_APP_USER="${MONGO_APP_USER}" \
  MONGO_APP_PASSWORD="${MONGO_APP_PASSWORD}"

# MinIO secrets (remove block if not needed)
vault_exec kv put secret/"$APP_NAME"-minio \
  MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}"

# ── Verify ────────────────────────────────────────────────────────────────────
echo "[4/4] Verifying..."
vault_exec read auth/kubernetes/role/"$APP_NAME"
vault_exec read auth/kubernetes-dev/role/"$APP_NAME"
vault_exec kv get secret/"$APP_NAME"
vault_exec kv get secret/"$APP_NAME"-mongo
vault_exec kv get secret/"$APP_NAME"-minio

echo ""
echo "=== Save these generated values ==="
echo "  KEY_4:             ${KEY_4}"
echo "  KEY_5:             ${KEY_5}"
echo "  Mongo app pass:    ${MONGO_APP_PASSWORD}"
