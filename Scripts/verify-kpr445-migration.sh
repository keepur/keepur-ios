#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
kpr445_base=49c3423ddf3057e9ae2b893b23dee325fe545094
kpr445_work=$(mktemp -d /tmp/keepur-kpr445-migration.XXXXXX)
mkdir "$kpr445_work/baseline"
kpr445_files=(Session Message Workspace TeamChannel TeamMessage MessageRole TeamWSMessage)
kpr445_old=()
kpr445_new=()
for kpr445_name in "${kpr445_files[@]}"; do
    git show "$kpr445_base:Models/$kpr445_name.swift" > "$kpr445_work/baseline/$kpr445_name.swift"
    kpr445_old+=("$kpr445_work/baseline/$kpr445_name.swift")
    kpr445_new+=("Models/$kpr445_name.swift")
done
xcrun swiftc -target arm64-apple-macos15.0 -swift-version 5 -parse-as-library -module-name KeepurMigration -D PRE_E \
    "${kpr445_old[@]}" Scripts/KPR445MigrationCheck.swift -o "$kpr445_work/pre-e" \
    2>&1 | tee "$kpr445_work/baseline-build.log"
xcrun swiftc -target arm64-apple-macos15.0 -swift-version 5 -parse-as-library -module-name KeepurMigration \
    "${kpr445_new[@]}" Models/HistoryMerger.swift Scripts/KPR445MigrationCheck.swift \
    -o "$kpr445_work/e" 2>&1 | tee "$kpr445_work/e-build.log"
"$kpr445_work/pre-e" seed "$kpr445_work/fixture.store" | tee "$kpr445_work/seed.log"
"$kpr445_work/pre-e" baseline-reopen "$kpr445_work/fixture.store" | tee "$kpr445_work/baseline-reopen.log"
"$kpr445_work/e" migrate "$kpr445_work/fixture.store" | tee "$kpr445_work/migrate.log"
"$kpr445_work/e" verify "$kpr445_work/fixture.store" | tee "$kpr445_work/reopen.log"
git rev-parse HEAD > "$kpr445_work/head.txt"
git diff -- Models > "$kpr445_work/models.diff"
