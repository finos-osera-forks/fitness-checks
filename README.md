# fitness-checks

[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![lint](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/lint.yaml/badge.svg)](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/lint.yaml)
[![e2e](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/e2e.yaml/badge.svg)](https://github.com/finos-osera-forks/fitness-checks/actions/workflows/e2e.yaml)

This repository contains the reusable GitHub Workflow and the Composite Actions that run the source side
fitness checks of the [OSERA Remediation Standards](https://standards.osera.finos.org/) on a patch repository
at a release tag. One action per requirement of the standards pack, plain bash with git, jq and yq, one signed result.

The library lives in the `finos-osera-forks` organisation next to the patch repositories. The organisation the checks expect a patch repository in, and the `uses:` owner in the caller, follow the library's home.

## The standard version a check implements

Every check action declares the version of the standard it was written against, twice in the same words: in its `description` (`FORK-001.REQ-001 (FORK-001 0.1.0): ...`) and in its `check_is` line (`check_is FORK-001 0.1.0 FORK-001.REQ-001 FORK-001.CHECK-001`). At run time the recorder reads the pack file at `STANDARDS_REF` (`docs/catalog/packs/<pack>.json`, which names every included standard with its version) and compares: equal, the record says `standard_version` and `check_version`; different, the requirement is recorded `not-tested` with both versions in `observed`, the roll up is not a pass, and the gate refuses. Before a release the lint job makes the same comparison for every action, so a library release cannot move `STANDARDS_REF` to a pack whose standards changed without the actions changing with it. The result also carries `pack_checksum`, the digest of that pack file. A new pack whose standards changed is a new major of this library; a pack patch that changes no check is a patch release that moves `STANDARDS_REF` and nothing else.

## A rehearsal before the release tag

A producer can run every check on a branch or commit before pushing the release tag: in the patch repository, Actions, "OSERA fitness checks", Run workflow, choose the branch, type the tag you intend to push. The workflow checks that commit as if the tag pointed at it (the tag is created locally in the runner, never pushed), prints the result and uploads it as an artifact, and signs nothing: the result says `rehearsal, not signed`, no attestation exists, so the gate can never accept it. A red rehearsal costs nothing. The real release is the tag push, unchanged.

## Workflows

### Fitness checks on a release tag

The [fitness](.github/workflows/fitness.yaml) workflow checks a patch repository at a release tag by performing the following steps:

- Checks out the patch repository at the tag, with every branch and tag, and this library next to it.
- Runs one action per requirement of OSERA-SP-0.1.0 that can be checked on the source (table below). Each writes one record.
- Runs the ControlPlane proposals (REL-004 early warnings), which warn and never fail the run.
- Writes `result.json` with the [fitness page](https://standards.osera.finos.org/fitness/)'s fields: one entry per requirement saying what was expected, what was observed and the commands and outputs that showed it, one status per standard, the proposals underneath. Records are written outside the checkout, so nothing a producer commits can pre fill them.
- Attests `result.json` with GitHub Attestations: an in-toto statement, predicate type `https://osera.finos.org/fitness-result/v1`, signed with the workflow's OIDC identity through Sigstore, stored by GitHub with the repository.
- Attests the same result a second time under a subject the gate can compute from the tag alone: the SHA256 of the tagged commit id (subject name `git:<owner>/<repo>@<commit>`). The gate gets the commit for the tag from GitHub, hashes it, fetches the attestation by that digest, verifies signer, source and commit, and reads the result from the predicate. Nothing from the producer, no run to pick, no artifact retention.
- Uploads `result.json`, the Sigstore bundle and the producer's evidence file (`patch-evidence.yaml`, a copy of `.osera/patch-evidence.yaml` at the tag) as a workflow artifact. The result names the evidence file by its SHA256 (`evidence_file.digest`), so the signature on the result covers it: the gate takes the evidence from this artifact, checks the digest, publishes it next to the promoted jar, and refuses a release whose result names none.
- Fails the run when any blocking check failed or could not run.

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

- `result`: `pass`, `warn`, `fail` or `not-tested`.

3rd-party actions used:

- [actions/checkout](https://github.com/actions/checkout)
- [actions/attest](https://github.com/actions/attest)
- [actions/upload-artifact](https://github.com/actions/upload-artifact)

Verify a result: `gh attestation verify result.json --repo <patch repo> --signer-repo <this repo> --predicate-type https://osera.finos.org/fitness-result/v1`.

## Versioning

Callers pin the moving major tag, `@v1`. Releases are exact tags (`v1.0.0`, `v1.0.1`, `v1.1.0`) and `v1` is moved to the latest of them only after the e2e workflow is green, so a producer's repository never changes and still receives fixes. A breaking change becomes `v2` and a pull request on every caller. Every result records the exact library commit that produced it, which is what the gate checks.

## Actions

One composite action per requirement, under [`.github/actions`](.github/actions). Bash only: git for the repository, yq for the evidence file and the approved producers file, jq for the record.

| Action | Requirement | What it checks |
|---|---|---|
| `fork-001-req-001` | FORK-001.REQ-001 | repository in the expected organisation |
| `fork-001-req-002` | FORK-001.REQ-002 | repository name `patch-<name>`; the suffix is compared with the fork parent, an artifact name is left to the gate |
| `fork-002-req-001` | FORK-002.REQ-001 | a `patch/<version>` or `patch/<major.minor>.x` branch exists and contains the release tag |
| `fork-003-req-001` | FORK-003.REQ-001 | `v<VERSION>+patch.baseline` exists and points strictly before the release tag on the same history |
| `src-002-req-001` | SRC-002.REQ-001 | every fix in `.osera/patch-evidence.yaml` links an upstream commit, pull request, advisory or release note |
| `src-002-req-002` | SRC-002.REQ-002 (SHOULD, advisory) | commits naming an upstream commit carry a `Co-authored-by` trailer, not applicable when none does |
| `src-003-req-001` | SRC-003.REQ-001 | new source or test files since the baseline carry the header of the nearest same type file (years, whitespace and asterisks ignored), not applicable when no convention exists |
| `rel-001-req-001` | REL-001.REQ-001 | test provenance recorded in the evidence file: the tested commit, command, runtime, report name, passing result. The release tag may sit after the tested commit only if the commits in between touch nothing but the evidence file and the caller workflow |
| `write-result` | | `result.json` |

ControlPlane proposals, not requirements on the site, put to the working group on [remediation-standards #52](https://github.com/finos-osera/remediation-standards/issues/52). They warn, they never fail the run:

| Action | Id in the result | What it checks |
|---|---|---|
| `proposal-rel-004-producer-named` | CP-REL-004-01 | the evidence file has a producer line |
| `proposal-rel-004-producer-approved` | CP-REL-004-02 | that producer is in the approved producer registry of the standards repository (`docs/_data/approved_producers.yml`, REL-004), checked out at `STANDARDS_REF` and recorded in the result as `registry_ref` |
| `proposal-rel-004-accounts-in-entry` | CP-REL-004-03 | the account that pushed the tag and the accounts on the commits between the baseline tag and the release tag are all in that entry's `github_users` |

Actions take no inputs: the workflow sets the `OSERA_*` environment once and every action reads it. Each sources [`lib/record.sh`](lib/record.sh) and reads the same way: `check_is` names the requirement, `expect` states the rule with the actual values in it, `step` names what is being done, `ev` runs a command and keeps its command line (quoted so it can be pasted into a shell), exit code and output as evidence, `given` keeps a value GitHub set in the run context (owner, owner id, fork flag), `record` writes the status and what was observed. A check that dies before recording is written as `not-tested` with the step that failed and the evidence gathered so far. The artifact side checks (REL-002 bytecode level, REL-003 version pattern, REL-004 at the upload and at publication, REL-005 files and checksums, FEED-001) belong to the gate and are not here.

## The result

`result.json` keeps the fitness page's fields. `checks` has one entry per requirement, `standards` one status per standard, `proposals` the ControlPlane entries in the same shape:

```json
{
  "standard_pack": "OSERA-SP-0.1.0", "pack_checksum": null,
  "repository": "dev-finos-osera-forks/patch-commons-codec", "release": "v1.16.0+osera-patch.001", "commit": "5c4ae60a...",
  "artifact_digest": null, "library": "finos-osera-forks/fitness-checks@4dcdf38...", "producer": "controlplane-dv",
  "producer_accounts": {"registry": null, "observed": {"tag_actor": "d1gital-f", "upload_account": null}},
  "result": "fail",
  "signature": "see the GitHub artifact attestation on this file",
  "standards": [{"standard": "FORK-003", "standard_version": "0.1.0", "status": "fail"}],
  "checks": [{
    "standard": "FORK-003", "standard_version": "0.1.0", "requirement": "FORK-003.REQ-001", "check": "FORK-003.CHECK-001",
    "status": "fail",
    "expected": "tag v1.16.0+patch.baseline exists and points to a commit strictly before v1.16.0+osera-patch.001 on the same history",
    "observed": "no tag v1.16.0+patch.baseline (baseline tags present: none)",
    "evidence": [{"command": "git tag --list v1.16.0+patch.baseline *+patch.baseline", "exit": 0, "output": ""}]
  }],
  "proposals": [{"standard": "REL-004", "requirement": "CP-REL-004-02", "check": null, "status": "warn", "expected": "...", "observed": "...", "evidence": []}]
}
```

`producer_accounts` is the fitness page's REL-004.REQ-002 block: `registry` is the producer's `staging_account` and `github_users` copied from the registry entry (null when the producer has no entry, the REL-004 proposals say so), `observed.tag_actor` the GitHub account that pushed the release tag (`github.actor` of the push event that started the run), `observed.upload_account` null here, the gate fills it at upload time. `expected` is the rule in words with the actual values in it, `observed` what the repository showed, `evidence` the commands that showed it with their real output (first 40 lines). One rollup everywhere: any fail is a fail, then warn, then not-tested, then pass; not-applicable only when everything underneath is. The signed copy lives in GitHub's attestation store for the patch repository (and, for a public repository, in Sigstore's transparency log), under two subjects: the digest of `result.json`, for `gh attestation verify result.json`, and the SHA256 of the tagged commit id, for the gate. The gate fetches and verifies it at upload time and keeps it with the artifact. To find it by hand: `printf '%s' <commit> | sha256sum`, then `gh api repos/<owner>/<repo>/attestations/sha256:<digest>`.

## Testing

- [lint](.github/workflows/lint.yaml): actionlint (release binary, checksum pinned) on the workflows, shellcheck on every action's bash.
- [e2e](.github/workflows/e2e.yaml): runs the fitness workflow itself against two reference repositories in the dev organisation at their release tags (the workflow honours the `reference` input only when its caller is the library), forks of libraries far from any line OSERA carries: the known good `patch-jfiglet`, laid out the way the standard asks, and the known bad `patch-emoji-java`, one mistake per blocking check (the release tag on no `patch/` branch, the baseline at the release commit, a fix with no upstream link, no test record), each compared with its expected list under [`e2e/`](e2e/). A check that cannot run at all records `not-tested` rather than disappearing from the result.

## Notes

- In GitHub tag filters `+` is a special character: the generic pattern must be written `v*\+osera-patch.*`, otherwise the workflow never parses. The Java form needs no escaping: `v*-osera-*`.
- Because the caller file lives on the patch branch and not on the repository's default branch, the Actions tab lists it under its path; `run-name` titles every run by the tag.
