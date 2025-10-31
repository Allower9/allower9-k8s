#!/bin/bash

set -e

echo "🚀 Установка Prometheus + Grafana Stack..."

echo "📁 Создаём namespace monitoring..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "🔐 Создаём TLS Secret для Grafana..."
kubectl create secret tls grafana-allower-ru-tls \
  --cert=../certs/grafana-allower-ru/cert.pem \
  --key=../certs/grafana-allower-ru/key.pem \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

echo "📦 Добавляем Helm репозитории..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo "📊 Установка Prometheus Stack..."
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f prometheus-values.yaml \
  --wait --timeout=5m

echo "📈 Установка Grafana..."
helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f grafana-values.yaml \
  --wait --timeout=5m

echo "🌐 Создаём Ingress для Prometheus..."
kubectl apply -f - << 'INGRESS1'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus-ingress
  namespace: monitoring
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - "allower.ru"
      secretName: "allower-ru-tls"
  rules:
  - host: allower.ru
    http:
      paths:
      - path: /prometheus
        pathType: Prefix
        backend:
          service:
            name: prometheus-operated
            port:
              number: 9090
INGRESS1

echo "🌐 Создаём Ingress для Grafana..."
kubectl apply -f - << 'INGRESS2'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - "grafana.allower.ru"
      secretName: "grafana-allower-ru-tls"
  rules:
  - host: grafana.allower.ru
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 80
INGRESS2

echo ""
echo "✅ Monitoring Stack установлен!"
echo ""
echo "🔗 Доступ:"
echo "   Prometheus: https://allower.ru/prometheus"
echo "   Grafana: https://grafana.allower.ru"
echo ""
echo "🔐 Grafana credentials:"
echo "   Username: admin"
echo "   Password: GrafanaSecurePass123!"
