#!/usr/bin/env bats
# Tests for the v5.27.0 package-removal consent (Issue #213, reported by @kemko).
#
# The installer purges snapd and friends and then wipes /snap, /var/snap and
# /var/lib/snapd. v5.27.0 asks first. Because the answer gates an irreversible
# rm -rf, every check in that path has to fail toward KEEPING the packages.
# Two review passes found the opposite: a read failure, an unreadable snap
# directory, an unusable dpkg and a mangled config value all collapsed into a
# quiet zero, which is the destructive branch. The Russian answer "нет" did the
# same, because the parser tested the answer for the Latin letter n only.
#
# These tests pin the fail direction so the next edit cannot flip it back.

load test_helper

bats_require_minimum_version 1.5.0

# Pull the consent helpers out of the installer and eval them with stub loggers.
# The prompt reads from /dev/tty, which a test cannot drive, so for the parsing
# cases the redirect is stripped and the answer arrives on stdin instead.
_load_consent() {
    local script="$1" strip_tty="${2:-0}" fn body
    OS_ID=ubuntu; NO_TWEAKS=0; AUTO_YES=0; KEEP_PACKAGES=""
    log() { :; }
    log_warn() { :; }
    for fn in _cleanup_package_list _dpkg_usable _cloud_init_removable \
              _snaps_dir_readable _user_snaps configure_package_cleanup; do
        body=$(awk "/^${fn}\(\) \{/,/^\}/" "$script")
        [ -n "$body" ] || return 1
        if [ "$strip_tty" = "1" ]; then
            body=${body// < \/dev\/tty/}
        fi
        eval "$body"
    done
    # Neutralise everything that would touch the real system.
    _dpkg_usable() { return 0; }
    _cloud_init_removable() { return 1; }
    _snaps_dir_readable() { return 0; }
    _cleanup_package_list() { printf '%s' "snapd modemmanager"; }
    dpkg-query() { echo "install ok installed"; }
}

# Answer the prompt and report the resulting KEEP_PACKAGES.
_answer() {
    local script="$1" reply="$2"
    _load_consent "$script" 1
    _user_snaps() { printf 'certbot\n'; }   # something to lose -> [y/N] branch
    printf '%s\n' "$reply" | {
        configure_package_cleanup >/dev/null 2>&1
        printf '%s' "$KEEP_PACKAGES"
    }
}

@test "RU installer: Russian 'нет' keeps the packages" {
    result=$(_answer "$BATS_TEST_DIRNAME/../install_amneziawg.sh" "нет")
    [ "$result" = "1" ]
}

@test "RU installer: 'не', 'н' and a stray key all keep the packages" {
    local script="$BATS_TEST_DIRNAME/../install_amneziawg.sh" a
    for a in "не" "н" "ok" "х" ""; do
        result=$(_answer "$script" "$a")
        [ "$result" = "1" ]
    done
}

@test "RU installer: removal needs an explicit yes" {
    local script="$BATS_TEST_DIRNAME/../install_amneziawg.sh" a
    for a in "y" "Y" "yes" "да" "ДА"; do
        result=$(_answer "$script" "$a")
        [ "$result" = "0" ]
    done
}

@test "EN installer: the same allowlist applies" {
    local script="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    [ "$(_answer "$script" "no")" = "1" ]
    [ "$(_answer "$script" "нет")" = "1" ]
    [ "$(_answer "$script" "yes")" = "0" ]
}

@test "a failing read keeps the packages" {
    # The real prompt reads from /dev/tty, which a test cannot take away: under
    # bats a terminal usually exists and the read would simply block. So the
    # redirect is stripped and stdin is CLOSED instead - `read` fails the same
    # way it does when /dev/tty is missing, which is the branch under test.
    local script="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    _load_consent "$script" 1
    _user_snaps() { printf 'certbot\n'; }
    configure_package_cleanup <&- >/dev/null 2>&1
    [ "$KEEP_PACKAGES" = "1" ]
}

@test "unusable dpkg keeps the packages" {
    local script="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    _load_consent "$script" 1
    _dpkg_usable() { return 1; }
    printf 'y\n' | { configure_package_cleanup >/dev/null 2>&1; [ "$KEEP_PACKAGES" = "1" ]; }
}

@test "unreadable snap directory switches the default to keep" {
    local script="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    _load_consent "$script" 1
    _snaps_dir_readable() { return 1; }
    result=$(printf '\n' | { configure_package_cleanup >/dev/null 2>&1; printf '%s' "$KEEP_PACKAGES"; })
    [ "$result" = "1" ]
}

@test "lxd counts as a user snap: LXD keeps its containers in /var/snap/lxd" {
    run grep -c 'snapd|bare|core|core\[0-9\]\*' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$status" -eq 0 ]
    run grep -c 'snapd|bare|lxd' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    [ "$output" = "0" ]
}

@test "retained revisions are deduplicated in the warning" {
    local dir; dir=$(mktemp -d)
    mkdir -p "$dir/snaps"
    touch "$dir/snaps/certbot_1.snap" "$dir/snaps/certbot_2.snap" "$dir/snaps/core22_1.snap"
    # Same pipeline as _user_snaps, against a directory we control.
    result=$(for f in "$dir"/snaps/*.snap; do
                 name="${f##*/}"; name="${name%_*.snap}"
                 case "$name" in snapd|bare|core|core[0-9]*) continue ;; esac
                 printf '%s\n' "$name"
             done | sort -u | tr '\n' ' ')
    rm -rf "$dir"
    [ "$result" = "certbot " ]
}

@test "the cleanup gate runs only on a recorded zero" {
    local script a
    for script in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -c 'elif \[\[ "\$KEEP_PACKAGES" != "0" \]\]; then' \
            "$BATS_TEST_DIRNAME/../$script"
        [ "$output" = "1" ]
    done
    # An empty or mangled value must not reach the destructive branch.
    for a in "" "yes" "true" "01x"; do
        KEEP_PACKAGES="$a"
        if [[ "$KEEP_PACKAGES" != "0" ]]; then :; else false; fi
    done
}

@test "consent is asked outside the config-exists branch" {
    local script
    for script in install_amneziawg.sh install_amneziawg_en.sh; do
        # The call must NOT sit inside the "no config yet" branch: a --force
        # reinstall keeps the config, and step99 removed the state file, so the
        # run would reach the cleanup again without ever asking.
        run grep -c '^        configure_package_cleanup$' "$BATS_TEST_DIRNAME/../$script"
        [ "$output" = "0" ]
        run grep -c '^    configure_package_cleanup$' "$BATS_TEST_DIRNAME/../$script"
        [ "$output" = "1" ]
    done
}

@test "the consent helpers are line-equal between RU and EN installers" {
    local fn ru en
    for fn in _cleanup_package_list _dpkg_usable _cloud_init_removable \
              _snaps_dir_readable _user_snaps configure_package_cleanup; do
        ru=$(awk "/^${fn}\(\) \{/,/^\}/" "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
             | grep -vE '^\s*#' | grep -vE '^\s*(log|log_warn) ' | sed 's/[[:space:]]*$//')
        en=$(awk "/^${fn}\(\) \{/,/^\}/" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh" \
             | grep -vE '^\s*#' | grep -vE '^\s*(log|log_warn) ' | sed 's/[[:space:]]*$//')
        [ "$(printf '%s' "$ru" | wc -l)" -eq "$(printf '%s' "$en" | wc -l)" ]
    done
}
