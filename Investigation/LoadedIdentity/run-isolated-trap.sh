#!/bin/bash
# The parent shell preserves inputs before the child may hit a fatal assertion.
set -u
cd "$(dirname "$0")/../.." || exit 2
artifact_dir="${BOUTIQUE_LOADED_IDENTITY_ARTIFACTS:-.build/loaded-identity-isolated}"
mkdir -p "$artifact_dir"
cp Investigation/LoadedIdentity/migration-history.json "$artifact_dir/original.json"
cp Investigation/LoadedIdentity/migration-history.json "$artifact_dir/reduced.json"
export BOUTIQUE_LOADED_IDENTITY_MIGRATION=1
export BOUTIQUE_LOADED_IDENTITY_TRAP=1
Scripts/property-tests.sh --jobs 2 --filter LoadedIdentityDiscoveryTests/migrationCharacterization > "$artifact_dir/child.log" 2>&1
status=$?
printf '%s\n' "$status" > "$artifact_dir/child-exit-status.txt"
printf 'Child exited %s; inputs and log preserved in %s\n' "$status" "$artifact_dir"
exit "$status"
