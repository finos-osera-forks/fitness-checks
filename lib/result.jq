# Copyright (c) 2026 Control Plane Limited. All rights reserved.
# Built by ControlPlane for the FINOS OSERA Exchange.
# SPDX-License-Identifier: Apache-2.0
#
# Builds result.json from the per requirement records (jq -s: the input is the array of all records).
# Arguments: $pack $pack_checksum $repo $release $commit $producer $library $registry_ref $evidence_sha $rehearsal
#            $registry_entry (JSON: the producer's staging_account and github_users copied from the registry, or null) $tag_actor
#            $required (JSON: the check ids of the pack's included_standards, the checks the gate refuses on)
#            $included (JSON: the standard ids of the pack's included_standards, the standards summarised in standards)
#            $standards_order (JSON: the standard ids of the pack, included_standards then observe_standards, in the
#            pack's order; the rows of osera_checks are sorted by it, then by id).

# The schema of the result: two sections of rows, osera_checks (the checks of the standards) and extra_checks (the
# checks of ours, CP-...), every row with expected and observed (Francesco, 30 Oct 2026). The gate reads this schema.
def schema:
  "https://osera.finos.org/fitness-result/0.3.0";

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

# the place of a standard in the pack's order; a standard the pack does not name goes last
def standard_rank:
  . as $standard
  | ($standards_order | index([$standard])) // ($standards_order | length);

# the checks of the standards, in the pack's order then by id, and the checks of ours, by id: only osera_checks
# counts in the rollup, so a check of ours never changes the result
(map(select(.id | startswith("CP-") | not)) | sort_by([(.standard | standard_rank), .id])) as $osera_checks
| (map(select(.id | startswith("CP-"))) | sort_by(.id)) as $extra_checks

# one result per standard the pack includes, the fitness page's view; the observe standards are run and reported
# in osera_checks, and never summarised as a standard that passed
| ($osera_checks | map(select(.standard | IN($included[]))) | group_by(.standard) | map({standard: .[0].standard, standard_version: .[0].standard_version, result: rollup})) as $standards

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
    result: ($osera_checks | rollup),
    signature: (if $rehearsal == "true" then "rehearsal, not signed: the gate never accepts this result" else "see the GitHub artifact attestation on this file" end),
    standards: $standards,
    osera_checks: $osera_checks,
    extra_checks: $extra_checks
  }
