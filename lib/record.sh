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
#   expect "<the rule in words, with the actual values in it>" what a pass needs
#   step "<what is being done>"                             named so that a crash reads as "could not run: <step> failed"
#   ev <command...>                                         runs the command, keeps the command line (quoted so it can be
#                                                           pasted into a shell), exit code and output as evidence, prints
#                                                           the output, returns the command's exit code
#   given <github context name> <value>                     keeps a value GitHub set in the run context as evidence
#   note "<what the standard says should be otherwise>"     a second row, <check id>.NOTE, fail advisory: a SHOULD of the
#                                                           standard not met while the MUST is; the gate never requires it
#   record <result> "<reason>"                              writes the row and returns failure when a check the pack
#                                                           requires failed, whatever its severity (the gate's rule)
#
# The row is the gate's shape (the verdict's checks rows): id, result, severity, reason, expected, evidence, and the
# standard, standard_version, check_version and requirement the gate compares with the pack. The result is one of three
# words, pass, fail or "not applicable"; nothing else is ever written. The severity is the check's own: observe for a
# check of the pack's observe standards, else what the standard's front matter says (blocking, advisory or observe);
# a proposal has no standard, so it is advisory. A check that dies before recording is written as fail.

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
# (Francesco, 30 Oct 2026). A proposal has no check id and is never required.
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
# requirement is not found, and for a proposal (CP-*), which has no check id: record then names the row by the
# requirement, as the proposal actions do.
check_id_of() {
  local req="$1" file=""
  # 1. a proposal
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

# write_row <id> <result> <severity> <reason> <standard version> <file>: one row in the gate's shape, with the
# expected text and the evidence gathered so far
write_row() {
  local id="$1" result="$2" severity="$3" reason="$4" standard_version="$5" file="$6"
  jq -n --arg id "$id" --arg result "$result" --arg severity "$severity" --arg reason "$reason" \
        --arg expected "$EXPECTED" --slurpfile evidence "$EVFILE" \
        --arg standard "$CHECK_STD" --arg standard_version "$standard_version" --arg check_version "$CHECK_VERSION" \
        --arg requirement "$CHECK_REQ" \
        '{id: $id, result: $result, severity: $severity, reason: $reason,
          expected: $expected, evidence: $evidence,
          standard: $standard, standard_version: $standard_version, check_version: $check_version,
          requirement: $requirement}' > "$file"
}

# note "<reason>": a second row next to the check's, id <check id>.NOTE, result fail, severity advisory. For a SHOULD
# of the standard that is not met while the MUST is: the check passes, the note says what should be otherwise, and
# the release is promoted (Francesco, 30 Oct 2026). The gate requires no .NOTE id, so it never blocks.
note() {
  local reason="$1" pack_version
  pack_version="$(pack_version_of "$CHECK_STD")"
  if [ -z "$pack_version" ]; then
    pack_version="$CHECK_VERSION"
  fi
  write_row "$CHECK_ID.NOTE" fail advisory "$reason" "$pack_version" "$OSERA_RESULTS_DIR/$CHECK_REQ.note.json"
  echo "$CHECK_REQ note (fail advisory): $reason"
}

# record <result> "<reason>": the check's row. The result is pass, fail or "not applicable"; the severity is looked
# up here, for display. Returns failure for a fail of a check the pack requires (required_check), whatever the
# severity, so the action stops there under set -e and the step is red exactly when the gate would refuse; a fail of
# a proposal, an advisory or an observe check returns success and the action goes on.
record() {
  local result="$1" reason="$2" pack_version id severity file
  # 1. only the three words of the gate's shape
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
    echo "$CHECK_REQ keeps its fail row, not overwritten by $result: $reason"
    if required_check; then
      return 1
    fi
    return 0
  fi
  # 2. the version the pack names for this standard, against the version this check implements
  pack_version="$(pack_version_of "$CHECK_STD")"
  if [ -z "$pack_version" ]; then
    result=fail
    reason="the pack file $OSERA_PACK_FILE does not name $CHECK_STD, the check (written for $CHECK_STD $CHECK_VERSION) was not counted"
    pack_version="$CHECK_VERSION"
  elif [ "$pack_version" != "$CHECK_VERSION" ]; then
    result=fail
    reason="the check implements $CHECK_STD $CHECK_VERSION, the pack $OSERA_PACK names $CHECK_STD $pack_version, the check was not counted"
  fi
  # 3. the id: the check's, or the requirement's for a proposal, which has no check id
  id="$CHECK_ID"
  if [ -z "$id" ]; then
    id="$CHECK_REQ"
  fi
  # 4. the severity: advisory for a proposal (no standard, and a check we invented is advisory); the check's own
  #    otherwise; when none is found the reason says so, and a check the pack requires is taken as blocking
  if [ -z "$CHECK_ID" ]; then
    severity=advisory
  else
    severity="$(severity_of "$CHECK_ID")"
    if [ -z "$severity" ]; then
      if pack_requires "$CHECK_ID"; then
        severity=blocking
      else
        severity=advisory
      fi
      reason="$reason; no severity found for $CHECK_ID in $OSERA_STANDARDS_DIR nor in the observe standards of $OSERA_PACK_FILE, taken as $severity"
    fi
  fi
  # 5. the row
  write_row "$id" "$result" "$severity" "$reason" "$pack_version" "$file"
  echo "$CHECK_REQ $result ($severity): $reason"
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
    record fail "could not run: ${STEP:-the check} failed" || true
  fi
}
trap on_exit EXIT
