#!/bin/bash
# generate-manifest.sh - Generate production-ready Kubernetes manifests
# Usage: ./generate-manifest.sh <app-name> [options]

set -e

APP_NAME=${1:-""}
TYPE="deployment"
IMAGE=""
PORT="8080"
REPLICAS="2"
NAMESPACE="default"
OUTPUT_DIR=""

if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 <app-name> [options]" >&2
    echo "" >&2
    echo "Generates production-ready Kubernetes manifests with security best practices." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --type <deployment|statefulset>  Workload type (default: deployment)" >&2
    echo "  --image <image>                  Container image (default: registry.example.com/<app>:latest)" >&2
    echo "  --port <port>                    Container port (default: 8080)" >&2
    echo "  --replicas <N>                   Replica count (default: 2)" >&2
    echo "  --namespace <ns>                 Target namespace (default: default)" >&2
    echo "  --output-dir <dir>               Output directory (default: stdout)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payment-service --image registry.example.com/payment:3.2 --port 8080" >&2
    echo "  $0 worker-service --type statefulset --replicas 3 --output-dir ./manifests" >&2
    exit 1
fi

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --replicas) REPLICAS="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$IMAGE" ] && IMAGE="registry.example.com/${APP_NAME}:latest"

echo "=== MANIFEST GENERATION ===" >&2
echo "Application: $APP_NAME" >&2
echo "Type: $TYPE" >&2
echo "Image: $IMAGE" >&2
echo "Port: $PORT" >&2
echo "Replicas: $REPLICAS" >&2
echo "Namespace: $NAMESPACE" >&2
[ -n "$OUTPUT_DIR" ] && echo "Output: $OUTPUT_DIR" >&2
echo "" >&2

write_file() {
    local filename="$1"
    local content="$2"
    if [ -n "$OUTPUT_DIR" ]; then
        mkdir -p "$OUTPUT_DIR"
        echo "$content" > "${OUTPUT_DIR}/${filename}"
        echo "  ✅ Generated ${OUTPUT_DIR}/${filename}" >&2
    else
        echo "---"
        echo "# ${filename}"
        echo "$content"
    fi
}

# ServiceAccount
SA_YAML=$(cat << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: desk-agent
automountServiceAccountToken: false
EOF
)
write_file "serviceaccount.yaml" "$SA_YAML"

# Deployment or StatefulSet
if [ "$TYPE" == "deployment" ]; then
WORKLOAD_YAML=$(cat << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: desk-agent
spec:
  replicas: ${REPLICAS}
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
          image: ${IMAGE}
          ports:
            - containerPort: ${PORT}
              name: http
              protocol: TCP
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
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 12
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
)
else
WORKLOAD_YAML=$(cat << EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: desk-agent
spec:
  serviceName: ${APP_NAME}-headless
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  updateStrategy:
    type: RollingUpdate
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
      terminationGracePeriodSeconds: 60
      containers:
        - name: ${APP_NAME}
          image: ${IMAGE}
          ports:
            - containerPort: ${PORT}
              name: http
              protocol: TCP
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
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /data
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 100Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
EOF
)
fi
write_file "${TYPE}.yaml" "$WORKLOAD_YAML"

# Service
SVC_YAML=$(cat << EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: desk-agent
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
)
write_file "service.yaml" "$SVC_YAML"

# Add headless service for StatefulSet
if [ "$TYPE" == "statefulset" ]; then
HEADLESS_YAML=$(cat << EOF
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-headless
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  type: ClusterIP
  clusterIP: None
  ports:
    - port: ${PORT}
      targetPort: http
      name: http
  selector:
    app.kubernetes.io/name: ${APP_NAME}
EOF
)
write_file "service-headless.yaml" "$HEADLESS_YAML"
fi

# ConfigMap skeleton
CM_YAML=$(cat << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-config
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: desk-agent
data:
  APP_PORT: "${PORT}"
  LOG_LEVEL: "info"
  # Add your application-specific config here
EOF
)
write_file "configmap.yaml" "$CM_YAML"

# NetworkPolicy
NP_YAML=$(cat << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - ports:
        - protocol: TCP
          port: ${PORT}
  egress:
    # Allow DNS
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow HTTPS (for external APIs)
    - ports:
        - protocol: TCP
          port: 443
EOF
)
write_file "networkpolicy.yaml" "$NP_YAML"

# HPA
HPA_YAML=$(cat << EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
    app.kubernetes.io/managed-by: desk-agent
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: $([ "$TYPE" == "deployment" ] && echo "Deployment" || echo "StatefulSet")
    name: ${APP_NAME}
  minReplicas: ${REPLICAS}
  maxReplicas: $(( REPLICAS * 5 ))
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
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
EOF
)
write_file "hpa.yaml" "$HPA_YAML"

# PodDisruptionBudget
PDB_YAML=$(cat << EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${APP_NAME}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${APP_NAME}
EOF
)
write_file "pdb.yaml" "$PDB_YAML"

echo "" >&2
echo "========================================" >&2
echo "MANIFEST GENERATION COMPLETE" >&2
echo "  Application: $APP_NAME" >&2
echo "  Type: $TYPE" >&2
echo "  Files: 7 manifests generated" >&2
echo "========================================" >&2
echo "" >&2
echo "Apply with:" >&2
if [ -n "$OUTPUT_DIR" ]; then
    echo "  kubectl apply -f ${OUTPUT_DIR}/" >&2
else
    echo "  $0 $APP_NAME [options] --output-dir ./manifests && kubectl apply -f ./manifests/" >&2
fi
