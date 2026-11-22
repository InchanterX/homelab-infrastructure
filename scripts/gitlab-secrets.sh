#!/usr/bin/env bash
# Run on the target server: bash scripts/gitlab-secrets.sh
# Requires Bash, kubectl, kubeseal and access to the target cluster.
# Only encrypted data is written to disk. No resources are applied.
set +x
set -euo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/kustomization/gitlab-dependencies/base/secrets"
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets-controller}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-infrastructure-dev}"
for bin in kubectl kubeseal; do
  command -v "$bin" >/dev/null || { echo "Не найден $bin" >&2; exit 1; }
done
exec 3<>/dev/tty
printf 'Кластер: %s; namespace секретов: gitlab\n' "$(kubectl config current-context)" >&3
mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.staging.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
kubeseal --fetch-cert --controller-name "$CONTROLLER_NAME" \
  --controller-namespace "$CONTROLLER_NAMESPACE" > "$STAGE/cert.pem"

ask() {
  local label="$1" confirm
  while true; do
    IFS= read -r -s -p "$label: " REPLY <&3
    printf '\n' >&3
    [[ -n "$REPLY" ]] || { echo 'Пустое значение запрещено.' >&3; continue; }
    IFS= read -r -s -p 'Повторите: ' confirm <&3
    printf '\n' >&3
    [[ "$REPLY" == "$confirm" ]] && break
    echo 'Значения не совпали.' >&3
  done
}

# Arguments contain only resource names and keys; plaintext travels via stdin.
begin_secret() {
  NAME="$1"
  cat > "$STAGE/$NAME.yaml" <<EOF
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: $NAME
  namespace: gitlab
spec:
  template:
    metadata:
      name: $NAME
      namespace: gitlab
    type: Opaque
  encryptedData:
EOF
}
seal_key() {
  local key="$1" encrypted
  encrypted="$(kubeseal --raw --scope strict --cert "$STAGE/cert.pem" \
    --namespace gitlab --name "$NAME")"
  printf '    %s: %s\n' "$key" "$encrypted" >> "$STAGE/$NAME.yaml"
}

echo 'Существующие файлы будут заменены. Это не меняет пароли внутри уже работающей БД.' >&3
begin_secret gitlab-postgresql-auth
ask 'Пароль администратора PostgreSQL (postgres)'
printf '%s' "$REPLY" | seal_key postgres-password
ask 'Пароль пользователя PostgreSQL (gitlab)'
printf '%s' "$REPLY" | seal_key password

begin_secret gitlab-redis-auth
ask 'Пароль Redis'
printf '%s' "$REPLY" | seal_key redis-password

begin_secret gitlab-garage-rpc
while true; do
  ask 'Garage RPC secret (64 hex-символа)'
  [[ "$REPLY" =~ ^[[:xdigit:]]{64}$ ]] && break
  echo 'Нужно ровно 64 hex-символа.' >&3
done
printf '%s' "$REPLY" | seal_key rpcSecret

begin_secret gitlab-object-storage
ask 'S3 access key из Garage'
ACCESS_KEY="$REPLY"
ask 'S3 secret key из Garage'
# Escape single quotes for YAML single-quoted scalars.
ACCESS_KEY="${ACCESS_KEY//\'/\'\'}"
REPLY="${REPLY//\'/\'\'}"
printf "provider: AWS\nregion: garage\naws_access_key_id: '%s'\naws_secret_access_key: '%s'\nendpoint: http://gitlab-garage.gitlab.svc.cluster.local:3900\npath_style: true\naws_signature_version: 4\n" \
  "$ACCESS_KEY" "$REPLY" | seal_key connection
unset ACCESS_KEY REPLY

IFS= read -r -p 'Токен Runner уже получен в GitLab? [y/N]: ' answer <&3
if [[ "$answer" =~ ^[yY]$ ]]; then
  begin_secret gitlab-runner-auth
  while true; do
    ask 'Runner authentication token (glrt-...)'
    [[ "$REPLY" == glrt-?* ]] && break
    echo 'Нужен authentication token с префиксом glrt-.' >&3
  done
  printf '%s' "$REPLY" | seal_key runner-token
  printf '' | seal_key runner-registration-token
else
  echo 'Runner пропущен; после создания токена запустите скрипт повторно с прежними паролями.' >&3
fi
unset REPLY

# Publish only after every requested secret has been encrypted successfully.
for file in "$STAGE"/*.yaml; do
  mv -- "$file" "$OUT/"
done
{
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n'
  for file in "$OUT"/*.yaml; do
    [[ "${file##*/}" == kustomization.yaml ]] && continue
    printf '  - %s\n' "${file##*/}"
  done
} > "$STAGE/kustomization.yaml"
mv -- "$STAGE/kustomization.yaml" "$OUT/kustomization.yaml"
echo "SealedSecrets записаны в $OUT. Проверьте diff и закоммитьте изменения." >&3
