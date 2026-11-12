#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

profile_write() {
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$1"
}

snapshot_write() {
    local file=$1 count=$2 key proto port dest
    : > "$file"
    for key in $MAPPING_WITNESS_KEYS; do
        IFS=$'\t' read -r proto port dest <<< "$(mapping_witness_spec "$key")"
        printf '[%s:0] -A MEmtest -i mmtest -s 140.82.112.10/32 -d %s/32 -p %s --dport %s -m comment --comment "mtest-%s" -j DROP\n' "$count" "$dest" "$proto" "$port" "$key" >> "$file"
    done
}

witness_write() {
    local cross=0 input=0 udp=0 tcp=0
    case "$3" in
        cross-network|host-published) cross=$1 ;;
        host-input) input=$1 ;;
        dns-udp) udp=$1 ;;
        dns-tcp) tcp=$1 ;;
    esac
    printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19420\n%s 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' "$cross" "$input" "$udp" "$tcp" > "$2"
}

identity_write() {
    local dir=$1
    printf 'run_id\tmtest\nscenario\tmapping-fallback-isolation\ngeneration\tg1\nnetwork_id\tnet-one\nimage_id\timage\nprofile_sha256\t%s\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' "$MP_PROFILE_SHA256" > "$dir/identity.tsv"
}

isolation_produces_and_consumes_five_bound_cases() (
    local root=$WORK/run dir=$WORK/case key count=0 rc received=0 paused=0 product_id other_id
    product_id=$(printf '%064d' 3)
    other_id=$(printf '%064d' 4)
    mkdir -p "$root/control" "$dir"
    IT_CONTROL_DIR=$root/control IT_EVIDENCE_DIR=$dir MAPPING_PROFILE=$WORK/profile.tsv
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_CALIBRATED_GENERATION=g1 MAPPING_ASSERT_PRODUCT=$product_id MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=net-one MPF_SCENARIO=mapping-fallback-isolation
    mapping_profile_load "$MAPPING_PROFILE"
    identity_write "$dir"
    mapping_fixture_docker() { [[ $1 == inspect && $4 == product ]] || return 80; printf '%064d\n' 3; }
    resource_ledger_dir() { printf '%s\n' "$root/control/resources"; }
    resource_crosscheck() { return 0; }
    resource_verify_object() { [[ $1 == container && $2 == "$product_id" && $3 == mapping-fallback-isolation && $4 == product ]]; }
    mapping_control_request() {
        [[ $1 == mapping-snapshot && $2 == g1 && $3 == net-one && $4 == "$MP_PROFILE_SHA256" && ${5:-} == "$MAPPING_ASSERT_TARGET" ]] || return 65
        count=$((count + 1)); CONTROL_SEQ=$count
        snapshot_write "$root/mapping-snapshot-$count.rules" "$((count % 5 == 0 ? 20 : 10))"
        witness_write "$received" "$root/mapping-snapshot-$count.witness" "$MAPPING_ASSERT_TARGET"
        printf 'target\t%s\nseq\t%s\ngeneration\tg1\nnetwork_id\tnet-one\nprofile_sha256\t%s\nrules_sha256\t%s\nwitness_sha256\t%s\n' "$MAPPING_ASSERT_TARGET" "$count" "$MP_PROFILE_SHA256" \
            "$(sha256sum "$root/mapping-snapshot-$count.rules" | cut -d' ' -f1)" \
            "$(sha256sum "$root/mapping-snapshot-$count.witness" | cut -d' ' -f1)" > "$root/mapping-snapshot-$count.receipt"
    }
    mapping_receiver_listener_control() {
        [[ $2 != STOP ]] || paused=1
        [[ $2 != CONT ]] || paused=0
        [[ $2 != CONT || $3 == 123 ]] || return 80
        printf '123\n'
    }
    mapping_receiver_negative_probe() {
        [[ $paused == 1 ]] || return 80
        local spec proto port dest token output status
        spec=$(mapping_witness_spec "$1"); IFS=$'\t' read -r proto port dest <<< "$spec"
        token="mtest-g1-$1"
        if [[ $1 == dns-* ]]; then
            output='no servers could be reached'; status=9
            [[ $1 != dns-udp ]] || proto=+notcp
            [[ $1 != dns-tcp ]] || proto=+tcp
            mapping_probe_record "$2/negative/command.tsv" g1 net-one "$1" "$count" "$status" "$output" exec gm-mtest-witness dig +time=1 +tries=1 "$proto" "@$dest" "$token.invalid" A
        else
            output='connection refused'; status=7
            [[ $1 != host-input ]] || port=49383
            mapping_probe_record "$2/negative/command.tsv" g1 net-one "$1" "$count" "$status" "$output" exec gm-mtest-witness sh -c "printf '%s' '$token' | busybox nc -w 2 '$dest' '$port'"
        fi
        printf '%s\n' "$output"
    }
    mapping_receiver_listener_running() { [[ $paused == 0 ]]; }
    mapping_receiver_listener_observed_state() { if [[ $paused == 1 ]]; then printf 'T\n'; else printf 'R\n'; fi; }
    mapping_receiver_witness_counts() { printf '0\n0\n0\n0\n'; }
    mapping_receiver_probe() { [[ $paused == 0 ]] || return 1; received=$((received + 1)); }
    mapping_probe_egress() {
        local spec proto port dest output status
        spec=$(mapping_witness_spec "$3"); IFS=$'\t' read -r proto port dest <<< "$spec"
        if [[ $3 == dns-tcp ]]; then
            output='no servers could be reached'; status=9
            printf 'TCP_DNS_SHARED_NETNS_TOOL=%064d PRODUCT=%s NOT_PRODUCT_DIRECT_TCP=1\n' 2 "$product_id"
            mapping_probe_record "$4/probe/command.tsv" g1 net-one "$3" "$count" "$status" "$output" exec "$(printf '%064d' 2)" dig +time=1 +tries=1 +tcp "@$dest" mtest-g1.invalid A
        elif [[ $3 == dns-udp ]]; then
            output='connection timed out'; status=124
            mapping_probe_record "$4/probe/command.tsv" g1 net-one "$3" "$count" "$status" "$output" exec "$1" timeout 4 busybox nslookup mtest-g1.invalid "$dest"
        else
            output='connection timed out'; status=28
            mapping_probe_record "$4/probe/command.tsv" g1 net-one "$3" "$count" "$status" "$output" exec "$1" curl --noproxy '*' --connect-timeout 2 --max-time 3 "http://$dest:$port/"
        fi
        printf '%s\n' "$output"
    }
    for key in $MAPPING_WITNESS_KEYS; do
        MAPPING_ASSERT_TARGET=$key
        mapping_isolation_check product g1 "$MAPPING_PROFILE" || return 1
        [[ -d $dir/isolation/$key ]] || return 1
        local sub=$dir/isolation/$key proto port dest
        IFS=$'\t' read -r proto port dest <<< "$(mapping_witness_spec "$key")"
        [[ $(cat "$sub/probe.target.tsv") == "$(printf 'target\t%s\nprotocol\t%s\nport\t%s\ndestination\t%s' "$key" "$proto" "$port" "$dest")" ]] || return 1
        [[ $(cat "$sub/negative.target.tsv") == "$(cat "$sub/probe.target.tsv")" ]] || return 1
        [[ $(cat "$sub/listener.stopped.state") == T && $(cat "$sub/listener.restored.state") == R ]] || return 1
        [[ -s $sub/probe/raw.log && -s $sub/negative/raw.log && -s $sub/probe/raw.exit && -s $sub/negative/raw.exit ]] || return 1
        mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || return 1
    done
    (
        local matrix=$dir/mapping-negative-matrix.tsv matrix_root=$WORK/matrix-root case_id evidence generation status
        local -a generations=(g1 g2 g3 g4 g5)
        cp -R "$root" "$matrix_root"
        IT_CONTROL_DIR=$matrix_root/control
        eval "$(declare -f mapping_negative_case_evidence_accept | sed '1s/mapping_negative_case_evidence_accept/mapping_original_case_evidence_accept/')"
        mapping_negative_case_evidence_accept() {
            if [[ $1 == isolation/* ]]; then
                mapping_original_case_evidence_accept "$@"
            else
                return 0
            fi
        }
        for case_id in $MAPPING_NEGATIVE_CASES; do
            evidence=$dir/raw-${case_id//\//-}
            mkdir -p "$evidence"
            if [[ $case_id == isolation/* ]]; then
                key=${case_id#isolation/}
                mkdir -p "$evidence/isolation"
                cp "$dir/identity.tsv" "$evidence/identity.tsv"
                cp -R "$dir/isolation/$key" "$evidence/isolation/$key"
            fi
            printf '%s\tmtest\tmapping-fallback-isolation\tg1\tmanifest\tinput\t%s\t0\tPASS\n' "$case_id" "$evidence" >> "$matrix"
        done
        local index=0 sub receipt name offset file seq first_key second_key first_seq
        for key in $MAPPING_WITNESS_KEYS; do
            offset=$((index * 25))
            index=$((index + 1))
            evidence=$dir/raw-isolation-$key
            sub=$evidence/isolation/$key
            for file in "$sub/negative/command.tsv" "$sub/probe/command.tsv" "$sub/seq.before" "$sub/seq.after"; do
                awk -F '\t' -v OFS='\t' -v offset="$offset" '$1 == "seq_before" || $1 == "seq_after" || NF == 1 {$NF += offset} {print}' "$file" > "$file.next"
                mv "$file.next" "$file"
            done
            for name in calibration.before calibration.after negative before after; do
                receipt=$sub/$name.receipt
                awk -F '\t' -v OFS='\t' -v offset="$offset" '$1 == "seq" {$2 += offset} {print}' "$receipt" > "$receipt.next"
                mv "$receipt.next" "$receipt"
                seq=$(awk -F '\t' '$1 == "seq" {print $2}' "$receipt")
                [[ ! -e $matrix_root/mapping-snapshot-$seq.receipt ]] || [[ $offset == 0 ]] || return 1
                [[ $offset == 0 ]] || cp "$receipt" "$matrix_root/mapping-snapshot-$seq.receipt"
            done
            mapping_original_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$evidence" || return 1
        done
        status=0
        mapping_negative_matrix_accept "$matrix" mtest manifest input || status=$?
        [[ $status == 1 ]] || { printf 'same-generation matrix with distinct seq: %s\n' "$status" >&2; return 1; }
        index=0
        for key in $MAPPING_WITNESS_KEYS; do
            generation=${generations[index]}
            index=$((index + 1))
            evidence=$dir/raw-isolation-$key
            sub=$evidence/isolation/$key
            sed -i "s/generation\tg1/generation\t$generation/" "$sub/binding.tsv" "$sub/negative/command.tsv" "$sub/probe/command.tsv" "$evidence/identity.tsv" "$sub/"*.receipt
            sed -i "s/mtest-g1/mtest-$generation/g" "$sub/negative/command.tsv" "$sub/probe/command.tsv"
            for name in calibration.before calibration.after negative before after; do
                receipt=$sub/$name.receipt
                seq=$(awk -F '\t' '$1 == "seq" {print $2}' "$receipt")
                [[ $index == 1 ]] || cp "$receipt" "$matrix_root/mapping-snapshot-$seq.receipt"
            done
            awk -F '\t' -v OFS='\t' -v k="isolation/$key" -v g="$generation" '$1 == k {$4=g} {print}' "$matrix" > "$matrix.next"
            mv "$matrix.next" "$matrix"
            mapping_original_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation "$generation" manifest input "$evidence" || return 1
        done
        mapping_negative_matrix_accept "$matrix" mtest manifest input || return 1
        read -r first_key second_key _ <<< "$MAPPING_WITNESS_KEYS"
        first_seq=$(awk -F '\t' '$1 == "seq" {print $2}' "$dir/raw-isolation-$first_key/isolation/$first_key/before.receipt")
        receipt=$matrix_root/mapping-snapshot-$first_seq.receipt
        cp "$receipt" "$WORK/first-root-receipt"
        cp "$dir/raw-isolation-$second_key/isolation/$second_key/before.receipt" "$receipt"
        status=0
        mapping_original_case_evidence_accept "isolation/$first_key" mtest mapping-fallback-isolation g1 manifest input "$dir/raw-isolation-$first_key" || status=$?
        [[ $status == 1 ]] || { printf 'cross-case root receipt: %s\n' "$status" >&2; return 1; }
        cp "$WORK/first-root-receipt" "$receipt"
        mapping_original_case_evidence_accept "isolation/$first_key" mtest mapping-fallback-isolation g1 manifest input "$dir/raw-isolation-$first_key" || return 1
    ) || return 1
    for key in $MAPPING_WITNESS_KEYS; do
        sub=$dir/isolation/$key
        for name in negative probe; do
            cp "$sub/$name/raw.log" "$WORK/$key-$name-raw.log"
            printf '\0' >> "$sub/$name/raw.log"
            rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
            [[ $rc == 1 ]] || { printf '%s %s NUL: %s\n' "$key" "$name" "$rc" >&2; return 1; }
            cp "$WORK/$key-$name-raw.log" "$sub/$name/raw.log"
            printf '\n' >> "$sub/$name/raw.log"
            rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
            [[ $rc == 1 ]] || { printf '%s %s newline: %s\n' "$key" "$name" "$rc" >&2; return 1; }
            cp "$WORK/$key-$name-raw.log" "$sub/$name/raw.log"
            mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || return 1
        done
    done
    MAPPING_ASSERT_GENERATION=g2 MAPPING_ASSERT_PRODUCT=$other_id
    mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || return 1
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_PRODUCT=$product_id
    cp "$dir/isolation/host-input/binding.tsv" "$WORK/binding"
    sed -i "s/$product_id/$other_id/" "$dir/isolation/host-input/binding.tsv"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/binding" "$dir/isolation/host-input/binding.tsv"
    local sub=$dir/isolation/dns-udp
    cp "$sub/probe/raw.exit" "$WORK/udp-exit"
    printf '1\n' > "$sub/probe/raw.exit"
    rc=0; mapping_negative_case_evidence_accept isolation/dns-udp mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/udp-exit" "$sub/probe/raw.exit"
    cp "$sub/probe/command.tsv" "$WORK/udp-command"
    sed -i 's/^exit\t124$/exit\t1/' "$sub/probe/command.tsv"
    rc=0; mapping_negative_case_evidence_accept isolation/dns-udp mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/udp-command" "$sub/probe/command.tsv"
    sub=$dir/isolation/host-input
    cp "$sub/probe/raw.log" "$WORK/probe-raw"
    cp "$sub/probe.log" "$WORK/probe-log"
    printf 'Operation timed out\n' > "$sub/probe/raw.log"
    printf 'Operation timed out\n' >> "$sub/probe.log"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/probe-raw" "$sub/probe/raw.log"
    cp "$WORK/probe-log" "$sub/probe.log"
    local sub=$dir/isolation/host-input
    [[ -s $sub/probe/command.tsv && -s $sub/negative/command.tsv ]] || return 1
    cp "$sub/probe/command.tsv" "$WORK/probe-command.tsv"
    cp "$dir/isolation/cross-network/probe/command.tsv" "$sub/probe/command.tsv"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/probe-command.tsv" "$sub/probe/command.tsv"
    sed -i 's/generation\tg1/generation\tg2/' "$sub/probe/command.tsv"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/probe-command.tsv" "$sub/probe/command.tsv"
    sed -i 's/seq_before\t14/seq_before\t4/' "$sub/probe/command.tsv"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/probe-command.tsv" "$sub/probe/command.tsv"
    cp "$sub/negative/command.tsv" "$WORK/negative-command.tsv"
    sed -i 's/seq_after\t13/seq_after\t8/' "$sub/negative/command.tsv"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/negative-command.tsv" "$sub/negative/command.tsv"
    [[ $count == 25 ]] || return 1
    local sub=$dir/isolation/cross-network
    for name in probe/raw.exit negative/raw.exit probe.target.tsv negative.target.tsv listener.stopped.state listener.restored.state; do
        cp "$sub/$name" "$WORK/${name//\//-}"
        rm "$sub/$name"
        rc=0; mapping_negative_case_evidence_accept isolation/cross-network mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
        [[ $rc == 80 ]] || { printf '%s missing: %s\n' "$name" "$rc" >&2; return 1; }
        cp "$WORK/${name//\//-}" "$sub/$name"
    done
    printf '0\n' > "$sub/probe/raw.exit"
    rc=0; mapping_negative_case_evidence_accept isolation/cross-network mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/probe-raw.exit" "$sub/probe/raw.exit"
    printf 'invalid\n' > "$sub/negative/raw.exit"
    rc=0; mapping_negative_case_evidence_accept isolation/cross-network mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    cp "$WORK/negative-raw.exit" "$sub/negative/raw.exit"
    printf 'target\tother\n' > "$sub/probe.target.tsv"
    rc=0; mapping_negative_case_evidence_accept isolation/cross-network mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/probe.target.tsv" "$sub/probe.target.tsv"
    printf 'R\n' > "$sub/listener.stopped.state"
    rc=0; mapping_negative_case_evidence_accept isolation/cross-network mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/listener.stopped.state" "$sub/listener.stopped.state"
    printf 'T\n' > "$sub/listener.restored.state"
    rc=0; mapping_negative_case_evidence_accept isolation/cross-network mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/listener.restored.state" "$sub/listener.restored.state"
    for name in calibration.before calibration.after negative before after; do
        cp "$dir/isolation/dns-udp/$name.receipt" "$dir/isolation/host-input/$name.receipt"
        cp "$dir/isolation/dns-udp/$name.rules" "$dir/isolation/host-input/$name.rules"
        cp "$dir/isolation/dns-udp/$name.witness" "$dir/isolation/host-input/$name.witness"
    done
    cp "$dir/isolation/host-input/seq.before" "$WORK/seq.before"
    cp "$dir/isolation/host-input/seq.after" "$WORK/seq.after"
    cp "$dir/isolation/dns-udp/seq.before" "$dir/isolation/host-input/seq.before"
    cp "$dir/isolation/dns-udp/seq.after" "$dir/isolation/host-input/seq.after"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/seq.before" "$dir/isolation/host-input/seq.before"
    cp "$WORK/seq.after" "$dir/isolation/host-input/seq.after"
    count=11
    for name in calibration.before calibration.after negative before after; do
        for key in rules witness receipt; do
            cp "$root/mapping-snapshot-$count.$key" "$dir/isolation/host-input/$name.$key"
        done
        count=$((count + 1))
    done
    for key in $MAPPING_WITNESS_KEYS; do
        [[ -s $dir/isolation/$key/calibration.before.receipt && -s $dir/isolation/$key/calibration.after.receipt \
            && -s $dir/isolation/$key/negative.receipt && -s $dir/isolation/$key/before.receipt \
            && -s $dir/isolation/$key/after.receipt ]] || return 1
    done
    cp "$dir/isolation/host-input/before.rules" "$WORK/original.rules"
    cp "$dir/isolation/dns-udp/after.rules" "$dir/isolation/host-input/before.rules"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/original.rules" "$dir/isolation/host-input/before.rules"
    cp "$dir/isolation/dns-udp/before.receipt" "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$root/mapping-snapshot-19.receipt" "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$root/mapping-snapshot-19.receipt" "$WORK/receipt"
    rm "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    cp "$WORK/receipt" "$dir/isolation/host-input/before.receipt"
    sed -i 's/generation\tg1/generation\tg2/' "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/receipt" "$dir/isolation/host-input/before.receipt"
    sed -i 's/network_id\tnet-one/network_id\tnet-two/' "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$root/mapping-snapshot-14.receipt" "$dir/isolation/host-input/before.receipt"
    for key in before.rules negative.exit; do
        cp "$dir/isolation/host-input/$key" "$WORK/$key"
        rm "$dir/isolation/host-input/$key"
        rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
        [[ $rc == 80 ]] || { printf '%s missing: %s\n' "$key" "$rc" >&2; return 1; }
        : > "$dir/isolation/host-input/$key"
        rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
        [[ $rc == 80 ]] || { printf '%s empty: %s\n' "$key" "$rc" >&2; return 1; }
        printf 'invalid\n' > "$dir/isolation/host-input/$key"
        rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
        if [[ $key == before.rules ]]; then
            [[ $rc == 1 ]] || { printf '%s invalid: %s\n' "$key" "$rc" >&2; return 1; }
        else
            [[ $rc == 80 ]] || { printf '%s invalid: %s\n' "$key" "$rc" >&2; return 1; }
        fi
        cp "$WORK/$key" "$dir/isolation/host-input/$key"
    done
    key=host-input
    cp "$dir/isolation/$key/after.rules" "$WORK/after.rules"
    printf 'not a drop rule\n' > "$dir/isolation/$key/after.rules"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    snapshot_write "$dir/isolation/$key/after.rules" 10
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/after.rules" "$dir/isolation/$key/after.rules"
    printf '0\n' > "$dir/isolation/$key/seq.after"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf '20\n' > "$dir/isolation/$key/seq.after"
    key=dns-udp
    printf 'target\tother\ngeneration\tg1\nnetwork_id\tnet-one\nprofile_sha256\t%s\nproduct_id\t%s\n' "$MP_PROFILE_SHA256" "$product_id" > "$dir/isolation/$key/binding.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    key=host-published
    printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n' > "$dir/isolation/$key/after.witness"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    key=cross-network
    printf 'wrong\n' > "$dir/isolation/$key/reject.layer"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'policy\n' > "$dir/isolation/$key/reject.layer"
    printf 'probe_exit\t1\n' > "$dir/isolation/$key/negative.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'probe_exit\t0\n' > "$dir/isolation/$key/negative.tsv"
    printf 'no listener stopped\n' > "$dir/isolation/$key/listener.pid"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    key=dns-tcp
    rm "$dir/isolation/$key/negative.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    printf 'probe_exit\t2\n' > "$dir/isolation/$key/negative.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    IT_EVIDENCE_DIR=$WORK/no-negative
    mkdir -p "$IT_EVIDENCE_DIR"
    MAPPING_ASSERT_TARGET=cross-network
    mapping_receiver_negative_probe() { return 80; }
    rc=0; mapping_isolation_check product g1 "$MAPPING_PROFILE" || rc=$?
    [[ $rc == 80 && ! -f $IT_EVIDENCE_DIR/isolation/cross-network/reject.layer ]] || return 1
    return 0
)

probe_execution_records_actual_argv() (
    local dir=$WORK/actual-command output status=0
    mkdir -p "$dir/probe" "$dir/negative"
    MP_RUN_ID=mtest MP_NETWORK_ID=net-one MAPPING_ASSERT_GENERATION=g1 CONTROL_SEQ=9
    mapping_fixture_docker() {
        printf '%s\n' "$*" > "$dir/observed"
        printf 'Connection timed out\n'
        return 28
    }
    mapping_probe_egress product g1 host-input "$dir" > /dev/null || status=$?
    [[ $status == 0 && $(cat "$dir/observed") == 'exec product curl --noproxy * --connect-timeout 2 --max-time 3 http://172.30.243.1:49383/' ]] || return 1
    [[ $(cat "$dir/probe/raw.exit") == 28 && $(cat "$dir/probe/raw.log") == 'Connection timed out' ]] || return 1
    [[ $(tail -n 1 "$dir/probe/command.tsv") == $'arg\thttp://172.30.243.1:49383/' ]] || return 1
    mapping_fixture_docker() {
        printf '%s\n' "$*" > "$dir/observed"
        printf 'no servers could be reached\n'
        return 9
    }
    mapping_receiver_negative_probe dns-tcp "$dir" > /dev/null || return 1
    [[ $(cat "$dir/observed") == 'exec gm-mtest-witness dig +time=1 +tries=1 +tcp @172.30.244.53 mtest-g1-dns-tcp.invalid A' ]] || return 1
    [[ $(cat "$dir/negative/raw.exit") == 9 && $(cat "$dir/negative/raw.log") == 'no servers could be reached' ]] || return 1
)

isolation_stop_failure_restores_or_blocks() (
    local mode=$1 root dir rc=0 paused=0 resumes=0 probes=0
    root=$WORK/$mode dir=$WORK/$mode/evidence
    mkdir -p "$root/control" "$dir"
    IT_CONTROL_DIR=$root/control IT_EVIDENCE_DIR=$dir MAPPING_PROFILE=$WORK/profile.tsv
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_CALIBRATED_GENERATION=g1 MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=net-one
    mapping_profile_load "$MAPPING_PROFILE"
    mapping_fixture_docker() { [[ $1 == inspect && $4 == product ]] || return 80; printf '%064d\n' 3; }
    resource_ledger_dir() { printf '%s\n' "$root/control/resources"; }
    resource_crosscheck() { return 0; }
    resource_verify_object() { [[ $1 == container && $2 == "$(printf '%064d' 3)" && $4 == product ]]; }
    mapping_receiver_probe() { probes=$((probes + 1)); [[ $paused == 0 ]] || return 80; }
    mapping_receiver_witness_counts() { printf '0\n0\n0\n0\n'; }
    mapping_control_request() {
        [[ $1 == mapping-snapshot && ${5:-} == cross-network ]] || return 65
        [[ $mode != snapshot_failure || $paused == 0 ]] || return 77
        CONTROL_SEQ=$(( ${CONTROL_SEQ:-0} + 1 ))
        snapshot_write "$root/mapping-snapshot-$CONTROL_SEQ.rules" 10
        witness_write "$probes" "$root/mapping-snapshot-$CONTROL_SEQ.witness" cross-network
        printf 'target\tcross-network\nseq\t%s\ngeneration\tg1\nnetwork_id\tnet-one\nprofile_sha256\t%s\nrules_sha256\t%s\nwitness_sha256\t%s\n' "$CONTROL_SEQ" "$MP_PROFILE_SHA256" \
            "$(sha256sum "$root/mapping-snapshot-$CONTROL_SEQ.rules" | cut -d' ' -f1)" \
            "$(sha256sum "$root/mapping-snapshot-$CONTROL_SEQ.witness" | cut -d' ' -f1)" > "$root/mapping-snapshot-$CONTROL_SEQ.receipt"
        if [[ $mode == snapshot_copy_failure && $paused == 1 ]]; then
            rm "$root/mapping-snapshot-$CONTROL_SEQ.witness"
        fi
    }
    mapping_receiver_listener_control() {
        if [[ $2 == STOP ]]; then
            paused=1
            [[ $mode != stop_output_failure ]] || return 0
            [[ $mode != stop_error && $mode != stop_unknown && $mode != stop_resume_failure ]] || return 77
            printf '123\n'
            return 0
        fi
        resumes=$((resumes + 1))
        [[ $mode != cont_failure && $mode != stop_resume_failure ]] || return 77
        paused=0
        printf '123\n'
    }
    mapping_receiver_listener_pid() {
        printf 'lookup\n' >> "$root/lookups"
        [[ $mode != stop_unknown ]] || return 80
        printf '123\n'
    }
    mapping_receiver_listener_running() { [[ $paused == 0 && $mode != running_failure ]]; }
    mapping_receiver_listener_observed_state() { if [[ $paused == 1 ]]; then printf 'T\n'; else printf 'R\n'; fi; }
    mapping_receiver_negative_probe() { [[ $mode != negative_failure ]] || return 77; printf 'connection refused\n'; }
    mapping_isolation_check product g1 "$MAPPING_PROFILE" || rc=$?
    [[ $rc == 80 && $probes == 2 ]] || return 1
    [[ -f $dir/isolation/cross-network/stop.outcome.tsv ]] || return 1
    [[ ! -e $dir/isolation/host-published ]] || return 1
    case "$mode" in
        stop_error|stop_unknown|stop_output_failure|stop_resume_failure)
            [[ $(wc -l < "$root/lookups") == 1 && $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tstop'* ]] || return 1
            if [[ $mode == stop_unknown || $mode == stop_resume_failure ]]; then
                [[ $paused == 1 ]] || return 1
                [[ $mode != stop_unknown || $resumes == 0 ]] || return 1
                [[ $mode != stop_resume_failure || ( $resumes == 1 && $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'restore_exit\t77'*$'running_exit\t1'* ) ]] || return 1
                return 0
            fi
            [[ $resumes == 1 && $paused == 0 ]] || return 1
            ;;
        negative_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tnegative-probe'*$'original_exit\t77'* ]] || return 1 ;;
        snapshot_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tsnapshot'*$'original_exit\t77'* ]] || return 1 ;;
        snapshot_copy_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tsnapshot-copy'*$'original_exit\t1'* ]] || return 1 ;;
        cont_failure)
            [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tnone'*$'restore_exit\t77'*$'running_exit\t1'* && $paused == 1 && $resumes == 1 ]] || return 1
            return 0
            ;;
        running_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'running_exit\t1'* ]] || return 1 ;;
    esac
    [[ $paused == 0 ]] || return 1
    [[ $mode == running_failure || $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'running_exit\t0'* ]] || return 1
    return 0
)

profile_write "$WORK/profile.tsv"
probe_execution_records_actual_argv
isolation_produces_and_consumes_five_bound_cases
for failure in negative_failure snapshot_failure snapshot_copy_failure cont_failure running_failure; do
    isolation_stop_failure_restores_or_blocks "$failure"
done
for failure in stop_error stop_output_failure stop_unknown stop_resume_failure; do
    isolation_stop_failure_restores_or_blocks "$failure"
done
