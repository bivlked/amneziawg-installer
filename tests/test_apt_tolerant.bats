#!/usr/bin/env bats
# Tests for apt_update_tolerant() in awg_common.sh
# Verifies that source-only 404s are ignored, other errors propagate.

setup() {
    # shellcheck source=/dev/null
    source "${BATS_TEST_DIRNAME}/../awg_common.sh"
    # Silence logging in tests
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
}

@test "apt_update_tolerant: returns 0 on clean update" {
    apt-get() { return 0; }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -eq 0 ]
}

@test "apt_update_tolerant: returns 0 when only source/Sources 404s fail" {
    apt-get() {
        cat <<'ERR' >&2
Hit:1 http://mirror.hetzner.com/ubuntu noble InRelease
Err:5 http://mirror.hetzner.com/ubuntu noble-updates/main/source/Sources
  404 Not Found [IP: 10.0.0.1 80]
E: Failed to fetch http://mirror.hetzner.com/ubuntu/dists/noble-updates/main/source/Sources  404 Not Found [IP: 10.0.0.1 80]
E: Some index files failed to download. They have been ignored, or old ones used instead.
ERR
        return 100
    }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -eq 0 ]
}

@test "apt_update_tolerant: returns 0 when deb-src errors only" {
    apt-get() {
        echo "Err:10 http://mirror/ubuntu noble main/deb-src Sources 404" >&2
        echo "E: Failed to fetch deb-src: Sources  404" >&2
        return 100
    }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -eq 0 ]
}

@test "apt_update_tolerant: fails on GPG signature error" {
    apt-get() {
        cat <<'ERR' >&2
W: GPG error: http://mirror.hetzner.com/ubuntu noble InRelease: The following signatures were invalid: EXPKEYSIG 871920D1991BC93C
E: Repository 'http://mirror.hetzner.com/ubuntu noble InRelease' is not signed.
ERR
        return 100
    }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -ne 0 ]
}

@test "apt_update_tolerant: fails on binary package 404" {
    apt-get() {
        echo "Err:3 http://ppa.launchpadcontent.net/amnezia/ppa/ubuntu noble/main amd64 Packages" >&2
        echo "  404 Not Found" >&2
        echo "E: Failed to fetch http://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/noble/main/binary-amd64/Packages 404" >&2
        return 100
    }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -ne 0 ]
}

@test "apt_update_tolerant: mixed source-404 + binary-404 fails" {
    apt-get() {
        cat <<'ERR' >&2
Err:1 http://mirror/ubuntu noble-updates/main/source/Sources 404
E: Failed to fetch http://mirror/ubuntu/dists/noble-updates/main/source/Sources  404
Err:2 http://mirror/ubuntu noble/main amd64 Packages 404
E: Failed to fetch http://mirror/ubuntu/dists/noble/main/binary-amd64/Packages 404
ERR
        return 100
    }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -ne 0 ]
}
