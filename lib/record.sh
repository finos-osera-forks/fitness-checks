#!/usr/bin/env bash
# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Shared by every check action. The actions take no inputs: they read the job environment the fitness workflow sets
# once in its first step (OSERA_TAG, OSERA_REPOSITORY, OSERA_EXPECTED_ORG, OSERA_APPROVED_PRODUCERS, OSERA_ACTOR,
# OSERA_RESULTS_DIR, OSERA_PACK, OSERA_PACK_FILE, OSERA_STANDARDS_DIR, OSERA_LIBRARY, OSERA_OWNER, OSERA_OWNER_ID,
# OSERA_IS_FORK). Only OSERA_TAG and OSERA_REPOSITORY are required, the rest default here.
#
# A check reads like this:
#   check_is <standard> <version> <requirement> <check id or empty>   names the check; one record per requirement
#   expect "<what a pass needs, with the actual values in it>"
#   step "<what is being done>"                             named so that a crash reads as "failed step: <step>"
#   ev <command...>                                         runs the command, keeps the command line (quoted so it can be
#                                                           pasted into a shell), exit code and output as evidence, prints
#                                                           the output, returns the command's exit code
#   given <github context name> <value>                     keeps a value GitHub set in the run context as evidence
#   record <result> "<observed>"                            writes the row and returns failure when a check the pack
#                                                           requires failed, whatever its severity (the gate's rule)
#   extra <id> <result> "<expected>" "<observed>"           a row of ours (CP-...) next to the check's, in extra_checks,
#                                                           severity advisory: a SHOULD of the standard not met while the
#                                                           MUST is; the gate never requires it
#
# expected and observed are facts, every fact "name: value", facts separated by "; ", lists by ", ", a counted list
# "4 (a, b, c, d)", an empty list "none", a field that is not there "absent". No other words.
#
# Two row shapes (Francesco, 30 Oct 2026). A check of the standards, in osera_checks: id, standard, standard_version,
# doc_status, ratified_in, ratified_date, candidate_pack, fitness_role, severity, result, expected, observed, evidence.
# A check of ours, in extra_checks: id, severity, result, expected, observed, evidence. The result is one of three
# words, pass, fail or "not applicable"; nothing else is ever written. The severity is the check's own: observe for a
# check of the pack's observe standards, else what the standard's front matter says (blocking, advisory or observe);
# a check of ours has no standard, so it is advisory. A check that dies before recording is written as fail.

: "${OSERA_TAG:?OSERA_TAG is required}"
: "${OSERA_REPOSITORY:?OSERA_REPOSITORY is required}"
: "${OSERA_EXPECTED_ORG:=finos-osera-forks}"
: "${OSERA_APPROVED_PRODUCERS:=.osera-standards/docs/_data/approved_producers.yml}" # the standards repository at the pack ref, checked out by the workflow
: "${OSERA_ACTOR:=${GITHUB_ACTOR:-}}"
: "${OSERA_PACK:=OSERA-SP-0.1.0}"
: "${OSERA_PACK_FILE:=.osera-standards/docs/catalog/packs/${OSERA_PACK}.json}" # the pack file at the standards ref, names every standard's version
: "${OSERA_STANDARDS_DIR:=.osera-standards/docs/_standards}" # the standards' files at the standards ref, each check's severity in the front matter
: "${OSERA_LIBRARY:=}"
: "${OSERA_REGISTRY_REF:=}"   # <repository>@<commit> of the registry the checks read, set by the workflow
: "${OSERA_RESULTS_DIR:=${RUNNER_TEMP:-.}/osera-results}"
: "${OSERA_OWNER:=}"     # from the run context when the caller is the repository under test, empty otherwise
: "${OSERA_OWNER_ID:=}"
: "${OSERA_IS_FORK:=}"
export OSERA_EXPECTED_ORG OSERA_APPROVED_PRODUCERS OSERA_ACTOR OSERA_PACK OSERA_PACK_FILE OSERA_STANDARDS_DIR OSERA_LIBRARY OSERA_RESULTS_DIR OSERA_REGISTRY_REF
export OSERA_OWNER OSERA_OWNER_ID OSERA_IS_FORK
mkdir -p "$OSERA_RESULTS_DIR"

# derived from the release tag, two forms (OSERA-SP-0.1.0):
#   generic  v2.14.2+osera-patch.001      -> 2.14.2,      2.14.x, v2.14.2+patch.baseline
#   Java     v5.3.39.1-osera-00001        -> 5.3.39,      5.3.x,  v5.3.39+patch.baseline   (REL-003-JAVA: the .N the patch added is dropped)
#   Java     v1.33.1-osera-00001          -> 1.33,        1.33.x, v1.33+patch.baseline     (a two part upstream, the same rule)
#   Java     v5.6.15.Final-osera-00001    -> 5.6.15.Final, 5.6.x, v5.6.15.Final+patch.baseline (qualified base, no .N)
#   npm      v4.1.2-osera-00001           -> 4.1.1,       4.1.x,  v4.1.1+patch.baseline    (REL-003-JAVASCRIPT: the patch number is the baseline's plus one)
# The Java rule is the gate's (REL-003-JAVA.CHECK-001): the shortest base, then an optional .N, then -osera-NNNNN.
# The npm rule is REL-003-JAVASCRIPT's (a Draft for OSERA-SP-0.2.0): "A patch to 1.4.1 is 1.4.2-osera-00001".
# The two forms look alike, so the project decides: a package.json and no pom.xml at the root of the
# patch repository, checked out at the root of the workspace, is an npm project (lab, 22 Oct 2026).
upstream_version_of() {
  local tag="$1"
  local version
  # 1. drop the v prefix
  version="${tag#v}"
  # 2. generic form: everything before the + is the upstream version
  if [[ "$version" == *+osera-patch.* ]]; then
    version="${version%%+*}"
    printf '%s\n' "$version"
    return 0
  fi
  # 3. npm form: the patch number less one, in an npm project only
  if [[ -f package.json && ! -f pom.xml && "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-osera-[0-9]{5}$ ]]; then
    if [[ "${BASH_REMATCH[3]}" -gt 0 ]]; then
      printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$((BASH_REMATCH[3] - 1))"
      return 0
    fi
  fi
  # 4. Java form: drop the -osera-NNNNN suffix
  if [[ "$version" == *-osera-[0-9]* ]]; then
    version="${version%-osera-*}"
    # 5. the .N the patch added, dropped whatever the upstream's number of components (the gate's rule)
    if [[ "$version" =~ ^(.+)\.[0-9]+$ ]]; then
      version="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$version"
    return 0
  fi
  # 6. neither form: the tag as it is, the checks report the mismatch
  printf '%s\n' "$version"
}
VERSION="$(upstream_version_of "$OSERA_TAG")"
LINE="$(printf '%s' "$VERSION" | cut -d. -f1,2).x"
MAJOR="$(printf '%s' "$VERSION" | cut -d. -f1).x"
BASE="v${VERSION}+patch.baseline"
export VERSION LINE MAJOR BASE

EXPECTED=""
STEP=""

# check_is <standard> <standard version the check implements> <requirement> <check id or empty>
# The version is the one the action was written against. At record time it is compared with the version the pack
# names for that standard (the pack file at the standards ref); a difference records the requirement as fail,
# so a check written for an older standard never passes under a newer pack.
check_is() {
  CHECK_STD="$1"
  CHECK_VERSION="$2"
  CHECK_REQ="$3"
  CHECK_ID="$4"
  EVFILE="$OSERA_RESULTS_DIR/.$CHECK_REQ.evidence"
  : > "$EVFILE"
}

# the version the pack names for a standard, from the pack file; empty when the pack file or the standard is missing
pack_version_of() {
  local standard="$1"
  if [ ! -f "$OSERA_PACK_FILE" ]; then
    printf ''
    return 0
  fi
  jq -r --arg s "$standard" '[.standards.included_standards[], .standards.observe_standards[] | select(.id == $s) | .version] | first // ""' "$OSERA_PACK_FILE"
}

# the file of the standards checkout whose front matter carries the given id (a check or a requirement); the files
# are not named by id, so the id line is looked for. Empty when the checkout or the id is not there.
standard_file_of() {
  local id="$1" file=""
  if [ ! -d "$OSERA_STANDARDS_DIR" ]; then
    printf ''
    return 0
  fi
  file="$(grep -l -E "^[[:space:]]*-[[:space:]]+id:[[:space:]]+${id//./\\.}[[:space:]]*$" "$OSERA_STANDARDS_DIR"/*.md 2>/dev/null | head -n 1 || true)"
  printf '%s' "$file"
}

# the file of the standards checkout that is the given standard (its standard_id line). Empty when the checkout or
# the standard is not there.
standard_doc_of() {
  local standard="$1" file=""
  if [ ! -d "$OSERA_STANDARDS_DIR" ]; then
    printf ''
    return 0
  fi
  file="$(grep -l -E "^standard_id:[[:space:]]+${standard}[[:space:]]*$" "$OSERA_STANDARDS_DIR"/*.md 2>/dev/null | head -n 1 || true)"
  printf '%s' "$file"
}

# the status of a standard, five values separated by tabs: doc_status, ratified_in, ratified_date, candidate_pack,
# fitness_role. For a standard the pack includes, the pack is the source: the pack ratified it, at the version the
# pack names, in the role the pack gives it; its file on the standards' main branch may have moved on since
# (REL-001 is a Draft 0.2.0 there while OSERA-SP-0.1.0 ratified 0.1.0). For a standard of the pack's observe
# standards, the values are the front matter of its file at the standards ref. Five empty values when neither says.
status_of() {
  local standard="$1" role="" pack_id="" pack_date="" file=""
  # 1. no pack file: nothing to say
  if [ ! -f "$OSERA_PACK_FILE" ]; then
    printf '\t\t\t\t'
    return 0
  fi
  # 2. a standard the pack includes: ratified in this pack
  role="$(jq -r --arg s "$standard" '[.standards.included_standards[] | select(.id == $s) | .role] | first // ""' "$OSERA_PACK_FILE")"
  if [ -n "$role" ]; then
    pack_id="$(jq -r '.pack.id // ""' "$OSERA_PACK_FILE")"
    pack_date="$(jq -r '.pack.ratified_date // ""' "$OSERA_PACK_FILE")"
    printf 'Ratified\t%s\t%s\t%s ratified\t%s' "$pack_id" "$pack_date" "$pack_id" "$role"
    return 0
  fi
  # 3. an observe standard: its own file at the standards ref
  file="$(standard_doc_of "$standard")"
  if [ -z "$file" ]; then
    printf '\t\t\t\t'
    return 0
  fi
  yq --front-matter=extract -r '[."doc-status", ."ratified-in", ."ratified-date", ."candidate-pack", ."fitness-role"] | map(. // "" | tostring) | join("\t")' "$file"
}

# the severity of a check: observe when the pack lists the check under its observe standards, else the severity the
# standard's front matter gives the check (blocking, advisory or observe); empty when neither names it
severity_of() {
  local id="$1" file=""
  # 1. a check of the pack's observe standards
  if [ -f "$OSERA_PACK_FILE" ]; then
    if jq -e --arg c "$id" '[.standards.observe_standards[].checks[]] | any(.[]; . == $c)' "$OSERA_PACK_FILE" >/dev/null; then
      printf 'observe'
      return 0
    fi
  fi
  # 2. the standard's front matter
  file="$(standard_file_of "$id")"
  if [ -z "$file" ]; then
    printf ''
    return 0
  fi
  ID="$id" yq --front-matter=extract -r '[.requirements[] | .checks[]? | select(.id == env(ID)) | .severity // ""] | .[0] // ""' "$file"
}

# whether the pack requires a check: the check is listed under one of its included standards
pack_requires() {
  local id="$1"
  if [ ! -f "$OSERA_PACK_FILE" ]; then
    return 1
  fi
  jq -e --arg c "$id" '[.standards.included_standards[].checks[]] | any(.[]; . == $c)' "$OSERA_PACK_FILE" >/dev/null
}

# whether a fail of the current check stops the action and makes the run red: the check has an id and the pack
# requires it, or the pack file is not there to say. The severity never decides this: it comes from the standards'
# main branch, which is not pinned, and the gate refuses a failed required check whatever the severity says
# (Francesco, 30 Oct 2026). A check of ours has no check id and is never required.
required_check() {
  if [ -z "$CHECK_ID" ]; then
    return 1
  fi
  if [ ! -f "$OSERA_PACK_FILE" ]; then
    return 0
  fi
  pack_requires "$CHECK_ID"
}

# the check id of a requirement, from the standard's front matter (the first check listed under it). Empty when the
# requirement is not found, and for a check of ours (CP-*), which has no check id: record then names the row by the
# requirement, as the CP-REL-004 actions do.
check_id_of() {
  local req="$1" file=""
  # 1. a check of ours
  case "$req" in
    CP-*)
      printf ''
      return 0
      ;;
  esac
  # 2. the standard's front matter
  file="$(standard_file_of "$req")"
  if [ -z "$file" ]; then
    printf ''
    return 0
  fi
  REQ="$req" yq --front-matter=extract -r '[.requirements[] | select(.id == env(REQ)) | .checks[]? | .id] | .[0] // ""' "$file"
}

expect() {
  EXPECTED="$1"
}

step() {
  STEP="$1"
}

# the command line as it can be pasted into a shell: arguments with special characters in single quotes
quoted() {
  local a q="" s
  for a in "$@"; do
    case "$a" in
      *[!A-Za-z0-9_./:@=+^{}-]*|"")
        s="$(printf '%s' "$a" | sed "s/'/'\\\\''/g")"
        q="$q '$s'"
        ;;
      *)
        q="$q $a"
        ;;
    esac
  done
  printf '%s' "${q# }"
}

ev() {
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  jq -cn --arg command "$(quoted "$@")" --argjson exit "$rc" \
         --arg output "$(printf '%s' "$out" | head -n 40 | head -c 4000)" \
         '{command: $command, exit: $exit, output: $output}' >> "$EVFILE"
  printf '%s\n' "$out"
  return "$rc"
}

given() {
  jq -cn --arg context "$1" --arg value "$2" '{context: $context, value: $value}' >> "$EVFILE"
}

# counted <list, one item per line> [separator]: a counted list, "4 (a, b, c, d)", or "none" when the list is empty.
# The separator is ", " unless the items carry commas themselves, then the caller passes "; "
counted() {
  local list="$1" separator="${2:-, }" n
  list="$(grep -v '^$' <<<"$list" || true)"
  if [ -z "$list" ]; then
    printf 'none'
    return 0
  fi
  n="$(wc -l <<<"$list" | tr -d ' ')"
  printf '%s (%s)' "$n" "$(awk -v sep="$separator" 'NR > 1 {printf "%s", sep} {printf "%s", $0}' <<<"$list")"
}

# listed <list, one item per line>: a plain list, "a, b", or "none" when the list is empty
listed() {
  local list="$1"
  list="$(grep -v '^$' <<<"$list" || true)"
  if [ -z "$list" ]; then
    printf 'none'
    return 0
  fi
  paste -sd, - <<<"$list" | sed 's/,/, /g'
}

# write_osera_row <id> <result> <severity> <expected> <observed> <standard version> <file>: one row of osera_checks,
# with the standard's status fields and the evidence gathered so far
write_osera_row() {
  local id="$1" result="$2" severity="$3" expected="$4" observed="$5" standard_version="$6" file="$7"
  local doc_status ratified_in ratified_date candidate_pack fitness_role
  IFS=$'\t' read -r doc_status ratified_in ratified_date candidate_pack fitness_role <<<"$(status_of "$CHECK_STD")"
  jq -n --arg id "$id" --arg result "$result" --arg severity "$severity" \
        --arg expected "$expected" --arg observed "$observed" --slurpfile evidence "$EVFILE" \
        --arg standard "$CHECK_STD" --arg standard_version "$standard_version" \
        --arg doc_status "${doc_status:-}" --arg ratified_in "${ratified_in:-}" --arg ratified_date "${ratified_date:-}" \
        --arg candidate_pack "${candidate_pack:-}" --arg fitness_role "${fitness_role:-}" \
        '{id: $id,
          standard: $standard,
          standard_version: $standard_version,
          doc_status: (if $doc_status == "" then null else $doc_status end),
          ratified_in: (if $ratified_in == "" then null else $ratified_in end),
          ratified_date: (if $ratified_date == "" then null else $ratified_date end),
          candidate_pack: (if $candidate_pack == "" then null else $candidate_pack end),
          fitness_role: (if $fitness_role == "" then null else $fitness_role end),
          severity: $severity,
          result: $result,
          expected: $expected,
          observed: $observed,
          evidence: $evidence}' > "$file"
}

# write_extra_row <id> <result> <expected> <observed> <file>: one row of extra_checks, a check of ours, severity
# advisory, with the evidence gathered so far
write_extra_row() {
  local id="$1" result="$2" expected="$3" observed="$4" file="$5"
  jq -n --arg id "$id" --arg result "$result" \
        --arg expected "$expected" --arg observed "$observed" --slurpfile evidence "$EVFILE" \
        '{id: $id,
          severity: "advisory",
          result: $result,
          expected: $expected,
          observed: $observed,
          evidence: $evidence}' > "$file"
}

# extra <id> <result> "<expected>" "<observed>": a row of ours next to the check's, in extra_checks, severity
# advisory. For a SHOULD of the standard that is not met while the MUST is (CP-NOTE-001, CP-NOTE-002, CP-NOTE-003):
# the check passes, the extra row says what the standard says should be otherwise, and the release is promoted
# (Francesco, 30 Oct 2026). The gate requires no CP- id, so it never blocks.
extra() {
  local id="$1" result="$2" expected="$3" observed="$4"
  write_extra_row "$id" "$result" "$expected" "$observed" "$OSERA_RESULTS_DIR/$id.json"
  echo "$id $result (advisory): $observed"
}

# record <result> "<observed>": the check's row. The result is pass, fail or "not applicable"; the severity is looked
# up here, for display. Returns failure for a fail of a check the pack requires (required_check), whatever the
# severity, so the action stops there under set -e and the step is red exactly when the gate would refuse; a fail of
# a check of ours, an advisory or an observe check returns success and the action goes on.
record() {
  local result="$1" observed="$2" pack_version id severity file
  # 1. only the three words of the row shape
  case "$result" in
    pass|fail|"not applicable")
      ;;
    *)
      echo "record: the result must be pass, fail or \"not applicable\", not \"$result\""
      return 2
      ;;
  esac
  # 1b. a fail already recorded for this requirement stands: a later record never overwrites it (a safety net under
  #     the actions, which stop or exit after a fail themselves)
  file="$OSERA_RESULTS_DIR/$CHECK_REQ.json"
  if [ -f "$file" ] && [ "$(jq -r .result "$file")" = fail ]; then
    echo "$CHECK_REQ keeps its fail row, not overwritten by $result: $observed"
    if required_check; then
      return 1
    fi
    return 0
  fi
  # 2. the version the pack names for this standard, against the version this check implements: a difference is a
  #    fail, and observed says both versions
  pack_version="$(pack_version_of "$CHECK_STD")"
  if [ -z "$pack_version" ]; then
    result=fail
    observed="$observed; check version: $CHECK_VERSION; pack version: absent"
    pack_version="$CHECK_VERSION"
  elif [ "$pack_version" != "$CHECK_VERSION" ]; then
    result=fail
    observed="$observed; check version: $CHECK_VERSION; pack version: $pack_version"
  fi
  # 3. a check of ours (no check id): a row of extra_checks, named by the requirement, severity advisory
  if [ -z "$CHECK_ID" ]; then
    write_extra_row "$CHECK_REQ" "$result" "$EXPECTED" "$observed" "$file"
    echo "$CHECK_REQ $result (advisory): $observed"
    return 0
  fi
  # 4. the severity: the check's own; when none is found the log says so, and a check the pack requires is taken
  #    as blocking
  id="$CHECK_ID"
  severity="$(severity_of "$CHECK_ID")"
  if [ -z "$severity" ]; then
    if pack_requires "$CHECK_ID"; then
      severity=blocking
    else
      severity=advisory
    fi
    echo "no severity found for $CHECK_ID in $OSERA_STANDARDS_DIR nor in the observe standards of $OSERA_PACK_FILE, taken as $severity"
  fi
  # 5. the row
  write_osera_row "$id" "$result" "$severity" "$EXPECTED" "$observed" "$pack_version" "$file"
  echo "$CHECK_REQ $result ($severity): $observed"
  # 6. the return: a failed required check stops the action; the severity is not read here
  if [ "$result" = fail ] && required_check; then
    return 1
  fi
  return 0
}

# If the check dies before recording (a git failure, a missing file), the requirement is recorded as fail
# with the step that failed and the evidence gathered so far, so it never silently disappears from the result.
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "${CHECK_REQ:-}" ] && [ ! -f "$OSERA_RESULTS_DIR/$CHECK_REQ.json" ]; then
    record fail "failed step: ${STEP:-the check}" || true
  fi
}
trap on_exit EXIT
