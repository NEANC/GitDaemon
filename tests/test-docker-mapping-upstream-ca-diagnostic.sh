#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"

# 验证目标仓库的具体证书链诊断可识别，异源与无关细节不能归因于错 CA。
upstream_ca_diagnostic_cases() {
    local dir sample expected rc
    dir=$(mktemp -d)
    MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_OWNER=acme MAPPING_UPSTREAM_REPO=demo
    for sample in issuer-no-prefix issuer-with-prefix chain-no-prefix verify-first expired-certificate hostname-mismatch self-signed-leaf other-host unrelated-no-prefix unrelated-with-prefix certificate-noise mixed-fatal; do
        expected=1
        case $sample in
            issuer-no-prefix) printf "fatal: unable to access 'https://github.com/acme/demo.git/': unable to get local issuer certificate\n" > "$dir/git.log"; expected=0 ;;
            issuer-with-prefix) printf "fatal: unable to access 'https://github.com/acme/demo.git/': SSL certificate problem: unable to get local issuer certificate\n" > "$dir/git.log"; expected=0 ;;
            chain-no-prefix) printf "fatal: unable to access 'https://github.com/acme/demo.git/': self-signed certificate in certificate chain\n" > "$dir/git.log"; expected=0 ;;
            verify-first) printf "fatal: unable to access 'https://github.com/acme/demo.git/': unable to verify the first certificate\n" > "$dir/git.log"; expected=0 ;;
            expired-certificate) printf "fatal: unable to access 'https://github.com/acme/demo.git/': SSL certificate problem: certificate has expired\n" > "$dir/git.log" ;;
            hostname-mismatch) printf "fatal: unable to access 'https://github.com/acme/demo.git/': SSL: certificate subject name 'elsewhere.invalid' does not match target host name 'github.com'\n" > "$dir/git.log" ;;
            self-signed-leaf) printf "fatal: unable to access 'https://github.com/acme/demo.git/': SSL certificate problem: self-signed certificate\n" > "$dir/git.log" ;;
            other-host) printf "fatal: unable to access 'https://elsewhere.invalid/acme/demo.git/': unable to get local issuer certificate\n" > "$dir/git.log" ;;
            unrelated-no-prefix) printf "fatal: unable to access 'https://github.com/acme/demo.git/': connection refused\n" > "$dir/git.log" ;;
            unrelated-with-prefix) printf "fatal: unable to access 'https://github.com/acme/demo.git/': SSL certificate problem: connection refused\n" > "$dir/git.log" ;;
            certificate-noise) printf "fatal: unable to access 'https://github.com/acme/demo.git/': connection refused; certificate cache stale\n" > "$dir/git.log" ;;
            mixed-fatal) printf "fatal: unable to access 'https://github.com/acme/demo.git/': unable to get local issuer certificate\nfatal: unable to access 'https://elsewhere.invalid/': repository not found\n" > "$dir/git.log" ;;
        esac
        rc=0
        mapping_upstream_ca_git_diagnostic "$dir/git.log" || rc=$?
        [[ $rc == "$expected" ]] || { printf '%s: expected %s got %s\n' "$sample" "$expected" "$rc" >&2; return 1; }
    done
}

upstream_ca_diagnostic_cases
