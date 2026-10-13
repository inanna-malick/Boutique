#!/bin/bash
# Diagnostic only: does not call Boutique or open any Preview database.
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift_bin=/private/tmp/boutique-swift-6.2.4-expanded/swift-6.2.4-RELEASE-osx-package.pkg/Payload/usr/bin/swift
preview_root=$(mktemp -d /private/tmp/BoutiquePreviewInvestigation.XXXXXXXX)
trap 'rm -rf "$preview_root"' EXIT
TMPDIR="$preview_root/" "$swift_bin" -e 'import Foundation; print("TMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "unset")"); print("URL.temporaryDirectory=\(URL.temporaryDirectory.path)"); print("NSTemporaryDirectory=\(NSTemporaryDirectory())")'
