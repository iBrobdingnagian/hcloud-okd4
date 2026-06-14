#!/usr/bin/env bash
# functions/storage.sh — persistent-storage backends for components that need PVCs
# Sourced by deploy-okd.sh; not meant to be executed directly.
#
# platform "none" ships NO storageclass (no CSI driver), so anything needing a
# PVC (GitLab's gitaly/postgres/redis, jenkins-persistent) has nothing to bind.
# ensure_storage_backend() provisions a default storageclass via one of:
#   local  - Rancher local-path-provisioner: a dir on each node. Simplest, no
#            credentials, but data is pinned to one node (no replication).
#   smb    - Hetzner Storage Box over CIFS via csi-driver-smb: real off-cluster
#            storage that survives node loss, ReadWriteMany. Needs Storage Box
#            credentials (host/share/user/password).
# Object storage (S3 / Hetzner Object Storage) is NOT a generic PV — it can't
# back a database — so it's wired into GitLab's object store separately
# (install_gitlab), never as a storageclass.

ensure_storage_backend() {
  # idempotent: if a default storageclass already exists, use it
  if oc get storageclass -o json 2>/dev/null \
     | jq -e '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")' >/dev/null 2>&1; then
    echo "    a default storageclass already exists — reusing it"
    return 0
  fi

  local backend=${FLAG_STORAGE_BACKEND:-}
  if [ -z "$backend" ]; then
    if [ "$ASSUME_YES" = 1 ]; then
      backend=local
    else
      echo
      echo "No storageclass on this cluster. Choose a persistent-storage backend:"
      echo "  1) local  — node-local volumes (local-path-provisioner) [simplest, no creds]"
      echo "  2) smb    — Hetzner Storage Box over CIFS (off-node, RWX; needs box creds)"
      printf 'Selection [1]: '
      read -r SB; SB=${SB:-1}
      case "$SB" in 1) backend=local ;; 2) backend=smb ;; *) backend=local ;; esac
    fi
  fi
  STORAGE_BACKEND=$backend
  case "$backend" in
    local) _storage_local ;;
    smb)   _storage_smb ;;
    *) err "unknown storage backend: $backend (use 'local' or 'smb')" ;;
  esac
}

# ── local-path-provisioner (node-local dirs) ──────────────────────────────
_storage_local() {
  log "Installing local-path-provisioner (node-local volumes; lab-grade)"
  oc apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml >/dev/null \
    || { echo "    WARNING: could not apply local-path-provisioner manifest"; return 1; }
  # helper pods use hostPath -> permissive SCC on OpenShift
  oc adm policy add-scc-to-user privileged \
    -z local-path-provisioner-service-account -n local-path-storage >/dev/null 2>&1 || true
  # Two OpenShift gotchas with the upstream provisioner, both fixed by patching
  # the helper-pod template + setup script:
  #  1. the default helper pod doesn't REQUEST root, so OpenShift gives it a
  #     random uid and its `mkdir` in the root-owned hostPath fails
  #     ("Permission denied" -> PVCs stuck Pending). Run it root/privileged
  #     under the (already privileged) provisioner SA.
  #  2. SELinux is Enforcing: the new dir lands as type `var_t`, which a
  #     confined container (container_t) cannot write — workloads then crash
  #     with "permission denied" the moment they touch the volume. The setup
  #     script relabels it to `container_file_t`. busybox has no `chcon`, so the
  #     helper image is ubi-minimal (public, ships chcon).
  local helper='apiVersion: v1
kind: Pod
metadata:
  name: helper-pod
spec:
  priorityClassName: system-node-critical
  serviceAccountName: local-path-provisioner-service-account
  tolerations:
    - key: node.kubernetes.io/disk-pressure
      operator: Exists
      effect: NoSchedule
  containers:
  - name: helper-pod
    image: registry.access.redhat.com/ubi9/ubi-minimal
    imagePullPolicy: IfNotPresent
    securityContext:
      runAsUser: 0
      privileged: true'
  local setup='#!/bin/sh
set -eu
mkdir -m 0777 -p "$VOL_DIR"
chcon -R -t container_file_t "$VOL_DIR" 2>/dev/null || true'
  oc -n local-path-storage patch cm local-path-config --type merge \
    -p "$(jq -n --arg h "$helper" --arg s "$setup" '{data:{"helperPod.yaml":$h,"setup":$s}}')" >/dev/null 2>&1 || true
  oc -n local-path-storage rollout restart deploy/local-path-provisioner >/dev/null 2>&1 || true
  oc -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s \
    || echo "    WARNING: local-path-provisioner did not become ready"
  oc patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null 2>&1 || true
  echo "    default storageclass 'local-path' ready"
}

# ── Hetzner Storage Box over CIFS (csi-driver-smb) ────────────────────────
# UNTESTED in this lab (needs a real Storage Box). Credentials come from .env
# (SMB_HOST/SMB_SHARE/SMB_USER/SMB_PASS) or are prompted.
_storage_smb() {
  log "Setting up Hetzner Storage Box storage (csi-driver-smb)"
  : "${SMB_HOST:=}"; : "${SMB_SHARE:=}"; : "${SMB_USER:=}"; : "${SMB_PASS:=}"
  [ -n "$SMB_HOST" ]  || { printf '  Storage Box SMB host (e.g. u123456.your-storagebox.de): '; read -r SMB_HOST; }
  [ -n "$SMB_SHARE" ] || { printf '  Share / sub-folder (e.g. backups; blank = box root): ';       read -r SMB_SHARE; }
  [ -n "$SMB_USER" ]  || { printf '  Storage Box user (e.g. u123456): ';                            read -r SMB_USER; }
  [ -n "$SMB_PASS" ]  || { printf '  Storage Box password: ';                                       read -rs SMB_PASS; echo; }
  [ -n "$SMB_HOST" ] && [ -n "$SMB_USER" ] && [ -n "$SMB_PASS" ] \
    || { echo "    missing Storage Box credentials — aborting smb setup"; return 1; }

  local ver=v1.17.0
  echo "    installing csi-driver-smb $ver"
  # upstream remote installer applies the controller + node DaemonSet manifests
  if command -v curl >/dev/null; then
    curl -skSL "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/$ver/deploy/install-driver.sh" \
      | bash -s "$ver" -- >/dev/null 2>&1 \
      || { echo "    WARNING: csi-driver-smb install script failed"; return 1; }
  else
    echo "    curl is required to install csi-driver-smb"; return 1
  fi
  # the node plugin mounts CIFS and runs privileged -> SCC
  oc adm policy add-scc-to-user privileged -z csi-smb-node-sa -n kube-system >/dev/null 2>&1 || true
  oc -n kube-system rollout status daemonset/csi-smb-node --timeout=180s 2>/dev/null || true

  oc -n kube-system create secret generic smbcreds \
    --from-literal=username="$SMB_USER" --from-literal=password="$SMB_PASS" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc apply -f - >/dev/null <<SC
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: smb.csi.k8s.io
parameters:
  source: //${SMB_HOST}/${SMB_SHARE}
  csi.storage.k8s.io/provisioner-secret-name: smbcreds
  csi.storage.k8s.io/provisioner-secret-namespace: kube-system
  csi.storage.k8s.io/node-stage-secret-name: smbcreds
  csi.storage.k8s.io/node-stage-secret-namespace: kube-system
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - dir_mode=0777
  - file_mode=0777
  - uid=1000
  - gid=1000
  - noperm
  - mfsymlinks
  - cache=strict
  - vers=3.0
SC
  echo "    default storageclass 'smb' ready (Storage Box //${SMB_HOST}/${SMB_SHARE})"
}
