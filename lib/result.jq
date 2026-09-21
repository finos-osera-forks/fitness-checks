# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Builds result.json from the per requirement records (jq -s: the input is the array of all records).
# Arguments: $pack $pack_checksum $repo $release $commit $producer $library $registry_ref $evidence_sha $rehearsal
#            $registry_entry (JSON: the producer's staging_account and github_users copied from the registry, or null) $tag_actor.

# The one rollup, used per standard and at the top: any fail is a fail, then warn, then not-tested, then pass;
# not-applicable only when everything underneath is.
def rollup:
  map(.status) as $s
  | if   any($s[]; . == "fail") then "fail"
    elif any($s[]; . == "warn" or . == "manual-evidence-required") then "warn"
    elif any($s[]; . == "not-tested") then "not-tested"
    elif any($s[]; . == "pass") then "pass"
    else "not-applicable" end;

# the requirements of the pack, and the ControlPlane proposals (CP-*), kept apart
(map(select(.requirement | startswith("CP-") | not))) as $checks
| (map(select(.requirement | startswith("CP-")))) as $proposals

# one status per standard, the fitness page's view
| ($checks | group_by(.standard) | map({standard: .[0].standard, standard_version: .[0].standard_version, status: rollup})) as $standards

| {
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
    result: ($standards | rollup),
    signature: (if $rehearsal == "true" then "rehearsal, not signed: the gate never accepts this result" else "see the GitHub artifact attestation on this file" end),
    standards: $standards,
    checks: $checks,
    proposals: $proposals
  }
