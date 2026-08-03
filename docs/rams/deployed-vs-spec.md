# ERC-8226 deployed contracts vs. EIP reference implementation

**Date:** 2026-07-08 (verification run)
**Deployment chain:** Ethereum Sepolia (11155111) — NOT Base Sepolia as the
original task brief stated; see `verification-status.md` for the discovery
trail.

## Method

Stronger than a source diff: we compiled the EIP reference implementation
(`ethereum/ERCs` `assets/erc-8226/`, vendored read-only at
`contracts/lib/rams-reference/`) locally with the deployed toolchain — solc
0.8.30, optimizer on, 200 runs (the reference's own `foundry.toml` settings),
OpenZeppelin 5.6.1 (this repo's pinned submodule) — and compared runtime
bytecode against `eth_getCode` output, masking immutable-reference regions
and the CBOR metadata tail.

## Result: ZERO code deviations

| Contract | Address | Runtime bytecode vs reference |
|---|---|---|
| AgentMandate | `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e` | **MATCH** (9,977 bytes compared, 7 immutable refs masked) |
| ComplianceProvider | `0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278` | **MATCH** (1,727 bytes, no immutables) |
| AgentExecutor | `0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952` | **MATCH** (2,474 bytes, 6 immutable refs masked) |

The deployed contracts are byte-for-byte the EIP reference implementation.
All three are also Etherscan-verified ("Exact Match", solc
v0.8.30+commit.73712a01). The reference's own Foundry suite (72 tests) passes
against the same build.

Because the code is identical, every spec-conformance property of the
reference carries over to the deployment: EIP-712 domain ("RAMS", "1"),
per-principal nonces, SignatureChecker/EIP-1271 path, grant-time compliance
check, revert-on-cap recordExecution, admin/enforcer role separation
(`AdminEnforcerOverlap`), `type(uint256).max` = no-limit caps, cumulativeUsed
preserved across extendMandate.

## Deployment provenance and live configuration (matters for the review)

Deployed 2026-07-06 ~11:14 UTC in blocks 11215028 / 11215031 / 11215035
(three plain CREATE transactions), all by EOA
`0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1` (busy dev key: nonce 5741,
~34 sepETH). That key currently holds every position of authority:

| Position | Holder |
|---|---|
| AgentMandate `DEFAULT_ADMIN_ROLE` | `0xB610470a…faf1` (deployer) |
| AgentMandate `ENFORCER_ROLE` | **nobody — never granted** |
| AgentMandate `RECORDER_ROLE` | **nobody — never granted** |
| ComplianceProvider owner | `0xB610470a…faf1` |
| AgentExecutor owner | `0xB610470a…faf1` |
| AgentExecutor principal (immutable) | `0xB610470a…faf1` |
| AgentExecutor → rams (immutable) | AgentMandate ✓ (correctly wired) |

Live state observations (as of block ~11233510):

- **No ENFORCER_ROLE holder exists, so `freezeAgent` is currently
  uncallable by anyone.** The code's `AdminEnforcerOverlap` guard prevents
  the admin from granting itself the role; a second address is required. The
  spec's PrincipalRevoked→freeze mitigation window is therefore not just a
  window on this deployment — the freeze lever is unwired. No freeze relay
  can exist yet. (Security review item.)
- No `PrincipalGranted` on the ComplianceProvider, no mandates, no operator
  approvals, no executions recorded: the deployment is unused.
- AgentExecutor's action-selector registry is empty (`actions(0x23b872dd)`
  and `actions(0xa9059cbb)` both unset). `setAction` emits **no event**, so
  this was confirmed by direct storage reads; the lack of observability on
  that cap-critical registry is itself a review note.

## Deviations to document per the task brief

- **Code deviations: none.**
- **Configuration deviations from the spec's operational assumptions:**
  1. Chain differs from the task brief (Ethereum Sepolia, not Base Sepolia).
  2. Enforcer role unassigned → freeze path inert (spec assumes an enforcer
     exists to close the revocation window).
  3. Single EOA concentration: compliance operator, registry admin, executor
     owner, and executor principal are one key. Acceptable for a testnet
     demo; noted for the review's role-separation section.
