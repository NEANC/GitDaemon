#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ID=$(printf '%064d' 3)
OTHER=$(printf '%064d' 4)
LEDGER=$WORK/control/resources
mkdir -p "$LEDGER/objects"
INSPECT=$LEDGER/objects/2-container.json

write_inspect() {
    printf '[{"Id":"%s","Config":{"Labels":{"gitdaemon.run":"mtest","gitdaemon.scenario":"mapping-fallback-isolation","gitdaemon.role":"%s"}}}]\n' "$1" "$2" > "$INSPECT"
}

write_ledger() {
    printf '1\tregister\tnetwork\tnet-one\tmtest\tmapping\tnetwork\thash\tnet-one\t%s\n2\tregister\tcontainer\t%s\tmtest\tmapping-fallback-isolation\t%s\thash\t%s\t%s\n3\tremoved\tnetwork\tnet-one\tmtest\tmapping\tnetwork\thash\tnet-one\t%s\n' "$LEDGER/objects/1-network.json" "$1" "$2" "$1" "$INSPECT" "$LEDGER/objects/1-network.json" > "$LEDGER/ledger.tsv"
}

expect_status() {
    local expected=$1 rc=0
    mapping_isolation_product_registration_accept "$ID" mtest mapping-fallback-isolation "$LEDGER" || rc=$?
    [[ $rc == "$expected" ]] || { printf 'expected %s got %s\n' "$expected" "$rc" >&2; return 1; }
}

write_inspect "$ID" product
write_ledger "$ID" product
expect_status 0
printf '5\tregister\tcontainer\t%s\tmtest\tmapping-fallback-isolation\tproduct\thash\t%s\t%s\n' "$OTHER" "$OTHER" "$LEDGER/objects/5-container.json" >> "$LEDGER/ledger.tsv"
expect_status 0
write_ledger "$OTHER" product
expect_status 1
write_ledger "$ID" product
sed -i 's/mapping-fallback-isolation\tproduct/mapping-fallback-isolation\tother/' "$LEDGER/ledger.tsv"
expect_status 1
write_ledger "$ID" wrong-role
expect_status 1
write_ledger "$ID" product
printf '4\tregister\tcontainer\t%s\tmtest\tmapping-fallback-isolation\tproduct\thash\t%s\t%s\n' "$ID" "$ID" "$INSPECT" >> "$LEDGER/ledger.tsv"
expect_status 1
write_ledger "$ID" product
printf 'broken\n' > "$INSPECT"
expect_status 80
write_inspect "$OTHER" product
expect_status 1
write_inspect "$ID" wrong-role
expect_status 1
write_inspect "$ID" product
expect_status 0
sed -i 's/gitdaemon.run":"mtest"/gitdaemon.run":"another"/' "$INSPECT"
expect_status 1
write_inspect "$ID" product
sed -i 's/gitdaemon.scenario":"mapping-fallback-isolation"/gitdaemon.scenario":"mapping-direct"/' "$INSPECT"
expect_status 1
write_inspect "$ID" product
sed -i 's/mtest\tmapping-fallback-isolation\tproduct/mtest\tmapping-direct\tproduct/' "$LEDGER/ledger.tsv"
expect_status 1
write_ledger "$ID" product
sed -i 's/\tmtest\tmapping-fallback-isolation\tproduct/\tother\tmapping-fallback-isolation\tproduct/' "$LEDGER/ledger.tsv"
expect_status 1
write_ledger "$ID" product
mv "$INSPECT" "$WORK/inspect.saved"
expect_status 80
mv "$WORK/inspect.saved" "$INSPECT"
expect_status 0
