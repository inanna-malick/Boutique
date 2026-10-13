#!/bin/zsh
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export BOUTIQUE_SWIFT=/private/tmp/boutique-swift-6.2.4-expanded/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin/swift
Scripts/property-tests.sh --jobs 2 --filter "${BOUTIQUE_SHARED_FILTER:-StoreSharedPersistenceDiscoveryTests}" "$@"
