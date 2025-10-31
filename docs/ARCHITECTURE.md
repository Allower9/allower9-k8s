# ARCHITECTURE.md - Архитектура Kubernetes проекта allower.ru

## 🏗️ Общая архитектура

```
ИНТЕРНЕТ
   ↓ DNS: allower.ru → 203.0.113.45
   ↓
┌────────────────────────────────────────────────────┐
│         LoadBalancer (External IP)                 │
│    ingress-nginx-controller Service                │
│         Port: 80 (HTTP) → 443 (HTTPS)              │
└────────────┬──────────────────────────────────────┘
             ↓
┌────────────────────────────────────────────────────┐
│     NGINX Ingress Controller (DaemonSet)           │
│  Reads Ingress rules, terminates TLS (HTTPS→HTTP) │
└────┬──────────────────────┬───────────────┬────────┘
     ↓                      ↓               ↓
  Host: allower.ru (/)  Host: allower.ru (/api)  Other hosts
     ↓                      ↓
┌─────────────────┐   ┌──────────────┐
│   Frontend      │   │   Backend    │
│   Service:80    │   │ Service:5000 │
│   (ClusterIP)   │   │ (ClusterIP)  │
└────┬────────────┘   └──────┬───────┘
     ↓                       ↓
  [nginx pod]          [busybox pod]
  [nginx pod]          [busybox pod]
  [nginx pod]          [busybox pod]
     ↓                       ↓
 PVC:frontend-data    PVC:backend-data
    3GB SSD              5GB SSD
```

---

## 🔄 Как работает запрос

### Пример: Пользователь открывает https://allower.ru

1. **DNS resolution** (allower.ru → 203.0.113.45)
2. **LoadBalancer** принимает HTTPS запрос на port 443
3. **Ingress Controller** читает Ingress resource:
   ```yaml
   host: allower.ru, path: /, → Service: frontend:80
   ```
4. **Frontend Service** балансирует трафик между 3 nginx pods
5. **Nginx pod** отвечает HTML с UI

### Пример: JavaScript делает fetch('/api/hello')

1. **Browser** отправляет запрос на https://allower.ru/api/hello
2. **Ingress Controller** читает:
   ```yaml
   host: allower.ru, path: /api → Service: backend:5000
   ```
3. **Backend Service** выбирает один из 3 backend pods
4. **Backend pod** (busybox + netcat) отвечает JSON
5. **Browser** отображает результат

---

## 🔐 TLS/HTTPS Flow

```
Client                    Ingress Controller         Backend
  │                              │                       │
  │──── HTTPS (TLS) ────────────→│                       │
  │                              │ (Terminates TLS)      │
  │                              │─── HTTP (plain) ──────→
  │                              │ (internal, safe)      │
  │                        (Response)                     │
  │←─── HTTPS (TLS) ────────────│←─── HTTP ────────────┤
```

**Wichtig:** TLS только от client до Ingress. Внутри кластера HTTP (safe, virtual network).

---

## 💾 Persistent Data Architecture

### StorageClass vs PVC vs PV

```
┌────────────────────────────────────────┐
│  Kubernetes Cluster (Node-1, Node-2, 3)│
├────────────────────────────────────────┤
│                                        │
│  Pod                      PVC          │
│  ┌─────────┐         ┌──────────┐     │
│  │ Frontend│─mount──→│ frontend-│     │
│  │ (nginx) │         │  data    │     │
│  └─────────┘         │ 3GB SSD  │     │
│       ↓              └────┬─────┘     │
│    Node-1                 ↓           │
│                    ┌──────────────┐   │
│                    │ StorageClass │   │
│                    │yc-storage-ssd    │
│                    │(provisioner) │   │
│                    └──────┬───────┘   │
│                           ↓           │
│         ┌─────────────────────┐       │
│         │  CSI Driver         │       │
│         │ (Yandex Cloud)      │       │
│         └────────┬────────────┘       │
└──────────────────┼────────────────────┘
                   ↓
          ┌─────────────────┐
          │  Yandex Disk    │
          │  SSD Volume     │
          │  (Persistent!)  │
          └─────────────────┘
```

### PVC Creation Flow

```
1. Pod запускается
   ↓
2. Kubernetes видит PVC: backend-data
   ↓
3. volumeBindingMode: WaitForFirstConsumer
   (ждём первого consume'а)
   ↓
4. Pod монтирует PVC
   ↓
5. CSI Driver создаёт Yandex Disk (5GB)
   ↓
6. PVC становится Bound
   ↓
7. Pod может писать/читать данные
```

**Advantage:** Диск создаётся только когда нужен = экономим деньги!

---

## 🔀 Pod Anti-Affinity

### Как работает

```
┌──────────────┐
│   Node-1     │
│ (iviq)       │
├──────────────┤
│ Backend pod  │ kubernetes.io/hostname: iviq
└──────────────┘

┌──────────────┐
│   Node-2     │
│ (ixyx)       │
├──────────────┤
│ Backend pod  │ kubernetes.io/hostname: ixyx
└──────────────┘

┌──────────────┐
│   Node-3     │
│ (ulaz)       │
├──────────────┤
│ Backend pod  │ kubernetes.io/hostname: ulaz
└──────────────┘

Scheduler правило:
  Не ставь 2 pod'а с меткой app:backend на один hostname
```

### Без Anti-Affinity (плохо)

```
Node-1: Backend-1, Backend-2, Backend-3
Node-2: (пусто)
Node-3: (пусто)

Если Node-1 упадёт → все Backend pods вниз ❌
```

### С Anti-Affinity (хорошо)

```
Node-1: Backend-1
Node-2: Backend-2
Node-3: Backend-3

Если Node-1 упадёт → Backend-2,3 работают ✅
```

---

## 🎯 Service Types

### 1. LoadBalancer (для Ingress Controller)

```
External Internet
        ↓
   [203.0.113.45:80/443]
   LoadBalancer Service
   type: LoadBalancer
        ↓
   NGINX Controller Pods
```

**Получает внешний IP** от Yandex Cloud

### 2. ClusterIP (для Backend/Frontend)

```
Internal Cluster
   Ingress Controller
        ↓
   ClusterIP Service
   type: ClusterIP
   (10.96.X.X - internal only)
        ↓
   Backend/Frontend Pods
```

**Только внутренний** (virtual) IP, недоступен снаружи

---

## 📊 Мониторинг Architecture

```
┌─────────────────────────────────────┐
│    Kubernetes Cluster (monitoring)  │
├─────────────────────────────────────┤
│                                     │
│  Node Exporter                      │
│  (DaemonSet на каждой ноде)         │
│  ├─ Собирает CPU, Memory, Disk      │
│  └─ Exposes :9100/metrics           │
│      ↓                              │
│  Prometheus                         │
│  (StatefulSet, 1 pod)               │
│  ├─ Scrapes metrics every 15s       │
│  ├─ Stores in PVC (10GB, 30 days)   │
│  └─ Exposes :9090/api               │
│      ↓                              │
│  Grafana                            │
│  (Deployment, 1 pod)                │
│  ├─ Reads from Prometheus           │
│  ├─ Shows dashboards                │
│  └─ Port 3000 (via Ingress)         │
│      ↓                              │
│  AlertManager                       │
│  (StatefulSet, 1 pod)               │
│  └─ Sends alerts (Slack, Email)     │
│                                     │
└─────────────────────────────────────┘
       Access via HTTPS
       grafana.allower.ru
```

---

## 🔍 ELK Stack Architecture

```
┌──────────────────────────────────────────────────┐
│         Kubernetes Nodes (3 шт)                  │
├──────────────────────────────────────────────────┤
│                                                  │
│  Filebeat DaemonSet (на каждой ноде)             │
│  └─ Reads /var/log/containers/*.log              │
│     ├─ Parses JSON logs                          │
│     ├─ Adds K8s metadata (pod, namespace)        │
│     └─ Sends to Elasticsearch                    │
│          ↓                                       │
├──────────────────────────────────────────────────┤
│                                                  │
│  Elasticsearch (3 pods, StatefulSet)             │
│  ├─ Stores logs in indexes (logs-2025.10.31)     │
│  ├─ Replicas for HA                              │
│  ├─ PVC: 10GB SSD each                           │
│  └─ Full-text search capabilities                │
│      ↓                                           │
│  Kibana (1 pod, Deployment)                      │
│  ├─ Web UI for searching logs                    │
│  ├─ Create dashboards                           │
│  └─ Visualize metrics                            │
│                                                  │
│  Accessible via HTTPS: kibana.allower.ru        │
│                                                  │
└──────────────────────────────────────────────────┘
```

---

## 🚀 Deployment Flow

```
1. Разработчик пушит код в GitHub
           ↓
2. CI/CD pipeline (GitLab CI / GitHub Actions)
   ├─ Build Docker image
   ├─ Push to registry
   └─ Update k8s manifests (image tag)
           ↓
3. Git repo с k8s конфигами обновлены
           ↓
4. ArgoCD watches Git repo
   └─ Detects changes
           ↓
5. ArgoCD applies new manifests
   └─ kubectl apply -f ...
           ↓
6. Kubernetes создаёт новые pods
   ├─ Graceful shutdown старых
   ├─ Health checks новых
   └─ Трафик переходит на новые
           ↓
7. Prometheus и Grafana видят новые метрики
           ↓
8. Filebeat собирает логи из новых pods
```

---

## 🔄 High Availability (HA)

### Frontend HA

```
User запрашивает https://allower.ru

LoadBalancer распределяет:
├─ 33% на Frontend pod-1 (Node-1)
├─ 33% на Frontend pod-2 (Node-2)
└─ 33% на Frontend pod-3 (Node-3)

Если Node-1 упадёт:
├─ Pod-1 dies
├─ Но Pod-2 и Pod-3 живы
├─ LoadBalancer перенаправляет 100% трафика на них
└─ Сервис остаётся доступным ✅
```

### Backend HA

```
Аналогично Frontend:
├─ 3 replicas распределены по 3 нодам
├─ Service балансирует трафик
└─ Fault tolerance при потере одной ноды
```

### Data Persistence HA

```
PVC backend-data (5GB)
├─ Хранится в Yandex Disk (высокая доступность)
├─ Реплицируется автоматически
└─ Восстанавливается при потере ноды
```

---

## 📝 Что происходит при разных сценариях

### Сценарий 1: Pod crashit

```
Backend pod dies
     ↓
Kubernetes Deployment контроллер видит
     ↓
Создаёт новый pod
     ↓
New pod запускается
     ↓
Health checks проходят
     ↓
Service начинает отправлять трафик
     ↓
Сервис остаётся доступным ✅
```

### Сценарий 2: Node падает

```
Node-1 падает (hardware failure)
     ↓
Kubernetes видит Node offline
     ↓
Все pods на Node-1 переходят в Failed
     ↓
Deployment контроллер создаёт новые pods
     ↓
Anti-affinity → распределяет на Node-2, Node-3
     ↓
PVC переподключается к новому ноду
     ↓
Сервис восстановлен ✅
```

### Сценарий 3: Обновление приложения

```
Новая версия готова
     ↓
kubectl apply -f deployment.yaml (image: v2.0)
     ↓
Kubernetes создаёт новый pod (v2.0)
     ↓
Health checks pass
     ↓
Service постепенно переводит трафик
     ↓
Старые pods v1.0 gracefully shutdown
     ↓
Полный откат если что-то сломалось:
   kubectl rollout undo deployment/backend
```

---

## 🎓 Ключевые концепции

| Концепт | Назначение | Пример |
|---------|-----------|--------|
| **Namespace** | Изоляция ресурсов | `default`, `monitoring`, `elk` |
| **Deployment** | Управление pods | `backend`, `frontend` |
| **Pod** | Контейнер приложения | nginx, busybox |
| **Service** | Балансировка и DNS | backend:5000 |
| **Ingress** | Внешний доступ + TLS | allower.ru → frontend |
| **PVC** | Запрос хранилища | backend-data: 5GB |
| **PV** | Реальный диск | Yandex Disk |
| **ConfigMap** | Конфиги + код | index.html, nginx.conf |
| **Secret** | Чувствительные данные | TLS сертификаты |
| **DaemonSet** | Pod на каждой ноде | Filebeat, node-exporter |
| **StatefulSet** | Stateful приложения | Prometheus, Elasticsearch |

---

## ✅ Итого

Эта архитектура обеспечивает:
- **High Availability** - fault tolerance при потере нод
- **Scalability** - легко добавить replicas
- **Observability** - Prometheus + Grafana + ELK Stack
- **Security** - TLS/HTTPS, isolated namespaces
- **Data Persistence** - Yandex Disk + PVC
- **Cost Efficiency** - WaitForFirstConsumer для PVC

