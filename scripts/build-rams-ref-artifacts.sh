#!/usr/bin/env bash
# Rebuild the checked-in ERC-8226 reference-implementation artifacts used by
# the Foundry tests (contracts/test/rams-artifacts/). The reference needs solc
# 0.8.30 while this repo pins 0.8.26, so it is built out-of-tree with its own
# foundry.toml and only the creation bytecode is kept.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

cp -R "$ROOT/contracts/lib/rams-reference/." "$BUILD/"
mkdir -p "$BUILD/lib"
ln -s "$ROOT/contracts/lib/openzeppelin-contracts" "$BUILD/lib/openzeppelin-contracts"
(cd "$BUILD" && forge build --skip test > /dev/null)

OUTDIR="$ROOT/contracts/test/rams-artifacts"
mkdir -p "$OUTDIR"
for c in AgentMandate ComplianceProvider AgentExecutor uRWA20; do
  src="$BUILD/out/$c.sol/$c.json"
  [ -f "$src" ] || { echo "missing artifact $c"; exit 1; }
  python3 - "$src" "$OUTDIR/$c.json" << 'PY'
import json, sys
a = json.load(open(sys.argv[1]))
minimal = {
    "_comment": "Minimal ERC-8226 reference artifact for vm.getCode; rebuild with scripts/build-rams-ref-artifacts.sh",
    "abi": a["abi"],
    "bytecode": {"object": a["bytecode"]["object"]},
}
json.dump(minimal, open(sys.argv[2], "w"), indent=0)
PY
  echo "wrote $OUTDIR/$c.json"
done
