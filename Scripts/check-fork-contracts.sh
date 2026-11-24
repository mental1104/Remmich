#!/usr/bin/env bash
# 用swiftc运行内存契约检查；不读取凭据或访问生产图库，只在临时目录输出测试程序。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
build_directory=$(mktemp -d "${TMPDIR:-/tmp}/remmich-contracts.XXXXXX")
swiftc -swift-version 6 \
  Remmich/Infrastructure/Management/LibraryMutationClient.swift \
  Remmich/Infrastructure/Management/AssetEditList+StrictDecoding.swift \
  Remmich/Domain/Editing/AssetViewerFreshAsset.swift \
  Remmich/Domain/Albums/ForkAlbumDirectory.swift \
  Remmich/Domain/Management/AlbumDirectoryManagement.swift \
  Remmich/Domain/LocalMedia/LocalMediaMetadataStream.swift \
  Remmich/Domain/Timeline/NativeSearchModels.swift \
  Remmich/Domain/Timeline/NativeSearchPreset.swift \
  Scripts/check-fork-contracts.swift \
  -o "$build_directory/check-contracts"
"$build_directory/check-contracts"
