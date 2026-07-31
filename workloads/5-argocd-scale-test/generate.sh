#!/bin/bash
set -euo pipefail

TOTAL=8
SIZE=50Gi
NAMESPACE=argocd-scale-dr
APPNAME=argocd-scale-dr
SC_WRITER=sc-argocd-scale-dr-writer
SC_READER=sc-argocd-scale-dr-reader
WRITER_COUNT=4

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$SCRIPT_DIR/generated"
rm -rf "$OUTDIR"

RESOURCE_LIST=()

for i in $(seq 1 "$TOTAL"); do
  if [ "$i" -le "$WRITER_COUNT" ]; then
    ROLE="writer"
    SC="$SC_WRITER"
  else
    ROLE="reader"
    SC="$SC_READER"
  fi

  PVC_DIR="$OUTDIR/pvcs/$ROLE"
  DEPLOY_DIR="$OUTDIR/deployments/$ROLE"
  mkdir -p "$PVC_DIR" "$DEPLOY_DIR"

  PVC_FILE="$PVC_DIR/pvc-argo-$i.yaml"
  cat > "$PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-argo-$i
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
  RESOURCE_LIST+=("generated/pvcs/$ROLE/pvc-argo-$i.yaml")

  DEPLOY_FILE="$DEPLOY_DIR/deploy-argo-$i-$ROLE.yaml"
  if [ "$ROLE" = "writer" ]; then
    cat > "$DEPLOY_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-argo-$i-writer
  labels:
    appname: $APPNAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app-key: argo-$i
  template:
    metadata:
      labels:
        app-key: argo-$i
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
              usage() { df /data | awk 'NR==2 {gsub("%","",\$5); print \$5}'; }
              emit() {
                  echo "\$(date) \$1" | tee -a /data/ramen.log
                  sync
              }
              trap "emit STOP; exit" TERM
              emit START
              i=0
              while true; do
                  u=\$(usage)
                  if [ "\$u" -ge 90 ]; then
                      emit "usage \${u}%, cleaning up to 50%"
                      while [ "\$u" -ge 50 ]; do
                          oldest=\$(ls -tr /data/chunk_*.bin 2>/dev/null | head -1)
                          [ -z "\$oldest" ] && break
                          rm -f "\$oldest"
                          u=\$(usage)
                      done
                      emit "usage now \${u}%"
                  fi
                  dd if=/dev/zero of=/data/chunk_\$i.bin bs=1M count=1024 status=none
                  sync
                  i=\$((i+1))
                  emit UPDATE
                  sleep 10 & wait
              done
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pvc-argo-$i
EOF
  else
    cat > "$DEPLOY_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-argo-$i-reader
  labels:
    appname: $APPNAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app-key: argo-$i
  template:
    metadata:
      labels:
        app-key: argo-$i
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
            claimName: pvc-argo-$i
EOF
  fi
  RESOURCE_LIST+=("generated/deployments/$ROLE/deploy-argo-$i-$ROLE.yaml")
done

KFILE="$SCRIPT_DIR/kustomization.yaml"
{
  echo "resources:"
  for f in "${RESOURCE_LIST[@]}"; do
    echo "  - $f"
  done
  echo "namespace: $NAMESPACE"
} > "$KFILE"

echo "Generated $TOTAL PVCs (${SIZE} each): $WRITER_COUNT writers on $SC_WRITER, $((TOTAL-WRITER_COUNT)) readers on $SC_READER"
echo "Structure: generated/pvcs/<role>/... and generated/deployments/<role>/..."