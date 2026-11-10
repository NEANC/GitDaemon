#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/run/control" "$WORK/run/g1/control" "$WORK/run/g2/control" "$WORK/source"
MAPPING_PROFILE=$WORK/profile.tsv
MAPPING_MANIFEST=$WORK/manifest.tsv
MAPPING_PRODUCT_IMAGE=product
IT_EVIDENCE_DIR=$WORK/run
IT_CONTROL_DIR=$WORK/run/control
MAPPING_INPUT_ROOT=$WORK/run
printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
printf 'manifest\n' > "$MAPPING_MANIFEST"
printf 'frozen\n' > "$WORK/source/input.sh"
printf 'unique\n' > "$WORK/run/g1/control/unique-commit"
printf 'unique\n' > "$WORK/run/g2/control/unique-commit"
mapping_network_id_load() { printf 'network-id\n'; }
mapping_scenario_input_facts() {
    [[ ${BAD_OWNER:-0} == 0 ]] || { printf '10001 644\n'; return; }
    printf '0 644\n'
}

freeze_inputs() {
    sha256sum "$WORK/source/input.sh" > "$WORK/run/inputs.sha256"
    sha256sum "$WORK/run/inputs.sha256" | cut -d' ' -f1 > "$WORK/run/inputs.sha256.digest"
}

identity_status() {
    local generation=$1 rc=0
    rm -f "$WORK/run/$generation/identity.tsv"
    mapping_scenario_identity_write fallback mapping-fallback "$generation" "$WORK/run/$generation" || rc=$?
    printf '%s\n' "$rc"
}

freeze_inputs
expected=$(sha256sum "$WORK/run/inputs.sha256" | cut -d' ' -f1)
[[ $(identity_status g1) == 0 ]] || { printf 'run-root-only positive failed\n' >&2; exit 1; }
[[ $(awk -F '\t' '$1=="input_sha256"{print $2}' "$WORK/run/g1/identity.tsv") == "$expected" ]] || exit 1
[[ $(identity_status g2) == 0 ]] || { printf 'second generation failed\n' >&2; exit 1; }
[[ $(awk -F '\t' '$1=="input_sha256"{print $2}' "$WORK/run/g2/identity.tsv") == "$expected" ]] || exit 1
printf 'fake\n' > "$WORK/run/g2/inputs.sha256"
[[ $(identity_status g2) == 0 ]] || exit 1
[[ $(awk -F '\t' '$1=="input_sha256"{print $2}' "$WORK/run/g2/identity.tsv") == "$expected" ]] || exit 1
rm "$WORK/run/inputs.sha256"
[[ $(identity_status g1) == 80 && ! -e $WORK/run/g1/identity.tsv ]] || exit 1
freeze_inputs
printf 'tampered\n' > "$WORK/run/inputs.sha256"
[[ $(identity_status g1) == 80 && ! -e $WORK/run/g1/identity.tsv ]] || exit 1
freeze_inputs
printf 'tampered\n' > "$WORK/source/input.sh"
[[ $(identity_status g1) == 80 && ! -e $WORK/run/g1/identity.tsv ]] || exit 1
printf 'frozen\n' > "$WORK/source/input.sh"
freeze_inputs
rm "$WORK/run/inputs.sha256.digest"
[[ $(identity_status g1) == 80 && ! -e $WORK/run/g1/identity.tsv ]] || exit 1
freeze_inputs
printf '%064d\n' 0 > "$WORK/run/inputs.sha256.digest"
[[ $(identity_status g1) == 80 && ! -e $WORK/run/g1/identity.tsv ]] || exit 1
freeze_inputs
BAD_OWNER=1
[[ $(identity_status g1) == 80 && ! -e $WORK/run/g1/identity.tsv ]] || exit 1
BAD_OWNER=0
IT_CONTROL_DIR=$WORK/run/g1/control
[[ $(identity_status g1) == 80 && ! -e $WORK/run/g1/identity.tsv ]] || exit 1
printf 'input contract PASS\n'
