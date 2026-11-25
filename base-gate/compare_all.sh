#!/usr/bin/env bash
# Run the kit's base-image comparison for every entry of a base-gate plan (base-gate/plan.py).
#
# Per comparison it writes REPORTS/<id>/decision.json with scripts/evaluate.py, the same
# engine and policy (policy/config.json) the base approval workflow uses:
#   * each image is READ from the first of its plan `sources` (config.json mirrors, then the
#     pinned registry) that serves exactly the pinned digest; sources.txt records which one.
#     Reports, decisions and acceptances keep naming the pinned reference;
#   * the executable platform sets must match (drift becomes a BLOCK reason here, as the
#     approval workflow refuses it too);
#   * scripts/compare.sh: Syft, Grype, diffoci and the file inventory on every platform;
#   * an "added" pin is compared with itself: reports/previous.digest makes evaluate.py run in
#     self-comparison mode, which lists the image's absolute findings as attention reasons.
# Never runs image contents. Needs the base toolset (ci/install_verified_tools.py --kind base)
# and, for private GHCR images, `crane auth login` (read-only token).
#
# Usage: compare_all.sh PLAN.json REPORT_DIR   (run from the repository root)
set -Eeuo pipefail
plan="${1:?plan.json}"
reports="${2:?report directory}"
mkdir -p "$reports"

# Validate the whole plan first (a process substitution would swallow a validation failure).
python3 -I -c '
import json, re, sys
ref = re.compile(r"[a-z0-9.:-]+(/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}")
for c in json.load(open(sys.argv[1]))["comparisons"]:
    if not (re.fullmatch(r"c[0-9]+", c["id"]) and ref.fullmatch(c["old_ref"]) and ref.fullmatch(c["new_ref"])):
        sys.exit("malformed plan entry")
    srcs = c.get("sources") or {}
    out = [c["id"], c["old_ref"], c["new_ref"]]
    for side, pinned in (("old", c["old_ref"]), ("new", c["new_ref"])):
        s = srcs.get(side) or [pinned]
        digest = pinned.split("@", 1)[1]
        # Every source must name the pinned digest, and the pinned registry comes last.
        if not (s[-1] == pinned and all(ref.fullmatch(x) and x.endswith("@" + digest) for x in s)):
            sys.exit("malformed plan sources")
        out.append(",".join(s))
    print(*out)
' "$plan" > "$reports/entries.txt"
mapfile -t entries < "$reports/entries.txt"

block() {  # decision file for a comparison that cannot run the engine
  python3 -I -c '
import json, sys
json.dump({"decision": "BLOCK", "block_reasons": [sys.argv[2]], "attention_reasons": [],
           "routine_reasons": [], "review_reasons": []}, open(sys.argv[1], "w"), indent=2)
' "$1/decision.json" "$2"
}

pick_source() {  # pick_source DIGEST SOURCE... -> first source serving exactly DIGEST
  local digest="$1" src
  shift
  for src in "$@"; do
    if [[ "$(crane digest "$src" 2>/dev/null)" == "$digest" ]]; then
      printf '%s\n' "$src"
      return 0
    fi
  done
  crane digest "${@: -1}" >&2 || true   # show the pinned registry's own error
  echo "no source serves $digest: $*" >&2
  return 1
}

for entry in "${entries[@]}"; do
  read -r id old_ref new_ref old_sources new_sources <<< "$entry"
  dir="$reports/$id"
  mkdir -p "$dir"
  printf '\n===== %s: %s -> %s =====\n' "$id" "$old_ref" "$new_ref"
  IFS=',' read -ra old_list <<< "$old_sources"
  IFS=',' read -ra new_list <<< "$new_sources"
  old_src="$(pick_source "${old_ref##*@}" "${old_list[@]}")"
  new_src="$(pick_source "${new_ref##*@}" "${new_list[@]}")"
  printf 'old %s\nnew %s\n' "$old_src" "$new_src" | tee "$dir/sources.txt"
  crane manifest "$old_src" > "$dir/old-index.json"
  crane manifest "$new_src" > "$dir/candidate-index.json"
  if ! platforms="$(python3 -I scripts/manifest_platforms.py "$dir/old-index.json" "$dir/candidate-index.json" 2> "$dir/platforms.err")"; then
    cat "$dir/platforms.err" >&2
    block "$dir" "platform set cannot be compared: $(tail -n 1 "$dir/platforms.err")"
    continue
  fi
  printf '%s\n' "$platforms" > "$dir/platforms.txt"
  if [[ "$old_ref" == "$new_ref" ]]; then
    printf '%s\n' "${new_ref##*@}" > "$dir/previous.digest"
  fi
  OLD_REF="$old_src" CANDIDATE_REF="$new_src" PLATFORMS="$platforms" REPORT_DIR="$dir" bash scripts/compare.sh
  python3 -I scripts/evaluate.py --report-dir "$dir" --platforms "$platforms" --candidate-ref "$new_ref" \
    > "$dir/evaluate.json"
done
