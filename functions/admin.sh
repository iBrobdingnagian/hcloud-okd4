#!/usr/bin/env bash
# functions/admin.sh — htpasswd admin user creation
# Sourced by deploy-okd.sh; not meant to be executed directly.

ADMIN_CREATED=""
create_admin() {
  command -v htpasswd >/dev/null \
    || { echo "    htpasswd binary not found — manual steps are in the summary"; return 1; }
  local user pass pass2 attempt=0 tmp t lkc
  printf 'Admin username [admin]: '
  read -r user; user=${user:-admin}
  while :; do
    attempt=$((attempt+1))
    printf 'Password for %s: ' "$user"; read -rs pass; echo
    printf 'Repeat password : '; read -rs pass2; echo
    [ -n "$pass" ] && [ "$pass" = "$pass2" ] && break
    [ $attempt -ge 3 ] && { echo "    giving up — manual steps are in the summary"; return 1; }
    echo "    empty or mismatched — try again"
  done
  tmp=$(mktemp -d)   # mktemp -d is 0700
  htpasswd -c -B -b "$tmp/users.htpasswd" "$user" "$pass" >/dev/null 2>&1
  oc create secret generic htpass-secret \
    --from-file=htpasswd="$tmp/users.htpasswd" -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  rm -rf "$tmp"
  oc apply -f - <<'OAUTH'
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
OAUTH
  oc adm policy add-cluster-role-to-user cluster-admin "$user"
  echo "    waiting for the OAuth server to accept the new login (2-5 min typical)"
  t=0; lkc=$(mktemp)
  until KUBECONFIG=$lkc oc login --server="https://api.$DOMAIN:6443" \
        --insecure-skip-tls-verify=true -u "$user" -p "$pass" >/dev/null 2>&1; do
    t=$((t+1))
    [ $t -le 30 ] || { rm -f "$lkc"; echo "    login still failing after 10 min — check: oc get co authentication"; return 1; }
    sleep 20
  done
  rm -f "$lkc"
  echo "    verified: $user can log in"
  ADMIN_CREATED=$user
  printf 'Delete kubeadmin (recommended once the new admin works)? [y/N]: '
  read -r DELKA
  if [ "$DELKA" = "y" ] || [ "$DELKA" = "Y" ]; then
    oc delete secret kubeadmin -n kube-system && echo "    kubeadmin removed"
  fi
  return 0
}
