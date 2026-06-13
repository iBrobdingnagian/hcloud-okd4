#!/usr/bin/env bash
# functions/admin.sh — htpasswd admin user creation
# Sourced by deploy-okd.sh; not meant to be executed directly.

ADMIN_CREATED=""
create_admin() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  [ -f "$KUBECONFIG" ] || { echo "    no kubeconfig at $KUBECONFIG — cannot create the admin user"; return 1; }
  if ! command -v htpasswd >/dev/null && ! command -v openssl >/dev/null; then
    echo "    neither htpasswd nor openssl found — manual steps are in the summary"
    return 1
  fi
  local user pass pass2 attempt=0 t lkc hash htpw="$PWD/users.htpasswd"
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

  # Persist a real htpasswd file in the repo root (users.htpasswd, gitignored).
  # Seed it from the live secret first so re-running for a second admin does
  # not wipe existing users, then add/update this one, then apply.
  if [ ! -f "$htpw" ] && oc -n openshift-config get secret htpass-secret >/dev/null 2>&1; then
    oc -n openshift-config get secret htpass-secret \
      -o jsonpath='{.data.htpasswd}' 2>/dev/null | base64 -d > "$htpw" 2>/dev/null || true
  fi
  if command -v htpasswd >/dev/null; then
    if [ -s "$htpw" ]; then
      htpasswd -B -b "$htpw" "$user" "$pass" >/dev/null 2>&1   # add/update, keep others
    else
      htpasswd -c -B -b "$htpw" "$user" "$pass" >/dev/null 2>&1 # create fresh
    fi
  else
    # no htpasswd binary: apr1 via openssl is a valid htpasswd entry that the
    # OpenShift htpasswd identity provider accepts
    hash=$(openssl passwd -apr1 "$pass")
    if [ -f "$htpw" ] && grep -q "^$user:" "$htpw"; then
      sedi "s|^$user:.*|$user:$hash|" "$htpw"
    else
      printf '%s:%s\n' "$user" "$hash" >> "$htpw"
    fi
  fi
  chmod 600 "$htpw"
  echo "    wrote/updated '$user' in $htpw ($(grep -c : "$htpw") user(s) total)"

  oc create secret generic htpass-secret \
    --from-file=htpasswd="$htpw" -n openshift-config \
    --dry-run=client -o yaml | oc apply -f -
  # patch (not apply) the singleton OAuth — avoids the "missing
  # last-applied-configuration" warning on the installer-created resource
  oc patch oauth cluster --type=merge -p '{"spec":{"identityProviders":[{"name":"htpasswd_provider","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpass-secret"}}}]}}'
  oc adm policy add-cluster-role-to-user cluster-admin "$user"
  echo "    waiting for the OAuth server to reload the new config (rollout ~1-3 min)"
  t=0; lkc=$(mktemp)
  until KUBECONFIG=$lkc oc login --server="https://api.$DOMAIN:6443" \
        --insecure-skip-tls-verify=true -u "$user" -p "$pass" >/dev/null 2>&1; do
    t=$((t+1))
    [ $t -le 30 ] || { rm -f "$lkc"; echo; echo "    login still failing after 10 min — check: oc get co authentication"; return 1; }
    printf '\r    still waiting for oauth rollout (%d/30, ~%ds elapsed) ' "$t" $((t*20))
    sleep 20
  done
  echo
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
