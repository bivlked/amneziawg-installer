#!/usr/bin/env bats
# v5.16.1 (MyAI-1ju6, Issue #42): iOS fix for the default routing mode (mode 2).
#
# Background: mode 2 (ALLOWED_IPS_MODE=2, our default) builds a fragmented
# AllowedIPs list. Its first element used to be 0.0.0.0/5, which covers the
# reserved 0.0.0.0/8. On iOS the kernel chokes on that zero block and never
# reaches the rest of the list, so the tunnel comes up and then stalls after
# ~10s (looked exactly like behavioural DPI). @LiaNdrY traced it and proposed
# splitting 0.0.0.0/5 into 1.0.0.0/8 + 2.0.0.0/7 + 4.0.0.0/6 = the same range
# minus the non-routable 0.0.0.0/8. Split-tunnel (mode 2) is preserved.
#
# install_amneziawg{,_en}.sh are not sourceable (run top to bottom), so these
# are structural greps on the literal mode-2 list, like the other structural
# pins in this suite. They guard against a future "simplify back to 0.0.0.0/5".

# Required for `run !` (negation) below; suppresses bats BW02 warning.
bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."

@test "mode-2 list starts with 1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6 (RU installer)" {
    grep -qF 'ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7,' "$ROOT/install_amneziawg.sh"
}

@test "mode-2 list starts with 1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6 (EN installer)" {
    grep -qF 'ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7,' "$ROOT/install_amneziawg_en.sh"
}

@test "mode-2 list no longer starts with the bare 0.0.0.0/5 (RU installer)" {
    run ! grep -qF 'ALLOWED_IPS="0.0.0.0/5' "$ROOT/install_amneziawg.sh"
}

@test "mode-2 list no longer starts with the bare 0.0.0.0/5 (EN installer)" {
    run ! grep -qF 'ALLOWED_IPS="0.0.0.0/5' "$ROOT/install_amneziawg_en.sh"
}

@test "mode-2 list still ends with the DNS host routes (RU installer)" {
    grep -qF '8.8.8.8/32, 1.1.1.1/32"' "$ROOT/install_amneziawg.sh"
}

@test "mode-2 list still ends with the DNS host routes (EN installer)" {
    grep -qF '8.8.8.8/32, 1.1.1.1/32"' "$ROOT/install_amneziawg_en.sh"
}
