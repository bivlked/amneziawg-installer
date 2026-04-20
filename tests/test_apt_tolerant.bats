#!/usr/bin/env bats
# Tests for apt_update_tolerant() — inline в install_amneziawg.sh с v5.10.2.
# До v5.10.2 функция жила в awg_common.sh и грузилась через source; после v5.10.1
# hotfix — inline в install (нужна в шагах 1-2 до скачивания awg_common.sh).
# Тесты извлекают функцию через sed range и source'ят в bats setup.
#
# Covered: source-only 404s ignored, non-source errors propagate, silent crash
# (rc!=0 + empty stderr) propagates (WARN-1 fix).

setup() {
    # shellcheck disable=SC2154
    # Extract apt_update_tolerant function body from install_amneziawg.sh
    # and source it. If extraction fails, all tests will fail.
    local installer="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    [ -f "$installer" ] || { echo "Installer not found: $installer" >&2; return 1; }
    # shellcheck source=/dev/null
    source <(sed -n '/^apt_update_tolerant() {$/,/^}$/p' "$installer")
    # Silence logging
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

# WARN-1 regression: rc != 0 + пустой stderr = SIGKILL / OOM / silent crash.
# До фикса функция ошибочно возвращала 0 (source-only fallback без проверки
# что в выводе вообще есть source-маркеры). Теперь — propagates error.
@test "apt_update_tolerant: fails on silent crash (rc!=0, empty stderr)" {
    apt-get() { return 137; }   # 137 = SIGKILL
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -ne 0 ]
}

# WARN-1 regression: DNS failure пишет warning без классических E:/Err:
# (например, "Temporary failure resolving 'archive.ubuntu.com'"). Функция
# не должна это скрывать — нет source-маркеров, значит возвращаем ошибку.
@test "apt_update_tolerant: fails on DNS failure without E: prefix" {
    apt-get() {
        cat <<'ERR' >&2
Temporary failure resolving 'archive.ubuntu.com'
Temporary failure resolving 'security.ubuntu.com'
ERR
        return 100
    }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -ne 0 ]
}

# Regression guard: "Sources" в названии component типа "MainSources" не должно
# триггерить source-only fallback. Regex Sources([^[:alpha:]]|$) — точнее, чем
# Sources([[:space:]]|$). С v5.10.2 используется [^[:alpha:]].
@test "apt_update_tolerant: does not false-match 'Sources<letter>' strings" {
    apt-get() {
        echo "E: SourcesMirror config broken" >&2
        return 100
    }
    export -f apt-get
    run apt_update_tolerant
    [ "$status" -ne 0 ]
}
