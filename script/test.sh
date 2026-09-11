#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .build/tests .build/module-cache
xcrun swiftc -parse-as-library -module-cache-path .build/module-cache OpenTransmit/Models/Models.swift OpenTransmit/Services/LocalFileService.swift OpenTransmit/Services/TrashService.swift Tests/LocalFileServiceTests.swift -o .build/tests/LocalFileServiceTests
.build/tests/LocalFileServiceTests
