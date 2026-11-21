#!/usr/bin/env bash
# Apply RUNBOOK.md section 3 ("Configure") to the repository with the GitHub CLI.
#
# Run it on YOUR machine, from a clone of the repository, after generating the keys
# (RUNBOOK.md section 3, "Keys"). Safe to re-run: every step sets the desired state.
#   * Needs: gh (logged in with admin rights on the repository), python3, base64.
#     cosign is optional; when present, the two cosign passwords are checked before use.
#   * Reads the key files from KEY_DIR (default ~/ghcr-poc-keys) and prompts for the two cosign
#     passwords. Nothing secret is printed, written to disk or passed on a command line.
#
# Environment overrides:
#   REPO=owner/name       default stefanf81/base-image-gatekeeper
#   KEY_DIR=dir           default ~/ghcr-poc-keys
#   SKIP_RULESETS=1       configure everything except the three rulesets
#
# Steps:
#   1. Actions workflow permissions: read-only, Actions may not approve pull requests
#   2. Repository variables (GHCR_NAMESPACE, RELEASE_GATE_*, RELEASE_REQUIRED_CHECKS)
#   3. Repository secrets: the two PUBLIC keys
#   4. The 11 environments, each deployable from exactly `main`; you as required reviewer on
#      base-manual-approval and application-high-cve-review ("Prevent self-review" off)
#   5. Environment secrets: private keys and cosign passwords, each in its one environment
#   6. The `grants` branch for the release gate (created before the creation ruleset)
#   7. Rulesets: restrict branch and tag creation to admins; protect main (pull request with
#      0 approvals, required checks unit-tests / base-image-gate / test, no deletion, no bypass)
#      After this, every change to main goes through a pull request.
#   8. ci/audit_repo_settings.py, which must pass
set -Eeuo pipefail

REPO="${REPO:-stefanf81/base-image-gatekeeper}"
KEY_DIR="${KEY_DIR:-$HOME/ghcr-poc-keys}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="$(printf '%s' "${REPO%%/*}" | tr '[:upper:]' '[:lower:]')"
RULESET_PREFIX='base-image-gatekeeper'

step() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
b64() { base64 < "$1" | tr -d '\n'; }   # same output on Linux and macOS

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "REPO must be OWNER/NAME"
for tool in gh python3 base64; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done
step "Key files in $KEY_DIR"
for f in approval.key approval.pub app.key app.pub verifier.key verifier.pub gate.key gate.pub; do
  [[ -s "$KEY_DIR/$f" ]] || die "missing $KEY_DIR/$f (generate the keys first: RUNBOOK.md section 3, Keys)"
done
echo "all 8 present"

read_password() {   # read_password VAR PROMPT KEYFILE
  local value
  read -rsp "$2: " value; echo
  [[ -n "$value" ]] || die 'empty password'
  if command -v cosign >/dev/null; then
    COSIGN_PASSWORD="$value" cosign public-key --key "$3" >/dev/null 2>&1 \
      || die "that password does not open $3"
  else
    echo '  (cosign not installed: password not checked)'
  fi
  printf -v "$1" '%s' "$value"
}
step 'Cosign passwords'
read_password APPROVAL_PASSWORD 'Password of approval.key' "$KEY_DIR/approval.key"
read_password APP_PASSWORD 'Password of app.key' "$KEY_DIR/app.key"

gh auth status >/dev/null 2>&1 || die 'gh is not logged in: run gh auth login'
[[ "$(gh api "repos/$REPO" --jq .permissions.admin)" == true ]] \
  || die "your gh login has no admin rights on $REPO"
[[ -f "$ROOT/ci/audit_repo_settings.py" ]] || die "run this from a clone of $REPO"

step '1. Actions workflow permissions'
gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null
echo 'read-only; Actions may not approve pull requests'

step '2. Repository variables'
set_variable() { gh variable set "$1" --repo "$REPO" --body "$2" >/dev/null && echo "$1=$2"; }
set_variable GHCR_NAMESPACE "$NAMESPACE"
set_variable RELEASE_GATE_URL "https://raw.githubusercontent.com/$REPO/refs/heads/grants"
set_variable RELEASE_GATE_ISSUER base-image-gatekeeper-release-gate
set_variable RELEASE_GATE_SCHEMA https://example.org/verified-release/v1
set_variable RELEASE_REQUIRED_CHECKS tests

step '3. Repository secrets (public keys only)'
b64 "$KEY_DIR/approval.pub" | gh secret set APPROVAL_PUBKEY_B64 --repo "$REPO" && echo APPROVAL_PUBKEY_B64
b64 "$KEY_DIR/gate.pub" | gh secret set RELEASE_GATE_PUBKEY_B64 --repo "$REPO" && echo RELEASE_GATE_PUBKEY_B64

step '4. Environments (deployable from main only)'
ME_ID="$(gh api user --jq .id)"
ME_LOGIN="$(gh api user --jq .login)"
environment() {   # environment NAME reviewer|none
  local body='{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}'
  if [[ "$2" == reviewer ]]; then
    body+=",\"reviewers\":[{\"type\":\"User\",\"id\":$ME_ID}],\"prevent_self_review\":false"
  fi
  gh api -X PUT "repos/$REPO/environments/$1" --input - <<< "$body}" >/dev/null
  # Exactly one deployment branch policy: the branch main (the audit refuses anything else).
  local policies has_main=no id kind name
  policies="$(gh api "repos/$REPO/environments/$1/deployment-branch-policies" \
    --jq '.branch_policies[] | "\(.id) \(.type // "branch") \(.name)"')"
  while read -r id kind name; do
    [[ -n "$id" ]] || continue
    if [[ "$kind" == branch && "$name" == main ]]; then
      has_main=yes
    else
      gh api -X DELETE "repos/$REPO/environments/$1/deployment-branch-policies/$id" >/dev/null
      echo "  removed deployment policy $kind '$name' from $1"
    fi
  done <<< "$policies"
  if [[ "$has_main" == no ]]; then
    gh api -X POST "repos/$REPO/environments/$1/deployment-branch-policies" \
      -f name=main -f type=branch >/dev/null
  fi
  echo "$1$([[ "$2" == reviewer ]] && echo " (required reviewer: $ME_LOGIN, self-review allowed)")"
}
environment base-manual-approval reviewer
environment application-high-cve-review reviewer
for name in application-source-read independent-verification ghcr-application-signing \
            release-gate base-auto-promotion ghcr-quarantine ghcr-read-only \
            ghcr-candidate-writer ghcr-application-promoter; do
  environment "$name" none
done

step '5. Environment secrets'
env_secret() {   # env_secret ENV NAME  (value on stdin)
  gh secret set "$2" --env "$1" --repo "$REPO" && echo "$1: $2"
}
b64 "$KEY_DIR/approval.key" | env_secret base-manual-approval APPROVAL_PRIVATE_KEY_B64
printf '%s' "$APPROVAL_PASSWORD" | env_secret base-manual-approval COSIGN_PASSWORD
b64 "$KEY_DIR/verifier.key" | env_secret independent-verification VERIFIER_PRIVATE_KEY_B64
b64 "$KEY_DIR/app.key" | env_secret ghcr-application-signing APP_COSIGN_KEY_B64
b64 "$KEY_DIR/app.pub" | env_secret ghcr-application-signing APP_COSIGN_PUBKEY_B64
printf '%s' "$APP_PASSWORD" | env_secret ghcr-application-signing COSIGN_PASSWORD
b64 "$KEY_DIR/verifier.pub" | env_secret ghcr-application-signing VERIFIER_PUBLIC_KEY_B64
b64 "$KEY_DIR/gate.key" | env_secret release-gate GATE_PRIVATE_KEY_B64
unset APPROVAL_PASSWORD APP_PASSWORD
echo 'base-auto-promotion gets no key on purpose (it fails closed)'

step '6. The grants branch'
if gh api "repos/$REPO/branches/grants" >/dev/null 2>&1; then
  echo 'exists'
else
  main_sha="$(gh api "repos/$REPO/commits/main" --jq .sha)"
  gh api -X POST "repos/$REPO/git/refs" -f ref=refs/heads/grants -f sha="$main_sha" >/dev/null
  echo 'created (the release gate replaces its content)'
fi

if [[ "${SKIP_RULESETS:-0}" == 1 ]]; then
  step '7. Rulesets: skipped (SKIP_RULESETS=1)'
else
  step '7. Rulesets'
  ruleset() {   # ruleset NAME JSON: create, or update the one with that name
    local id
    id="$(gh api "repos/$REPO/rulesets?per_page=100" --jq ".[] | select(.name == \"$1\") | .id")"
    if [[ -n "$id" ]]; then
      gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<< "$2" >/dev/null && echo "updated: $1"
    else
      gh api -X POST "repos/$REPO/rulesets" --input - <<< "$2" >/dev/null && echo "created: $1"
    fi
  }
  creation() {   # creation branch|tag
    printf '{"name":"%s","target":"%s","enforcement":"active",%s,%s,%s}' \
      "$RULESET_PREFIX: restrict $1 creation" "$1" \
      '"conditions":{"ref_name":{"include":["~ALL"],"exclude":[]}}' \
      '"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]' \
      '"rules":[{"type":"creation"}]'
  }
  ruleset "$RULESET_PREFIX: restrict branch creation" "$(creation branch)"
  ruleset "$RULESET_PREFIX: restrict tag creation" "$(creation tag)"
  ruleset "$RULESET_PREFIX: protect main" "$(cat <<JSON
{"name":"$RULESET_PREFIX: protect main","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "bypass_actors":[],
 "rules":[
  {"type":"deletion"},
  {"type":"pull_request","parameters":{"required_approving_review_count":0,
    "dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,
    "require_last_push_approval":false,"required_review_thread_resolution":false}},
  {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,
    "required_status_checks":[{"context":"unit-tests"},{"context":"base-image-gate"},{"context":"test"}]}}
 ]}
JSON
)"
  echo 'main now only changes through pull requests that pass unit-tests, base-image-gate and test'
fi

step '8. Settings audit'
cd "$ROOT"
python3 ci/audit_repo_settings.py --repo "$REPO"

cat <<EOF

Done. Still by hand (RUNBOOK.md section 4):
  * after step 1 (bootstrap): make the package approved/eclipse-temurin public, later also
    quarantine/eclipse-temurin (your profile -> Packages -> package settings)
  * APPLICATION_READ_TOKEN is not needed: the app is in this repository
EOF
