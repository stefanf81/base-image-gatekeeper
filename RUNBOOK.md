# Runbook: base-image-gatekeeper

Setup, first runs and tests for `stefanf81/base-image-gatekeeper`. What the repository is and
how a base image moves through it is in [README.md](README.md).

The repository must be **public**: on a free personal account, artifact attestations and
environment reviewers are only available for public repositories.

The repository name is a default. To use another one, change, in one commit:
- `policy/applications.json` (`source_repo`);
- `release-gate/allowlist.json`;
- the default `repository` input in `.github/workflows/release-gate.yml`;
- `REPO`/`GATE_REPO` in both files under `release-gate/tests/`;
- `tests/test_v3_fixes.py`;
- the allowlist lookup in `base-gate/tests/test_base_gate.py`;
- the `mirrors` entry in `base-gate/config.json` (it names the approved GHCR copy);
- the variables in step 3.

## What was verified before hand-off, and what was not

Verified in the session container (no GitHub, GHCR or Docker daemon available):

- **Kit suite:** 243 tests, 5 skipped (they need a Docker daemon with the containerd image
  store, or cosign). Among them are 33 PoC tests:
  - `ci/bootstrap_base.sh` runs end to end against stub crane/cosign that behave like GHCR (an
    empty package until the first copy; attestations accumulate). Its record is accepted as a
    comparison baseline, while the real precheck answers `needed` and `scripts/verify_bases.sh`
    refuses it for applications.
  - The bootstrap refuses before any write when the digest already carries a usable approval.
- **CI base-image gate:** 35 tests.
  - The planner runs against a real temporary git history: changed, added and removed pins;
    a Dockerfile dropped from the list is still watched; unpinned `FROM` fails.
  - `compare_all.sh` runs the kit's real `compare.sh` and `evaluate.py` against stub tools.
    A routine update passes. A new SUID file blocks even with an acceptance. A new base
    repository fails until accepted. Platform drift blocks.
  - The decision rules and the workflow wiring (`test` needs the gate) are tested too.
  - Mutation checks: accepting a block, ignoring an expiry, or ungating the build each make a
    test fail.
- **Release gate:** 19 tests run the publishing loop against a local repository:
  - it refuses and withdraws when `main` moves, and retries a transient API error;
  - the real workflow step stops on the runner's first signal;
  - a loop that survives a withdrawal cannot publish again (lease-protected pushes).
  - Its grants are accepted by the kit's `scripts/verify_release_authorization.py`, which
    rejects them for another commit or when they are more than 10 minutes old.
- **Single-repo build:** the pipeline's real `build` step ran twice on a `git archive` of this
  repository, as `application-release.yml` does. The jar was byte-identical (once normal, once
  `CI_SKIP_TESTS=1`), and `example-app/Dockerfile` passes `scripts/check_dockerfile_bases.py`.
- **buildx:** reproduced locally with buildx 0.39.0. `--builder default` fails once another
  context is current, which is what `docker/setup-docker-action` does. The PoC builds on the
  current context's builder.
- **Lint:** every workflow passes the kit's pinned actionlint 1.7.12 (with shellcheck 0.10.0),
  and `base-gate/compare_all.sh` passes shellcheck.

Not verified here: everything from step 2 on, including a gate run against real images.

## 1. Before you start (on your machine)

- **cosign v3:** key generation and the final verification.
- **openssl, git, curl.**
- **gh, logged in (`gh auth login`), and python3:** the settings audit and the attestation test.
- **docker:** the final `docker run`.
- **crane:** only for the gate tests in section 5 (finding another Temurin digest).
- **The pinned Temurin digest:**
  `sha256:577acb7ab9893a6dfd6bcb138a25a4fb579ef1f3abcd197e24d9752e33457d85` was the
  `eclipse-temurin:21-jre-resolute` index on 2026-11-20. It does not matter if the tag has
  moved since: the bootstrap imports exactly this pinned digest.

## 2. Create the repository and push

Create an **empty public** repository `stefanf81/base-image-gatekeeper`: no README, no
license. Push this tree to it as `main`:
- If Claude prepared it, it pushes the `standalone-poc` branch for you.
- Otherwise, from a clone that holds the tree on a branch: `git push
  https://github.com/stefanf81/base-image-gatekeeper.git <branch>:main`.

If git asks for credentials, the token needs the `workflow` scope (the push contains workflow
files). Keep file modes: `example-app/ci/build_and_test.sh` must stay executable, because the
release pipeline runs it from a `git archive`.

**Expected on the first push:**
- `base-image-approval.yml` fails in `precheck`: no baseline yet, and no variables until step 3.
  This is harmless.
- **Example app tests**: `base-image-gate` skips, because there is no baseline yet ("no
  previous commit", or "this change introduces the gate" when the repository was created with
  a README). Then `test` builds the app.

## 3. Configure

Generate the keys (below), then let `setup/configure_repo.sh` do the rest of this section.
Run it from a clone, with gh logged in as a repository admin:

```bash
bash setup/configure_repo.sh
```

It asks for the two cosign passwords, then sets:
- the Actions permissions;
- the variables and secrets;
- the 11 environments;
- the `grants` branch;
- the three rulesets.

Then it runs the settings audit. It is safe to run again. The subsections below describe what
it sets, and are the manual way to do it.

**No machine of your own?** Use a GitHub Codespace (a Linux shell in the browser).
1. Open the repository → **Code** → **Codespaces** → **Create codespace on main**.
2. In its terminal, run everything in that **one** terminal. The Codespace's own token cannot
   change settings, so log in as yourself first:

   ```bash
   unset GITHUB_TOKEN GH_TOKEN && gh auth login --hostname github.com --git-protocol https --web
   ```

3. Install cosign (checksum-verified, from the kit's lock):

   ```bash
   python3 -I ci/install_verified_tools.py --kind promote && export PATH="$(python3 -c 'import tempfile; print(tempfile.gettempdir())')/verified-security-tools:$PATH"
   ```

4. Generate the keys (below) and run `bash setup/configure_repo.sh`.
5. Keep the Codespace until the PoC ends: it holds `~/ghcr-poc-keys`, has docker for the final
   `docker run`, and stops by itself when idle. Then delete it (Codespaces page → `…` →
   Delete). After that, the private keys exist only as GitHub secrets, which nobody can read
   back. If you need them again, follow section 8.

### Keys

Generate them in a directory of their own, outside every repository, and keep it until the PoC
ends:

```bash
mkdir -p ~/ghcr-poc-keys && cd ~/ghcr-poc-keys && umask 077
```

```bash
COSIGN_PASSWORD='<approval-password>' cosign generate-key-pair --output-key-prefix approval
```

```bash
COSIGN_PASSWORD='<app-password>' cosign generate-key-pair --output-key-prefix app
```

```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out verifier.key && openssl pkey -in verifier.key -pubout -out verifier.pub
```

```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out gate.key && openssl pkey -in gate.key -pubout -out gate.pub
```

Each `*_B64` secret below is `base64 -w0 <file>` (on macOS: `base64 -i <file>`).

### Settings → Actions → General

- Workflow permissions: **Read repository contents and packages permissions**. Every job asks
  for more itself.
- Leave "Allow GitHub Actions to create and approve pull requests" **off**.

### Variables

| Name | Value |
| --- | --- |
| `GHCR_NAMESPACE` | `stefanf81` |
| `RELEASE_GATE_URL` | `https://raw.githubusercontent.com/stefanf81/base-image-gatekeeper/refs/heads/grants` |
| `RELEASE_GATE_ISSUER` | `base-image-gatekeeper-release-gate` |
| `RELEASE_GATE_SCHEMA` | `https://example.org/verified-release/v1` |
| `RELEASE_REQUIRED_CHECKS` | `tests` |

### Repository secrets (public keys only)

- `APPROVAL_PUBKEY_B64`: `approval.pub`
- `RELEASE_GATE_PUBKEY_B64`: `gate.pub`

### Optional: Docker Hub login for the CI gate

Docker Hub limits anonymous pulls per IP address, and GitHub's runners share addresses, so the
CI gate's comparisons are sometimes refused. A refusal fails the gate. To avoid that:
- create a free Docker Hub account;
- under Account settings → Personal access tokens, create a token with the
  **Public Repo Read-only** scope;
- set the repository variable `DOCKERHUB_USERNAME` and the secret `DOCKERHUB_TOKEN`.

`setup/configure_repo.sh` does not set these.

### Environments

Create all eleven. Each one gets *Deployment branches and tags → Selected branches → `main`*.
Do not use "Protected branches only": the audit refuses it.

| Environment | Required reviewer | Secrets |
| --- | --- | --- |
| `base-manual-approval` | you; *Prevent self-review* **off** | `APPROVAL_PRIVATE_KEY_B64` (approval.key), `COSIGN_PASSWORD` (approval password) |
| `application-high-cve-review` | you; *Prevent self-review* **off** | none |
| `independent-verification` | none | `VERIFIER_PRIVATE_KEY_B64` (verifier.key) |
| `ghcr-application-signing` | none | `APP_COSIGN_KEY_B64` (app.key), `APP_COSIGN_PUBKEY_B64` (app.pub), `COSIGN_PASSWORD` (app password), `VERIFIER_PUBLIC_KEY_B64` (verifier.pub) |
| `release-gate` | none (add yourself if each grant should need a click) | `GATE_PRIVATE_KEY_B64` (gate.key) |
| `application-source-read` | none | none needed (see below) |
| `base-auto-promotion` | none | **none**: unreachable while upstream provenance is unverified; without a key it fails closed |
| `ghcr-quarantine`, `ghcr-read-only`, `ghcr-candidate-writer`, `ghcr-application-promoter` | none | none |

**`APPLICATION_READ_TOKEN` is optional.** The app is in this repository, so `authorize` reads
it with the job's own `GITHUB_TOKEN`. Set the secret in `application-source-read` only if the
app ever moves to another (private) repository. It is a fine-grained token, Contents
read-only, for that repository only.

### The `grants` branch

The release gate publishes grants on an orphan branch `grants`. If you add the "Restrict
creations" ruleset below, create the branch once by hand first, or the gate's first push is
refused. Any content works, because the gate replaces it:

```bash
gh api -X POST repos/stefanf81/base-image-gatekeeper/git/refs -f ref=refs/heads/grants -f sha="$(gh api repos/stefanf81/base-image-gatekeeper/commits/main --jq .sha)"
```

### Rulesets

These are optional for a green run, but required for `ci/audit_repo_settings.py` to pass.
- **Creations:** a branch ruleset and a tag ruleset, each targeting `~ALL`, with *Restrict
  creations*. Bypass: Repository admin.
- **Default branch:** a branch ruleset with:
  - *Require a pull request* with **0** approvals (the PoC switch allows 0);
  - *Require status checks*: `unit-tests`, `base-image-gate` and `test`;
  - *Restrict deletions*;
  - an **empty** bypass list.

  From then on, every change goes through a pull request, and a pull request that moves a base
  image without passing the gate cannot be merged.

Check all of this with the audit, from a clone (needs a token with admin rights to the
repository). It reads `allow_self_approval` from `policy/config.json` on `main`, not from your
clone:

```bash
GH_TOKEN="$(gh auth token)" python3 ci/audit_repo_settings.py --repo stefanf81/base-image-gatekeeper
```

## 4. First runs, in order

| # | Action | Expected result |
| --- | --- | --- |
| 1 | Run **GHCR - bootstrap first approved base (PoC)** with `confirm_digest` = `sha256:577acb7a…85` (full value from `catalog/Dockerfile.temurin`), then approve the `base-manual-approval` deployment | `approved/eclipse-temurin:21-jre-resolute` exists and is signed. The record carries `"bootstrap": true` and `approver: self:stefanf81` (in the `bootstrap-evidence` artifact). If the copy fails with `DENIED` on a manifest push right after the first manifest went through, re-run the failed job: see "First push into a new package" in section 7. |
| 2 | Packages (your profile → Packages) | `approved/eclipse-temurin` is linked to this repository. In its **Package settings**: make it **public** (two copies of a four-platform JRE count against the free private storage), and under *Manage Actions access* lower the repository's role from **Admin** (GitHub's default for a package a workflow created) to **Write**, which is all the pipeline needs. |
| 3 | Run **GHCR - approve public base image** | See the walkthrough below the table. |
| 4 | Run it again | `precheck`: `approved`; every other job is skipped. |
| 5 | Note the `main` HEAD SHA | Its **Example app tests** run on `main` is green: `base-image-gate`, then `test`. |
| 6 | Run **Release gate (PoC)** with that SHA (`repository` defaults to this one), minutes `90` (the default) | The log shows "re-issued" every minute. Wait for that line before you curl, and before step 7: a 404 fetched too early can stay cached for 5 minutes. Then `curl -s https://raw.githubusercontent.com/stefanf81/base-image-gatekeeper/refs/heads/grants/<SHA>` returns JSON. If the CI run is still running (or is re-run later), the log says "not finished: no new grant this round" and the gate waits. It only gives up on a failed run or a new `main` HEAD. |
| 7 | Run **GHCR - protected application release** with `app_name=example-app` and `app_commit=<SHA>`. **Merge nothing until it has signed**: a new `main` HEAD makes the gate withdraw | `authorize` → `compile` a/b → `image_build` a/b (attested) → `scan` → `push_candidate` → (`high_review` only on High findings: approve it) → `promote` → `independent_rescan` → `independent_verification` → `sign`. |
| 8 | Cancel the gate run | The grant is withdrawn (the `grants` branch holds only a README). A copy already cached by raw.githubusercontent.com can still be served for up to 5 minutes. |

**Step 3 walkthrough:**
- `precheck` answers `needed` and `quarantine` copies the index.
- `evaluate` returns **REVIEW**. The digest is compared with itself, so no diff check can find
  anything, and the run lists the image's **absolute** findings instead. The `evaluate` job
  summary shows every reason:
  - the two routine ones ("No verified upstream publisher signature", "No independently
    validated upstream build provenance");
  - "Candidate is the approved baseline itself …";
  - per platform, "absolute review" lines for SUID/SGID files, world-writable files and
    directories, symlinks into watched locations, and Critical/High/unknown vulnerabilities.
- `evaluate` takes a few minutes: under 4 for all four platforms on 2026-11-24.
- Read them before you approve `promote`. For `eclipse-temurin:21-jre-resolute@sha256:577acb7a…`
  (Ubuntu 26.04.1 LTS), the first live run found exactly this on all four platforms:
  - 11 SUID/SGID files, the stock Ubuntu ones: `chage`, `chfn`, `chsh`, `expiry`, `gpasswd`,
    `mount`, `passwd`, `su`, `umount`, `unix_chkpwd`, `pam_extrausers_chkpwd`;
  - 4 world-writable directories, all sticky (`1777`) and owned by root: `tmp`, `var/tmp`,
    `run/lock` and `var/lib/pebble/default`. The last one belongs to `/usr/bin/pebble`,
    Canonical's Pebble service manager, which Ubuntu ships in its container base images
    (Go module `github.com/canonical/pebble`, not owned by a `.deb` package);
  - among the symlinks into watched locations, `var/lock` (pointing to `/run/lock`);
  - no Critical, High or unrated vulnerabilities (amd64: 231 Medium, 13 Low).

  Anything else needs a reason before you approve. The full lists are in `decision.json` of
  the `base-evidence` artifact; the `*.fs.json` files show each path's mode and owner, and
  the `*.syft.json` files show which package a file belongs to.
- Once approved, `promote` signs a record with the current policy fingerprint.
- **Approve with *Review deployments*, not *Start all waiting jobs*.** On the run page, click
  **Review deployments**, tick `base-manual-approval` and click **Approve and deploy**. As a
  repository admin you may also see **Start all waiting jobs**: that bypasses the protection
  rule, and GitHub records it as `skipped`, not `approved`. `promote` then refuses with "NO
  VALID ENVIRONMENT REVIEWER: no recorded approval for environment 'base-manual-approval'"
  before writing anything. Re-run the failed job and approve it properly. The same applies to
  the bootstrap (step 1) and to `high_review` in a release.
- Make `quarantine/eclipse-temurin` public too, and lower its repository role to **Write**
  as in step 2.

**If `scan` ends in BLOCK** (a Critical or unrated finding in the Ubuntu base), add an
exception to `critical_exceptions` in `policy/config.json` via a pull request. Scope it to the
approved **base**:

```json
{"id": "CVE-…", "package": "…", "package_version": "…", "platform": "linux/amd64",
 "expires": "2026-12-31", "reason": "PoC: …", "approved_by": "stefanf81",
 "base_image_ref": "ghcr.io/stefanf81/approved/eclipse-temurin@sha256:577acb7a…"}
```

- **Not `image_ref`:** in a single repository, the merge of that pull request is a new commit.
  Its jar carries a new commit timestamp, so the image digest named by `image_ref` never comes
  back.
- **`base_image_ref`:** it covers every commit of the app built on that base, because the app
  image only adds files on top of it.
- **Fingerprint:** neither form changes the base policy fingerprint, so the base approval
  stays valid.
- **Then:** release the merge commit (steps 5–7).

**Verify the result** (from `~/ghcr-poc-keys`, which holds `app.pub`). The
`applications/example-app` package is private until you change it: either make it public
first, or `docker login ghcr.io` with a classic token that has `read:packages` (cosign uses the
same Docker credentials):

```bash
IMAGE=ghcr.io/stefanf81/applications/example-app@sha256:<digest from the sign job summary>
```

```bash
cosign verify --insecure-ignore-tlog=true --key app.pub "$IMAGE"
```

```bash
cosign verify-attestation --insecure-ignore-tlog=true --key app.pub --type cyclonedx "$IMAGE" > /dev/null && echo SBOM ok
```

```bash
cosign verify-attestation --insecure-ignore-tlog=true --key app.pub --type https://example.org/github-actions-build-record/v1 "$IMAGE" > /dev/null && echo build record ok
```

```bash
docker run --rm "$IMAGE"
```

The last command prints `example-app: released through the signed GHCR pipeline`.

## 5. Tests (no cluster needed)

The **read-only tests** change nothing and can run in any order once section 4 is done.

The **pull-request tests** exercise the CI base-image gate. Close each pull request unmerged
when you are done; nothing changes on `main`.

The **state-changing tests** change a setting or `main`. Run them one at a time, and finish
each one's undo step before the next, or later tests fail for unrelated reasons.

### Read-only tests

| Test | Expected |
| --- | --- |
| Dispatch the bootstrap, the base approval or the application release from a branch other than `main` | Every job is skipped (`if: github.ref == 'refs/heads/main'`) |
| Release with the gate not running | `authorize` fails: curl 404 from the grant URL |
| Release with an `app_name` that is not in `policy/applications.json` | `authorize`: "APPLICATION NOT ALLOWED" |
| Run the bootstrap again | "… already points at sha256:…; use base-image-approval.yml" |
| Download the `image-a` artifact of a release run, change one byte of `application-image.tar`, run `gh attestation verify application-image.tar --repo stefanf81/base-image-gatekeeper` | Verification fails |

### Pull-request tests (CI base-image gate)

Find another Temurin digest with `crane digest eclipse-temurin:21-jre-noble` (Ubuntu 24.04
instead of 26.04). The repository is the same, so the gate compares the two digests.

| Pull request | Expected in **Example app tests** |
| --- | --- |
| Change only the README | `base-image-gate`: "No base-image pin changed" (seconds); `test` runs |
| In `catalog/Dockerfile.temurin`, replace the digest (and, for readability, the tag) with the `noble` one | `base-image-gate` **fails** after the scan. The summary lists ATTENTION reasons (packages added/removed or downgraded, files in watched locations, probably new High CVEs) and any BLOCK. `test` is skipped. The `base-image-gate-evidence` artifact holds the reports. |
| Same pull request plus an acceptance in `base-gate/config.json` for `docker.io/library/eclipse-temurin@<noble digest>` (expires within 90 days) | If the first run had no BLOCK: `ACCEPTED`, and `test` runs. A BLOCK still fails. |
| In `example-app/Dockerfile`, add `FROM docker.io/library/alpine@<digest> AS tools` above the existing `FROM` (`crane digest alpine:3.22`) | `base-image-gate` fails: "added pin … compared with itself". The summary has "Candidate is the approved baseline itself …" and the image's absolute findings. Accepting it would pass this gate, but the release would still refuse a base that is not approved. |
| Remove `catalog/Dockerfile.temurin` from `dockerfiles` in `base-gate/config.json` and change its digest | The gate still compares it: files listed on `main` stay watched. |

### State-changing tests

| Test | Expected | Undo |
| --- | --- | --- |
| **Revocation.** Add yourself as required reviewer of `ghcr-application-signing`. Start a release with the gate running. When `sign` waits for approval, cancel the gate. Approve `sign` more than 10 minutes after the cancel and less than 30 minutes after `independent_verification` finished (about 12–15 minutes after the cancel works). | `sign` fails: curl 404, or "release authorization is not freshly issued". Approving later than 30 minutes fails earlier, on the expired verification record ("independent scan attestation expired"), and does not test revocation. | Remove the reviewer. |
| **Merge during a release.** Start the gate and a release for the HEAD, then merge a README-only pull request. | The gate logs "… is not the main HEAD …", withdraws and ends; the release fails at its next grant fetch (`sign` at the latest). | None; release the new HEAD if you need a green release. |
| **Non-reproducible build.** In `example-app/Dockerfile`, add `RUN cat /proc/sys/kernel/random/uuid > /stamp` above the `USER` line (below it, the write is denied). Merge, grant and release the new HEAD. | `scan` refuses: "Independent builder archives have different verified layer sequences" | Revert via pull request. |
| **Self-approval off.** Pull request that sets `allow_self_approval` to `false`; merge it. | The merge changes the base fingerprint and starts a base run: `precheck` says `needed`. Approve its `promote` deployment: the job then refuses you ("… started or reran this workflow and cannot approve 'base-manual-approval'") and fails. Meanwhile releases fail in `image_build` ("signed policy content hash does not match"). | Pull request back to `true`. The fingerprint is the approved one again, and the merge's base run stops at `precheck`: `approved`. |
| **Fingerprint change.** Pull request that adds a comment line to `scripts/evaluate.py`; merge it. | The merge starts a base run: `precheck` says `needed`, and `evaluate` reviews the digest against itself again. Meanwhile a release fails in `image_build`: "No acceptable signed approval record: … signed policy content hash does not match current trusted policy". | Approve its `promote` (a new record with the new fingerprint), or cancel the run and revert. Releases fail until one of the two is done. |
| **Stale commit.** Merge a README-only pull request, then grant and release the **previous** SHA. | The gate refuses ("… is not the main HEAD …"); a release fails in `authorize` with "Requested commit is not the exact protected main HEAD (… main is <new SHA>)". | None, but later tests must use the **new** HEAD (wait for its CI run to go green). |
| **Deleted signing key.** Delete the secret `APP_COSIGN_KEY_B64` (GitHub stores no empty values). Grant and release. | `sign` fails closed at `cosign sign`; the promoted image stays unsigned. | Restore the secret. |

## 6. Single-repository trade-offs

- **Separation of duties is weaker.** Pipeline, app and release gate share one repository and
  one set of maintainers, so whoever can change `main` can change all three. The kit intends
  separate repositories or services; this PoC keeps them together for simplicity.
- **Pull requests run their own workflow files.** A `pull_request` run uses the PR's version of
  `example-app-ci.yml` and `base-gate/`, so a PR could weaken the gate it is checked by. Review
  changes to `.github/workflows/`, `base-gate/`, `scripts/` and `policy/`. Once there is a
  second maintainer, use CODEOWNERS and required approvals.
- **No merges during a release.** Any merge moves `main`; the release gate then withdraws.
- **Exceptions by base, not by image:** see "If `scan` ends in BLOCK" above.
- **Acceptances outlive the pull request.** The push run after the merge compares the same pins
  again, so keep an acceptance until the release has passed; delete it once it has expired.

## 7. Known risks the live run has to settle

1. **cosign v3 bundles on GHCR:** one signature plus several attestations on the same digest.
   Settled for base images on 2026-11-24: steps 1 and 3 signed, attested and verified
   `approved/eclipse-temurin`. The application image (step 7) is still open.
2. **Package visibility and linking** of nested names (`approved/eclipse-temurin`) created by
   `GITHUB_TOKEN`. Settled on 2026-11-24: both packages were created and linked to this
   repository (with role Admin, see step 2), and can be made public.
3. **`actions/attest` v4** may also want `artifact-metadata: write`. The kit grants `id-token`
   and `attestations` only.
4. **Grant cache age:** compare raw.githubusercontent.com's `age`/`x-cache` headers on the
   grant with the 10-minute limit.
5. **Compile toolchain:** the bare `compile` job relies on the runner image's Maven and default
   JDK 17.
6. **Approval expiry:** base approvals expire after 720 h (`approval_max_age_hours`), and
   nothing re-runs them on a schedule. After 30 days, releases fail until step 3 is repeated.
7. **CI gate pulls:** registries limit anonymous downloads per IP address. Running the gate
   locally on 2026-11-25 against real images, Docker Hub refused with HTTP 429 and AWS's
   public mirror with "Data limit exceeded". A refused pull fails the gate (fail closed).
   - The gate now reads the old pin from the approved GHCR copy (`mirrors` in
     `base-gate/config.json`).
   - It can log in to Docker Hub for the new image (section 3, optional).
   - Each source is used only if it serves exactly the pinned digest.
   - GHCR is read with the job's `packages: read` token, which needs the approved package to
     be linked to this repository (step 2 of section 4).
10. **Platform drift blocks:** a candidate published for more or fewer CPU platforms than the
    pin is blocked, with no acceptance possible. Example: `21-jre-noble` adds
    `linux/riscv64` (found on 2026-11-25). If upstream adds a platform to `21-jre-resolute`,
    updates stay blocked until the rule or the pin changes.
8. **CI gate duration:** a moved pin is scanned on every platform of the index (four for
   Temurin), twice per image. The same scan took under 4 minutes in step 3, so expect a few
   minutes; the job's limit is 120.
9. **First push into a new package:** a multi-platform copy pushes its platform manifests in
   parallel. The first one creates the package, and GHCR can refuse the others with `DENIED`
   for a moment while it is still setting the package up. This happened on the bootstrap's
   first attempt (2026-11-24). Re-run the failed job: the package exists then, the copy is
   idempotent, and the guards ignore the partial copy (no tag, no complete index). Only
   the first push into `approved/` and `quarantine/` can hit this; the application packages
   hold single-platform images.

Fixed after review, still worth watching:
- **Image build:** it now runs on the current Docker context's builder instead of
  `--builder default`.
- **Jar mode:** the app's jar is copied with `--chmod=0444`.

## 8. Recovery: the approved baseline can no longer be verified

This happens after rotating or losing the approval key, or when the baseline is older than 365
days (`historical_baseline_max_age_hours`):
- base runs fail in `evaluate` at `cosign verify`, or report the record as too old;
- the bootstrap refuses because the tracking tag exists;
- releases stop once the current approval passes 720 h.

To recover:

1. Your profile → Packages → `approved/eclipse-temurin` → Package settings → **Delete this
   package**. Its signatures and attestations are stored in the same package and go with it.
2. Run step 1 (bootstrap) again with the current catalog pin, then steps 3 and 4.

If only the tracking tag is missing and the digest still carries a current approval, do not
delete anything. The bootstrap refuses and prints the `crane tag …` command that restores the
tag.

## 9. Results log

| Date | Step / test | Run URL | Result | Notes |
| --- | --- | --- | --- | --- |
| 2026-11-21 | First push: Example app tests | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/44908914149 | green on attempt 2 | Attempt 1: Maven Central answered HTTP 429; `base-image-gate` skipped (baseline predates the gate) |
| 2026-11-24 | Section 3: `setup/configure_repo.sh` from a Codespace | | passed | Settings audit passed on the first run |
| 2026-11-24 | Step 1: bootstrap | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45489185941 | green on attempt 2 | Attempt 1: `DENIED` on the first push into the new package (section 7, risk 9) |
| 2026-11-24 | Step 3: base approval | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45492263750 | REVIEW, approved, signed | Findings as listed in the step 3 walkthrough; `evaluate` took 3.5 minutes |
| 2026-11-24 | Step 4: base approval again | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45499314730 | `precheck` approved, rest skipped | |
| 2026-11-24 | Read-only tests: unknown app, no gate, non-`main` dispatch | runs 45499319194, 45499325225, 45499330590 | all refused or skipped as expected | "APPLICATION NOT ALLOWED"; curl 404; whole run skipped |
| 2026-11-24 | Step 7: first release of `6d57c1b` | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45500301538 | promoted, **not signed** | `compile (a)` hit Maven Central 429 for 12 min (re-run passed). Then `sign` and the two jobs before it were skipped because `high_review` was skipped (no High CVEs): fixed in #3 |
| 2026-11-24 | Release gate for `6d57c1b` | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45500146143 | withdrew at 22:30 | GitHub answered HTTP 500 to three grant pushes in a row; the gate withdrew and stopped (fail closed) |
| 2026-11-25 | Step 7: release of `2171b3b` | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45568133430 | **signed** | `ghcr.io/stefanf81/applications/example-app@sha256:9182a0707d53bf5cb80200291bb823f308d8cd762cbe973bedda2b86773fe63c`; 7 minutes; no High CVEs |
| 2026-11-25 | CI gate, run locally on real images | | noble: BLOCK (platform drift, `riscv64`); 25-jre / 21-jdk: refused downloads, gate failed closed | Docker Hub 429 and AWS mirror data limit from a shared IP; led to `mirrors` and the optional Docker Hub login |
| 2026-11-25 | CI gate with `mirrors`, run locally: pin moved to `25-jre-resolute` (`a0862ac8…`) | | **FAIL: attention**, no blocks | Old image read from GHCR, new from Docker Hub, 251 s. Found: 34 packages removed (`curl`, `gnupg`, …); `root/.wget-hsts` and `etc/ld.so.cache` in watched locations; JVM `java.security`/`java.policy` changed; no new Critical or High CVEs |
| 2026-11-25 | Pull-request test: pin moved to `25-jre-resolute` (#5, closed unmerged) | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45616963855 | **`base-image-gate` failed, `test` skipped** | 0 block, 20 attention findings, identical to the local run; old image read from the GHCR mirror, new from Docker Hub without a token, no 429; comparison 2 min 31 s |
| 2026-11-25 | Same PR plus an acceptance for exactly `sha256:a0862ac8…` | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45618585406 | **ACCEPTED, gate passed, `test` passed** | The summary still lists all 20 findings with "accepted by stefanf81 until 2026-12-02" |
| 2026-11-25 | Stale commit: gate and release for `2171b3b` after `main` moved to `e9ddf10` | runs 45621832417 (gate), 45621838628 (release) | both refused | Gate: "GRANT REFUSED: … is not the main HEAD …", then withdrew; release `authorize`: "Requested commit is not the exact protected main HEAD (… main is e9ddf10…)" |
| 2026-11-25 | Merge during a release: gate and release for `6d57a76`, then a README-only pull request merged | runs 45623536815 (gate), 45624154382 (release) | both stopped | Gate at 13:32:30: "… is not the main HEAD …", withdrew and ended; the release's `sign` then failed at 13:37:11 reading the grant: "curl: (22) … 404". Nothing signed |
| 2026-11-25 | Non-reproducible build (#8, `e45389a`): CI | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45632244055 | green on attempt 2 | Attempt 1: Maven Central 429 for 12 min, despite 8 retries |
| 2026-11-25 | Same: gate while CI was red | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45632270145 | refused | "GRANT REFUSED: .github/workflows/example-app-ci.yml run 45632244055 for e45389a… is completed/failure", withdrew. A new gate run (45635829992) granted after the CI re-run |
| 2026-11-25 | Same: release of `e45389a` | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45635936566 | **refused in `scan`** | Both `image_build` jobs passed; `scan`: "image-a/verified-diff-ids.json image-b/verified-diff-ids.json differ" and "Independent builder archives have different verified layer sequences". Nothing pushed. Reverted in #9 |
| 2026-11-25 | Fingerprint change (#10, `fad2534`): base run | https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45638872010 | REVIEW, approved on attempt 3, signed | Started by the merge; `precheck`: needed; `evaluate`: "Candidate is the approved baseline itself …" plus the same absolute findings as step 3. Attempts 1 and 2 were started with *Start all waiting jobs*: recorded as `skipped`, and `promote` refused both ("NO VALID ENVIRONMENT REVIEWER") before writing. Attempt 3, approved with *Review deployments*: signed |
| 2026-11-25 | Same: release before the re-approval | runs 45642579963 (gate), 45642673611 (release) | **refused in `image_build`** | "No acceptable signed approval record: [['signed policy content hash does not match current trusted policy'], …]" (one entry per platform) |
| 2026-11-26 | Same: release after the re-approval | runs 45783265679 (gate), https://github.com/stefanf81/base-image-gatekeeper/actions/runs/45783331644 | **signed** | `ghcr.io/stefanf81/applications/example-app@sha256:bf11cadbb0fe8aef1ead92a0d26cbbf9614c1c738e4e6c76c86f04b43e65301c`; 8 minutes; no High CVEs. The test comment stays in `scripts/evaluate.py` (removing it changes the fingerprint again) |
| | | | | |
