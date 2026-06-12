#!/usr/bin/env bash
# functions/release.sh — OKD release resolution (menu or --release)
# Sourced by deploy-okd.sh; not meant to be executed directly.

select_release() {
if [ -n "$FLAG_RELEASE" ] && ! echo "$FLAG_RELEASE" | grep -Eq '^[0-9]+\.[0-9]+$'; then
  # full tag given verbatim, e.g. 4.16.0-okd-scos.1
  OPENSHIFT_RELEASE=$FLAG_RELEASE
  log "Using OKD release $OPENSHIFT_RELEASE (from --release)"
else
  if [ -n "$FLAG_RELEASE" ]; then
    PREFIX=$FLAG_RELEASE
  elif [ "$ASSUME_YES" = 1 ]; then
    PREFIX=4.16
  else
    log "Choose an OKD version:"
    LINES="4.14 4.16 4.18 4.20 4.22 5.0"
    i=1
    for v in $LINES; do echo "  $i) $v"; i=$((i+1)); done
    printf 'Selection [matching 4.16]: '
    read -r SEL; SEL=${SEL:-2}
    PREFIX=$(echo $LINES | awk -v n="$SEL" '{print $n}')
    [ -n "$PREFIX" ] || err "invalid selection"
  fi

  log "Resolving latest release tag for OKD $PREFIX ..."
  RELDIR=$(mktemp -d); trap 'rm -rf "$RELDIR"' EXIT
  for p in 1 2 3 4 5 6; do
    curl -s "https://api.github.com/repos/okd-project/okd/releases?per_page=100&page=$p" \
      -o "$RELDIR/rel_$p.json"
    jq -e 'type=="array"' "$RELDIR/rel_$p.json" >/dev/null \
      || err "GitHub API error: $(jq -r '.message // "invalid response"' "$RELDIR/rel_$p.json")"
  done
  ALL_RELEASES=$(jq -s 'add' "$RELDIR"/rel_*.json)
  OPENSHIFT_RELEASE=$(echo "$ALL_RELEASES" | jq -r --arg p "$PREFIX" '
    [ .[] | select(.tag_name | startswith($p)) ] as $m
    | ([ $m[] | select(.prerelease == false) ]
       | if length > 0 then .[0].tag_name else ($m[0].tag_name // empty) end)')
  [ -n "$OPENSHIFT_RELEASE" ] && [ "$OPENSHIFT_RELEASE" != "null" ] \
    || err "no release found for $PREFIX"
  PRE=$(echo "$ALL_RELEASES" | jq -r --arg t "$OPENSHIFT_RELEASE" \
    '.[] | select(.tag_name==$t) | .prerelease')
  echo "    -> $OPENSHIFT_RELEASE $([ "$PRE" = "true" ] && echo '(PRERELEASE — no stable exists for this line)')"
fi
}
