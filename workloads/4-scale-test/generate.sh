#!/bin/bash
set -euo pipefail

TOTAL=75
NUM_SC=5
PER_SC=$((TOTAL / NUM_SC))
SIZE=40Gi
NAMESPACE=scale-pvc-dr
APPNAME=scale-pvc-dr
WRITER_SC_COUNT=2

SCS=(sc-scale-dr-1 sc-scale-dr-2 sc-scale-dr-3 sc-scale-dr-4 sc-scale-dr-5)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$SCRIPT_DIR/generated"
rm -rf "$OUTDIR"

RESOURCE_LIST=()

GLOBAL_IDX=1
for sc_idx in $(seq 0 $((NUM_SC - 1))); do
  SC="${SCS[$sc_idx]}"
  if [ "$sc_idx" -lt "$WRITER_SC_COUNT" ]; then
    ROLE="writer"
  else
    ROLE="reader"
  fi

  PVC_DIR="$OUTDIR/pvcs/$SC"
  DEPLOY_DIR="$OUTDIR/deployments/$ROLE/$SC"
  mkdir -p "$PVC_DIR" "$DEPLOY_DIR"

  for _ in $(seq 1 "$PER_SC"); do
    i=$GLOBAL_IDX

    PVC_FILE="$PVC_DIR/pvc-scale-$i.yaml"
    cat > "$PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-scale-$i
  labels:
    appname: $APPNAME
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $SC
  resources:
    requests:
      storage: $SIZE
EOF
    RESOURCE_LIST+=("generated/pvcs/$SC/pvc-scale-$i.yaml")

    DEPLOY_FILE="$DEPLOY_DIR/deploy-scale-$i-$ROLE.yaml"
    if [ "$ROLE" = "writer" ]; then
      cat > "$DEPLOY_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-scale-$i-writer
  labels:
    appname: $APPNAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app-key: scale-$i
  template:
    metadata:
      labels:
        app-key: scale-$i
        appname: $APPNAME
        scale-test: spread
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              scale-test: spread
      containers:
        - name: logger
          image: quay.io/nirsof/busybox:stable
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              emit() {
                  echo "\$(date) \$1" | tee -a /data/ramen.log
                  sync
              }
              trap "emit STOP; exit" TERM
              emit START
              while true; do
                  sleep 10 & wait
                  emit UPDATE
              done
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pvc-scale-$i
EOF
    else
      cat > "$DEPLOY_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-scale-$i-reader
  labels:
    appname: $APPNAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app-key: scale-$i
  template:
    metadata:
      labels:
        app-key: scale-$i
        appname: $APPNAME
        scale-test: spread
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              scale-test: spread
      containers:
        - name: busybox
          image: quay.io/nirsof/busybox:stable
          command: ["tail", "-f", "/dev/null"]
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pvc-scale-$i
EOF
    fi
    RESOURCE_LIST+=("generated/deployments/$ROLE/$SC/deploy-scale-$i-$ROLE.yaml")

    GLOBAL_IDX=$((GLOBAL_IDX + 1))
  done
done

KFILE="$SCRIPT_DIR/kustomization.yaml"
{
  echo "resources:"
  for f in "${RESOURCE_LIST[@]}"; do
    echo "  - $f"
  done
  echo "namespace: $NAMESPACE"
} > "$KFILE"

echo "Generated $TOTAL PVCs across $NUM_SC storage classes."
echo "  Writer SCs (1-$WRITER_SC_COUNT): ${SCS[@]:0:$WRITER_SC_COUNT} — $((WRITER_SC_COUNT * PER_SC)) PVCs"
echo "  Reader SCs ($((WRITER_SC_COUNT+1))-$NUM_SC): ${SCS[@]:$WRITER_SC_COUNT} — $(((NUM_SC - WRITER_SC_COUNT) * PER_SC)) PVCs"
echo "Structure: generated/pvcs/<sc>/... and generated/deployments/<role>/<sc>/..."
echo "kustomization.yaml written to $KFILE"