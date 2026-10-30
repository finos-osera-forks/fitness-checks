# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Builds result.json from the per requirement records (jq -s: the input is the array of all records).
# Arguments: $pack $pack_checksum $repo $release $commit $producer $library $registry_ref $evidence_sha $rehearsal
#            $registry_entry (JSON: the producer's staging_account and github_users copied from the registry, or null) $tag_actor
#            $observe (JSON: the requirement ids of the pack's observe_standards)
#            $required (JSON: the check ids of the pack's included_standards, the checks the gate refuses on).

# The schema of the result: the rows are in the gate's shape (id, result, severity, reason). The gate reads this
# schema, and a result without one in the library's first shape.
def schema:
  "https://osera.finos.org/fitness-result/0.2.0";

# The one rollup, used per standard and at the top: fail when any row failed that the pack requires (the gate
# refuses it, whatever its severity) or that carries severity blocking, else pass; "not applicable" only when every
# row is. The gate does not read it: it reads the rows against its own pack list; this rule keeps CI and the gate
# in agreement.
def rollup:
  if any(.[]; .result == "fail" and ((.id | IN($required[])) or .severity == "blocking")) then
    "fail"
  elif all(.[]; .result == "not applicable") then
    "not applicable"
  else
    "pass"
  end;

# the requirements of the pack (with their .NOTE rows), the ControlPlane proposals (CP-*) and the observe checks,
# kept apart: only $checks counts in the rollup, and the gate reads only checks, so a proposal or an observe check
# never changes the result
(map(select((.requirement | startswith("CP-") | not) and (.requirement | IN($observe[]) | not)))) as $checks
| (map(select(.requirement | startswith("CP-")))) as $proposals
| (map(select(.requirement | IN($observe[])))) as $observe_checks

# one result per standard, the fitness page's view
| ($checks | group_by(.standard) | map({standard: .[0].standard, standard_version: .[0].standard_version, result: rollup})) as $standards

| {
    schema: schema,
    standard_pack: $pack,
    pack_checksum: (if $pack_checksum == "" then null else $pack_checksum end),
    registry_ref: (if $registry_ref == "" then null else $registry_ref end),
    repository: $repo,
    release: $release,
    commit: $commit,
    artifact_digest: null,
    evidence_file: (if $evidence_sha == "" then null else {path: ".osera/patch-evidence.yaml", artifact: "patch-evidence.yaml", digest: $evidence_sha} end),
    library: (if $library == "" then null else $library end),
    producer: (if $producer == "" then null else $producer end),
    # the fitness page's producer_accounts (REL-004.REQ-002): the registry entry copied, what the run observed;
    # the upload account is the gate's to fill, null here
    producer_accounts: {
      registry: $registry_entry,
      observed: {
        tag_actor: (if $tag_actor == "" then null else $tag_actor end),
        upload_account: null
      }
    },
    result: ($checks | rollup),
    signature: (if $rehearsal == "true" then "rehearsal, not signed: the gate never accepts this result" else "see the GitHub artifact attestation on this file" end),
    standards: $standards,
    checks: $checks,
    proposals: $proposals,
    # the pack's observe_standards: run and reported, never in the rollup (the fitness page: observe checks do not block)
    observe: $observe_checks
  }
