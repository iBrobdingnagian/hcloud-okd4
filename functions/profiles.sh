#!/usr/bin/env bash
# functions/profiles.sh — deployment profile selection (production/lab/manual)
# Sourced by deploy-okd.sh; not meant to be executed directly.

select_profile() {
if [ -n "$FLAG_PROFILE" ]; then
  PROFILE=$FLAG_PROFILE
elif [ "$ASSUME_YES" = 1 ]; then
  PROFILE=2
elif [ -n "$FLAG_MASTERS$FLAG_WORKERS$FLAG_MASTER_TYPE$FLAG_WORKER_TYPE" ]; then
  PROFILE=4   # explicit topology/type flags given -> go straight to manual
else
  echo
  echo "Choose a deployment profile:"
  echo "  1) Production - Best Servers    (3 masters / 3 workers, dedicated CCX types)"
  echo "  2) Production - Cost Optimized  (3 masters / 3 workers, cheapest qualifying types)"
  echo "  3) Lab                          (choose topology and cost tier)"
  echo "  4) Manual                       (pick region, counts and types yourself)"
  printf 'Selection [4]: '
  read -r PROFILE; PROFILE=${PROFILE:-4}
fi
case "$PROFILE" in 1|2|3|4) ;; *) err "invalid profile: $PROFILE (must be 1-4)";; esac

# defaults a profile may override: OKD minimum specs, no type-name filter,
# "interactive" strategy = old behaviour (prompt, or cheapest with --yes)
MIN_C_MASTER=4 MIN_R_MASTER=16 MIN_C_WORKER=2 MIN_R_WORKER=8
TYPE_PREFIX="" TYPE_STRATEGY="interactive"

case "$PROFILE" in
  1)
    MASTERS=3 WORKERS=3
    MIN_C_MASTER=8 MIN_R_MASTER=32 MIN_C_WORKER=4 MIN_R_WORKER=16
    TYPE_PREFIX="ccx" TYPE_STRATEGY="cheapest"
    log "Profile 1: Production - Best Servers (3 masters / 3 workers, dedicated CCX types)"
    ;;
  2)
    MASTERS=3 WORKERS=3
    TYPE_STRATEGY="cheapest"
    log "Profile 2: Production - Cost Optimized (3 masters / 3 workers, cheapest qualifying types)"
    ;;
  3)
    if [ -n "$FLAG_LAB_TOPOLOGY" ]; then LAB_TOPOLOGY=$FLAG_LAB_TOPOLOGY
    elif [ "$ASSUME_YES" = 1 ]; then LAB_TOPOLOGY=1x1
    else
      echo
      echo "Lab topology (masters x workers):"
      echo "  1) 1x0   single node, schedulable master, no separate workers"
      echo "  2) 1x1"
      echo "  3) 1x2"
      echo "  4) 1x3"
      echo "  5) 3x3   highly available control plane"
      printf 'Selection [2]: '
      read -r TSEL; TSEL=${TSEL:-2}
      case "$TSEL" in
        1) LAB_TOPOLOGY=1x0 ;; 2) LAB_TOPOLOGY=1x1 ;; 3) LAB_TOPOLOGY=1x2 ;;
        4) LAB_TOPOLOGY=1x3 ;; 5) LAB_TOPOLOGY=3x3 ;; *) err "invalid selection";;
      esac
    fi
    case "$LAB_TOPOLOGY" in
      1x0) MASTERS=1 WORKERS=0 ;;
      1x1) MASTERS=1 WORKERS=1 ;;
      1x2) MASTERS=1 WORKERS=2 ;;
      1x3) MASTERS=1 WORKERS=3 ;;
      3x3) MASTERS=3 WORKERS=3 ;;
      *) err "invalid lab topology: $LAB_TOPOLOGY (use 1x0, 1x1, 1x2, 1x3 or 3x3)" ;;
    esac

    if [ -n "$FLAG_LAB_TIER" ]; then LAB_TIER=$FLAG_LAB_TIER
    elif [ "$ASSUME_YES" = 1 ]; then LAB_TIER=low
    else
      echo
      echo "Lab cost tier:"
      echo "  1) low   cheapest qualifying types (OKD minimum specs)"
      echo "  2) mid   mid-range types (more headroom)"
      echo "  3) high  dedicated CCX types (best performance)"
      printf 'Selection [1]: '
      read -r TIERSEL; TIERSEL=${TIERSEL:-1}
      case "$TIERSEL" in 1) LAB_TIER=low ;; 2) LAB_TIER=mid ;; 3) LAB_TIER=high ;; *) err "invalid selection";; esac
    fi
    case "$LAB_TIER" in
      low)  TYPE_STRATEGY="cheapest" ;;
      mid)  TYPE_STRATEGY="mid" ;;
      high)
        MIN_C_MASTER=8 MIN_R_MASTER=32 MIN_C_WORKER=4 MIN_R_WORKER=16
        TYPE_PREFIX="ccx" TYPE_STRATEGY="cheapest"
        ;;
      *) err "invalid lab tier: $LAB_TIER (use low, mid or high)" ;;
    esac
    log "Profile 3: Lab ($LAB_TOPOLOGY topology, $LAB_TIER cost tier)"
    ;;
  4)
    log "Profile 4: Manual"
    ;;
esac
}
