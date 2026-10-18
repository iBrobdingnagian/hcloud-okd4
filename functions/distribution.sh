#!/usr/bin/env bash
# Select the installer distribution without altering an existing cluster identity.
configure_distribution() {
  local recorded=${DEPLOYMENT_TYPE:-okd}
  DEPLOYMENT_TYPE=${FLAG_DISTRIBUTION:-$recorded}
  if [ -n "${CLUSTER_ID:-}" ] && [ "$DEPLOYMENT_TYPE" != "$recorded" ]; then
    err "--distribution must match the pinned cluster YAML"
  fi
  case "$DEPLOYMENT_TYPE" in okd|openshift) ;; *) err "--distribution must be okd or openshift" ;; esac
  if [ -f .phases/configured ] || [ -s ignition/auth/kubeconfig ] || [ -s terraform/terraform.tfstate ]; then
    [ "$DEPLOYMENT_TYPE" = "$recorded" ] || err "cannot change distribution of an existing cluster; use a separate --cluster workspace"
    [ -z "$FLAG_PULL_SECRET" ] || err "--pull-secret-file is for fresh installations only"
  fi
  if [ "$DEPLOYMENT_TYPE" = openshift ]; then
    # Named workspaces use their YAML; legacy workspaces may use Red Hat env defaults.
    if [ -z "${CLUSTER_ID:-}" ] && [ ! -f .phases/configured ] && [ ! -s ignition/auth/kubeconfig ]; then
      FLAG_RELEASE=${FLAG_RELEASE:-${RH_OPENSHIFT_RELEASE:-}}
      FLAG_PULL_SECRET=${FLAG_PULL_SECRET:-${RH_PULL_SECRET_FILE:-}}
    fi
    local requested=${FLAG_RELEASE:-${OPENSHIFT_RELEASE:-}}
    # A fresh OKD workspace can still contain its old OKD tag; offer the Red Hat menu.
    if [ -z "$FLAG_RELEASE" ] && [[ "$requested" == *okd* ]]; then requested=""; fi
    if [ -n "$requested" ]; then
      [[ "$requested" =~ ^4\.[0-9]+\.[0-9]+$ ]] || err "OpenShift requires --release 4.MINOR.PATCH"
      # Recorded settings are validation input, not explicit CLI overrides.
      # Keep FLAG_RELEASE empty on resume/day-two operations.
      if [ ! -f .phases/configured ] && [ ! -s ignition/auth/kubeconfig ]; then
        FLAG_RELEASE=$requested
      fi
    elif [ "${ASSUME_YES:-0}" = 1 ]; then
      err "OpenShift --yes requires an exact --release or RH_OPENSHIFT_RELEASE"
    fi
    if [ ! -f .phases/configured ] && [ ! -s ignition/auth/kubeconfig ]; then
      python3 "$REPO_ROOT/scripts/openshift_config.py" install-config.yaml "$FLAG_PULL_SECRET" || err "invalid Red Hat pull secret"
    fi
  elif [ -n "$FLAG_PULL_SECRET" ]; then
    err "--pull-secret-file requires --distribution openshift"
  fi
  export DEPLOYMENT_TYPE
}
