#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-resource-ledger.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RESOURCE_LEDGER_DIR=$WORK/resources
RESOURCE_RUN=mtest
ID=$(printf '%064d' 3)
SCENARIO=mapping-fallback-isolation
GENERATION=g1

# 仅模拟 Docker 的 inspect 外部输出，其余登记及消费函数均真实执行。
resource_docker() {
    [[ $1 == inspect ]] || return 2
    if [[ ${2:-} == -f ]]; then
        case $3 in
            *Labels*) printf '%s\t%s\tproduct\n' "$RESOURCE_RUN" "$SCENARIO" ;;
            *) return 2 ;;
        esac
    else
        printf '[{"Id":"%s","Name":"/gm-%s-%s-product","Config":{"Labels":{"gitdaemon.run":"%s","gitdaemon.scenario":"%s","gitdaemon.role":"product"}}}]\n' \
            "$ID" "$RESOURCE_RUN" "$GENERATION" "$RESOURCE_RUN" "$SCENARIO"
    fi
}

# 通过真实登记与删除回执构造消费者所需的完整账本和对象快照。
register_generation() {
    local generation=$1
    GENERATION=$generation
    resource_register_body container "$ID" "$SCENARIO" product
    local hash
    hash=$(awk -F '\t' '$2 == "register" {value=$8} END {print value}' "$RESOURCE_LEDGER_DIR/ledger.tsv")
    resource_record_removed "$RESOURCE_LEDGER_DIR" container "$ID" "$RESOURCE_RUN" "$SCENARIO" product "$hash" "$ID"
}

# 检查消费者退出状态，不以模拟的哈希代替真实账本字段。
expect_status() {
    local expected=$1 generation=$2 rc=0
    mapping_isolation_product_registration_accept "$ID" "$RESOURCE_RUN" "$SCENARIO" "$RESOURCE_LEDGER_DIR" "$generation" || rc=$?
    [[ $rc == "$expected" ]] || { printf 'generation=%s expected=%s actual=%s\n' "$generation" "$expected" "$rc" >&2; return 1; }
}

register_generation g1
SNAPSHOT=$RESOURCE_LEDGER_DIR/objects/1-container.json
[[ -s $SNAPSHOT && $(wc -l < "$RESOURCE_LEDGER_DIR/ledger.tsv") == 2 ]]
expect_status 0 g1
expect_status 1 g2
printf ' ' >> "$SNAPSHOT"
expect_status 1 g1
rm -rf "$RESOURCE_LEDGER_DIR"
register_generation g1
sed -i "1s/$(awk -F '\t' 'NR == 1 {print $8}' "$RESOURCE_LEDGER_DIR/ledger.tsv")/$(printf '%064d' 9)/" "$RESOURCE_LEDGER_DIR/ledger.tsv"
expect_status 1 g1
