# VAR × ERC-8226 (RAMS): token-side integration

GatedUSDRams is, to our knowledge, the first independent token-side
integration of ERC-8226 — built against the reference implementation and
verified against the live Ethereum Sepolia deployment
(`AgentMandate 0xD68E1bb9…`, bytecode-identical to the EIP assets).

## Ten-minute reproduction

```sh
git clone <this repo> && cd verified-agent-rails
git submodule update --init --recursive

# 1. Full suite: 63 pre-existing VAR tests + 51 RAMS integration tests = 114.
#    The 5 fork tests require a Sepolia RPC and FAIL (not skip) without one.
cd contracts && ETH_SEPOLIA_RPC_URL=<any sepolia rpc> forge test

# 2. The compromised-key demo, with narration
forge test --match-contract CompromisedKeyDemo -vv

# 3. Against YOUR live registry (read-only checks + fork-local composition)
ETH_SEPOLIA_RPC_URL=<any sepolia rpc> forge test --match-contract RamsForkTest -vv
```

No API keys needed; the reference contracts deploy from prebuilt artifacts
(`contracts/test/rams-artifacts/`, rebuild with
`scripts/build-rams-ref-artifacts.sh` — the reference wants solc 0.8.30,
this repo pins 0.8.26, so tests load its bytecode via `vm.getCode`).

## Architecture

```
                      grant (EIP-712, "RAMS"/"1")          checkPrincipal
   principal ────────────────────────────────► AgentMandate ─────────────► ComplianceProvider
       │                                        (live Sepolia)   grant time    (or our adapter
       │ approve (plain ERC-20 allowance,                ▲                      fronting VAR's
       │ untouched by RAMS)                              │ canExecute +         DelegationMirror)
       ▼                                                 │ recordExecution              ▲
   GatedUSDRams.transferFrom(principal → to)             │ (atomic w/ transfer)         │
       msg.sender == from?  ── yes ──► holder path: VAR mirror checks only              │
       │ no (agent-initiated)                            │                              │
       ├─► RAMS gate: (msg.sender, from) mandate ────────┘                              │
       ├─► LIVE compliance re-check ────────────────────────────────────────────────────┘
       ├─► ERC-20 allowance + VAR mirror gate (GatedUSD._update, untouched)
       └─► recordExecution (reverts on cap breach → atomic accounting)
```

Three pieces, ~400 lines total:

- **`src/interfaces/rams/`** — `IAgentMandate`, `IComplianceProvider`,
  `IAgentExecutor` copied verbatim from the EIP assets (pragma-only change,
  `^0.8.29` → `^0.8.26`).
- **`src/GatedUSDRams.sol`** — extends GatedUSD (original untouched, still
  the standalone VAR reference). The RAMS hook lives in `transferFrom`
  because that is the only entry point where an initiator distinct from the
  holder exists (and `GatedUSD._update` is intentionally non-virtual).
  Composition rule with VAR's DelegationMirror: the mirror leashes the
  *sender* (agent spending its own balance), RAMS leashes the *initiator*
  (agent spending the principal's balance); when both apply, both must pass,
  and ERC-20 allowance is required regardless — RAMS replaces nothing.
- **`src/rams/VARComplianceProviderAdapter.sol`** — VAR's attestation layer
  behind the spec's `IComplianceProvider` ABI. Returns the structured
  verdict the spec requires (reason + expiresAt; a binary oracle is
  non-conformant). identityRef = keccak256(attestation ID), attestation ID =
  the EIP-712 hashStruct of the mirror attestation. Binding is
  permissionless but proof-carrying: only the attestation currently live in
  the mirror can be bound, so the adapter adds no trust surface.

## The strict-mode decision

The spec's example integration falls through to plain allowance when no
mandate exists. The spec also explicitly permits requiring a mandate for
every non-holder transfer. We ship both behind a constructor immutable
(`strictMandates`) and deploy strict, because the fall-through reintroduces
exactly the failure VAR exists to prevent: a compromised agent key with a
standing allowance is indistinguishable from a legitimate operator. Two
details regardless of mode:

- A pair that HAS a mandate is always enforced — including asset scope — so
  a mandated agent can never dodge its caps via a leftover approval on a
  different token (`RAMS_WRONG_ASSET`, not fall-through).
- Permissive mode exists so integrators can quantify the trade-off in tests:
  `test_PermissiveModeAllowsMandatelessUnderPlainAllowance` vs
  `test_StrictModeBlocksMandatelessAgentTransfer`.

## What the integration adds on top of the registry

1. **Execution-path compliance (closes the grant-time gap).** Every mandated
   transfer re-calls `checkPrincipal` on the mandate's own provider. The
   spec checks eligibility only at grant; we checked on the live registry
   that `canExecute` stays true after `PrincipalRevoked`. At this token the
   next transfer reverts in the same block — the admitted
   PrincipalRevoked→freezeAgent window is zero here (and on the current
   deployment there is no enforcer, so the registry-side window is otherwise
   unbounded; see `security-review-draft.md`).
2. **Atomic cap accounting.** `recordExecution` is called inside the
   transfer; it reverts on breach, so caps cannot be raced past
   `canExecute`.
3. **Dual-layer failure diagnosis** (the spec flags this as an integrator
   problem): distinct custom errors per layer — `TransferBlocked(mirror
   code)` for VAR, `RamsMandateRequired`/`RamsBlocked(RAMS_* code)` for the
   registry, `RamsComplianceBlocked(ReasonCode)` for the provider, OZ's
   standard error for allowance — plus a free `canTransferBy(operator,
   from, value)` pre-flight and `ramsDiagnose` (the registry's `canExecute`
   is a bare bool; the view re-derives which check failed, in the
   registry's own evaluation order).

## The compromised-key demo (`test/demo/CompromisedKey.t.sol`)

- **A** — agent routes through the reference AgentExecutor under a valid
  mandate; executor and asset each verify a leash; both ledgers record.
  (Operational note: the executor needs `RECORDER_ROLE` on the registry —
  the live deployment hasn't granted it, so the deployed executor currently
  can't record.)
- **B** — the same agent key, compromised, signs a raw `transferFrom` for
  the full balance, bypassing the executor. Blocked at the asset:
  `RamsBlocked(RAMS_OVER_TX_CAP)`. Patient cap-sized theft is bounded by the
  cumulative cap (200 of 1,000 in the demo), and the principal's
  `revokeMandate` cuts it off mid-incident — no enforcer involved.
- **C** — `PrincipalRevoked` fires, no freeze lands. The registry still says
  yes (`canExecute == true`, demonstrated); the asset says no
  (`RamsComplianceBlocked(AML_FLAG)`) on both the raw and executor paths.

## Deploying

```sh
export DEPLOYER_PRIVATE_KEY=… ETH_SEPOLIA_RPC_URL=…
make deploy-rams      # mirror + GatedUSDRams(strict) + adapter, sanity-checked
make sanity-rams MIRROR=… TOKEN=… ADAPTER=…   # re-run checks any time
make verify-rams MIRROR=… TOKEN=… ADAPTER=…   # Etherscan verification
```

Deployment targets **Ethereum Sepolia (11155111)** — the task brief said Base
Sepolia, but Phase 0 verification found the live RAMS contracts on Ethereum
Sepolia (all three Etherscan-verified, bytecode == EIP reference); see
`verification-status.md` for the trail. Addresses land in
`shared/addresses.json` under `eth-sepolia`.
