#!/bin/bash
# template-app.sh - Application scaffolding from templates
# Usage: ./template-app.sh <app-name> [options]

set -e

APP_NAME=${1:-""}
APP_TYPE="web-api"
PORT="8080"
DATABASE="none"
OUTPUT_DIR=""
NAMESPACE="default"

if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 <app-name> [options]" >&2
    echo "" >&2
    echo "Scaffolds a complete application with Kubernetes manifests," >&2
    echo "Kustomize overlays, Dockerfile, and documentation." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --type <web-api|worker|cronjob>  Application type (default: web-api)" >&2
    echo "  --port <port>                     Container port (default: 8080)" >&2
    echo "  --database <postgres|mysql|none>  Database dependency (default: none)" >&2
    echo "  --namespace <ns>                  Base namespace (default: default)" >&2
    echo "  --output-dir <dir>                Output directory (default: ./<app-name>)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payment-service --type web-api --port 8080 --database postgres" >&2
    echo "  $0 email-worker --type worker --database none" >&2
    echo "  $0 report-generator --type cronjob" >&2
    exit 1
fi

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --type) APP_TYPE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --database) DATABASE="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$OUTPUT_DIR" ] && OUTPUT_DIR="./${APP_NAME}"

echo "=== APPLICATION SCAFFOLDING ===" >&2
echo "Application: $APP_NAME" >&2
echo "Type: $APP_TYPE" >&2
echo "Port: $PORT" >&2
echo "Database: $DATABASE" >&2
echo "Output: $OUTPUT_DIR" >&2
echo "" >&2

# Create directory structure
mkdir -p "${OUTPUT_DIR}/k8s/base"
mkdir -p "${OUTPUT_DIR}/k8s/overlays/dev"
mkdir -p "${OUTPUT_DIR}/k8s/overlays/staging"
mkdir -p "${OUTPUT_DIR}/k8s/overlays/production"
echo "  ✅ Directory structure created" >&2

# ========================================
# Kustomization base
# ========================================
RESOURCES="- serviceaccount.yaml
- configmap.yaml
- networkpolicy.yaml"

case "$APP_TYPE" in
    web-api)
        RESOURCES="${RESOURCES}
- deployment.yaml
- service.yaml
- hpa.yaml"
        ;;
    worker)
        RESOURCES="${RESOURCES}
- deployment.yaml
- hpa.yaml"
        ;;
    cronjob)
        RESOURCES="${RESOURCES}
- cronjob.yaml"
        ;;
esac

cat << EOF > "${OUTPUT_DIR}/k8s/base/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

metadata:
  name: ${APP_NAME}

commonLabels:
  app.kubernetes.io/name: ${APP_NAME}
  app.kubernetes.io/managed-by: kustomize

resources:
${RESOURCES}
EOF
echo "  ✅ k8s/base/kustomization.yaml" >&2

# ServiceAccount
cat << EOF > "${OUTPUT_DIR}/k8s/base/serviceaccount.yaml"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_NAME}
automountServiceAccountToken: false
EOF
echo "  ✅ k8s/base/serviceaccount.yaml" >&2

# ConfigMap
DB_CONFIG=""
[ "$DATABASE" != "none" ] && DB_CONFIG="
  DB_HOST: \"${APP_NAME}-db\"
  DB_PORT: \"$([ "$DATABASE" == "postgres" ] && echo "5432" || echo "3306")\"
  DB_NAME: \"${APP_NAME//-/_}\""

cat << EOF > "${OUTPUT_DIR}/k8s/base/configmap.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-config
data:
  APP_NAME: "${APP_NAME}"
  APP_PORT: "${PORT}"
  LOG_LEVEL: "info"
  LOG_FORMAT: "json"${DB_CONFIG}
EOF
echo "  ✅ k8s/base/configmap.yaml" >&2

# NetworkPolicy
INGRESS_RULE=""
[ "$APP_TYPE" == "web-api" ] && INGRESS_RULE="
  ingress:
    - ports:
        - protocol: TCP
          port: ${PORT}"

cat << EOF > "${OUTPUT_DIR}/k8s/base/networkpolicy.yaml"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${APP_NAME}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  policyTypes:
    - Ingress
    - Egress${INGRESS_RULE}
  egress:
    # Allow DNS
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow HTTPS
    - ports:
        - protocol: TCP
          port: 443
$([ "$DATABASE" == "postgres" ] && echo "    # Allow PostgreSQL
    - ports:
        - protocol: TCP
          port: 5432")
$([ "$DATABASE" == "mysql" ] && echo "    # Allow MySQL
    - ports:
        - protocol: TCP
          port: 3306")
EOF
echo "  ✅ k8s/base/networkpolicy.yaml" >&2

# Workload manifest
case "$APP_TYPE" in
    web-api|worker)
        PORTS_SECTION=""
        PROBE_SECTION=""
        if [ "$APP_TYPE" == "web-api" ]; then
            PORTS_SECTION="
          ports:
            - containerPort: ${PORT}
              name: http
              protocol: TCP"
            PROBE_SECTION="
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 12"
        fi

        cat << EOF > "${OUTPUT_DIR}/k8s/base/deployment.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${APP_NAME}
    spec:
      serviceAccountName: ${APP_NAME}
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      terminationGracePeriodSeconds: 30
      containers:
        - name: ${APP_NAME}
          image: registry.example.com/${APP_NAME}:latest${PORTS_SECTION}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi${PROBE_SECTION}
          envFrom:
            - configMapRef:
                name: ${APP_NAME}-config
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 100Mi
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: ${APP_NAME}
EOF
        echo "  ✅ k8s/base/deployment.yaml" >&2
        ;;

    cronjob)
        cat << EOF > "${OUTPUT_DIR}/k8s/base/cronjob.yaml"
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${APP_NAME}
spec:
  schedule: "0 * * * *"  # Every hour
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 3
      activeDeadlineSeconds: 3600
      template:
        spec:
          serviceAccountName: ${APP_NAME}
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            seccompProfile:
              type: RuntimeDefault
          restartPolicy: OnFailure
          containers:
            - name: ${APP_NAME}
              image: registry.example.com/${APP_NAME}:latest
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
              envFrom:
                - configMapRef:
                    name: ${APP_NAME}-config
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: tmp
              emptyDir:
                sizeLimit: 100Mi
EOF
        echo "  ✅ k8s/base/cronjob.yaml" >&2
        ;;
esac

# Service (web-api only)
if [ "$APP_TYPE" == "web-api" ]; then
cat << EOF > "${OUTPUT_DIR}/k8s/base/service.yaml"
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
spec:
  type: ClusterIP
  ports:
    - port: ${PORT}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: ${APP_NAME}
EOF
echo "  ✅ k8s/base/service.yaml" >&2
fi

# HPA (deployment types only)
if [ "$APP_TYPE" != "cronjob" ]; then
cat << EOF > "${OUTPUT_DIR}/k8s/base/hpa.yaml"
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${APP_NAME}
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 60
EOF
echo "  ✅ k8s/base/hpa.yaml" >&2
fi

# ========================================
# Kustomize overlays
# ========================================
for ENV in dev staging production; do
    REPLICAS="1"
    CPU_REQ="50m"
    MEM_REQ="64Mi"
    CPU_LIM="200m"
    MEM_LIM="256Mi"

    case "$ENV" in
        dev)      REPLICAS="1"; CPU_LIM="200m"; MEM_LIM="256Mi" ;;
        staging)  REPLICAS="2"; CPU_LIM="500m"; MEM_LIM="512Mi" ;;
        production) REPLICAS="3"; CPU_LIM="1000m"; MEM_LIM="1Gi" ;;
    esac

    cat << EOF > "${OUTPUT_DIR}/k8s/overlays/${ENV}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${APP_NAME}-${ENV}

resources:
  - ../../base

commonLabels:
  environment: ${ENV}

patches:
  - target:
      kind: Deployment
      name: ${APP_NAME}
    patch: |-
      - op: replace
        path: /spec/replicas
        value: ${REPLICAS}
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/cpu
        value: ${CPU_REQ}
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/memory
        value: ${MEM_REQ}
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/cpu
        value: ${CPU_LIM}
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: ${MEM_LIM}

configMapGenerator:
  - name: ${APP_NAME}-config
    behavior: merge
    literals:
      - LOG_LEVEL=$([ "$ENV" == "production" ] && echo "warn" || echo "debug")
      - ENVIRONMENT=${ENV}

images:
  - name: registry.example.com/${APP_NAME}
    newTag: latest  # Override in CI/CD
EOF
    echo "  ✅ k8s/overlays/${ENV}/kustomization.yaml" >&2
done

# ========================================
# Dockerfile
# ========================================
cat << 'DOCKERFILE' > "${OUTPUT_DIR}/Dockerfile"
# Build stage
FROM golang:1.22-alpine AS builder
# Replace with your build toolchain (node:20-alpine, python:3.12-slim, etc.)

WORKDIR /app

# Copy dependency manifests
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o main .

# Runtime stage
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /app

COPY --from=builder /app/main .

USER nonroot:nonroot

EXPOSE 8080

ENTRYPOINT ["/app/main"]
DOCKERFILE
echo "  ✅ Dockerfile" >&2

# .dockerignore
cat << 'DOCKERIGNORE' > "${OUTPUT_DIR}/.dockerignore"
.git
.gitignore
.github
README.md
LICENSE
k8s/
docs/
*.md
.env
.env.*
Makefile
DOCKERIGNORE
echo "  ✅ .dockerignore" >&2

# ========================================
# README.md
# ========================================
cat << README > "${OUTPUT_DIR}/README.md"
# ${APP_NAME}

> Type: ${APP_TYPE} | Port: ${PORT} | Database: ${DATABASE}

## Quick Start

### Local Development

\`\`\`bash
# Build
docker build -t ${APP_NAME}:dev .

# Run
docker run -p ${PORT}:${PORT} ${APP_NAME}:dev
\`\`\`

### Deploy to Kubernetes

\`\`\`bash
# Dev environment
kubectl apply -k k8s/overlays/dev

# Staging
kubectl apply -k k8s/overlays/staging

# Production (use ArgoCD)
# argocd app sync ${APP_NAME}-prod
\`\`\`

## Directory Structure

\`\`\`
k8s/
├── base/                    # Base manifests
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── serviceaccount.yaml
│   ├── configmap.yaml
│   ├── networkpolicy.yaml
│   └── hpa.yaml
└── overlays/                # Environment overrides
    ├── dev/
    ├── staging/
    └── production/
\`\`\`

## Configuration

Environment-specific settings are managed via Kustomize overlays.
Secrets should be managed through Vault / External Secrets Operator.

## Monitoring

- Health: \`GET /healthz\`
- Ready: \`GET /readyz\`
- Metrics: \`GET /metrics\` (Prometheus format)

---

*Scaffolded by Desk Agent — Developer Experience Specialist*
README
echo "  ✅ README.md" >&2

# Summary
FILE_COUNT=$(find "${OUTPUT_DIR}" -type f | wc -l | tr -d ' ')
echo "" >&2
echo "========================================" >&2
echo "APPLICATION SCAFFOLDING COMPLETE" >&2
echo "  Application: $APP_NAME" >&2
echo "  Type: $APP_TYPE" >&2
echo "  Files: $FILE_COUNT files generated" >&2
echo "  Directory: $OUTPUT_DIR" >&2
echo "========================================" >&2
echo "" >&2
echo "Next steps:" >&2
echo "  1. Replace the Dockerfile with your actual build" >&2
echo "  2. Update image name in kustomize overlays" >&2
echo "  3. Set up ArgoCD Application pointing to k8s/overlays/<env>" >&2
echo "  4. Add secrets via Vault / external-secrets-operator" >&2

# Output JSON
cat << EOF
{
  "operation": "template-app",
  "app_name": "$APP_NAME",
  "app_type": "$APP_TYPE",
  "port": "$PORT",
  "database": "$DATABASE",
  "output_dir": "$OUTPUT_DIR",
  "files_generated": $FILE_COUNT,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
