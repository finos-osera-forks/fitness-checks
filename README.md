# fitness-checks

[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![lint](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/lint.yaml/badge.svg)](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/lint.yaml)
[![e2e](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/e2e.yaml/badge.svg)](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/e2e.yaml)

This repository contains the reusable GitHub Workflow and the Composite Actions that run the source side
fitness checks of the [OSERA Remediation Standards](https://standards.osera.finos.org/) on a patch repository
at a release tag. One action per requirement of the standards pack, plain bash with git, jq and yq, one signed result.

The library lives in the `finos-osera-forks` organisation next to the patch repositories. The organisation the checks expect a patch repository in, and the `uses:` owner in the caller, follow the library's home.

## The standard version a check implements

Every check action declares the version of the standard it was written against, twice in the same words: in its `description` (`FORK-001.REQ-001 (FORK-001 0.1.0): ...`) and in its `check_is` line (`check_is FORK-001 0.1.0 FORK-001.REQ-001 FORK-001.CHECK-001`). At run time the recorder reads the pack file at `STANDARDS_REF` (`docs/catalog/packs/<pack>.json`, which names every included standard with its version) and compares: equal, the row says `standard_version`; different, the row is `fail` and `observed` ends with `check version: <the check's>; pack version: <the pack's>`, the roll up is not a pass, and the gate refuses. Before a release the lint job makes the same comparison for every action, so a library release cannot move `STANDARDS_REF` to a pack whose standards changed without the actions changing with it. The result also carries `pack_checksum`, the digest of that pack file. A new pack whose standards changed is a new major of this library; a pack patch that changes no check is a patch release that moves `STANDARDS_REF` and nothing else.

## A rehearsal before the release tag

A producer can run every check on a branch or commit before pushing the release tag: in the patch repository, Actions, "OSERA fitness checks", Run workflow, choose the branch, type the tag you intend to push. The workflow checks that commit as if the tag pointed at it (the tag is created locally in the runner, never pushed), prints the result and uploads it as an artifact, and signs nothing: the result says `rehearsal, not signed`, no attestation exists, so the gate can never accept it. A red rehearsal costs nothing. The real release is the tag push, unchanged.

## Workflows

### Fitness checks on a release tag

The [fitness](.github/workflows/fitness.yaml) workflow checks a patch repository at a release tag by performing the following steps:

- Checks out the patch repository at the tag, with every branch and tag, and this library next to it.
- Runs one action per requirement of OSERA-SP-0.1.0 that can be checked on the source (table below). Each writes one record.
- Runs our own checks on the producer (CP-REL-004-01 to 03), whose rows are advisory and never fail the run.
- Runs the observe checks, one action per requirement of the pack's `observe_standards` (table below). They report in `osera_checks` with severity `observe`; the pack requires none of them, so they never change the result nor fail the run.
- Writes `result.json` with the [fitness page](https://standards.osera.finos.org/fitness/)'s fields: the rows of the standards' checks in `osera_checks` and the rows of our own checks in `extra_checks`, every row with `expected`, `observed` and the commands and outputs that showed it, one result per standard the pack includes. Records are written outside the checkout, so nothing a producer commits can pre fill them.
- Attests `result.json` with GitHub Attestations: an in-toto statement, predicate type `https://osera.finos.org/fitness-result/v1`, signed with the workflow's OIDC identity through Sigstore, stored by GitHub with the repository.
- Attests the same result a second time under a subject the gate can compute from the tag alone: the SHA256 of the tagged commit id (subject name `git:<owner>/<repo>@<commit>`). The gate gets the commit for the tag from GitHub, hashes it, fetches the attestation by that digest, verifies signer, source and commit, and reads the result from the predicate. Nothing from the producer, no run to pick, no artifact retention.
- Uploads `result.json`, the Sigstore bundle and the producer's evidence file (`patch-evidence.yaml`, a copy of `.osera/patch-evidence.yaml` at the tag) as a workflow artifact. The result names the evidence file by its SHA256 (`evidence_file.digest`), so the signature on the result covers it: the gate takes the evidence from this artifact, checks the digest, publishes it next to the promoted jar, and refuses a release whose result names none.
- Fails the run when the result is `fail`: a check the pack requires failed or could not run, or a blocking check failed. An advisory or observe row that failed, and every row of `extra_checks`, leaves the run green.

Example usage, the file a patch repository carries on its patch branch ([template](templates/osera-fitness.yaml)):

```yaml
name: OSERA fitness checks
run-name: OSERA fitness checks on ${{ github.ref_name }}
on:
  push:
    tags:
      - 'v*-osera-*'
      - 'v*\+osera-patch.*'
permissions:
  contents: read # for checking out the repository.
  id-token: write # for creating OIDC tokens for signing.
  attestations: write # for GitHub Attestations.
jobs:
  fitness:
    uses: finos-osera-forks/fitness-checks/.github/workflows/fitness.yaml@v1
    with:
      tag: ${{ github.ref_name }}
```

Inputs:

- `tag` (string, required): the release tag under test, for example `v5.3.39.1-osera-00001` (Java, the CARE style form of REL-003-JAVA) or `v2.14.2+osera-patch.001` (the generic form). The upstream version, the line and the baseline tag are derived from either form (`lib/record.sh`).
- `reference` (string, ignored unless the caller is the library itself): which reference repository the library's own e2e checks.

Nothing else: the organisation FORK-001 expects, the library version the actions run from and the repository under test are fixed in the workflow file or derived from the run itself, never taken from the caller.

Outputs:

- `result`: `pass` or `fail`; `not applicable` when every check is.

3rd-party actions used:

- [actions/checkout](https://github.com/actions/checkout)
- [actions/attest](https://github.com/actions/attest)
- [actions/upload-artifact](https://github.com/actions/upload-artifact)

Verify a result: `gh attestation verify result.json --repo <patch repo> --signer-repo <this repo> --predicate-type https://osera.finos.org/fitness-result/v1`.

## Versioning

Callers pin the moving major tag, `@v1`. Releases are exact tags (`v1.0.0`, `v1.0.1`, `v1.1.0`) and `v1` is moved to the latest of them only after the e2e workflow is green, so a producer's repository never changes and still receives fixes. A change to the shape of `result.json` stays on `v1` too: only the gate and `oseractl` read the file, and both are deployed to read the new shape before `v1` moves, so every producer gets the new shape on its next release with no change on its side (Francesco, 30 Oct 2026). Every result records the exact library commit that produced it, which is what the gate checks.

## Actions

One composite action per requirement, under [`.github/actions`](.github/actions). Bash only: git for the repository, yq for the evidence file and the approved producers file, jq for the record.

| Action | Requirement | What it checks |
|---|---|---|
| `fork-001-req-001` | FORK-001.REQ-001 | repository in the expected organisation |
| `fork-001-req-002` | FORK-001.REQ-002 | repository name `patch-<name>`; the fork parent is recorded, an artifact name is left to the gate, which names the fork from the pom and the declaration; a name that includes `osera` passes with a `CP-NOTE-001` row |
| `fork-002-req-001` | FORK-002.REQ-001 | a `patch/<version>`, `patch/<major.minor>.x` or `patch/<major>.x` branch exists and contains the release tag |
| `fork-003-req-001` | FORK-003.REQ-001 | `v<VERSION>+patch.baseline` exists and points strictly before the release tag on the same history; an evidence file naming another baseline passes with a `CP-NOTE-002` row |
| `src-002-req-001` | SRC-002.REQ-001 | every fix in `.osera/patch-evidence.yaml` links an upstream commit, pull request, advisory or release note; a fix naming no CVE passes with a `CP-NOTE-003` row |
| `src-002-req-002` | SRC-002.REQ-002 (SHOULD, advisory) | commits naming an upstream commit carry a `Co-authored-by` trailer, not applicable when none does; a fail is advisory and never blocks |
| `src-003-req-001` | SRC-003.REQ-001 | new source or test files since the baseline carry the header of the nearest same type file (years, whitespace and asterisks ignored), not applicable when no convention exists |
| `rel-001-req-001` | REL-001.REQ-001 | test provenance recorded in the evidence file: the tested commit, command, runtime, report name, passing result. The release tag may sit after the tested commit only if the commits in between touch nothing but the evidence file and the caller workflow |
| `write-result` | | `result.json` |

Our own checks on the producer, not requirements on the site, put to the working group on [remediation-standards #52](https://github.com/finos-osera/remediation-standards/issues/52). Their rows sit in `extra_checks` and are advisory (a check we invented is advisory, whatever it finds), so they never fail the run:

| Action | Id in the result | What it checks |
|---|---|---|
| `proposal-rel-004-producer-named` | CP-REL-004-01 | the evidence file has a producer line |
| `proposal-rel-004-producer-approved` | CP-REL-004-02 | that producer is in the approved producer registry of the standards repository (`docs/_data/approved_producers.yml`, REL-004), checked out at `STANDARDS_REF` and recorded in the result as `registry_ref` |
| `proposal-rel-004-accounts-in-entry` | CP-REL-004-03 | the account that pushed the tag and the accounts on the commits between the baseline tag and the release tag are all in that entry's `github_users` |

Observe checks, the pack's `observe_standards` (fitness page: observe checks run during the gate, collect data for OSERA-SP-0.2.0 and do not block). Each records in `osera_checks` with severity `observe`, carries the status of its standard as the standard's own file says it (Pre-Draft, not ratified), and never fails the run. Where the standard defines no field or format yet, the row says which fields the evidence file has and which are absent, and the check passes when the fields its `expected` names are there, the values not judged; where a check looks for a field the standard does not name, the action's comment says so.

| Action | Requirement | What it checks |
|---|---|---|
| `fork-004-req-001` | FORK-004.REQ-001 | the release tag can be read from `https://github.com/<repository>.git` without credentials and names the checked out commit |
| `fork-004-req-002` | FORK-004.REQ-002 | every licence and notice file at the baseline tag (LICENSE, LICENCE, NOTICE, COPYING, COPYRIGHT, any directory) is unchanged at the release tag; not applicable when the baseline has none |
| `fork-004-req-003` | FORK-004.REQ-003 | the repository is in the expected organisation and is a GitHub fork; the parent is recorded, which upstream is the appropriate one is not defined yet |
| `src-001-req-001` | SRC-001.REQ-001 | a patch basis per fix (`fixes[].basis`, else the release's `patch.basis.type`); pass when every fix has one, the value is not judged |
| `rel-006-req-001` | REL-006.REQ-001 | an authorization record: pass when `backlog_item` or `sponsor_record` is there, the value is not judged |
| `rel-008-req-001` | REL-008.REQ-001 | build security scan evidence: pass when `build_security_scan_tool`, `scan_scope` and `scan_result` are all there, a fail names the absent ones |
| `rel-008-req-002` | REL-008.REQ-002 | finding disposition: pass when `unresolved_findings` and `finding_disposition` are there, or `not_applicable_rationale` is |
| `evd-001-req-001` | EVD-001.REQ-001 | `recipient_guidance` (or `patch.recipient_guidance`) valid against the standards repository's `docs/schemas/osera-recipient-guidance-0.1.0.schema.json` ([`lib/schema.jq`](lib/schema.jq)) |
| `app-001-req-001` | APP-001.REQ-001 | fail: it reads the feed and the recipient's estate, neither is in the patch repository |

REL-007 (REL-007.REQ-001 and REL-007.REQ-002, build provenance and signed attestation) is checked by the gate at promotion, not here: it is about the digest of the artifact, which is built and uploaded after this run.

Actions take no inputs: the workflow sets the `OSERA_*` environment once and every action reads it. Each sources [`lib/record.sh`](lib/record.sh) and reads the same way: `check_is` names the requirement, `expect` states what a pass needs with the actual values in it, `step` names what is being done, `ev` runs a command and keeps its command line (quoted so it can be pasted into a shell), exit code and output as evidence, `given` keeps a value GitHub set in the run context (owner, owner id, fork flag), `extra` writes a row of ours (`CP-NOTE-001`, `CP-NOTE-002`, `CP-NOTE-003`; fail, advisory) for a SHOULD of the standard that is not met while the MUST is, `record` writes the row: the result and what was observed. A check that dies before recording is written as `fail` with `failed step: <step>` and the evidence gathered so far. The artifact side checks (REL-002 bytecode level, REL-003 version pattern, REL-004 at the upload and at publication, REL-005 files and checksums, FEED-001) belong to the gate and are not here.

## The result

`result.json` names its schema, `https://osera.finos.org/fitness-result/0.3.0`, and keeps the fitness page's fields. The rows sit in two sections. `osera_checks` holds every check of the standards, the pack's required checks and its observe checks alike: `id`, `standard`, `standard_version`, `doc_status`, `ratified_in`, `ratified_date`, `candidate_pack`, `fitness_role`, `severity`, `result`, `expected`, `observed`, `evidence`. `extra_checks` holds every check of ours, the `CP-` rows: `id`, `severity`, `result`, `expected`, `observed`, `evidence`. `standards` has one result per standard the pack includes:

```json
{
  "schema": "https://osera.finos.org/fitness-result/0.3.0",
  "standard_pack": "OSERA-SP-0.1.0", "pack_checksum": "sha256:...",
  "repository": "finos-osera-forks/patch-jetty.project", "release": "v9.4.58.v20250814-osera-00012", "commit": "723f6586...",
  "artifact_digest": null, "library": "finos-osera-forks/fitness-checks@...", "producer": "moderne",
  "producer_accounts": {"registry": {"staging_account": "moderne-deploy", "github_users": ["jkschneider", "pstreef"]}, "observed": {"tag_actor": "pstreef", "upload_account": null}},
  "result": "pass",
  "signature": "see the GitHub artifact attestation on this file",
  "standards": [{"standard": "FORK-003", "standard_version": "0.1.0", "result": "pass"}],
  "osera_checks": [{
    "id": "FORK-003.CHECK-001", "standard": "FORK-003", "standard_version": "0.1.0",
    "doc_status": "Ratified", "ratified_in": "OSERA-SP-0.1.0", "ratified_date": "2026-09-10", "candidate_pack": "OSERA-SP-0.1.0 ratified", "fitness_role": "Required check",
    "severity": "blocking", "result": "pass",
    "expected": "tag v9.4.58.v20250814+patch.baseline at a commit before v9.4.58.v20250814-osera-00012",
    "observed": "baseline tag: v9.4.58.v20250814+patch.baseline; baseline commit: 8f144058...; release tag: v9.4.58.v20250814-osera-00012; release commit: 723f6586...; commits between: 26",
    "evidence": [{"command": "git tag --list v9.4.58.v20250814+patch.baseline '*baseline*'", "exit": 0, "output": "v9.4.58.v20250814+patch.baseline"}]
  }],
  "extra_checks": [{
    "id": "CP-REL-004-02", "severity": "advisory", "result": "pass",
    "expected": "moderne is in the approved producers file", "observed": "entries: 1; moderne: present", "evidence": []
  }]
}
```

`expected` is what a pass needs, with the actual values in it. `observed` is what the repository showed, as facts: every fact is `name: value`, facts are separated by `; `, lists by `, `, a counted list is `4 (a, b, c, d)`, an empty list is `none`, a field that is not there is `absent`; how many are present, how many meet the rule, the list that meet it and the list that do not, and no other words. A pass and a fail take the same form: a failing REL-001.CHECK-001 ends with `result: fail`, `files changed after the tested commit: 2 (a, b)`, `commit in the repository: no` or `tested commit on the release history: no`, so the row names which condition it missed. A check that died before recording says `failed step: <step>`; a check whose action did not run says `failed step: the action did not run`. `evidence` is the commands that showed it with their real output (first 40 lines).

The status fields of an `osera_checks` row come from the pack, not from the standards' main branch, which moves on: for a standard the pack includes, `doc_status` is `Ratified`, `ratified_in` the pack id, `ratified_date` the pack's, `fitness_role` the role the pack gives it, `standard_version` the version the pack names and `candidate_pack` `<pack id> ratified` (REL-001 is a Draft 0.2.0 on main while OSERA-SP-0.1.0 ratified 0.1.0, and the row says Ratified 0.1.0). For a standard of the pack's `observe_standards`, the five values are the front matter of its file at `STANDARDS_REF` (Pre-Draft, not ratified, `OSERA-SP-0.2.0 observe`, `Observe-only check`).

The severity is the check's own, read at run time: `observe` for a check of the pack's `observe_standards`, else the `severity` the standard's front matter gives the check (`docs/_standards/*.md` at `STANDARDS_REF`, found by the check's `id:` line); every check of ours is `advisory`. When neither names it, the log says so and a check the pack requires is taken as `blocking`. A SHOULD of the standard not met inside a passing check (a name that includes `osera`, an evidence file naming another baseline, a fix naming no CVE) is a row of ours in `extra_checks`, `CP-NOTE-001`, `CP-NOTE-002` or `CP-NOTE-003`, `fail` and `advisory`, written only when the SHOULD is not met: the gate requires no `CP-` id, so the release is promoted and the row stays on record. `producer_accounts` is the fitness page's REL-004.REQ-002 block: `registry` is the producer's `staging_account` and `github_users` copied from the registry entry (null when the producer has no entry, CP-REL-004-02 says so), `observed.tag_actor` the GitHub account that pushed the release tag (`github.actor` of the push event that started the run), `observed.upload_account` null here, the gate fills it at upload time. One rollup everywhere: `fail` when any row of `osera_checks` failed that the pack requires (a check id under the pack's `included_standards`) or that carries severity `blocking`, else `pass`; `not applicable` only when every row is. The rows of `extra_checks` never change it. The gate does not read the rollup: it reads the rows against its own list of the pack's checks, and a failed required check always refuses, whatever its severity. `record` returns failure, and the run goes red, by that same pack list and never by the severity, so CI and the gate agree; the severity is for display only, and a requirement that already has a fail row is never overwritten by a later record. The rows of `osera_checks` follow the pack's order of standards (included, then observe), then the check id; `extra_checks` is by id. The signed copy lives in GitHub's attestation store for the patch repository (and, for a public repository, in Sigstore's transparency log), under two subjects: the digest of `result.json`, for `gh attestation verify result.json`, and the SHA256 of the tagged commit id, for the gate. The gate fetches and verifies it at upload time and keeps it with the artifact. To find it by hand: `printf '%s' <commit> | sha256sum`, then `gh api repos/<owner>/<repo>/attestations/sha256:<digest>`.

## Testing

- [lint](.github/workflows/lint.yaml): actionlint (release binary, checksum pinned) on the workflows, shellcheck on every action's bash.
- [e2e](.github/workflows/e2e.yaml): runs the fitness workflow itself against two reference repositories in the dev organisation at their release tags (the workflow honours the `reference` input only when its caller is the library), forks of libraries far from any line OSERA carries: the known good `patch-jfiglet`, laid out the way the standard asks, and the known bad `patch-emoji-java`, one mistake per blocking check (the release tag on no `patch/` branch, the baseline at the release commit, a fix with no upstream link, no test record), each compared, row by row (`id`, `result`, `severity`, the rows of `osera_checks` then `extra_checks`), with its expected list under [`e2e/`](e2e/). A check that cannot run at all records `fail` with `failed step: <step>` rather than disappearing from the result.

## Notes

- In GitHub tag filters `+` is a special character: the generic pattern must be written `v*\+osera-patch.*`, otherwise the workflow never parses. The Java form needs no escaping: `v*-osera-*`.
- Because the caller file lives on the patch branch and not on the repository's default branch, the Actions tab lists it under its path; `run-name` titles every run by the tag.
