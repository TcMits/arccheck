#!/bin/bash
#
# disk_health_check.sh
# Health-scores physical disks behind an Adaptec aacraid RAID controller by
# combining two sources:
#   1) smartctl -d aacraid,H,L,ID  -> drive-level media/wear health
#   2) arcconf GETCONFIG 1 AD/LD/PD -> controller/array/in-service status
# smartctl alone can't see whether the controller has actually failed a
# disk out of the array, and arcconf's SMART reporting is unreliable for
# SATA drives behind SAS controllers - so both are needed for a full picture.
#
# Usage: ./disk_health_check.sh [-v|--verbose]
# Requires: smartctl >= 7.x, arcconf (native or via docker), root privileges
#

# ---- Parse args -----------------------------------------------------------
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)
      echo "Usage: $0 [-v|--verbose]"
      echo "  -v, --verbose   Print a plain-English explanation under each note"
      exit 0
      ;;
  esac
done

# ---- Drive map: "label|device_node|host,lun,id" -------------------------
DRIVES=(
  "Disk0-Samsung870EVO|/dev/sda|0,0,0"
  "Disk4-MZ7L3960-A|/dev/sdb|0,0,4"
  "Disk5-MZ7L3960-B|/dev/sdb|0,0,5"
  "Disk6-MZ7L3960-C|/dev/sdb|0,0,6"
  "Disk7-MZ7L3960-D|/dev/sdb|0,0,7"
)

# ---- Colors ---------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Locate arcconf: native binary, or fall back to the docker wrapper ---
ARC_CMD=""
if command -v arcconf >/dev/null 2>&1; then
  ARC_CMD="arcconf"
elif command -v docker >/dev/null 2>&1; then
  ARC_CMD="docker run --rm --privileged akit042/docker-arccheck arcconf"
fi

# ---- Extract only the "Vendor Specific SMART Attributes" table -----------
# (avoids accidentally matching IDs against unrelated tables further down,
# e.g. the Selective self-test log's SPAN column which reuses 1-5, 256)
attr_table() {
  local smart_output="$1"
  echo "$smart_output" | awk '
    /^ID# ATTRIBUTE_NAME/ { grabbing=1; next }
    grabbing && /^$/ { grabbing=0 }
    grabbing { print }
  '
}

# ---- Helper: pull a RAW_VALUE for a given SMART attribute ID -------------
get_raw() {
  local table="$1"
  local attr_id="$2"
  echo "$table" | awk -v id="$attr_id" '
    $1 == id { print $NF; found=1; exit }
    END { if (!found) print "" }
  '
}

# ---- Helper: pull the normalized VALUE column for a given attribute ID ---
get_value() {
  local table="$1"
  local attr_id="$2"
  echo "$table" | awk -v id="$attr_id" '
    $1 == id { print $4; found=1; exit }
    END { if (!found) print "" }
  '
}

# ---- Strip leading zeros so bash doesn't treat values as octal -----------
denum() {
  local v="$1"
  v="${v#"${v%%[!0]*}"}"   # strip leading zeros
  [ -z "$v" ] && v=0
  echo "$v"
}

bar() {
  local score=$1
  local filled=$(( score / 5 ))
  local empty=$(( 20 - filled ))
  printf "["
  (( filled > 0 )) && printf "%0.s#" $(seq 1 $filled)
  (( empty > 0 )) && printf "%0.s-" $(seq 1 $empty)
  printf "]"
}

color_for_score() {
  local score=$1
  if   (( score >= 90 )); then echo "$GREEN"
  elif (( score >= 75 )); then echo "$CYAN"
  elif (( score >= 50 )); then echo "$YELLOW"
  else echo "$RED"
  fi
}

label_for_score() {
  local score=$1
  if   (( score >= 90 )); then echo "Excellent"
  elif (( score >= 75 )); then echo "Good"
  elif (( score >= 50 )); then echo "Watch"
  elif (( score > 0 ));   then echo "Poor - plan replacement"
  else echo "CRITICAL"
  fi
}

action_for_score() {
  local score=$1
  if   (( score >= 90 )); then
    echo "No action needed. Keep running this check on a regular schedule (e.g. weekly)."
  elif (( score >= 75 )); then
    echo "No action needed now. Recheck monthly and watch for the score trending downward over time."
  elif (( score >= 50 )); then
    echo "Increase check frequency (weekly). Make sure backups are current and a spare drive is on hand. Not urgent yet, but start planning."
  elif (( score > 0 )); then
    echo "Schedule replacement soon. Verify redundancy (RAID) is covering this drive and back up anything not redundant. Check daily until replaced."
  else
    echo "Replace this drive as soon as possible. Confirm the RAID array can tolerate the loss, and back up critical data now if it can't."
  fi
}

# ---- arcconf: controller + logical array summary (run once) -------------
print_arcconf_summary() {
  if [ -z "$ARC_CMD" ]; then
    echo -e "${YELLOW}arcconf not found (no native binary, no docker) - skipping controller/array check.${NC}\n"
    return
  fi

  local ad_out ld_out ctrl_status ld_summary defunct
  ad_out=$($ARC_CMD GETCONFIG 1 AD 2>/dev/null)
  ld_out=$($ARC_CMD GETCONFIG 1 LD 2>/dev/null)

  ctrl_status=$(echo "$ad_out" | grep -i "Controller Status" | awk -F: '{print $2}' | xargs)
  ld_summary=$(echo "$ad_out"  | grep -i "Logical devices/Failed/Degraded" | awk -F: '{print $2}' | xargs)
  defunct=$(echo "$ad_out"     | grep -i "Defunct disk drive count" | awk -F: '{print $2}' | xargs)

  local ctrl_col="$GREEN"
  [ "$ctrl_status" != "Optimal" ] && ctrl_col="$RED"

  echo -e "${BOLD}Controller / Array Status (arcconf)${NC}"
  echo -e "  Controller Status:    ${ctrl_col}${ctrl_status}${NC}"
  echo -e "  Logical Devs/Fail/Deg: ${ld_summary}"
  echo -e "  Defunct disk count:   ${defunct}"

  # per logical device status
  echo "$ld_out" | awk '
    /Logical [Dd]evice number/ { num=$0; sub(/.*: */,"",num) }
    /Status of [Ll]ogical [Dd]evice/ { st=$0; sub(/.*: */,"",st); print "  LD " num ": " st }
  '
  echo ""
}

# ---- arcconf: per-physical-disk controller-reported State ---------------
# Builds PD_STATE["targetID"]="State" by parsing GETCONFIG 1 PD once.
declare -A PD_STATE
load_pd_states() {
  [ -z "$ARC_CMD" ] && return
  local pd_out tid
  pd_out=$($ARC_CMD GETCONFIG 1 PD 2>/dev/null)
  tid=""
  while IFS= read -r line; do
    if [[ "$line" =~ Reported\ Channel,Device\(T:L\)[[:space:]]*:[[:space:]]*[0-9]+,([0-9]+) ]]; then
      tid="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*State[[:space:]]*:[[:space:]]*(.+)$ ]] && [ -n "$tid" ]; then
      PD_STATE["$tid"]="${BASH_REMATCH[1]}"
      tid=""
    fi
  done <<< "$pd_out"
}

echo -e "${BOLD}=== Disk Health Check ($(date)) ===${NC}\n"
if [ "$VERBOSE" = "1" ]; then
  echo -e "${CYAN}(verbose mode - showing full explanations for each note)${NC}\n"
fi

print_arcconf_summary
load_pd_states

for entry in "${DRIVES[@]}"; do
  IFS='|' read -r label dev hlid <<< "$entry"

  raw_out=$(smartctl -a -d "aacraid,${hlid}" "$dev" 2>/dev/null)

  if [ -z "$raw_out" ]; then
    echo -e "${RED}${BOLD}${label}${NC} (${dev} aacraid,${hlid}): ${RED}No data / device not found${NC}\n"
    continue
  fi

  model=$(echo "$raw_out" | grep -i "Device Model" | awk -F: '{print $2}' | xargs)
  overall=$(echo "$raw_out" | grep -i "overall-health self-assessment" | awk -F: '{print $2}' | xargs)

  table=$(attr_table "$raw_out")

  poh=$(get_raw "$table" 9)
  realloc=$(get_raw "$table" 5)
  uncorr=$(get_raw "$table" 187)
  bad_block=$(get_raw "$table" 183)
  prog_fail=$(get_raw "$table" 181)
  erase_fail=$(get_raw "$table" 182)
  crc=$(get_raw "$table" 199)
  added_bad=$(get_raw "$table" 252)
  wear_val=$(get_value "$table" 177)
  rsvd_val=$(get_value "$table" 179)

  # default missing fields, then strip leading zeros (avoid octal parsing)
  for v in realloc uncorr bad_block prog_fail erase_fail crc added_bad; do
    if [ -z "${!v}" ]; then eval "$v=0"; fi
    eval "$v=\$(denum \"\${$v}\")"
  done
  [ -z "$wear_val" ] && wear_val=100
  [ -z "$rsvd_val" ] && rsvd_val=100
  wear_val=$(denum "$wear_val")
  rsvd_val=$(denum "$rsvd_val")
  poh=$(denum "${poh:-0}")

  score=100
  notes=()

  # ---- controller-reported physical disk state (from arcconf) -----------
  target_id="${hlid##*,}"
  ctrl_state="${PD_STATE[$target_id]:-Unknown}"
  if [ -n "$ARC_CMD" ] && [ "$ctrl_state" != "Unknown" ] && \
     [ "$ctrl_state" != "Online" ] && [ "$ctrl_state" != "Ready" ]; then
    score=$(( score - 50 ))
    notes+=("Controller-reported state: $ctrl_state|arcconf reports this disk is not in a normal Online/Ready state. This is the controller's own view of whether the drive is actively serving the array - treat as more urgent than SMART data alone.")
  fi

  if [ "$overall" != "PASSED" ]; then
    score=0
    notes+=("SMART self-assessment: $overall|The drive's own built-in health check reported failure. Treat as urgent - back up data and plan replacement.")
  fi

  if (( realloc > 0 )); then
    d=$(( realloc * 2 )); (( d > 20 )) && d=20
    score=$(( score - d ))
    notes+=("Reallocated sectors: $realloc|A worn-out physical sector was swapped for a spare. A few over years is normal; a rising count means the media itself is degrading.")
  fi

  if (( uncorr > 0 )); then
    d=$(( uncorr * 10 )); (( d > 40 )) && d=40
    score=$(( score - d ))
    notes+=("Uncorrectable errors: $uncorr|Data was read/written and the drive's error-correction couldn't fix it. Any non-zero count is serious - possible silent data corruption.")
  fi

  if (( bad_block > 0 )); then
    d=$(( bad_block * 5 )); (( d > 30 )) && d=30
    score=$(( score - d ))
    notes+=("Runtime bad blocks: $bad_block|Blocks failed during normal operation (not just factory testing). Indicates active media wear.")
  fi

  if (( prog_fail > 0 )); then
    d=$(( prog_fail * 5 )); (( d > 20 )) && d=20
    score=$(( score - d ))
    notes+=("Program fail count: $prog_fail|The drive failed to write (program) data to flash cells. Suggests cells are wearing out.")
  fi

  if (( erase_fail > 0 )); then
    d=$(( erase_fail * 5 )); (( d > 20 )) && d=20
    score=$(( score - d ))
    notes+=("Erase fail count: $erase_fail|The drive failed to erase flash cells before rewriting them. Same underlying cause as program fails - cell wear.")
  fi

  if (( crc > 0 )); then
    d=$(( crc )); (( d > 15 )) && d=15
    score=$(( score - d ))
    notes+=("CRC/interface errors: $crc|Data got corrupted in transit between the drive and controller. Usually a cable/backplane/connector issue, not the drive dying - check physical connections first.")
  fi

  if (( added_bad > 0 )); then
    d=$(( added_bad )); (( d > 10 )) && d=10
    score=$(( score - d ))
    notes+=("Retired flash blocks: $added_bad|SSDs carry spare blocks and quietly retire worn ones. A handful is routine wear, not a fault - only worry if this climbs fast between checks.")
  fi

  if (( wear_val < 100 )); then
    d=$(( (100 - wear_val) * 3 / 10 ))
    score=$(( score - d ))
    notes+=("Wear leveling / life remaining: $wear_val|Starts at 100 (new) and counts down as the drive's rated write endurance gets used up. $wear_val roughly means about $(( 100 - wear_val ))% of rated endurance consumed. Worth close monitoring once it drops into the 20-30 range.")
  fi

  if (( rsvd_val < 100 )); then
    d=$(( (100 - rsvd_val) * 3 / 10 ))
    score=$(( score - d ))
    notes+=("Reserved block capacity remaining: $rsvd_val|Percentage of the SSD's spare-block pool still available for future bad-block swaps. Lower means less headroom left before the drive runs out of spares.")
  fi

  (( score < 0 )) && score=0
  (( score > 100 )) && score=100

  col=$(color_for_score "$score")
  lbl=$(label_for_score "$score")

  echo -e "${BOLD}${label}${NC}  (${dev} aacraid,${hlid})"
  echo -e "  Model:        $model"
  echo -e "  Power-on hrs: ${poh:-N/A}"
  echo -e "  Ctrl State:   ${ctrl_state}"
  echo -e "  Score:        ${col}${BOLD}${score}/100${NC}  ${col}${lbl}${NC}  $(bar "$score")"
  echo -e "  What to do:   $(action_for_score "$score")"
  if [ ${#notes[@]} -gt 0 ]; then
    echo -e "  Notes:"
    for n in "${notes[@]}"; do
      title="${n%%|*}"
      explain="${n#*|}"
      echo -e "    - $title"
      if [ "$VERBOSE" = "1" ] && [ "$explain" != "$title" ]; then
        echo -e "        ${CYAN}-> ${explain}${NC}"
      fi
    done
  else
    echo -e "  Notes:        none - clean bill of health"
  fi
  echo ""
done

echo -e "${BOLD}=== Done ===${NC}"
