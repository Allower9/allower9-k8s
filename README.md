# allower.ru Kubernetes Infrastructure

Полный стек Kubernetes на Yandex Cloud с NGINX Ingress, Prometheus, Grafana, ELK Stack и хранением данных через StorageClass.

## 📂 Структура проекта

```
allower-k8s/
├── k8s/
│   ├── 01-namespace.yaml          # Namespaces для проекта
│   ├── 02-storage-class.yaml      # StorageClass для PVC
│   ├── 03-configmaps.yaml         # ConfigMaps для frontend & backend
│   ├── 04-pvc.yaml                # PersistentVolumeClaim'ы
│   ├── 05-backend-deployment.yaml # Backend сервис
│   ├── 06-backend-service.yaml    # Service для backend
│   ├── 07-frontend-deployment.yaml# Frontend (nginx)
│   ├── 08-frontend-service.yaml   # Service для frontend
│   ├── 09-ingress.yaml            # Ingress правила с TLS
│   ├── 10-tls-secret.yaml         # TLS Secrets
│   └── apply-all.sh               # Скрипт применения всех манифестов
│
├── helm/
│   ├── prometheus-values.yaml     # Конфиг Prometheus Stack
│   ├── grafana-values.yaml        # Конфиг Grafana
│   ├── filebeat-values.yaml       # Конфиг Filebeat для ELK
│   └── install-monitoring.sh      # Установка Prometheus + Grafana
│
├── certs/
│   ├── allower-ru/
│   │   ├── cert.pem               # Основной сертификат + intermediate
│   │   └── key.pem                # Приватный ключ
│   └── grafana-allower-ru/
│       ├── cert.pem               # Сертификат для grafana
│       └── key.pem                # Приватный ключ
│
├── docs/
│   ├── ARCHITECTURE.md            # Описание архитектуры
│   ├── SETUP.md                   # Инструкция по запуску
│   ├── DECISIONS.md               # Решения проектирования
│   └── TROUBLESHOOTING.md         # Решение проблем
│
└── README.md                      # Главный файл проекта
```

---

## 🚀 Быстрый старт

### Предварительные условия
- Kubernetes кластер на Yandex Cloud (3 ноды)
- kubectl установлен и настроен
- helm 3.x установлен
- Доступ к доменам allower.ru и grafana.allower.ru

### Установка (5 минут)

```bash
# 1. Клонировать репозиторий
git clone https://github.com/YOUR_USERNAME/allower-k8s.git
cd allower-k8s

# 2. Подготовить сертификаты
mkdir -p certs/{allower-ru,grafana-allower-ru}
# Скопировать cert.pem и key.pem в соответствующие папки

# 3. Применить основной стек
cd k8s
chmod +x apply-all.sh
./apply-all.sh

# 4. Установить мониторинг
cd ../helm
chmod +x install-monitoring.sh
./install-monitoring.sh

# 5. Проверить статус
kubectl get pods -A
```

---

## 📊 Архитектура

```
┌─────────────────────────────────────┐
│         Internet (allower.ru)       │
└────────────────┬────────────────────┘
                 ↓
    ┌────────────────────────┐
    │  LoadBalancer Service  │ (external IP)
    │  (ingress-nginx)       │
    └────────────┬───────────┘
                 ↓
    ┌────────────────────────────────────┐
    │   NGINX Ingress Controller         │
    │   (TLS termination @ 443)          │
    └────┬──────────────────────┬────────┘
         │                      │
    HTTP:80, HTTPS:443  Routing по host/path
         │                      │
    ┌────▼─────────┐    ┌───────▼──────┐
    │ Frontend      │    │ Backend API  │
    │ (nginx)       │    │ (busybox)    │
    │ ✓ ClusterIP   │    │ ✓ ClusterIP  │
    │ ✓ 3 replicas  │    │ ✓ 3 replicas │
    │ ✓ Anti-affinity    │ ✓ Anti-affinity
    └────┬─────────┘    └───────┬──────┘
         │                      │
    ┌────▼──────────┐    ┌──────▼─────┐
    │ PVC frontend- │    │PVC backend- │
    │ data (3GB)    │    │ data (5GB)  │
    └───────────────┘    └─────────────┘
         (SSD)               (SSD)

Мониторинг (namespace: monitoring)
├─ Prometheus  → PVC 10GB
├─ Grafana     → PVC 5GB  (доступна по https://grafana.allower.ru)
└─ AlertManager→ PVC 2GB

Логирование (namespace: elk)
├─ Elasticsearch → PVC 10GB
├─ Kibana        (доступна в UI)
└─ Filebeat      (DaemonSet на каждой ноде)
```

---

## 🔑 Ключевые решения

### 1. Pod Anti-Affinity

**Почему используем?**
- Распределяем Pods по разным нодам для fault tolerance
- Если одна нода упадёт, сервис остаётся доступным

**Как работает?**
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app
          operator: In
          values:
          - backend
      topologyKey: kubernetes.io/hostname  # ← Каждая нода имеет уникальный hostname
```

- `requiredDuringScheduling` = строгое требование (pod не запустится без этого)
- `topologyKey: kubernetes.io/hostname` = распределяем по hostname нод
- **Результат:** 1 backend pod на Node-1, 1 на Node-2, 1 на Node-3

### 2. PersistentVolumeClaim (PVC)

**Почему используем?**
- Pod данные временные → нужно постоянное хранилище
- PVC запрашивает storage динамически через StorageClass

**Как работает?**
```
PVC (5GB запрос) → StorageClass (yc-network-ssd) → CSI Driver → Создаёт PV
                                                                       ↓
                                                            Yandex Disk (5GB)
```

- `storageClassName: yc-storage-ssd` = какой provider использовать
- `accessModes: ReadWriteOnce` = может быть подключен только одним pod'ом
- `volumeBindingMode: WaitForFirstConsumer` = ждём, пока pod не запросит, потом создаём на той же ноде

**Преимущество:** Динамическое создание вместо статического, автоматическое управление.

### 3. Service типов

**LoadBalancer (для Ingress Controller)**
```yaml
service:
  type: LoadBalancer  # ← Получает внешний IP от облака
  port: 80
```
- Получает внешний IP адрес от Yandex Cloud
- На него указывают DNS записи
- Маршрутизирует на pods контроллера

**ClusterIP (для Backend/Frontend)**
```yaml
service:
  type: ClusterIP  # ← Только внутренний IP
  port: 80
```
- Внутренний IP адрес в кластере
- Доступен только из других pods внутри кластера
- Более безопасно (нет прямого доступа снаружи)

### 4. Ingress с TLS

**Как работает?**
```
Client → HTTPS:443 → Ingress (читает TLS Secret) → Decryption → HTTP:80 к pods
```

- Ingress читает Secret с сертификатом
- Terminates TLS на уровне контроллера
- Трафик внутри кластера остаётся HTTP (или можно настроить SSL to backend)

---

## 📋 Структурирование YAML файлов

### Почему разбили на части?

Вместо одного большого файла создали несколько:

**Плюсы:**
- Лучше читаемость
- Легче редактировать отдельный компонент
- Видно зависимости между компонентами
- Проще версионировать в Git

**Порядок применения важен:**
1. Namespace (нужно место для ресурсов)
2. StorageClass (нужно определение перед PVC)
3. ConfigMaps (конфиг перед pods)
4. PVC (нужно перед Deployments)
5. Deployments (приложения)
6. Services (маршрутизация)
7. Ingress (внешний доступ)
8. TLS Secrets (сертификаты)

---

## 🔍 Компоненты в деталях

### Backend (`busybox` с простым HTTP сервером)

**Что делает:**
- Слушает port 5000
- Отвечает JSON с timestamp и hostname
- Хранит данные в `/data` (PVC)

**Почему busybox?**
- Очень лёгкий образ (~5 МБ)
- Есть nc (netcat) для простого HTTP сервера
- Подходит для демонстрации

**Production?** Используй реальное приложение (Node.js, Python, Go)

### Frontend (`nginx`)

**Что делает:**
- Сервит статический HTML
- Proxyирует `/api/*` запросы на Backend
- Обрабатывает routing внутри SPA

**Конфиг в ConfigMap:**
```nginx
location /api/ {
  proxy_pass http://backend:5000/;  # ← Используем DNS имя Service'а
}
```

### Prometheus + Grafana

**Prometheus:**
- Скребит метрики с контейнеров каждые 15 сек
- Хранит на PVC (30 дней retention)
- Предоставляет API для запросов

**Grafana:**
- Читает метрики из Prometheus
- Показывает dashboards
- Настраиваем alerts

### ELK Stack

**Filebeat (DaemonSet):**
- Работает на каждой ноде
- Читает логи из `/var/log/containers/`
- Отправляет в Elasticsearch

**Elasticsearch:**
- Хранит логи в индексах (logs-2025.10.31)
- Полнотекстовый поиск
- Replicas для HA

**Kibana:**
- UI для просмотра логов
- Создаём Index Patterns для поиска
- Visualizations & Dashboards

---

## 🛠️ Как работает развёртывание

### Шаг 1: DNS и Certificates

```bash
# DNS должен быть настроен перед деплоем
# allower.ru        A  203.0.113.45  (LoadBalancer IP)
# grafana.allower.ru A  203.0.113.45  (тот же IP)

# Сертификаты от Let's Encrypt в certs/
```

### Шаг 2: Применение k8s манифестов

```bash
./k8s/apply-all.sh
```

Происходит:
1. Создаётся namespace `default`
2. Создаётся StorageClass `yc-storage-ssd`
3. Создаются ConfigMaps с кодом frontend и скриптом backend
4. Создаются PVC (запрос хранилища)
5. Создаются Deployments (pods запускаются)
6. Создаются Services (маршрутизация)
7. Создаётся Ingress (внешний доступ)
8. Загружаются TLS Secrets

### Шаг 3: Мониторинг

```bash
./helm/install-monitoring.sh
```

1. Добавляются Helm репозитории
2. Создаётся namespace `monitoring`
3. Устанавливается Prometheus Stack (с node-exporter)
4. Устанавливается Grafana отдельно
5. Создаются Ingress для доступа

### Шаг 4: Проверка

```bash
# Все pods запущены?
kubectl get pods -A

# Ingress создан?
kubectl get ingress -A

# Доступ через браузер?
# https://allower.ru
# https://grafana.allower.ru
```

---

## 🔒 Безопасность

### TLS/HTTPS
- Используем Let's Encrypt сертификаты
- TLS terminates на Ingress controller
- Все трафик снаружи зашифрован

### Network Policies (не настроены в этом проекте, но рекомендуется)
- Ограничить трафик между pods
- Разрешить только необходимые соединения

### Pod Security
- Используем image'ы проверенные (nginx, busybox)
- Не используем root (или минимизируем)
- Resource limits (cpu, memory) предотвращают DoS

---

## 📈 Масштабирование

### Горизонтальное масштабирование (больше pods)

```yaml
spec:
  replicas: 5  # ← Увеличиваем количество
```

Kubernetes будет создавать pods на доступных нодах (anti-affinity работает).

### Вертикальное масштабирование (более мощные ноды)

Yandex Cloud позволяет увеличить размер нод или добавить новые.

---

## 🚨 Troubleshooting

### Pod не запускается (CrashLoopBackOff)
```bash
kubectl logs <pod-name> -n default  # Смотреть логи
kubectl describe pod <pod-name> -n default  # Детали
```

### PVC stuck in Pending
```bash
kubectl get pvc  # Проверить статус
kubectl describe pvc <pvc-name>  # Смотреть события
```

### Ingress не работает
```bash
kubectl get ingress  # Проверить ADDRESS
kubectl describe ingress web-ingress  # Детали правил
curl -v http://allower.ru  # Тестировать
```

---

## 📚 Дальнейшее развитие

### Фазы внедрения

**Phase 1: Базовый стек (✅ ГОТОВО)**
- Frontend & Backend
- TLS/HTTPS
- StorageClass & PVC
- Anti-affinity

**Phase 2: Мониторинг (✅ ГОТОВО)**
- Prometheus (метрики)
- Grafana (dashboards)
- AlertManager (alerts)

**Phase 3: Логирование (✅ ГОТОВО)**
- ELK Stack
- Filebeat (сборка логов)
- Kibana (UI)

**Phase 4: CI/CD (Рекомендуется)**
- GitLab CI / GitHub Actions
- Auto-build образов
- Auto-deploy через ArgoCD

**Phase 5: Advanced (Опционально)**
- Operators для stateful apps
- Service Mesh (Istio)
- Backup & Disaster Recovery

---

## 📞 Контакты и ссылки

- Kubernetes Docs: https://kubernetes.io/docs/
- Yandex Cloud K8s: https://cloud.yandex.com/docs/managed-kubernetes/
- Prometheus: https://prometheus.io/docs/
- Grafana: https://grafana.com/docs/

---

## 📝 Версия и история

- **v1.0.0** (2025-10-31): Базовый стек с мониторингом и логированием
  - ✅ Frontend & Backend на 3 нодах
  - ✅ TLS с Let's Encrypt
  - ✅ StorageClass & PVC
  - ✅ Prometheus + Grafana
  - ✅ ELK Stack

