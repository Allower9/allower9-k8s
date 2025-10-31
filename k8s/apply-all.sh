#!/bin/bash

set -e

echo "🚀 Применяем K8s манифесты..."

echo "🔐 Создаём TLS Secrets..."
kubectl create secret tls allower-ru-tls \
  --cert=../certs/allower-ru/cert.pem \
  --key=../certs/allower-ru/key.pem \
  --dry-run=client -o yaml | kubectl apply -f -

for file in 01-namespace.yaml 02-storage-class.yaml 03-configmaps.yaml 04-pvc.yaml \
            05-backend-deployment.yaml 06-backend-service.yaml \
            07-frontend-deployment.yaml 08-frontend-service.yaml \
            09-ingress.yaml; do
  echo "Применяю $file..."
  kubectl apply -f "$file"
done

echo ""
echo "✅ Манифесты применены!"
echo ""
echo "📊 Проверь статус:"
echo "  kubectl get pods"
echo "  kubectl get svc"
echo "  kubectl get ingress"
echo "  kubectl get pvc"
