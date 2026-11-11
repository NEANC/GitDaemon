#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"
[[ $(type -t mapping_upstream_san_case) == function ]]
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mapping_scenario_fixture_prepare() { return 0; }
mapping_scenario_calibrate() { return 0; }
mapping_scenario_product_up() { printf 'product\n'; }
mapping_scenario_upstream_count() { printf '1\n'; }
mapping_scenario_upstream_commit() { return 0; }
mapping_scenario_identity_write() { return 0; }
mapping_scenario_upstream_refs() { printf 'refs\n'; }
mapping_scenario_upstream_head() { printf 'head\n'; }
mapping_upstream_san_case() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WORK/dispatch"; return "$SAN_RC"; }
mapping_scenario_apply_negative() { printf 'generic\n' >> "$WORK/dispatch"; return 80; }

for SAN_RC in 1 80; do
    for kind in fallback direct; do
        scenario=$(mapping_assert_scenario "$kind")
        dir=$WORK/$kind-$SAN_RC
        mkdir -p "$dir"
        : > "$WORK/dispatch"
        MAPPING_ASSERT_CASE=wrong_upstream_san
        rc=0
        mapping_scenario_evidence "$kind" "$scenario" generation "$dir" || rc=$?
        [[ $rc == "$SAN_RC" ]] || exit 1
        [[ $(cat "$WORK/dispatch") == "$(printf '%s\t%s\t%s' "$dir" "$kind" "$scenario")" ]] || exit 1
    done
done
printf 'upstream SAN standalone dispatch PASS\n'
