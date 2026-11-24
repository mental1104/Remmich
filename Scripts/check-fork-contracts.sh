#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
build_directory=$(mktemp -d "${TMPDIR:-/tmp}/remmich-contracts.XXXXXX")
swiftc -swift-version 6 \
  Remmich/Infrastructure/Management/LibraryMutationClient.swift \
  Remmich/Domain/Albums/ForkAlbumDirectory.swift \
  Scripts/check-fork-contracts.swift \
  -o "$build_directory/check-contracts"
"$build_directory/check-contracts"
