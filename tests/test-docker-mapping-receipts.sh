#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/docker-validation-environment.sh"
source "$HERE/../scripts/lib/foundation.sh"
source "$HERE/docker-network-guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

profile=$WORK/profile.tsv
printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$profile"
MAPPING_ASSERT_GENERATION=gen1
MP_NETWORK_ID=netid-abc
IT_CONTROL_DIR=$WORK/control
mkdir -p "$IT_CONTROL_DIR"
mode=healthy
missing_key=''

mapping_control_request() {
    [[ $1 == mapping-snapshot && $2 == gen1 && $3 == netid-abc ]] || return 80
    CONTROL_SEQ=$((CONTROL_SEQ + 1))
    printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n' "$(cat "$WORK/hit-cross-network")" > "$WORK/mapping-snapshot-$CONTROL_SEQ.witness"
    printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19420\n' "$(cat "$WORK/hit-host-input")" >> "$WORK/mapping-snapshot-$CONTROL_SEQ.witness"
    printf '%s 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n' "$(cat "$WORK/hit-dns-udp")" >> "$WORK/mapping-snapshot-$CONTROL_SEQ.witness"
    printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' "$(cat "$WORK/hit-dns-tcp")" >> "$WORK/mapping-snapshot-$CONTROL_SEQ.witness"
}

docker() {
    [[ $1 == exec ]] || return 80
    printf '%s\n' "$*" >> "$WORK/probes"
    [[ $mode != missing ]] || return 80
    [[ $mode != execution-error ]] || return 80
    local key
    for key in $MAPPING_WITNESS_KEYS; do
        if [[ $* == *"mtest-gen1-$key"* ]]; then
            if [[ $mode != paused && $mode != "pause-$key" ]]; then
                local n
                n=$(cat "$WORK/hit-$key")
                printf '%s\n' "$((n + 1))" > "$WORK/hit-$key"
                if [[ $key == host-published ]]; then
                    n=$(cat "$WORK/hit-cross-network")
                    printf '%s\n' "$((n + 1))" > "$WORK/hit-cross-network"
                fi
            fi
            break
        fi
    done
    case "$*" in
        *'dig '*) printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; QUESTION SECTION:\n;%s. IN A\n;; SERVER: 172.30.244.53#53(172.30.244.53)\n' "${@: -2:1}" ;;
        *) printf '%s' "$5" | awk -F "'" '{print $4}' ;;
    esac
}

resource_crosscheck() { return 0; }
resource_verify_object() { return 0; }
mapping_fixture_docker() {
    if [[ $1 == exec ]]; then docker "$@"; return $?; fi
    case "$*" in
        'network inspect '*) printf '%064d\n' 2 ;;
        *'{{.Id}}'*) printf '%064d\n' 1 ;;
        *'{{.HostConfig.NetworkMode}}'*) printf 'gm-mtest-w-net|true|%064d\n' 2 ;;
        *) return 80 ;;
    esac
}
resource_ledger_dir() { printf '%s\n' "$WORK/control"; }

check_case() {
    local expected=$1 actual=0 key
    MP_WITNESS_CALIBRATED=0
    for key in $MAPPING_WITNESS_KEYS; do printf '0\n' > "$WORK/hit-$key"; done
    : > "$WORK/probes"
    mapping_calibrate_witness "$profile" > "$WORK/output" || actual=$?
    printf 'CALIBRATION mode=%s expected=%s actual=%s flag=%s\n' "$mode" "$expected" "$actual" "$MP_WITNESS_CALIBRATED"
    [[ $actual == "$expected" ]] || return 1
    if [[ $expected == 0 ]]; then
        for key in $MAPPING_WITNESS_KEYS; do
            case "$key" in
                dns-udp) grep -q -- '+notcp @172.30.244.53 mtest-gen1-dns-udp.invalid' "$WORK/probes" || return 1 ;;
                dns-tcp) grep -q -- '+tcp @172.30.244.53 mtest-gen1-dns-tcp.invalid' "$WORK/probes" || return 1 ;;
                *) grep -q -- "mtest-gen1-$key" "$WORK/probes" || return 1 ;;
            esac
        done
    fi
    if [[ $expected == 0 ]]; then [[ $MP_WITNESS_CALIBRATED == 1 ]]; else [[ $MP_WITNESS_CALIBRATED == 0 ]]; fi
}

mode=paused
check_case 1
mode=healthy
check_case 0
for missing_key in $MAPPING_WITNESS_KEYS; do
    mode=pause-$missing_key
    check_case 1
    mode=healthy
    check_case 0
done
mode=missing
check_case 80
mode=healthy
check_case 0
mode=execution-error
check_case 80

printf '0\n' > "$WORK/hit-cross-network"
printf '0\n' > "$WORK/hit-host-input"
printf '0\n' > "$WORK/hit-dns-udp"
printf '0\n' > "$WORK/hit-dns-tcp"
CONTROL_SEQ=0
mapping_control_request mapping-snapshot gen1 netid-abc
file=$WORK/mapping-snapshot-$CONTROL_SEQ.witness
[[ $(mapping_witness "$file") == $'0\n0\n0\n0' ]]
if witness_chain_counts "$file" >/dev/null 2>&1; then exit 1; fi
printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' > "$WORK/network.witness"
[[ $(witness_chain_counts "$WORK/network.witness") == $'0\n0\n0' ]]
if mapping_witness "$WORK/network.witness" >/dev/null 2>&1; then exit 1; fi
if mapping_witness_growth $'0\n0\n0\n0' $'1\n0\n0\n0' host-input; then exit 1; fi
if mapping_witness_growth $'0\n0\n0\n0' $'1\n1\n0\n0' cross-network; then exit 1; fi
mapping_witness_growth $'0\n0\n0\n0' $'1\n0\n0\n0' host-published
mapping_witness_growth $'0\n0\n0\n0' $'0\n1\n0\n0' host-input
mapping_witness_growth $'0\n0\n0\n0' $'0\n0\n1\n0' dns-udp
mapping_witness_growth $'0\n0\n0\n0' $'0\n0\n0\n1' dns-tcp

E=$WORK RUN=mtest
OWN_NS_RULES=() OWN_NS_CHAINS=()
docker() { [[ $1 == inspect ]] && printf '%064d\n' 1; }
guard_mapping_witness_identity() { printf '123\n'; }
nsenter() { printf '%s\n' "$*" >> "$WORK/guard-calls"; }
guard_mapping_witness_install
[[ ${#OWN_NS_RULES[@]} == 5 ]]
grep -q -- '-A MSmtest -p tcp --dport 19420 -j RETURN' "$WORK/guard-calls"
grep -q -- '-A MSmtest -p tcp --dport 19420 -j RETURN' "$WORK/witness-rules.owned"

scenario_calibration_contract() (
    local selected=$1 expected=$2 rc=0
    MAPPING_PROFILE=$profile MAPPING_ASSERT_GENERATION=gen1 MAPPING_ASSERT_CASE=$selected
    MAPPING_ASSERT_CALIBRATED_GENERATION='' MP_WITNESS_CALIBRATED=0
    : > "$WORK/scenario-probes"
    rm -f "$WORK/product-started"
    mapping_scenario_fixture_prepare() { return 0; }
    mapping_proxy_calibrate() { return 0; }
    mapping_receiver_witness_counts() {
        local cross=0 input=0 udp=0 tcp=0 name
        while IFS= read -r name; do
            case "$name" in
                cross-network|host-published) cross=$((cross + 1)) ;;
                host-input) input=$((input + 1)) ;;
                dns-udp) udp=$((udp + 1)) ;;
                dns-tcp) tcp=$((tcp + 1)) ;;
            esac
        done < "$WORK/scenario-probes"
        printf '%s\n%s\n%s\n%s\n' "$cross" "$input" "$udp" "$tcp"
    }
    mapping_receiver_probe() {
        [[ $expected != missing ]] || return 80
        [[ $expected != paused || $1 != dns-tcp ]] || return 1
        printf '%s\n' "$1" >> "$WORK/scenario-probes"
    }
    mapping_scenario_product_up() { : > "$WORK/product-started"; return 80; }
    mapping_scenario_evidence fallback mapping-fallback gen1 "$WORK" || rc=$?
    if [[ $selected == isolation/* ]]; then
        if [[ $expected == healthy ]]; then
            [[ $rc == 80 && -e $WORK/product-started && $MP_WITNESS_CALIBRATED == 1 ]] || return 1
            [[ $(wc -l < "$WORK/scenario-probes") == 5 ]] || return 1
        else
            [[ $rc == 80 && ! -e $WORK/product-started && $MP_WITNESS_CALIBRATED == 0 ]] || return 1
        fi
    else
        [[ $rc == 80 && -e $WORK/product-started && ! -s $WORK/scenario-probes ]] || return 1
    fi
)

scenario_calibration_contract isolation/cross-network healthy
scenario_calibration_contract isolation/cross-network missing
scenario_calibration_contract isolation/cross-network paused
scenario_calibration_contract '' healthy
