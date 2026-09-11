#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Build the app first; reuse its exact resolved packages and compiled dependency objects.
if [[ ! -f .build/Build/Products/Debug/Citadel.o ]]; then ./script/build_and_run.sh --build; fi
if [[ ! -x .build/sftp-test-env/bin/python ]]; then
  echo 'Prepare fixtures: python3 -m venv .build/sftp-test-env && .build/sftp-test-env/bin/python -m pip install paramiko==4.0.0' >&2
  exit 1
fi
python3 - <<'PY'
from pathlib import Path
import subprocess
root = Path.cwd()
products = root / '.build/Build/Products/Debug'
args = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(root / '.build/module-cache'), '-I', str(products)]
for p in (root / '.build/Build/Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'):
    args += ['-Xcc', '-fmodule-map-file=' + str(p)]
for package in ('swift-crypto', 'Citadel', 'swift-nio', 'swift-atomics'):
    for include in (root / '.build/SourcePackages/checkouts' / package / 'Sources').glob('*/include'):
        args += ['-Xcc', '-I' + str(include)]
        module = include / 'module.modulemap'
        if module.exists(): args += ['-Xcc', '-fmodule-map-file=' + str(module)]
args += [str(p) for p in products.glob('*.o')]
args += ['OpenTransmit/Models/Models.swift']
args += ['OpenTransmit/Services/' + name + '.swift' for name in ('TransferEndpoint', 'LocalTransferEndpoint', 'SSHHostTrust', 'SFTPConnection', 'SFTPStreams')]
args += ['Tests/SFTPIntegrationTests.swift', '-o', '.build/tests/SFTPIntegrationTests']
(root / '.build/tests').mkdir(exist_ok=True)
subprocess.run(args, check=True)
PY
.build/sftp-test-env/bin/python Tests/run_sftp_integration.py .build/tests/SFTPIntegrationTests
