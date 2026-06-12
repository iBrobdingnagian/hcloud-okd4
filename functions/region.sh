#!/usr/bin/env bash
# functions/region.sh — region selection and live capacity/pricing (Hetzner API)
# Sourced by deploy-okd.sh; not meant to be executed directly.

select_region() {
DEFAULT_LOC=${TF_VAR_location:-nbg1}

log "Fetching Hetzner regions and live server-type availability ..."
LOCATIONS_JSON=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/locations")
DC_JSON=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/datacenters")
TYPES_JSON=$(curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" \
  "https://api.hetzner.cloud/v1/server_types?per_page=50")
echo "$LOCATIONS_JSON" | jq -e '.locations | length > 0' >/dev/null 2>&1 \
  || err "could not fetch Hetzner locations (check HCLOUD_TOKEN)"
echo "$DC_JSON" | jq -e '.datacenters | length > 0' >/dev/null 2>&1 \
  || err "could not fetch Hetzner datacenters (check HCLOUD_TOKEN)"

# usable = x86 (the packer snapshot is x86_64) and not deprecated;
# AVAIL_BY_LOC maps location name -> [usable type ids placeable there NOW]
USABLE_IDS=$(echo "$TYPES_JSON" | jq \
  '[.server_types[] | select(.architecture=="x86" and .deprecated==false) | .id]')
AVAIL_BY_LOC=$(echo "$DC_JSON" | jq --argjson usable "$USABLE_IDS" '
  reduce .datacenters[] as $d ({};
    .[$d.location.name] = ((.[$d.location.name] // [])
      + ($d.server_types.available | map(select(. as $i | $usable | index($i))))
      | unique))')

# region rows: name city country network_zone usable_count
REGION_ROWS=$(echo "$LOCATIONS_JSON" | jq -r --argjson avail "$AVAIL_BY_LOC" '
  .locations[]
  | [.name, .city, .country, .network_zone, (($avail[.name] // []) | length)]
  | @tsv')

if [ -n "$FLAG_REGION" ] || [ "$ASSUME_YES" = 1 ]; then
  WANT=${FLAG_REGION:-$DEFAULT_LOC}
  ROW=$(echo "$REGION_ROWS" | awk -F'\t' -v l="$WANT" '$1==l')
  [ -n "$ROW" ] || err "unknown region: $WANT"
  echo "    region: $WANT"
else
  echo
  echo "Choose a region:"
  i=1 DEFAULT_IDX=1
  while IFS=$'\t' read -r name city country zone n; do
    [ "$name" = "$DEFAULT_LOC" ] && DEFAULT_IDX=$i
    if [ "$n" -eq 0 ]; then
      printf '  %d) %-5s %-20s %-13s (no usable x86 types)\n' \
        "$i" "$name" "$city, $country" "$zone"
    else
      printf '  %d) %-5s %-20s %-13s %2d x86 types available\n' \
        "$i" "$name" "$city, $country" "$zone" "$n"
    fi
    i=$((i+1))
  done <<REGIONS
$REGION_ROWS
REGIONS
  printf 'Selection [%d = %s, current .env value]: ' "$DEFAULT_IDX" "$DEFAULT_LOC"
  read -r RSEL; RSEL=${RSEL:-$DEFAULT_IDX}
  ROW=$(echo "$REGION_ROWS" | sed -n "${RSEL}p")
  [ -n "$ROW" ] || err "invalid selection"
fi
LOC=$(echo "$ROW" | cut -f1)
NETWORK_ZONE=$(echo "$ROW" | cut -f4)
[ "$(echo "$ROW" | cut -f5)" -gt 0 ] \
  || err "$LOC has no usable x86 server types right now — pick another region"

# ── 1b. live capacity & pricing check ────────────────────────────────────
log "Checking live server-type availability and pricing in $LOC ..."
AVAIL_IDS=$(echo "$AVAIL_BY_LOC" | jq --arg loc "$LOC" '.[$loc] // []')
[ "$(echo "$AVAIL_IDS" | jq 'length')" -gt 0 ] \
  || err "could not fetch live availability for $LOC (check HCLOUD_TOKEN)"

# OKD-compatible candidates: x86 (the packer snapshot is x86_64), not
# deprecated, and placeable in $LOC RIGHT NOW. Sorted by hourly price.
# Columns: name cores ram_gb disk_gb eur_per_hour(gross)
CANDIDATES=$(echo "$TYPES_JSON" | jq -r --argjson avail "$AVAIL_IDS" --arg loc "$LOC" '
  .server_types[]
  | select(.architecture=="x86" and .deprecated==false)
  | select(.id as $i | $avail | index($i))
  | . as $t
  | ($t.prices[] | select(.location==$loc) | .price_hourly.gross | tonumber) as $p
  | [$t.name, $t.cores, $t.memory, $t.disk, ($p*10000 | round / 10000)]
  | @tsv' | sort -t"$(printf '\t')" -k5 -n)
[ -n "$CANDIDATES" ] || err "no x86 server types available in $LOC right now"
}
