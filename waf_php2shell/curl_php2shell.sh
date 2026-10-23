#!/usr/bin/env bash
# Applies the PHP2Shell mitigations from Broadcom KB 460068 to an Avi WAF policy via the REST API.
#   Reference: https://knowledge.broadcom.com/external/article/460068
#   Step 1  Enables the CRS rules 920170, 920180, 920370, 920380, 932100-932200 and 933100-933190
#           in Enforcement mode (through crs_overrides).
#   Step 2  Adds the four PHP2Shell pre-CRS rules (IDs 200 to 203).
# Handles Avi session auth: POST /login -> csrftoken + sessionid cookies,
# then X-CSRFToken, Referer and X-Avi-Tenant headers on every call.
#
# Usage: curl_php2shell.sh [--dry-run] [--restore BACKUP.json] [-h]
#   --dry-run          Show the planned change; write nothing to the controller.
#   --restore FILE     Put crs_overrides and pre_crs_groups back from a backup written by an earlier run.
#
# Environment (all optional; missing credentials are prompted for):
#   AVI_CONTROLLER AVI_USER AVI_PASS AVI_TENANT(admin) AVI_API_VERSION(30.2.1)
#   WAF_POLICY_NAME  CREATE_POLICY=true  WAF_PROFILE_NAME  WAF_CRS_NAME
#   RULE_MODE CRS_MODE (WAF_MODE_ENFORCEMENT|WAF_MODE_DETECTION_ONLY)  CRS_ONLY=true  GROUP_NAME
#   AVI_CACERT=<ca.pem>   CA bundle used to verify the controller certificate
#   AVI_INSECURE=true     Skip certificate verification (not recommended)
#   AVI_TIMEOUT(30)       Per-request timeout in seconds
#   BACKUP_DIR(.)         Where pre-change backups are written (mode 0600)
#
# Security notes:
#   - TLS certificates are verified by default. Use AVI_CACERT, or AVI_INSECURE=true as an explicit opt-in.
#   - The password never appears on a command line: it is piped to curl over stdin and unset after login.
#   - Session headers are passed to curl through a 0600 file, not on the command line.
#   - Use a dedicated Avi account whose role is limited to WAF policy changes, not "admin".
set -euo pipefail
{ set +x; } 2>/dev/null     # never trace: xtrace would print credentials
umask 077

usage() { sed -n '/^# Usage:/,/^#   --restore/p' "$0" | sed 's/^# \{0,1\}//'; }

DRY_RUN="${DRY_RUN:-false}"; RESTORE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --restore) [ $# -ge 2 ] || { echo "--restore needs a file" >&2; exit 2; }; RESTORE_FILE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---- Preflight ----
need() { command -v "$1" >/dev/null 2>&1 || { echo "Required tool not found: $1" >&2; exit 1; }; }
need curl; need jq; need awk
# --fail-with-body needs curl 7.76 or later
awk -v v="$(curl --version | awk 'NR==1{print $2}')" 'BEGIN{split(v,a,"."); exit !((a[1]*10000+a[2]*100+a[3]+0) >= 70600)}' \
  || { echo "curl 7.76 or later is required (found $(curl --version | awk 'NR==1{print $2}'))" >&2; exit 1; }

# ---- Console helpers (all interactive output goes to stderr) ----
INTERACTIVE=false; [ -t 0 ] && INTERACTIVE=true
KB_URL="https://knowledge.broadcom.com/external/article/460068"
hr()      { printf '%s\n' "======================================================================" >&2; }
heading() { printf '\n' >&2; hr; printf '  %s\n' "$1" >&2; hr; printf '\n' >&2; }
say()     { printf '  %s\n' "$@" >&2; }
blank()   { printf '\n' >&2; }
warn()    { printf 'WARNING: %s\n' "$*" >&2; }
die()     { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# confirm "<question>" -> returns 0 for yes, 1 for no
confirm() {
  local a
  while :; do
    read -r -p "  $1 [y/n]: " a
    case "$a" in [Yy]|[Yy][Ee][Ss]) return 0 ;; [Nn]|[Nn][Oo]) return 1 ;; esac
    say "Please answer y or n."
  done
}

if $INTERACTIVE && [ -z "$RESTORE_FILE" ]; then
  heading "PHP2Shell WAF protection for Avi Load Balancer"
  say "Reference: $KB_URL"
  blank
  say "This script applies the mitigations from the KB article above"
  say "(CVE-2026-109618 and CVE-2026-109619) to an Avi WAF policy:"
  blank
  say "  Step 1  Enables these CRS rules in Enforcement mode:"
  say "            CRS_920_Protocol_Validation          920170, 920180, 920370, 920380"
  say "            CRS_932_Application_Attack_RCE       932100 - 932200"
  say "            CRS_933_Application_Attack_PHP       933100 - 933190"
  blank
  say "  Step 2  Adds four pre-CRS rules (IDs 200 to 203) that block PHPSESSID"
  say "          in POST bodies, unsafe PHP_SESSION_UPLOAD_PROGRESS values, PHP open"
  say "          tags in upload filenames, and serialized objects in filenames."
  blank
  say "You can modify an existing WAF policy or create a new one."
  say "Existing settings, other CRS overrides and other pre-CRS groups are kept."
  blank
  say "If you create a new policy, these defaults apply:"
  say "  - Policy mode:      Enforcement (WAF_MODE_ENFORCEMENT)"
  say "  - WAF profile/CRS:  the ones you choose from the controller lists"
  say "  - Rule groups:      inherited from the CRS version you choose"
  say "  - Step 1 and 2:     applied as described above, in Enforcement mode"
  say "  - Everything else:  left at the controller defaults"
  blank
  say "A backup of the policy is saved before any change (restore with --restore)."
  say "Nothing is changed on the controller until you confirm a summary."
fi

# ---- Settings and validation ----
RULE_MODE="${RULE_MODE:-WAF_MODE_ENFORCEMENT}"   # or WAF_MODE_DETECTION_ONLY
CRS_MODE="${CRS_MODE:-WAF_MODE_ENFORCEMENT}"     # mode forced on the Step 1 CRS rules
CRS_ONLY="${CRS_ONLY:-false}"                    # true = only touch crs_overrides, leave pre_crs_groups alone
CREATE_POLICY="${CREATE_POLICY:-false}"
AVI_INSECURE="${AVI_INSECURE:-false}"
AVI_CACERT="${AVI_CACERT:-}"
AVI_TIMEOUT="${AVI_TIMEOUT:-30}"
AVI_TENANT="${AVI_TENANT:-admin}"
AVI_API_VERSION="${AVI_API_VERSION:-30.2.1}"
GROUP_NAME="${GROUP_NAME:-PHP2Shell-CVE-2026-109618-109619}"
BACKUP_DIR="${BACKUP_DIR:-.}"

check_bool() { case "$2" in true|false) ;; *) die "$1 must be true or false (got '$2')" ;; esac; }
check_mode() { case "$2" in WAF_MODE_ENFORCEMENT|WAF_MODE_DETECTION_ONLY) ;; *) die "$1 must be WAF_MODE_ENFORCEMENT or WAF_MODE_DETECTION_ONLY (got '$2')" ;; esac; }
check_re()   { [[ "$2" =~ $3 ]] || die "$1 has an invalid value"; }
check_bool DRY_RUN "$DRY_RUN"; check_bool CRS_ONLY "$CRS_ONLY"; check_bool CREATE_POLICY "$CREATE_POLICY"; check_bool AVI_INSECURE "$AVI_INSECURE"
check_mode RULE_MODE "$RULE_MODE"; check_mode CRS_MODE "$CRS_MODE"
check_re AVI_TENANT "$AVI_TENANT" '^[A-Za-z0-9_.-]+$'          # goes into an HTTP header
check_re AVI_API_VERSION "$AVI_API_VERSION" '^[0-9]+(\.[0-9]+){1,3}$'
check_re AVI_TIMEOUT "$AVI_TIMEOUT" '^[0-9]+$'

# Controller, username and password come from the environment if set, otherwise they are prompted.
ask() { # ask VAR "prompt" [secret]
  local var="$1" prompt="$2" secret="${3:-}" val
  [ -n "${!var:-}" ] && return 0
  [ -t 0 ] || die "$var is not set and there is no terminal to prompt on"
  if [ -n "$secret" ]; then read -r -s -p "$prompt: " val; echo >&2; else read -r -p "$prompt: " val; fi
  [ -n "$val" ] || die "$var cannot be empty"
  printf -v "$var" '%s' "$val"
}
$INTERACTIVE && heading "Connect to the Avi controller"
ask AVI_CONTROLLER "Avi controller (IP or hostname, e.g. 10.1.1.10)"
ask AVI_USER "Avi username"
ask AVI_PASS "Avi password" secret
# Hostname or IPv4 with an optional port; blocks '@', '/', '?' and similar that would redirect the credentials
check_re AVI_CONTROLLER "$AVI_CONTROLLER" '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'

BASE="https://${AVI_CONTROLLER}"
JAR="$(mktemp)"; GROUPS_FILE="$(mktemp)"; BODY_FILE="$(mktemp)"; HDR_FILE="$(mktemp)"
CREATED_UUID=""; LOGGED_IN=false; WAF_POLICY_NAME="${WAF_POLICY_NAME:-}"
HDRS=(-H "Content-Type: application/json")
CURL=(curl -sS --fail-with-body --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time "$AVI_TIMEOUT" -b "$JAR" -c "$JAR")
if [ "$AVI_INSECURE" = "true" ]; then
  CURL+=(-k)
  warn "TLS certificate verification is DISABLED (AVI_INSECURE=true). Credentials and the session can be intercepted."
elif [ -n "$AVI_CACERT" ]; then
  [ -r "$AVI_CACERT" ] || die "AVI_CACERT '$AVI_CACERT' is not readable"
  CURL+=(--cacert "$AVI_CACERT")
fi

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  # A policy created by this run is deleted again if a later step fails, so no half-configured policy is left behind.
  if [ "$rc" -ne 0 ] && [ -n "$CREATED_UUID" ]; then
    echo "Failed after creating the policy; deleting it again ($CREATED_UUID)" >&2
    "${CURL[@]}" "${HDRS[@]}" -X DELETE "$BASE/api/wafpolicy/$CREATED_UUID" >/dev/null 2>&1 || echo "Could not delete it; remove '$WAF_POLICY_NAME' manually" >&2
  fi
  # End the Avi session so the cookie is useless after this script exits
  if $LOGGED_IN; then
    "${CURL[@]}" --max-time 5 "${HDRS[@]}" -X POST "$BASE/logout" >/dev/null 2>&1 || true
  fi
  rm -f "$JAR" "$GROUPS_FILE" "$BODY_FILE" "$HDR_FILE"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

tls_hint() {
  case "${1:-0}" in
    60|58|59|77|83|35|51|53|54)
      say "The controller certificate could not be verified." >&2
      say "Provide the CA with AVI_CACERT=/path/ca.pem, or set AVI_INSECURE=true to skip verification (not recommended)." >&2 ;;
  esac
}

# 1. Login. The password is piped over stdin so it never shows up in a process listing.
rc=0
printf '%s' "$AVI_PASS" | jq -Rs --arg u "$AVI_USER" '{username:$u,password:.}' \
  | "${CURL[@]}" -X POST "$BASE/login" -H "Content-Type: application/json" --data @- >/dev/null || rc=$?
unset AVI_PASS
if [ "$rc" -ne 0 ]; then tls_hint "$rc"; die "Login to $AVI_CONTROLLER failed (curl exit $rc)"; fi
LOGGED_IN=true
CSRF="$(awk '$6=="csrftoken"{print $7}' "$JAR")"
[[ "$CSRF" =~ ^[A-Za-z0-9]+$ ]] || die "No valid csrftoken received"

# Session headers go through a 0600 file (-H @file), keeping the CSRF token off the command line
printf '%s\n' "Content-Type: application/json" "X-Avi-Version: $AVI_API_VERSION" \
  "X-Avi-Tenant: $AVI_TENANT" "X-CSRFToken: $CSRF" "Referer: $BASE" > "$HDR_FILE"
HDRS=(-H "@$HDR_FILE")

# api <curl args...>: authenticated call; on failure prints the HTTP error body from Avi and returns non-zero
api() {
  local out rc=0
  out="$("${CURL[@]}" "${HDRS[@]}" "$@")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Avi API call failed (curl exit $rc): ${*: -3}" >&2
    [ -n "$out" ] && echo "Response: $out" >&2
    tls_hint "$rc"
    return "$rc"
  fi
  printf '%s\n' "$out"
}
enc() { jq -rn --arg n "$1" '$n|@uri'; }

# names <object type>: all object names, following pagination
names() {
  local type="$1" page=1 out="" resp
  while :; do
    resp="$(api "$BASE/api/$type?fields=name&page_size=200&page=$page")" || return 1
    out+="$(jq -r '.results[].name' <<<"$resp")"$'\n'
    [ -n "$(jq -r '.next // empty' <<<"$resp")" ] || break
    page=$((page+1))
  done
  printf '%s' "$out" | sed '/^$/d' | sort
}

# safe_ref <ref>: only follow object references on the controller this script logs in to (the session headers
# are sent with every call, so a reference to another host must never be fetched)
safe_ref() {
  case "$1" in
    "$BASE"/api/*) printf '%s\n' "$1" ;;
    /api/*)        printf '%s\n' "$BASE$1" ;;
    *) echo "Refusing to follow a reference outside $BASE: $1" >&2; return 1 ;;
  esac
}
# fetch_crs_groups <ref>: the CRS rule groups (ref is an object URL, or a ?name= query)
fetch_crs_groups() {
  local ref; ref="$(safe_ref "$1")" || return 1
  api "$ref" | jq -c 'if has("results") then (.results[0].groups // empty) else (.groups // empty) end'
}
# policy_state: the two fields this script changes, in a canonical form for comparisons
policy_state() { jq -S -c --argjson crsonly "$CRS_ONLY" '{c:(.crs_overrides // [])} + (if $crsonly then {} else {p:(.pre_crs_groups // [])} end)'; }

# Best effort: warn if the API version header does not match the controller
CTRL_VER="$(api "$BASE/api/initial-data" 2>/dev/null | jq -r '.version.Version // empty' 2>/dev/null || true)"
if [ -n "$CTRL_VER" ] && [ "$CTRL_VER" != "$AVI_API_VERSION" ]; then
  warn "Controller reports version $CTRL_VER but the API version header is $AVI_API_VERSION (set AVI_API_VERSION to match)."
fi
if $INTERACTIVE && [ "$AVI_USER" = "admin" ]; then
  say "Note: you are signed in as 'admin'. A dedicated account limited to WAF policy changes is safer."
fi

# ---- Restore mode ----
if [ -n "$RESTORE_FILE" ]; then
  [ -r "$RESTORE_FILE" ] || die "Backup file '$RESTORE_FILE' is not readable"
  RNAME="$(jq -r '.name // empty' "$RESTORE_FILE")"; [ -n "$RNAME" ] || die "Backup file has no policy name"
  RUUID="$(api "$BASE/api/wafpolicy?name=$(enc "$RNAME")" | jq -r '.results[0].uuid // empty')"
  [ -n "$RUUID" ] || die "WAF policy '$RNAME' not found on $AVI_CONTROLLER"
  jq '{replace:{crs_overrides:(.crs_overrides // []), pre_crs_groups:(.pre_crs_groups // [])}}' "$RESTORE_FILE" > "$BODY_FILE"
  if $INTERACTIVE; then
    heading "Restore a WAF policy from backup"
    say "Controller:    $AVI_CONTROLLER (tenant $AVI_TENANT)"
    say "Policy name:   $RNAME"
    say "Backup file:   $RESTORE_FILE"
    blank
    say "crs_overrides and pre_crs_groups will be set back to the values in the backup."
    blank
    confirm "Proceed with the restore?" || { say "Cancelled."; exit 0; }
  fi
  if [ "$DRY_RUN" = "true" ]; then say "Dry run: nothing written. Planned change:"; jq . "$BODY_FILE"; exit 0; fi
  api -X PATCH "$BASE/api/wafpolicy/$RUUID" --data @"$BODY_FILE" >/dev/null
  say "Restored '$RNAME' from $RESTORE_FILE"
  exit 0
fi

# choose "<title>" item... -> prints the selected item (menu goes to stderr)
choose() {
  local title="$1"; shift; local items=("$@") i=1 n it
  say "$title"; blank
  for it in "${items[@]}"; do printf '    %2d) %s\n' "$i" "$it" >&2; i=$((i+1)); done
  blank
  while :; do
    read -r -p "  Select [1-${#items[@]}]: " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#items[@]}" ] && break
    say "Enter a number between 1 and ${#items[@]}."
  done
  printf '%s\n' "${items[n-1]}"
}

# 2. Pick the WAF policy: modify an existing one, or create a new one.
#    Non-interactive: WAF_POLICY_NAME=<name> modifies it; add CREATE_POLICY=true to create it.
#    Creating also needs WAF_PROFILE_NAME and WAF_CRS_NAME (prompted from a list if unset).
#    Interactive runs end with a review step; answering n goes back (to the WAF profile menu when
#    creating a policy, or to the policy menu when modifying one).
WAF_PROFILE_NAME="${WAF_PROFILE_NAME:-}"
WAF_CRS_NAME="${WAF_CRS_NAME:-}"
UUID=""
NEW_LABEL="<create a new policy>"
while :; do
  if [ -z "$WAF_POLICY_NAME" ] && [ "$CREATE_POLICY" != "true" ]; then
    $INTERACTIVE || die "Set WAF_POLICY_NAME (or CREATE_POLICY=true WAF_POLICY_NAME=<new>) when not interactive"
    heading "Select a WAF policy"
    POLICIES=(); while IFS= read -r l; do [ -n "$l" ] && POLICIES+=("$l"); done < <(names wafpolicy)
    SEL="$(choose "WAF policies on $AVI_CONTROLLER (tenant $AVI_TENANT). Choose one to modify, or create a new one:" \
      "${POLICIES[@]+"${POLICIES[@]}"}" "$NEW_LABEL")"
    if [ "$SEL" = "$NEW_LABEL" ]; then CREATE_POLICY=true; else WAF_POLICY_NAME="$SEL"; fi
  fi

  if [ "$CREATE_POLICY" = "true" ]; then
    if [ -z "$WAF_POLICY_NAME" ]; then
      $INTERACTIVE || die "WAF_POLICY_NAME required to create a policy"
      heading "Name the new WAF policy"
      read -r -p "  Name for the new WAF policy: " WAF_POLICY_NAME
      [ -n "$WAF_POLICY_NAME" ] || die "Name cannot be empty"
    fi
    [ "$(api "$BASE/api/wafpolicy?name=$(enc "$WAF_POLICY_NAME")" | jq '.count')" = "0" ] \
      || die "WAF policy '$WAF_POLICY_NAME' already exists"
    if [ -z "$WAF_PROFILE_NAME" ]; then
      heading "Select a WAF profile"
      LIST=(); while IFS= read -r l; do [ -n "$l" ] && LIST+=("$l"); done < <(names wafprofile)
      [ "${#LIST[@]}" -gt 0 ] || die "No WAF profiles found; create one first"
      WAF_PROFILE_NAME="$(choose "WAF profiles on $AVI_CONTROLLER:" "${LIST[@]}")"
    fi
    if [ -z "$WAF_CRS_NAME" ]; then
      heading "Select a CRS version"
      LIST=(); while IFS= read -r l; do [ -n "$l" ] && LIST+=("$l"); done < <(names wafcrs)
      [ "${#LIST[@]}" -gt 0 ] || die "No WAF CRS versions found"
      WAF_CRS_NAME="$(choose "Core Rule Set versions on $AVI_CONTROLLER:" "${LIST[@]}")"
    fi
    if $INTERACTIVE; then
      heading "Review: create a new WAF policy"
      say "Controller:    $AVI_CONTROLLER (tenant $AVI_TENANT)"
      say "Policy name:   $WAF_POLICY_NAME  (new)"
      say "WAF profile:   $WAF_PROFILE_NAME"
      say "CRS version:   $WAF_CRS_NAME"
      say "Policy mode:   $CRS_MODE"
      [ "$DRY_RUN" = "true" ] && say "Dry run:       nothing will be written"
      blank
      say "Then, as described in $KB_URL :"
      say "  Step 1  Enable the CRS rules listed above, mode $CRS_MODE"
      [ "$CRS_ONLY" = "true" ] || say "  Step 2  Add pre-CRS group '$GROUP_NAME' (rules 200 to 203), mode $RULE_MODE"
      blank
    fi
  else
    UUID="$(api "$BASE/api/wafpolicy?name=$(enc "$WAF_POLICY_NAME")" | jq -r '.results[0].uuid // empty')"
    [ -n "$UUID" ] || die "WAF policy '$WAF_POLICY_NAME' not found"
    if $INTERACTIVE; then
      heading "Review: modify an existing WAF policy"
      say "Controller:    $AVI_CONTROLLER (tenant $AVI_TENANT)"
      say "Policy name:   $WAF_POLICY_NAME"
      say "Policy mode:   unchanged"
      [ "$DRY_RUN" = "true" ] && say "Dry run:       nothing will be written"
      blank
      say "As described in $KB_URL :"
      say "  Step 1  Enable the CRS rules listed above, mode $CRS_MODE"
      [ "$CRS_ONLY" = "true" ] || say "  Step 2  Add pre-CRS group '$GROUP_NAME' (rules 200 to 203), mode $RULE_MODE"
      say "Other CRS overrides and pre-CRS groups are kept. A backup is saved first."
      blank
    fi
  fi

  $INTERACTIVE || break
  if confirm "Proceed with these settings?"; then break; fi
  blank
  if [ "$CREATE_POLICY" = "true" ]; then
    say "Returning to the WAF profile selection."
    WAF_PROFILE_NAME=""; WAF_CRS_NAME=""
  else
    say "Returning to the WAF policy selection."
    WAF_POLICY_NAME=""; UUID=""
  fi
done

if [ "$CREATE_POLICY" = "true" ] && [ "$DRY_RUN" != "true" ]; then
  $INTERACTIVE && { heading "Applying changes"; say "Creating WAF policy '$WAF_POLICY_NAME'"; blank; }
  # The rule groups come from the referenced CRS object (crs_groups is deprecated since 20.1.6).
  UUID="$(jq -n --arg n "$WAF_POLICY_NAME" --arg m "$CRS_MODE" --arg p "/api/wafprofile?name=$(enc "$WAF_PROFILE_NAME")" \
      --arg c "/api/wafcrs?name=$(enc "$WAF_CRS_NAME")" \
      '{name:$n, mode:$m, waf_profile_ref:$p, waf_crs_ref:$c}' \
    | api -X POST "$BASE/api/wafpolicy" --data @- | jq -r '.uuid // empty')"
  [ -n "$UUID" ] || die "Policy creation failed"
  CREATED_UUID="$UUID"
elif $INTERACTIVE; then
  heading "Applying changes"
fi

# 3. Rules, verbatim from KB Step 2 (chained rules are newline-separated)
R200=$'SecRule REQUEST_METHOD "@streq POST" "id:200, phase:2, deny, status:403, t:none, tag:\'CVE-2026-109618\', tag:\'CVE-2026-109619\', msg:\'PHP2Shell: PHPSESSID submitted as POST form field (session fixation)\', severity:\'CRITICAL\', chain"\nSecRule ARGS_NAMES "@streq phpsessid" "t:none, t:lowercase"'
R201=$'SecRule REQUEST_METHOD "@streq POST" "id:201, phase:2, deny, status:403, t:none, tag:\'CVE-2026-109618\', tag:\'CVE-2026-109619\', msg:\'PHP2Shell: PHP_SESSION_UPLOAD_PROGRESS value contains unsafe characters\', severity:\'CRITICAL\', chain"\nSecRule ARGS:PHP_SESSION_UPLOAD_PROGRESS "!@rx ^[a-zA-Z0-9_.-]+$" "t:none"'
R202=$'SecRule FILES "@rx <\\?(?:php|=)" "id:202, phase:2, deny, status:403, t:none, t:lowercase, tag:\'CVE-2026-109618\', msg:\'PHP2Shell: PHP open tag in upload filename\', severity:\'CRITICAL\'"'
R203=$'SecRule FILES "@rx [|;](?:O|C|a|s):\\d+:" "id:203, phase:2, deny, status:403, t:none, tag:\'CVE-2026-109619\', msg:\'PHP2Shell: Serialized PHP object in upload filename\', severity:\'CRITICAL\'"'

# 4. Build the PATCH: pre-CRS group (existing ones kept) + crs_overrides for the Step 1 rules.
#    The CRS rule groups/IDs are read from the policy's waf_crs_ref; existing crs_overrides are preserved.
if [ -n "$UUID" ]; then
  CUR="$(api "$BASE/api/wafpolicy/$UUID")"
  CRS_REF="$(jq -r '.waf_crs_ref // empty' <<<"$CUR")"
else    # dry run of a policy that would be created: nothing exists yet, read the CRS directly
  CUR='{}'
  CRS_REF="/api/wafcrs?name=$(enc "$WAF_CRS_NAME")"
fi
[ -n "$CRS_REF" ] || die "Policy has no waf_crs_ref"
fetch_crs_groups "$CRS_REF" > "$GROUPS_FILE" || die "Could not read the CRS rule groups"
[ -s "$GROUPS_FILE" ] || die "The policy's CRS version has no rule groups"

# Backup of the policy before any change (0600). Restore with --restore <file>.
BACKUP_FILE=""
if [ -n "$UUID" ] && [ "$DRY_RUN" != "true" ]; then
  mkdir -p "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/waf-backup-$(printf '%s' "$WAF_POLICY_NAME" | tr -c 'A-Za-z0-9_.-' '_')-$(date +%Y%m%d-%H%M%S).json"
  printf '%s\n' "$CUR" > "$BACKUP_FILE"
  $INTERACTIVE && { say "Backup saved: $BACKUP_FILE"; blank; }
fi

jq --slurpfile g "$GROUPS_FILE" \
  --arg gn "$GROUP_NAME" --arg mode "$RULE_MODE" --arg crsmode "$CRS_MODE" --argjson crsonly "$CRS_ONLY" \
  --arg r200 "$R200" --arg r201 "$R201" --arg r202 "$R202" --arg r203 "$R203" '
  def rule($i;$n;$t): {index:$i, name:$n, rule:$t, enable:true, mode:$mode};
  # Step 1 CRS rules, by group: 920170/920180/920370/920380 in CRS_920_Protocol_Validation,
  # 932100-932200 in CRS_932_Application_Attack_RCE, 933100-933190 in CRS_933_Application_Attack_PHP
  def rid: (.rule_id | tonumber? // -1);
  def inscope($g): ($g | ascii_downcase) as $gn | rid as $n
    | ($gn == "crs_920_protocol_validation" and ([920170,920180,920370,920380] | index($n)) != null)
      or ($gn == "crs_932_application_attack_rce" and $n >= 932100 and $n <= 932200)
      or ($gn == "crs_933_application_attack_php" and $n >= 933100 and $n <= 933190);
  . as $pol | $g[0] as $groups
  | ([$groups[] | .name as $gn | .rules[]? | select(inscope($gn)) | rid]) as $have
  | ([920170,920180,920370,920380] | map(select(. as $x | $have | index($x) | not))) as $missing
  | (if ($missing | length) > 0 then error("CRS rules not found in group CRS_920_Protocol_Validation: \($missing|join(","))") else . end)
  | (if ([$have[] | select(. >= 932100 and . <= 932200)] | length) == 0 then error("No rules 932100-932200 found in group CRS_932_Application_Attack_RCE") else . end)
  | (if ([$have[] | select(. >= 933100 and . <= 933190)] | length) == 0 then error("No rules 933100-933190 found in group CRS_933_Application_Attack_PHP") else . end)
  | ([$groups[] | .name as $gn | {name:$gn, ids:[.rules[]? | select(inscope($gn)) | .rule_id]} | select(.ids | length > 0)]) as $targets
  | (($pol.crs_overrides // []) as $ex
      | ($ex | map(select(.name as $n | $targets | map(.name) | index($n) | not)))
        + ($targets | map(. as $t
            | (($ex | map(select(.name == $t.name)) | first) // {name: $t.name}) as $old
            | $old + {enable: true,
                      rule_overrides: ((($old.rule_overrides // []) | map(select(.rule_id as $r | $t.ids | index($r) | not)))
                                       + ($t.ids | map({rule_id: ., enable: true, mode: $crsmode})))}))) as $ov
  | ($pol.pre_crs_groups // [] | map(select(.name != $gn))) as $others
  | {replace: ({crs_overrides: $ov} + (if $crsonly then {} else {pre_crs_groups: ($others + [{
      name:$gn, enable:true, index:($others|length),
      rules:[ rule(0;"php2shell-200-phpsessid-post";$r200),
              rule(1;"php2shell-201-upload-progress-chars";$r201),
              rule(2;"php2shell-202-php-open-tag-filename";$r202),
              rule(3;"php2shell-203-serialized-object-filename";$r203) ]}])} end))}' <<<"$CUR" > "$BODY_FILE"

# Dry run: show the plan and stop
if [ "$DRY_RUN" = "true" ]; then
  if $INTERACTIVE; then blank; hr; say "Dry run: nothing was written to the controller. Planned change:"; hr; blank; fi
  jq . "$BODY_FILE"
  exit 0
fi

# Nothing to do if the policy already matches
if [ "$(jq -S -c '.replace | {c:.crs_overrides} + (if has("pre_crs_groups") then {p:.pre_crs_groups} else {} end)' "$BODY_FILE")" = "$(policy_state <<<"$CUR")" ]; then
  say "The policy already has the Step 1 and Step 2 settings. No change made."
  exit 0
fi

# Refuse to overwrite if somebody else changed the policy since it was read
FRESH="$(api "$BASE/api/wafpolicy/$UUID")"
[ "$(policy_state <<<"$FRESH")" = "$(policy_state <<<"$CUR")" ] \
  || die "The policy was changed by someone else while this script was running. Nothing was written; run it again."

# 5. Patch the policy
$INTERACTIVE && { say "Applying Step 1 and Step 2 to '$WAF_POLICY_NAME'"; blank; }
RESULT="$(api -X PATCH "$BASE/api/wafpolicy/$UUID" --data @"$BODY_FILE")"

# 6. Verify that the controller now reports what was requested
if ! jq -e --slurpfile b "$BODY_FILE" --arg crsmode "$CRS_MODE" --arg gn "$GROUP_NAME" --argjson crsonly "$CRS_ONLY" '
      . as $got
      | ([$b[0].replace.crs_overrides[] | .name as $g | .rule_overrides[]? | select(.mode == $crsmode) | [$g, .rule_id]]) as $need
      | ([($got.crs_overrides // [])[] | .name as $g | .rule_overrides[]? | select(.enable == true and .mode == $crsmode) | [$g, .rule_id]]) as $have
      | ($need | all(. as $x | $have | index([$x]) != null))
        and ($crsonly or ((($got.pre_crs_groups // []) | map(select(.name == $gn)) | first | (.rules // []) | length) == 4))' \
      <<<"$RESULT" >/dev/null; then
  die "Verification failed: the controller does not report every requested Step 1 / Step 2 setting.${BACKUP_FILE:+ Restore with: $0 --restore $BACKUP_FILE}"
fi

jq '{name, uuid, pre_crs_groups: [.pre_crs_groups[]? | {name, rules: [.rules[].name]}],
     crs_overrides: [.crs_overrides[]? | {group: .name, enable, rules: [.rule_overrides[]? | {rule_id, enable, mode}]}]}' <<<"$RESULT"
if $INTERACTIVE; then
  blank; hr
  say "Done and verified. Open WAF policy \"$WAF_POLICY_NAME\" in the Avi UI to check the result."
  [ -n "$BACKUP_FILE" ] && say "Backup of the previous settings: $BACKUP_FILE (restore with --restore)"
  hr; blank
fi
exit 0
