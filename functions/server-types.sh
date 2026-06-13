#!/usr/bin/env bash
# functions/server-types.sh — server type picker (filters, pricing strategies)
# Sourced by deploy-okd.sh; not meant to be executed directly.

pick_type() {  # pick_type <role> <min_cores> <min_ram_gb> <preset-or-empty> <name-prefix-or-empty> <strategy> → PICKED_TYPE / PICKED_PRICE
  # strategy: "interactive" (prompt, or cheapest with --yes), "cheapest", "mid"
  local role=$1 min_c=$2 min_r=$3 preset=${4:-} prefix=${5:-} strategy=${6:-interactive}
  local list flist n mid i row name cores ram disk price note sel reason
  list=$(echo "$CANDIDATES" | awk -F'\t' -v c="$min_c" -v r="$min_r" '$2>=c && $3>=r')
  [ -n "$list" ] || err "no $role-capable types available in $LOC right now — try another location"
  if [ -n "$prefix" ]; then
    flist=$(echo "$list" | awk -v p="^$prefix" '$0 ~ p')
    if [ -n "$flist" ]; then
      list=$flist
    else
      echo "    (no ${prefix}* type meets ${min_c} vCPU / ${min_r} GB RAM in $LOC — falling back to all qualifying types)"
    fi
  fi
  if [ -n "$preset" ]; then
    row=$(echo "$list" | awk -F'\t' -v t="$preset" '$1==t')
    [ -n "$row" ] || err "$role type '$preset' not available in $LOC (or below ${min_c} vCPU / ${min_r} GB RAM)"
    reason="requested"
  elif [ "$strategy" = "cheapest" ] || { [ "$strategy" = "interactive" ] && [ "$ASSUME_YES" = 1 ]; }; then
    row=$(echo "$list" | head -1)
    reason="cheapest qualifying"
  elif [ "$strategy" = "mid" ]; then
    n=$(echo "$list" | wc -l | tr -d ' ')
    mid=$(( (n + 1) / 2 ))
    row=$(echo "$list" | sed -n "${mid}p")
    reason="mid-range, $mid of $n qualifying types"
  else
    echo
    echo "Available $role types in $LOC (OKD minimum: ${min_c} vCPU / ${min_r} GB RAM; >=100 GB disk recommended):"
    i=1
    while IFS=$'\t' read -r name cores ram disk price; do
      note=""
      [ "$disk" -lt 100 ] && note="  (disk <100 GB)"
      printf '  %d) %-7s %2d vCPU  %3d GB RAM  %4d GB disk  %.4f EUR/h%s\n' \
        "$i" "$name" "$cores" "$ram" "$disk" "$price" "$note"
      i=$((i+1))
    done <<LIST
$list
LIST
    printf 'Choose %s type [1 = cheapest]: ' "$role"
    read -r sel; sel=${sel:-1}
    row=$(echo "$list" | sed -n "${sel}p")
    [ -n "$row" ] || err "invalid selection"
    reason="your choice"
  fi
  PICKED_TYPE=$(echo "$row" | cut -f1)
  PICKED_PRICE=$(echo "$row" | cut -f5)
  # always echo the chosen server's specs and price (not just the name)
  IFS=$'\t' read -r name cores ram disk price <<<"$row"
  note=""
  [ "$disk" -lt 100 ] && note="  (disk <100 GB)"
  printf '    %s type: %-7s %2d vCPU  %3d GB RAM  %4d GB disk  %.4f EUR/h  (%s)%s\n' \
    "$role" "$name" "$cores" "$ram" "$disk" "$price" "$reason" "$note"
}
