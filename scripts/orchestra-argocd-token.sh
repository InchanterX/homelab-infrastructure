#!/usr/bin/env bash
# Выпускает API-токен Argo CD для аккаунта orchestra и сразу запечатывает его в SealedSecret.
# Токен нигде не сохраняется в открытом виде: argocd -> kubectl (dry-run) -> kubeseal -> файл.
#
# Нужно на ноде: argocd, kubectl (доступ к кластеру), kubeseal.
# Перед запуском войти в Argo CD под admin:
#   argocd login argocd.faberge-eggs.ru --grpc-web
#
# Запуск из корня репозитория:
#   ./scripts/orchestra-argocd-token.sh
set -euo pipefail

ACCOUNT="${ACCOUNT:-orchestra}"
TOKEN_ID="${TOKEN_ID:-${ACCOUNT}-$(date +%Y%m%d)}"
EXPIRES_IN="${EXPIRES_IN:-0s}" # 0s - бессрочно, например 8760h - год

SECRET_NAME="${SECRET_NAME:-orchestra-argocd-token}"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-orchestra}"
ARGOCD_SERVER_ADDR="${ARGOCD_SERVER_ADDR:-argocd.faberge-eggs.ru}"

CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets-controller}"
CONTROLLER_NAMESPACE="${CONTROLLER_NAMESPACE:-infrastructure-dev}"

OUT="${OUT:-kustomization/orchestra-argocd/base/argocd-token-secret.yaml}"

for bin in argocd kubectl kubeseal; do
  command -v "$bin" >/dev/null || { echo "не найден: $bin" >&2; exit 1; }
done

argocd account get --account "$ACCOUNT" --grpc-web >/dev/null

argocd account generate-token \
    --account "$ACCOUNT" \
    --id "$TOKEN_ID" \
    --expires-in "$EXPIRES_IN" \
    --grpc-web \
  | tr -d '\n' \
  | kubectl create secret generic "$SECRET_NAME" \
      --namespace "$SECRET_NAMESPACE" \
      --from-file=ARGOCD_AUTH_TOKEN=/dev/stdin \
      --from-literal=ARGOCD_SERVER="$ARGOCD_SERVER_ADDR" \
      --dry-run=client -o yaml \
  | kubeseal \
      --controller-name "$CONTROLLER_NAME" \
      --controller-namespace "$CONTROLLER_NAMESPACE" \
      --format yaml \
  > "$OUT"

echo "Токен '$TOKEN_ID' выпущен, SealedSecret записан в $OUT"
echo "Отозвать: argocd account delete-token --account $ACCOUNT $TOKEN_ID --grpc-web"
