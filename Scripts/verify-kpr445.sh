#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
kpr445_group="${1:?required group}"
kpr445_evidence=$(mktemp -d "/tmp/keepur-kpr445-${kpr445_group}.XXXXXX")
kpr445_dd=/tmp/keepur-kpr443-task3-dd
kpr445_sim=ABAF19FA-8DE4-4EE1-B57E-DAA88C935FDE
xcodebuild -version > "$kpr445_evidence/toolchain.txt"
git rev-parse HEAD > "$kpr445_evidence/head.txt"
git diff --stat > "$kpr445_evidence/worktree.txt"
if [ "$kpr445_group" = macos ]; then
    xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$kpr445_dd" \
        CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$kpr445_evidence/build.log"
    exit 0
fi
kpr445_tests=()
case "$kpr445_group" in
    unit) kpr445_tests=(-only-testing:KeeperTests/HistoryMergerTests -only-testing:KeeperTests/TeamWSMessageTests -only-testing:KeeperTests/TypedStateTests) ;;
    models) kpr445_tests=(-only-testing:KeeperTests/TeamMessagePersistenceTests) ;;
    history) kpr445_tests=(-only-testing:KeeperTests/TeamHistoryTests -only-testing:KeeperTests/TeamViewModelTests) ;;
    cleanup) kpr445_tests=(-only-testing:KeeperTests/TeamStoreTests -only-testing:KeeperTests/TeamCleanupTests -only-testing:KeeperTests/PairingTeardownTests) ;;
    lifecycle) kpr445_tests=(-only-testing:KeeperTests/TeamDMLifecycleTests -only-testing:KeeperTests/PairingTeardownTests) ;;
    retained) kpr445_tests=(-only-testing:KeeperTests/TeamViewModelTests -only-testing:KeeperTests/PairingTeardownTests -only-testing:KeeperTests/PersistenceTests -only-testing:KeeperTests/ChatPersistenceTests -only-testing:KeeperTests/ChatViewModelTests -only-testing:KeeperTests/ChatResilienceTests -only-testing:KeeperTests/ChatViewModelSocketTests -only-testing:KeeperTests/ConciergeViewModelTests -only-testing:KeeperTests/BusyStateRecoveryTests -only-testing:KeeperTests/ContextClearedTests -only-testing:KeeperTests/SessionReplacedTests -only-testing:KeeperTests/TypedStateTests -only-testing:KeeperTests/TeamWSMessageTests) ;;
    regression) kpr445_tests=(-only-testing:KeeperTests -skip-testing:KeeperTests/CapabilityManagerTests) ;;
    full) kpr445_tests=(-only-testing:KeeperTests) ;;
    *) exit 64 ;;
esac
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
    -destination "platform=iOS Simulator,id=$kpr445_sim" -derivedDataPath "$kpr445_dd" \
    "${kpr445_tests[@]}" -resultBundlePath "$kpr445_evidence/Tests.xcresult" \
    2>&1 | tee "$kpr445_evidence/test.log"
xcrun xcresulttool get test-results summary --path "$kpr445_evidence/Tests.xcresult" \
    > "$kpr445_evidence/summary.json"
