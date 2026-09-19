#!/usr/bin/env bash
# functions/letsencrypt.sh — publicly-trusted certificates for the cluster via
# cert-manager + Let's Encrypt (ACME DNS-01 through Cloudflare).
#   *.apps.<domain>  -> default IngressController certificate (console, OAuth, all routes)
#   api.<domain>     -> kube-apiserver named certificate (oc login / kubectl)
# The certificates belong to hostnames, not nodes, and the load balancer passes
# TCP through, so scaling workers/masters up or down does not affect them.
# The internal certs (api-int, kubelets, etcd) stay on the cluster CA — untouched.
# Sourced by deploy-okd.sh; not meant to be executed directly.

LE_STAGING_URL=https://acme-staging-v02.api.letsencrypt.org/directory
LE_PROD_URL=https://acme-v02.api.letsencrypt.org/directory
LE_BACKUP_DIR=letsencrypt-backup   # gitignored; holds private keys

_le_wait() {  # _le_wait <namespace> <certificate> — DNS-01 usually takes 1-3 min
  oc -n "$1" wait --for=condition=Ready "certificate/$2" --timeout=600s >/dev/null 2>&1
}

# add the ACME intermediates (everything after the leaf in tls.crt) to the CA
# bundle of the local kubeconfig: a kubeconfig pins ONLY its own CA, so once the
# API serves a Let's Encrypt cert, oc would otherwise fail with "unknown authority"
_le_extend_kubeconfig() {
  local kc=$KUBECONFIG chain
  [ -f "$kc.orig" ] || cp "$kc" "$kc.orig"
  chain=$(oc -n openshift-config get secret api-cert-tls -o jsonpath='{.data.tls\.crt}' | base64 -d)
  LE_CHAIN="$chain" python3 - "$kc" <<'PY'
import sys, os, re, base64, yaml
kc = sys.argv[1]
pems = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", os.environ["LE_CHAIN"], re.S)
extra = "\n".join(pems[1:]).encode()          # drop the leaf, keep the issuing chain
if not extra:
    sys.exit(0)
d = yaml.safe_load(open(kc))
for c in d["clusters"]:
    cur = base64.b64decode(c["cluster"].get("certificate-authority-data", ""))
    if extra not in cur:
        c["cluster"]["certificate-authority-data"] = base64.b64encode(cur.rstrip() + b"\n" + extra + b"\n").decode()
yaml.safe_dump(d, open(kc, "w"), default_flow_style=False)
PY
}

# save the issued certificate secrets so a redeploy of the SAME hostnames reuses
# them until they expire (Let's Encrypt allows only ~5 duplicate certs per week)
le_save_certs() {  # le_save_certs <staging|prod>
  local dir="$LE_BACKUP_DIR/$DOMAIN/$1" pair ns sec
  mkdir -p "$dir" && chmod 700 "$LE_BACKUP_DIR" "$LE_BACKUP_DIR/$DOMAIN" "$dir"
  for pair in openshift-ingress:apps-wildcard-tls openshift-config:api-cert-tls; do
    ns=${pair%%:*}; sec=${pair##*:}
    oc -n "$ns" get secret "$sec" -o json 2>/dev/null \
      | jq 'del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.managedFields,.metadata.namespace)
            | .metadata.namespace="'"$ns"'"' > "$dir/$sec.json.tmp" \
      && [ -s "$dir/$sec.json.tmp" ] && mv "$dir/$sec.json.tmp" "$dir/$sec.json" && chmod 600 "$dir/$sec.json"
    rm -f "$dir/$sec.json.tmp"
  done
}

# restore saved secrets that are still valid (>7 days left); returns 0 if any restored
le_restore_certs() {  # le_restore_certs <staging|prod>
  local dir="$LE_BACKUP_DIR/$DOMAIN/$1" f end left restored=1
  ls "$dir"/*.json >/dev/null 2>&1 || return 1
  for f in "$dir"/*.json; do
    end=$(jq -r '.data["tls.crt"]' "$f" | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$end" ] || continue
    left=$(( ( $(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if [ "$left" -gt 7 ]; then
      oc apply -f "$f" >/dev/null 2>&1 && { echo "    reusing saved $(basename "$f" .json) ($left days left)"; restored=0; }
    else
      echo "    saved $(basename "$f" .json) has ${left}d left — a fresh one will be issued"
    fi
  done
  return $restored
}

install_letsencrypt() {
  export KUBECONFIG=$PWD/ignition/auth/kubeconfig
  local env=staging url=$LE_STAGING_URL
  if [ "${FLAG_LE_PROD:-0}" = 1 ]; then env=prod url=$LE_PROD_URL; fi
  local issuer="letsencrypt-$env"
  local email=${FLAG_LE_EMAIL:-${CLOUDFLARE_EMAIL:-}}
  local cf_token=${TF_VAR_cloudflare_api_token:-${CLOUDFLARE_API_TOKEN:-}}

  command -v jq >/dev/null 2>&1 || { err "jq is required for --letsencrypt"; return 1; }
  [ -n "$email" ]    || { err "no ACME email: pass --le-email or set CLOUDFLARE_EMAIL in .env"; return 1; }
  [ -n "$cf_token" ] || { err "no Cloudflare API token (TF_VAR_cloudflare_api_token / CLOUDFLARE_API_TOKEN in .env)"; return 1; }
  oc whoami >/dev/null 2>&1 || { echo "    cannot reach the cluster — is it running?"; return 1; }

  log "Let's Encrypt ($env) for *.apps.$DOMAIN and api.$DOMAIN"
  [ "$env" = staging ] && echo "    NOTE: staging certificates are NOT trusted by browsers — use --letsencrypt-prod for real ones"

  # cert-manager is a prerequisite (install it if the ClusterIssuer CRD is missing)
  if ! oc get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
    install_certmanager || { err "cert-manager install failed"; return 1; }
  fi
  local cm_ns
  cm_ns=$(oc get deploy -A -o jsonpath='{range .items[?(@.metadata.name=="cert-manager")]}{.metadata.namespace}{end}' 2>/dev/null)
  [ -n "$cm_ns" ] || { err "cannot find the cert-manager controller deployment"; return 1; }

  # reuse still-valid certificates saved from an earlier cluster with the same hostnames
  le_restore_certs "$env" || true

  oc -n "$cm_ns" create secret generic cloudflare-api-token \
    --from-literal=api-token="$cf_token" --dry-run=client -o yaml | oc apply -f - >/dev/null

  oc apply -f - >/dev/null <<ISSUER
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $issuer
spec:
  acme:
    server: $url
    email: $email
    privateKeySecretRef:
      name: $issuer-account-key
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
ISSUER

  oc apply -f - >/dev/null <<CERTS
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apps-wildcard
  namespace: openshift-ingress
spec:
  secretName: apps-wildcard-tls
  dnsNames: ["*.apps.$DOMAIN"]
  issuerRef: {name: $issuer, kind: ClusterIssuer}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-cert
  namespace: openshift-config
spec:
  secretName: api-cert-tls
  dnsNames: ["api.$DOMAIN"]
  issuerRef: {name: $issuer, kind: ClusterIssuer}
CERTS

  echo "    waiting for the certificates (DNS-01, usually 1-3 minutes) ..."
  _le_wait openshift-ingress apps-wildcard || { err "apps certificate not Ready — check: oc -n openshift-ingress describe certificate apps-wildcard; oc get challenges -A"; return 1; }
  _le_wait openshift-config  api-cert      || { err "api certificate not Ready — check: oc -n openshift-config describe certificate api-cert; oc get challenges -A"; return 1; }

  le_save_certs "$env"
  echo "    certificates saved to $LE_BACKUP_DIR/$DOMAIN/$env/ (reused on redeploy until they expire)"

  # keep oc working before the API starts serving the new certificate
  _le_extend_kubeconfig || echo "    WARNING: could not extend $KUBECONFIG — if oc reports 'unknown authority', use $KUBECONFIG.orig"

  oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge \
    -p '{"spec":{"defaultCertificate":{"name":"apps-wildcard-tls"}}}' >/dev/null
  oc patch apiserver cluster --type=merge \
    -p "{\"spec\":{\"servingCerts\":{\"namedCertificates\":[{\"names\":[\"api.$DOMAIN\"],\"servingCertificate\":{\"name\":\"api-cert-tls\"}}]}}}" >/dev/null

  echo "    applied — the router and kube-apiserver roll out the new certificate (a few minutes)"
  LETSENCRYPT_NOTE="  Let's Encrypt : $env certificates for *.apps.$DOMAIN and api.$DOMAIN
                  (auto-renewed by cert-manager; kubeconfig CA extended, original at ignition/auth/kubeconfig.orig)"
  return 0
}
