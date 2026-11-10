#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 模拟 Docker 外部事实，所有对象只存于本例临时目录，不运行容器命令。
probe_contract_docker() {
    local kind='' action=${1:-} arg id role='' scenario='' run='' format='' network=''
    printf '%s\n' "$*" >> "$CASE_DIR/docker.log"
    case "$action" in
        volume|network) kind=$action; shift; action=${1:-} ;;
    esac
    shift || return 98
    case "$action" in
        create)
            [[ ${CONTRACT_MODE:-} != prepare-fail ]] || return 42
            [[ -n $kind ]] || kind=container
            id=${*: -1}
            while (( $# )); do
                arg=$1; shift
                case "$arg" in
                    --label)
                        case "$1" in
                            gitdaemon.run=*) run=${1#*=} ;;
                            gitdaemon.scenario=*) scenario=${1#*=} ;;
                            gitdaemon.role=*) role=${1#*=} ;;
                        esac
                        shift ;;
                    --network) network=$1; shift ;;
                esac
            done
            [[ $kind != container ]] || id="container-$role"
            printf '%s\t%s\t%s\t%s\n' "$run" "$scenario" "$role" "$network" > "$CASE_DIR/objects/$id"
            printf '%s\n' "$id"
            ;;
        inspect)
            if [[ ${1:-} == -f ]]; then format=$2; shift 2; fi
            id=$1
            [[ -f $CASE_DIR/objects/$id ]] || return 1
            case "$format" in
                '{{.Id}}'|'{{.Name}}') printf '%s\n' "$id" ;;
                *gitdaemon.run*) cut -f1-3 "$CASE_DIR/objects/$id" ;;
                '{{json .Mounts}}') printf '[{"Destination":"/ev","RW":true}]\n' ;;
                *) printf '{"id":"%s"}\n' "$id" ;;
            esac
            ;;
        run)
            [[ " $* " == *' --network none '* ]] || return 98
            if [[ " $* " == *' -i '* ]]; then cat >/dev/null; fi
            ;;
        start)
            id=${*: -1}
            network=$(cut -f4 "$CASE_DIR/objects/$id")
            [[ $network == none ]] || { printf 'NETWORK_START\n' >> "$CASE_DIR/events"; return 98; }
            case "$id" in
                container-evidence-image-check) printf '10001:10001\n' ;;
                container-evidence-verify) printf 'owner=10001:10001\nwrite=PASS\nfifo=PASS\n' ;;
            esac
            ;;
        rm) rm -f "$CASE_DIR/objects/${*: -1}" ;;
        *) printf 'UNEXPECTED %s\n' "$action" >> "$CASE_DIR/events"; return 98 ;;
    esac
    return 0
}

# 加载真实库后，仅注入环境授权和 Docker 外部边界，保留所有被测业务函数。
probe_contract_source() {
    builtin source "$@"
    if [[ $1 == */docker-validation-environment.sh ]]; then
        validation_environment_verify() {
            [[ ${CONTRACT_MODE:-} != auth-fail ]] || return 77
            VE_DOCKER_ENDPOINT=unix:///contract-only/docker.sock
            return 0
        }
        validation_docker() { probe_contract_docker "$@"; }
        cat() {
            if [[ ${CONTRACT_MODE:-} == control-fail && ${1:-} == */ack-1 ]]; then return 42; fi
            command cat "$@"
        }
    fi
}

# 使用真实 CLI 握手和控制请求，通过文件协议响应 nonce/generation，而非注入 ACK 变量。
probe_entry_case() {
    local mode=$1 expected=$2 rc=0 pid request action generation network digest nonce i
    export CASE_DIR=$WORK/$mode CONTRACT_MODE=$mode
    mkdir -p "$CASE_DIR/control" "$CASE_DIR/objects"
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$CASE_DIR/profile"
    printf 'contract-manifest\n' > "$CASE_DIR/manifest"
    (
        for ((i=0; i<100; i++)); do
            if [[ -s $CASE_DIR/control/runner-handshake.tsv ]]; then
                printf 'PREPARE_START\n' >> "$CASE_DIR/events"
                : > "$CASE_DIR/control/prepare-start"
                break
            fi
            sleep 0.05
        done
        for ((i=0; i<100; i++)); do
            request=$CASE_DIR/control/request-1
            if [[ -s $request ]]; then
                read -r action generation network digest nonce < "$request"
                [[ $action == mapping-ready && $network == gm-mtest-m-net ]] || exit 1
                [[ $digest == "$(sha256sum "$CASE_DIR/profile" | cut -d' ' -f1)" ]] || exit 1
                [[ -s $CASE_DIR/control/resources/ledger.tsv ]] || exit 1
                [[ -f $CASE_DIR/mapping-evidence-volume.txt ]] || exit 1
                printf 'READY %s\n' "$generation" >> "$CASE_DIR/events"
                if [[ $mode == wrong-ack ]]; then generation=stale-generation; fi
                printf '%s %s\n' "$nonce" "$generation" > "$CASE_DIR/control/ack-1.tmp"
                mv "$CASE_DIR/control/ack-1.tmp" "$CASE_DIR/control/ack-1"
                exit 0
            fi
            [[ ! -f $CASE_DIR/control/runner-status.txt ]] || exit 0
            sleep 0.05
        done
        exit 1
    ) &
    pid=$!
    env -u MAPPING_ACK_GENERATION -u MAPPING_ASSERT_GENERATION -u MAPPING_GENERATION \
        BASH_ENV="$WORK/boundary.sh" IT_NETWORK_GUARD_READY=1 \
        IT_CONTROL_DIR="$CASE_DIR/control" IT_EVIDENCE_DIR="$CASE_DIR" \
        RESOURCE_LEDGER_DIR="$CASE_DIR/control/resources" \
        GUARD_RUNNER_MANIFEST="$CASE_DIR/manifest" GUARD_RUNNER_ATTESTATION="$CASE_DIR/manifest" \
        IT_MAPPING_PROFILE="$CASE_DIR/profile" IT_PRODUCT_IMAGE=product IT_TOOLS_IMAGE=tools \
        timeout 12 /bin/bash "$HERE/test-docker-network.sh" --mapping-probe > "$CASE_DIR/output" 2>&1 || rc=$?
    wait "$pid" || return 1
    printf '%s EXPECT=%s ACTUAL=%s\n' "$mode" "$expected" "$rc"
    if [[ $rc != "$expected" ]]; then cat "$CASE_DIR/output"; return 1; fi
    [[ ! -e $CASE_DIR/probe-summary.tsv && ! -e $CASE_DIR/probe-summary.tsv.tmp && ! -e $CASE_DIR/mapping-full-summary.tsv ]] || return 1
    ! grep -Eq 'NETWORK_START|UNEXPECTED' "$CASE_DIR/events" || return 1
    case "$mode" in
        ready|wrong-ack|control-fail) grep -q '^READY ' "$CASE_DIR/events" || return 1 ;;
        auth-fail) [[ ! -e $CASE_DIR/docker.log ]] || return 1 ;;
        prepare-fail) ! grep -q '^READY ' "$CASE_DIR/events" || return 1 ;;
    esac
    if [[ $mode == ready ]]; then
        [[ $(grep -c '^start -a container-evidence-verify$' "$CASE_DIR/docker.log") == 1 ]] || return 1
        [[ $(cat "$CASE_DIR/lifecycle") == $'prepare\nready\nactivate\nprobe' ]] || return 1
    elif [[ $mode == wrong-ack || $mode == control-fail ]]; then
        [[ $(cat "$CASE_DIR/lifecycle") == $'prepare\nready' ]] || return 1
    fi
    return 0
}

# 同名资源存在并不提供能力证据：逐项调用真实检查，要求未实现检查固定失败。
probe_unimplemented_checks() {
    local key rc failed=0
    source "$HERE/docker-network-fixture.sh"
    source "$HERE/docker-mapping-probe.sh"
    export CASE_DIR=$WORK/ready
    MP_NETWORK_NAME=gm-mtest-m-net MP_RUN_ID=mtest
    local name
    for name in gm-mtest-m-net gm-mtest-mapping-assets gm-mtest-mapping-ca gm-mtest-mapping-evidence; do
        : > "$CASE_DIR/objects/$name"
    done
    mapping_fixture_docker() { probe_contract_docker "$@"; }
    mapping_fixture_precheck || return 1
    for key in internal_peer uid_ports dns proxy_tls upstream_tls connect_dial git_resolve bridge_drop input_drop witness_negative offline; do
        rc=0
        "mapping_probe_check_$key" profile product tools "$CASE_DIR" || rc=$?
        printf '%s EXPECT=80 ACTUAL=%s\n' "$key" "$rc"
        [[ $rc == 80 ]] || failed=1
    done
    return "$failed"
}

{
    declare -f probe_contract_docker probe_contract_source
    printf 'source() { probe_contract_source "$@"; }\n'
    cat <<'BOUNDARY'
trap 'case "$BASH_COMMAND" in
    mapping_prepare\ *) printf "prepare\n" >> "$CASE_DIR/lifecycle" ;;
    mapping_ready\ *) printf "ready\n" >> "$CASE_DIR/lifecycle" ;;
    mapping_activate\ *) printf "activate\n" >> "$CASE_DIR/lifecycle" ;;
    mapping_probe_run\ *) printf "probe\n" >> "$CASE_DIR/lifecycle" ;;
esac' DEBUG
BOUNDARY
} > "$WORK/boundary.sh"
failed=0
for spec in ready:80 wrong-ack:65 control-fail:42 prepare-fail:80 auth-fail:77; do
    ( probe_entry_case "${spec%:*}" "${spec#*:}" ) || failed=1
done
( probe_unimplemented_checks ) || failed=1
exit "$failed"
