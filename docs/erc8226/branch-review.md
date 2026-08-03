# Review: `origin/feat/rams-8226-integration` @ `da8f661` (PR #11)

**Reviewed:** 2026-07-28 · **Branch tip:** `da8f661`, authored 2026-07-08 23:39 -0400
**PR #11:** open, base `main`, 0 reviews, 0 comments, never merged
**Method:** isolated `git worktree` at `da8f661`; the working tree at `/Users/user/VAR`
was not modified. All live reads against public RPCs. Every zero result below was
preceded by a positive control on a known-present term.

## Headline

The branch **builds clean and 99/104 tests pass**. The spec it was built against has
**not drifted by a single byte**. But two things must be fixed before you describe this
publicly:

1. **The one test that composes our token against their live registry fails today.**
   `test_Fork_GatedUSDRamsAgainstLiveRegistry` reverts `OwnableUnauthorizedAccount`
   because Brickken transferred ownership of both contracts after 2026-07-08. Our code
   is fine; the test hardcodes an address that is no longer the admin.
2. **Nothing was ever deployed and no live transaction exists.** The single fact you
   said would be worth more than the rest of the branch — our contract calling their
   `canExecute`/`recordExecution` on a live chain — **does not exist**. Every
   interaction is fork-local.

> **UPDATE 2026-08-03.** Item 1 is **FIXED**. `RamsFork.t.sol` now reads the provider
> owner at runtime (`IOwnable(LIVE_PROVIDER).owner()` → `0x6b0173489007dE9E2e619eccd98E8fa9c610849a`)
> instead of hardcoding, all 5 fork tests pass against live Sepolia, and the suite now
> **fails loudly** instead of skipping when `ETH_SEPOLIA_RPC_URL` is unset. Counts are
> now **114 passing, 0 skipped** (109 with `--no-match-contract RamsForkTest`).
>
> Item 2 is **STILL TRUE**. Deployment is blocked on two missing credentials: no
> `ETHERSCAN_API_KEY` anywhere in the environment (so source verification is impossible,
> and we will not deploy unverified), and the deployer `0x54E7B896…1dec` holds
> **0 Sepolia ETH at nonce 0** — it has never transacted on that chain. Until both are
> supplied, **no live-transaction claim may be made.**

---

## 1. Does it work

### 1.1 Setup

```sh
git worktree add --detach <scratch>/wt-rams da8f661     # exit 0
cd <scratch>/wt-rams && git submodule update --init --recursive   # exit 0
```

`contracts/lib/rams-reference/` is **not** a submodule — it is a vendored tree tracked
directly in git (`git ls-tree -d HEAD contracts/lib/rams-reference` → `040000 tree
6a657d94…`). Only `forge-std` and `openzeppelin-contracts` are submodules. The
reproduction steps in `docs/rams/INTEGRATION.md:11` are correct but the submodule step
is not required for the RAMS code itself.

### 1.2 Build

```sh
cd contracts && forge build
```

**BUILD_EXIT=0.** Foundry `1.5.1-stable` (commit `b0a9dd9c`, profile maxperf).
Three non-fatal lints, all in test code, none in `src/`:

| Lint | Location |
|---|---|
| `unsafe-typecast` on `bytes32("OK")` | `test/rams/GatedUSDRams.t.sol:268` |
| `erc20-unchecked-transfer` | `test/rams/GatedUSDRams.t.sol:304` |
| `unused-import` (`Test`) | `test/rams/RamsTestBase.sol:4` |

### 1.3 Test suite — default (no RPC)

```sh
cd contracts && forge test
```

**TEST_EXIT=0.** `Ran 13 test suites: 99 tests passed, 0 failed, 5 skipped (104 total tests)`

| Result | Count |
|---|---|
| Passed | **99** |
| Failed | **0** |
| Skipped | **5** |
| Total | **104** |

The 5 skipped are the entire `RamsForkTest` suite, gated behind `ETH_SEPOLIA_RPC_URL`
(`test/rams/RamsFork.t.sol:17`, the `onFork` modifier). **A default `forge test` run
therefore exercises none of the live-registry claims.** That matters: the branch's
strongest claim is live-fork verification, and it is off by default.

### 1.4 Test suite — with a live Sepolia RPC

```sh
ETH_SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com \
  forge test --match-contract RamsForkTest -vv
```

`Suite result: FAILED. 4 passed; 1 failed; 0 skipped`

| Test | Result |
|---|---|
| `test_Fork_ChainAndDomain` | PASS |
| `test_Fork_Erc165Surfaces` | PASS |
| `test_Fork_ExecutorWiring` | PASS |
| `test_Fork_ViewSurface` | PASS |
| **`test_Fork_GatedUSDRamsAgainstLiveRegistry`** | **FAIL** |

**Failing assertion:** `[FAIL: OwnableUnauthorizedAccount(0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1)]`

Trace (`-vvvv`), the exact failing call:

```
├─ [0] VM::prank(0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1)
├─ [2646] 0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278::grantPrincipal(forkPrincipal, 0xc707d60b…, 1787849928)
│   └─ ← [Revert] OwnableUnauthorizedAccount(0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1)
```

**Root cause — environmental, not a code defect.** `RamsFork.t.sol:27` hardcodes
`LIVE_ADMIN = 0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1` as the observed
ComplianceProvider owner and pranks as it to grant fork-local eligibility. Ownership has
since moved:

```sh
cast call 0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278 'owner()(address)' --rpc-url <sepolia>
# → 0x6b0173489007dE9E2e619eccd98E8fa9c610849a
```

The registry admin moved too (§4.4). Fix is one line: retarget `LIVE_ADMIN`, or better,
`vm.prank(LIVE_PROVIDER.owner())` so the test cannot rot again. **Nothing was
broadcast** — the test only mutates a local fork (`vm.createSelectFork`).

### 1.5 Test diff vs `f7bd69a`

`forge test --list --json` on both trees:

| Suite | `f7bd69a` | `da8f661` |
|---|---|---|
| 8 pre-existing suites | 63 | 63 (unchanged) |
| `test/demo/CompromisedKey.t.sol` | — | **3** |
| `test/rams/GatedUSDRams.t.sol` | — | **19** |
| `test/rams/VARComplianceProviderAdapter.t.sol` | — | **11** |
| `test/rams/RamsFork.t.sol` | — | **5** (skip by default) |
| `test/rams/RamsFuzz.t.sol` | — | **3** |
| **Total** | **63** | **104** |

**41 new tests**, not 36. `docs/rams/INTEGRATION.md:18` says "63 pre-existing VAR tests
+ 36 RAMS integration tests" — that counts only the 36 that run without an RPC and does
not disclose that 5 skip. `GatedUSD.t.sol` gained 22 lines but still has 12 tests.

The 41 new test names are enumerated in Appendix A.

---

## 2. Spec drift since July 8

**There is none. The vendored copy is byte-identical to the currently published spec.**

```sh
curl -sS -L https://raw.githubusercontent.com/ethereum/ERCs/master/ERCS/erc-8226.md -o eip8226-live.md   # HTTP 200
git show "${B}:contracts/lib/rams-reference/erc-8226-spec.md" > eip8226-vendored.md
diff -u eip8226-vendored.md eip8226-live.md
# DIFF_EXIT=0, 0 lines of output
shasum -a 256 eip8226-vendored.md eip8226-live.md
# e48e336f073e95d38d302a09ba28d33dacc1c5dfb60b48858067b10de578a13a  (both)
```

Both 538 lines, 32,430 bytes, identical SHA-256. **Positive control:** the same diff
harness against a one-word-mutated copy correctly emitted a hunk, so the zero-diff is a
real negative, not a broken command.

Corroborated upstream — the spec has not been touched since **before** the branch was written:

```sh
gh api "repos/ethereum/ERCs/commits?path=ERCS/erc-8226.md&per_page=20"
# 2026-06-29T21:55:49Z  dacbc4a3  Update ERC-8226: add reference implementation and refine spec
# 2026-05-12T17:05:10Z  3edf21b6  Add ERC: Regulated Agent Mandate
gh api "repos/ethereum/ERCs/contents/ERCS/erc-8226.md"   # size=32430
```

Last upstream change **2026-06-29**, nine days before the branch. Current `master` blob
is 32,430 bytes, matching ours exactly.

**Classification of differences: none exist.** All five areas you flagged —
`IAgentMandate` struct fields, EIP-712 typehashes, `canExecute` check order,
`recordExecution` caller restriction, `IComplianceProvider.ReasonCode` members — are
unchanged, because the whole document is unchanged.

> **Caveat you should state if asked.** This compares the *published EIP*. The authors
> may have proposed changes in the Ethereum Magicians thread
> (`ethereum-magicians.org/t/erc-8226-regulated-agent-mandate/28208`) that have not
> landed in `ethereum/ERCs`. I did not read the thread. "No drift in the published
> spec" is what I verified; "the authors have not changed their minds" is not.

---

## 3. What conformance we actually achieved

### 3.1 MUST-clause table

Extracted with `grep -n -E "MUST|SHALL|REQUIRED" eip8226-live.md`. Only clauses binding
on an *integrator* or a *compliance provider* are in scope; clauses binding on the
registry implementation are marked N/A (we integrate the reference registry, we do not
reimplement it).

| Spec line | Clause | Our status | Evidence |
|---|---|---|---|
| L42 | All implementations MUST implement ERC-165 | **Adapter: SATISFIED. Token: VIOLATED (arguable scope)** | `VARComplianceProviderAdapter.sol:123`; `GatedUSDRams` has none — see §3.2 |
| L59 | `checkPrincipal` MUST return structured data; binary oracle non-conformant | **SATISFIED** | `VARComplianceProviderAdapter.sol:87-105` returns the full triple |
| L59 | MUST verify `identityRef` resolves to a valid, unrevoked attestation; `eligible == false` if not | **SATISFIED** | `:92-93` unknown ref → `IDENTITY_NOT_FOUND`; `:101-102` superseded/revoked → `ATTESTATION_REVOKED` |
| L105 | `reason` MUST be `COMPLIANT` when `eligible` is true | **SATISFIED** | `:104` is the only `true` return, paired with `COMPLIANT` |
| L106 | `expiresAt` MUST be the re-check timestamp | **SATISFIED** | `:103-104` returns `_toUint48(m.expiry)` — real, see §3.3 |
| L61 / L161 | `grantMandate` MUST revert on zero provider / ineligible principal | **N/A (registry)** — verified present in reference | `docs/rams/security-review-draft.md` §4 |
| L130 | `recordExecution` MUST only be callable by asset/principal/RECORDER_ROLE | **SATISFIED as caller** | Our token is the mandate's `asset`; `GatedUSDRams.sol:159` |
| L423 | A transfer with `msg.sender != from` is agent-initiated and MUST satisfy the `(msg.sender, from)` mandate | **SATISFIED** | `GatedUSDRams.sol:134-153` — see §3.5 |
| L425 | Both token allowance AND the RAMS mandate MUST pass | **SATISFIED** | `:155` calls `super.transferFrom`, which runs OZ allowance; test `test_AllowanceStillRequiredAlongsideMandate` |
| L535 | Implementations MUST NOT rely on `metadata` for enforcement | **SATISFIED** | `metadata` is never read in `src/` |
| L126 | Freeze MUST be enforcer-restricted; admin MUST NOT be an enforcer | **N/A (registry)** | — |
| L134/L136 | EIP-1271 verification, per-principal nonces, deadline | **N/A (registry)** | Exercised in `testFuzz_NonceMonotonicityOnSignedOps` |
| — | `grantPrincipal` / `revokePrincipal` declared non-optional in `IComplianceProvider` | **SKIPPED — both revert unconditionally** | `VARComplianceProviderAdapter.sol:111-120` |

### 3.2 ERC-165

```sh
grep -rn "interfaceId\|IERC165\|supportsInterface" contracts/src/
```

- **`VARComplianceProviderAdapter`: correct.** `:123-125` returns true for
  `type(IComplianceProvider).interfaceId` and `type(IERC165).interfaceId`. Asserted by
  `test_SupportsInterface`.
- **`GatedUSDRams`: absent.** No `supportsInterface` anywhere in `GatedUSDRams.sol` or
  its parent `GatedUSD.sol` (control: the grep does find the adapter's, so the search
  works).

Whether L42 binds the token is genuinely ambiguous — `GatedUSDRams` implements neither
`IAgentMandate` nor `IComplianceProvider`; it is an integrating asset. A strict reader
of "All implementations MUST implement ERC-165" will call it non-conformant. This is the
same defect I flagged in `repo-brief.md` §8.6 about the ERC-7943 `canTransfer` surface,
and it is unfixed and cheap to fix. **Fix it before publishing** rather than argue scope.

### 3.3 `checkPrincipal` — the triple, and where each value comes from

`VARComplianceProviderAdapter.sol:87-105`. Full `(bool eligible, ReasonCode reason,
uint48 expiresAt)` signature, matching the spec at L112-113.

| Return | Source | Real? |
|---|---|---|
| `eligible` | Live `mirror.getMandate(binding.agent)` read on every call | Real, no caching |
| `reason` | Derived from mirror state, 4 branches (§3.6) | Real |
| `expiresAt` | **`_toUint48(m.expiry)`** — the mirror mandate's own expiry, saturated at `type(uint48).max` rather than truncated (`:136-138`) | **Real. Not hardcoded, not zero** on the eligible path |

`expiresAt` is `0` only on the `IDENTITY_NOT_FOUND` and `ATTESTATION_REVOKED` branches
(`:93`, `:97`, `:101-102`), where there is no meaningful expiry. Note the branch's own
security review flags this same `0`-on-false-branch pattern in *Brickken's* provider as
a nit colliding with the "0 = no expiry" convention — **our adapter has the identical
pattern.** If you raise that as a spec point, raise it as a shared observation, not as a
criticism of their code, because ours does it too.

### 3.4 Identity resolution — no off-chain call in the adapter, but §8.1 is LOAD-BEARING

Identity resolves through `_bindings[identityRef]` (`:49`), populated only by
`bindIdentity`. That function is permissionless but **proof-carrying**: it takes the full
`Attestation` struct, recomputes `hashStruct`, and rejects unless the attestation is the
one currently live in the mirror — same agent, same nonce, same principal. Enforced by
`test_BindRejectsNonCurrentAttestation`, and (since 2026-08-03) it also rejects revoked
and expired mandates — see `test_BindRejectsRevokedMandate_LatchCannotBeReset`.

There is no off-chain call, no World ID lookup and no AgentBook read in the adapter
(control: `grep -rn "IERC165" contracts/src/` returns hits, so the files are being
searched; `AgentBook`/`lookupHuman`/`worldchain` return nothing in `contracts/src/`).

**But do not read that as an all-clear, which the previous wording of this section
invited.** The accurate statement is stronger and less comfortable:

> `checkPrincipal` performs **no personhood check at all**. `_evaluate` reads exactly
> four mirror fields — `principal`, `nonce`, `revoked`, `expiry` — and **never reads
> `proofRef` or `kycRef`**, the only fields carrying personhood evidence (verified:
> `grep -n 'proofRef\|kycRef'` on the adapter returns only the `identityRef` hash
> preimage and the typehash string; control `identityRef` returns 39 hits). `proofRef`
> is *committed to* but never *checked*.

The personhood check happens once, off-chain, before any of this:
`web/app/api/var/grant/route.ts:88` calls `AgentBook.lookupHuman(agent)` on World Chain
(480); the result becomes `proofRef = keccak256(bytes32(humanId))`; the attestor signs;
`DelegationMirror.submitAttestation` stores that `bytes32` **unverified**, checking only
`registeredAttestor[ecrecover(...)]`.

So the adapter's eligibility verdict is exactly as trustworthy as §8.1 plus the single
attestor key of §8.2. **§8.1 remains a LIVE, UNFIXED finding** — re-verified 2026-08-03:
`sameOrigin.ts:11` still returns `null` (allow) when there is no `Origin` header, so every
non-browser caller including `curl` passes; `principal`, `spendCap` and `expiryMinutes` are
still taken verbatim and unbounded from the request body (`grant/route.ts:70-76`); and
`lookupHuman` still proves only that *the agent* is human-backed, never that the requester
is that human. Nothing in this branch fixes it, and this branch must not be described as
if it does.

The adapter is one hop from the problem, not free of it.

> **UPDATE 2026-08-03 — both halves addressed. State it precisely.**
>
> **`checkPrincipal` now enforces personhood on every evaluation.** The adapter
> stores a registered attestor's signed assertion that
> `AgentBook.lookupHuman(agent) == humanId` on World Chain 480, with an expiry
> and a revocation path, and `_evaluate` checks it on every call — returning
> `IDENTITY_NOT_FOUND` when it is absent, revoked, or does not match. The
> asserted `humanId` is bound to the mandate's own `proofRef` via
> `keccak256(bytes32(humanId))`, so **`proofRef` is now checked rather than
> merely committed to.** That derivation is pinned to live cross-chain data:
> the humanId AgentBook returns for agent `0x69e170Dd…cC54` hashes to exactly
> the `proofRef` in that agent's live Arc mandate.
>
> **What this earns, and what it does not.** AgentBook is on World Chain
> *mainnet*; this adapter targets Ethereum *Sepolia*; World Chain settles to
> Ethereum mainnet, so no canonical state root of 480 exists on Sepolia and no
> storage proof or bridge can carry `lookupHuman` here. **Trustless on-chain
> personhood on Sepolia is not hard, it is impossible.** (This also corrects
> the storage-proof option floated earlier in this document — it is unavailable,
> not merely heavy.) Every Sepolia-side design trusts someone; we trust the
> attestor set the mirror already trusts, adding no new party. Say
> **"personhood-attested and enforced at evaluation time."** Do **not** say
> "trustlessly World-ID-verified on-chain" — only deploying the stack on World
> Chain 480 would earn that.
>
> **§8.1's headline defect is fixed for the granting route** (proof of control
> over `principal`), but its sibling privileged routes are hardened, not
> authenticated. See the status block at `repo-brief.md` §8.1 for the exact
> split before making any claim about the deployment being authenticated.

### 3.5 The `msg.sender == from` question — the most important one

Their reference `canTransfer` returns true immediately when `msg.sender == from`, which
is every VAR transfer where the agent holds its own funds. Here is exactly what our code
does (`contracts/src/GatedUSDRams.sol:134-162`):

```solidity
function transferFrom(address from, address to, uint256 value) public override returns (bool) {
    address agent = _msgSender();
    if (agent == from) {
        // Holder-initiated; VAR checks only (in GatedUSD._update).
        return super.transferFrom(from, to, value);
    }

    IAgentMandate.Mandate memory m = rams.getMandate(agent, from);
    bool mandated = m.principal != address(0);

    if (!mandated && strictMandates) revert RamsMandateRequired(agent, from);
    if (mandated) {
        if (!rams.canExecute(agent, from, address(this), ACTION_TRANSFER_FROM, value)) {
            revert RamsBlocked(agent, from, ramsDiagnose(agent, from, value));
        }
        (bool eligible, IComplianceProvider.ReasonCode cpReason) = _checkCompliance(m, from);
        if (!eligible) revert RamsComplianceBlocked(agent, from, cpReason);
    }

    bool ok = super.transferFrom(from, to, value);

    if (mandated) {
        rams.recordExecution(agent, from, ACTION_TRANSFER_FROM, value);
    }
    return ok;
}
```

**The reconciliation is that the two gates are keyed on different addresses and neither
is asked to cover the other's case.**

- `agent == from` (agent spends its own balance): RAMS is skipped entirely — matching
  their model, where this is not an agent-initiated transfer. **VAR still enforces**,
  because `super.transferFrom` reaches `GatedUSD._update`, whose gate is keyed on `from`
  and is initiator-independent (`repo-brief.md` §2.1). Test:
  `test_HolderInitiatedTransferSkipsRamsLayer`, and
  `test_MirrorStillGatesMandatedAgentsOwnBalance`.
- `agent != from` (agent spends a principal's balance): RAMS enforces the
  `(agent, from)` mandate, then VAR's `from`-keyed gate *also* runs inside
  `super._update`, then OZ allowance. Three layers. Test:
  `test_BothLayersOnAgentInitiatedTransferFromMirrorAgent`.

So the RAMS layer covers precisely the hole I identified in `repo-brief.md` §6.2 path 3
(agent spending a third party's approved balance, uncapped and unrecorded), and the VAR
layer covers precisely the case their `canTransfer` waves through. **That composition
argument is the strongest technical content on this branch and it is defensible in
public.**

Two design choices worth stating plainly rather than being asked about:

- The hook is on `transferFrom`, **not** in `_update` (`:131-133` explains why: the
  initiator only exists at that entry point). Consequence: a direct `transfer()` never
  consults RAMS — correct, since `transfer` has `msg.sender == from` by construction.
- `recordExecution` is called **after** `super.transferFrom` settles (`:157-160`). The
  comment at `:128-130` argues this is safe because `recordExecution` re-checks caps and
  reverts, making accounting atomic with the transfer. That is true given the reference's
  shared `_mandateAllows` gate (confirmed in the reference at `AgentMandate.sol:166-185`).

### 3.6 Reason-code mapping — and how it lands against `repo-brief.md` §7

Two separate channels, deliberately not merged:

**Channel 1 — principal eligibility → their enum** (`VARComplianceProviderAdapter.sol:93-104`):

| Mirror state | `ReasonCode` |
|---|---|
| unknown `identityRef` | `IDENTITY_NOT_FOUND` |
| bound agent's principal ≠ principal | `IDENTITY_NOT_FOUND` |
| superseded by a newer nonce | `ATTESTATION_REVOKED` |
| revoked by principal | `ATTESTATION_REVOKED` |
| mandate expired | `KYC_EXPIRED` |
| live mandate | `COMPLIANT` |

**Channel 2 — mandate/spend failures → our own `bytes32` codes**, never forced into
their enum (`GatedUSDRams.sol:89-100`): `RAMS_NO_MANDATE`, `RAMS_WRONG_ASSET`,
`RAMS_NOT_YET_VALID`, `RAMS_EXPIRED`, `RAMS_REVOKED`, `RAMS_ACTION_DISABLED`,
`RAMS_FROZEN`, `RAMS_OVER_TX_CAP`, `RAMS_OVER_CUM_CAP`, `RAMS_PRINCIPAL_INELIGIBLE`.
Pinned by `test_ReasonCodeParity`.

**Does this contradict `repo-brief.md` §7?** §7 said "do not map" `EXPIRED→KYC_EXPIRED`
and `NO_MANDATE→IDENTITY_NOT_FOUND`, and the adapter makes both mappings. That is not a
contradiction — §7 was mapping the *mirror's transfer-gate* codes, while the adapter maps
*principal-eligibility states*, which is the axis their enum is actually for. On that
axis "the attestation expired" genuinely is the credential-expiry case.

**§7's substantive claim survives intact and is now backed by shipped code:** the
mandate/spend axis has no expressible form in their enum, and the branch's answer was to
build a second, parallel reason-code channel rather than collapse everything into
`OTHER`. That is a much stronger thing to say publicly than the original argument.

### 3.7 The one real conformance gap: dead lifecycle writes

`grantPrincipal` and `revokePrincipal` **revert unconditionally**
(`VARComplianceProviderAdapter.sol:111-120`, `LifecycleManagedByMirror`), asserted by
`test_LifecycleWritesRevert`. The spec declares both in `IComplianceProvider` (L91-99)
with no `MAY` and no optionality.

Two readings, and you should present the unfavourable one first:

- **Strict:** we implement the interface's shape but two of its three lifecycle
  functions are non-functional. A conformance checker calling `grantPrincipal` gets a
  revert. Non-conformant.
- **Charitable:** eligibility lifecycle is delegated to `DelegationMirror`'s
  attestor-signed flow, and the spec (L114) explicitly allows a provider to "delegate
  identity verification to … any other identity backend."

**The concrete interop consequence, which is not arguable:** the adapter emits
`PrincipalGranted` (`:79`) but **never emits `PrincipalRevoked`** (control: grepping the
file finds `PrincipalGranted` at :79 and nothing for `PrincipalRevoked`). Spec L531
tells integrators to run an automated relay watching `PrincipalRevoked` to trigger
`freezeAgent`. **Any such relay pointed at our adapter would never fire.** Our own
mitigation (execution-path re-check) makes this harmless *for our token*, but it makes
the adapter unsafe for any third party integrating it the way the spec describes. This
is a genuine finding about our own code and it belongs in the "known limitations" of any
public description.

---

## 4. Deployment state

### 4.1 Addresses deployed by this branch: **none**

```sh
git ls-tree -r --name-only origin/feat/rams-8226-integration | grep -E "^contracts/broadcast/"
# (empty — control: the same command on develop lists 7 Deploy.s.sol/SetAttestor artifacts)
```

**Zero broadcast artifacts on the branch.** `contracts/script/DeployRamsIntegration.s.sol`
exists (132 lines) but was never run against any chain. The branch's own address book
agrees:

```json
// shared/addresses.json → "eth-sepolia"
{ "AgentExecutor": "0xc81949…59952", "AgentMandate": "0xD68E1bb9…778e",
  "ComplianceProvider": "0xa90D2503…f278",
  "DelegationMirror": null, "GatedUSDRams": null,
  "VARComplianceProviderAdapter": null, "chainId": 11155111 }
```

`GatedUSDRams` and `VARComplianceProviderAdapter` are **`null`**. Nothing of ours exists
on any chain. The Arc addresses in the same file are inherited from `develop` and
unchanged by this branch.

### 4.2 Brickken's three contracts — confirmed live on Ethereum Sepolia

```sh
cast chain-id --rpc-url https://ethereum-sepolia-rpc.publicnode.com   # 11155111
cast code <addr> --rpc-url <same>
```

| Contract | Address | Runtime bytecode |
|---|---|---|
| AgentMandate | `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e` | **10,030 bytes** |
| ComplianceProvider | `0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278` | **1,780 bytes** |
| AgentExecutor | `0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952` | **2,527 bytes** |

Control: `cast code 0x…dEaD` → `0x`. All three confirmed present, chainId 11155111 —
**not Base Sepolia**, as the branch itself documented and corrected
(`docs/rams/verification-status.md:24-45`).

Live surface checks, run just now:

- `AgentMandate.DOMAIN_SEPARATOR()` → `0xae6058abd18e03ad7b88c512ba9d5d63492ae383ae54e0de103a578b8c90bec7`, <!-- pragma: allowlist secret -->
  **exactly** the value pinned at `RamsFork.t.sol:30`. Unchanged since July 8.
- `AgentMandate.supportsInterface(0x01ffc9a7)` → `true`.
- Bytecode length 10,030 bytes matches `deployed-vs-spec.md:22`'s figure — same contract,
  no redeploy.

### 4.3 Source verification — **could not confirm; do not claim it**

| Source | Result |
|---|---|
| Etherscan v2 API | **Unavailable.** `{"status":"0","message":"NOTOK","result":"Missing/Invalid API Key"}`. No key in env or any local `.env`. |
| Sourcify (chain 11155111) | **HTTP 404, `"match": null`** for all three addresses — not verified on Sourcify. |

> **UPDATE 2026-08-03 — the underlying question is now settled by a stronger method.**
> Etherscan's *verification status* is still unconfirmable without an API key (none has
> appeared), and Sourcify is additionally in a scheduled v1 brownout until 2027-01-08.
> But "is the deployed code the reference implementation?" no longer depends on either.
> I rebuilt the vendored reference out-of-tree with the deployed toolchain (solc 0.8.30,
> optimizer 200, OZ 5.6.1) and diffed runtime bytecode against `eth_getCode`:
>
> | Contract | Executable body | Immutables masked | Result |
> |---|---|---|---|
> | AgentMandate | 9,977 bytes | 7 | **identical** |
> | ComplianceProvider | 1,727 bytes | 0 | **identical** |
> | AgentExecutor | 2,474 bytes | 6 | **identical** |
>
> Only the 51-byte CBOR metadata tail differs, which is the source-path IPFS hash and
> carries no semantics. **State it as "executable code is byte-identical to the EIP
> reference implementation, independently reproduced" — which is what we can prove — and
> not as "Etherscan-verified Exact Match", which we still cannot.** Note this also makes
> `deployed-vs-spec.md`'s "byte-for-byte" phrasing slightly too strong; the precise claim
> is executable-code-identical with a differing metadata hash.

`docs/rams/deployed-vs-spec.md:31` claims all three are Etherscan-verified "Exact Match".
**I could not verify that claim.** It may well be true — Sourcify and Etherscan are
independent — but you cannot repeat it as verified until someone checks with a key.

The related "bytecode-identical to the EIP reference" claim is **also not reproducible
from this repo**: the vendored artifacts contain only `abi` and creation `bytecode`
(`jq 'keys[]'` → `_comment, abi, bytecode`), with no `deployedBytecode` and no
`immutableReferences`, and reproducing it needs solc 0.8.30 (absent; `~/.svm/` does not
exist) while the repo pins 0.8.26. What *is* independently confirmed is ABI-level
conformance: `test_Fork_ViewSurface` and `test_Fork_Erc165Surfaces` pass against live
state today.

### 4.4 Live authority has changed since July 8

| Position | Branch recorded (2026-07-08) | **Today (2026-07-28)** |
|---|---|---|
| ComplianceProvider `owner()` | `0xB610470a…faf1` | **`0x6b0173489007dE9E2e619eccd98E8fa9c610849a`** |
| AgentMandate `DEFAULT_ADMIN_ROLE` | `0xB610470a…faf1` | **`0x6b017348…849a`** (`hasRole` → deployer `false`, new `true`) |
| `RECORDER_ROLE` | nobody | **still nobody** (deployer, new admin, executor all `false`) |
| `ENFORCER_ROLE` | nobody | **still nobody** |

Control: `hasRole(DEFAULT_ADMIN_ROLE, address(0))` → `false`, so the getter discriminates.

This is the cause of the §1.4 test failure, and it means `deployed-vs-spec.md:44-50`'s
authority table is stale. **The two substantive security-review findings still reproduce
exactly** (§5).

### 4.5 Is there a live transaction of our contract calling theirs? **No.**

There is **no recorded transaction, on any chain, in which any VAR contract called
`canExecute` or `recordExecution`.** Nothing of ours is deployed (§4.1), so no such
transaction can exist. Every interaction in this branch is `vm.createSelectFork`
local-fork state that is discarded when the test process exits.

You identified this as the single most valuable public fact. It is currently unavailable,
and it is also **the cheapest thing on this list to obtain**: `DeployRamsIntegration.s.sol`
is written, the registry is live, Sepolia ETH is free. See "Blocking before publication".

---

## 5. The phase 5 security review

Source: `docs/rams/security-review-draft.md` (174 lines, commit `99b6588`). Marked
**"DRAFT — private. Not for distribution before the Brickken team has seen it."**

### 5.1 Findings about THEIR code and deployment

**No vulnerability was found in their contract code.** The review's own summary
(`:168-170`): *"The code is the reference implementation, and the reference is solid …
Everything we'd flag is deployment configuration, not code."* I verified the two
substantive findings independently against live state.

| # | Finding | Severity | Location | Reproduces today? | Spec deviation or spec flaw? |
|---|---|---|---|---|---|
| 1 | **Deployed `AgentExecutor` cannot record.** No `RECORDER_ROLE` ever granted, and the executor is neither asset nor principal, so every `AgentExecutor.execute` reverts `UnauthorizedRecorder` at the record step. | Medium (operational) | Live config of `0xc81949…59952` + `0xD68E1bb9…778e` | **YES** — `hasRole(RECORDER_ROLE, executor)` → `false` (verified §4.4) | Neither. Deployment config. Code correctly enforces spec L130. |
| 2 | **No enforcer exists; `freezeAgent` is uncallable by anyone.** The spec's mitigation for the `PrincipalRevoked`→freeze window assumes an enforcer; here the window is unbounded. | Medium (operational) | Live config of `0xD68E1bb9…778e` | **YES** — `hasRole(ENFORCER_ROLE, ·)` → `false` for every address checked | Neither, but it makes a **spec flaw** (finding 4) unmitigated in practice. |
| 3 | **Authority concentration.** One EOA was simultaneously registry admin, provider owner, executor owner and executor principal. | Low (testnet) | — | **PARTIALLY — and it has moved.** Both positions transferred to `0x6b017348…849a`; still a single EOA holding both. | Neither. Deployment config. |
| 4 | **`PrincipalRevoked` → freeze window.** `canExecute` reads only registry state, so after a provider revokes a principal, `canExecute` still returns `true` until a freeze or mandate revocation lands. | Low–Medium | Spec L531 + reference `canExecute` | **YES** (structural; unchanged bytecode) | **Spec flaw**, explicitly admitted by the spec at L531. This is the gap our token closes. |
| 5 | **`setAction` emits no event.** A wrong `amountIndex` silently mis-gates caps with no off-chain audit trail. | Low | Reference `AgentExecutor.sol` | Yes (structural) | **Reference-implementation quality gap**, not a spec violation. |
| 6 | **`principal` may call `recordExecution` directly**, burning their own agent's cumulative headroom with no transfer occurring. | Informational | Reference, per spec L130 | Yes | **Spec design consequence**, explicitly permitted. Integrators reconciling `cumulativeUsed` against transfers should know they are not 1:1. |
| 7 | **`expiresAt == 0` on the ineligible branch** collides with the "0 = no expiry" convention. | Informational | Reference `ComplianceProvider` | Yes | Spec ambiguity. **Our adapter has the identical pattern** (§3.3). |
| 8 | Items checked clean: reentrancy; `canExecute`/`recordExecution` drift (impossible — shared `_mandateAllows`); `extendMandate` cannot resurrect revoked mandates and preserves `cumulativeUsed`; ERC-165 on both. | — | — | — | — |

### 5.2 Findings about OUR code

The review is almost entirely outward-facing. Self-directed content is limited to the
design rationale in §6 of that document (the asset-layer closure of the revocation
window) and `test/demo/CompromisedKey.t.sol` scenario C. **The branch contains no
adversarial review of our own two contracts.** The gaps in §3.2 (no ERC-165 on the token)
and §3.7 (dead lifecycle writes, `PrincipalRevoked` never emitted) are ones I found in
this review, not ones the branch had already caught.

### 5.3 Disclosure buckets

**Bucket A — private disclosure required before any public post: NONE.**

I want to be precise, because this is the bucket that matters. No finding is a
vulnerability in deployed contract code. Findings 1–3 are configuration facts about a
public testnet deployment, readable by anyone with an RPC endpoint. There is no exploit,
no funds at risk, no undisclosed code flaw.

**However, send findings 1–3 to Brickken privately first anyway, as a courtesy**, before
mentioning any of it publicly. Two reasons: the review document is explicitly marked
private and not-yet-shared with them, and "your deployed executor cannot record and you
have no enforcer" reads very differently as a surprise forum post than as a heads-up
email. This is etiquette, not embargo. It also gives you a natural, non-adversarial
opening with the authors.

**Bucket B — safe to raise publicly as spec discussion points:**

- Finding 4, the `PrincipalRevoked`→freeze window. Already admitted in the spec at L531;
  raising it with a concrete asset-layer mitigation is a contribution, not a disclosure.
- Finding 6, `recordExecution` by the principal makes `cumulativeUsed` ≠ sum of
  transfers. Spec-level clarification request.
- Finding 7, `expiresAt == 0` overloading. Raise as a shared observation — ours does it too.
- Finding 5, `setAction` event. Reference-implementation quality suggestion, safe.

**Bucket C — not worth raising:** the minor `grantMandate` footguns (`asset` not
zero-checked, zero caps produce an inert mandate, `validFrom == 0` means immediately
active) — all principal-side, non-exploitable, and the review itself calls them "maybe
worth NatSpec". Also the two EIP-712 UX notes (direct calls consume no nonce; unbounded
`deadline`) — correct behaviour, relayer-implementer detail.

---

## 6. Do the four public findings survive

### (a) `canExecute` returns a bare bool — **CONFIRMED, and already solved in shipped code**

The spec's own normative pseudocode (L167-L196) returns `bool` from eight distinct
failure branches. Confirmed.

**The branch does not just observe this — it fixes it at the integration layer.**
`GatedUSDRams.ramsDiagnose` (`:197-211`) re-derives which check failed, in the registry's
own evaluation order:

```solidity
function ramsDiagnose(address agent, address holder, uint256 value) public view returns (bytes32) {
    IAgentMandate.Mandate memory m = rams.getMandate(agent, holder);
    if (m.principal == address(0)) return RAMS_NO_MANDATE;
    if (m.asset != address(this)) return RAMS_WRONG_ASSET;
    if (block.timestamp < m.validFrom) return RAMS_NOT_YET_VALID;
    if (block.timestamp > m.validUntil) return RAMS_EXPIRED;
    if (m.revoked) return RAMS_REVOKED;
    if (!rams.isActionEnabled(agent, holder, ACTION_TRANSFER_FROM)) return RAMS_ACTION_DISABLED;
    if (rams.isFrozen(agent)) return RAMS_FROZEN;
    if (m.maxTransactionValue != type(uint256).max && value > m.maxTransactionValue) return RAMS_OVER_TX_CAP;
    if (m.maxCumulativeValue != type(uint256).max && m.cumulativeUsed + value > m.maxCumulativeValue) {
        return RAMS_OVER_CUM_CAP;
    }
    return RAMS_OK;
}
```

**Present it as shipped code with a caveat.** The workaround costs a second `getMandate`
read plus up to three more external calls on the revert path, and it can only be built
because the mandate struct is fully public — it re-implements the registry's logic
off to the side, so it silently rots if the registry's check order ever changes. That
cost *is* the argument for putting reason codes in `canExecute`: an integrator should not
have to mirror your control flow to tell a user why their transfer failed.

### (b) `checkPrincipal`'s `expiresAt` is discarded at grant time — **CONFIRMED, verbatim**

`contracts/lib/rams-reference/contracts/AgentMandate.sol:69`:

```solidity
(bool eligible,,) = IComplianceProvider(p.complianceProvider).checkPrincipal(p.principal, p.identityRef);
if (!eligible) revert PrincipalNotEligible();
```

Both `reason` and `expiresAt` are discarded. The `Mandate` struct
(`interfaces/IAgentMandate.sol`) has **no field** for it: `agent, validFrom, validUntil,
principal, revoked, complianceProvider, identityRef, asset, maxTransactionValue,
maxCumulativeValue, cumulativeUsed, metadata`. Your point stands exactly as stated —
storing it and checking it in `canExecute` would bound the revocation window without
requiring an enforcer.

Noted and respected: **`principalEligibleUntil` is your coinage.** I did not search for
it as prior art. (The previous search reported it absent, which was a true negative about
this repo and says nothing about the spec.)

The branch solves the *same underlying problem* by a different route — re-checking
`checkPrincipal` live on the execution path (`GatedUSDRams.sol:151`, `:220-226`), which
closes the window to zero blocks rather than bounding it. **Both are worth presenting:
yours is the registry-side fix that helps every integrator; the branch's is the
asset-side fix that works without any registry change.** Note the branch's version
discards `expiresAt` too (`:221`, the third return is unnamed) — it does not need it,
because it re-reads every time.

### (c) Deleting a mandate on revoke is a privilege escalation — **NOT a defect in their code; keep it, reframed**

`AgentMandate.sol:99-109`: `revokeMandate` sets `m.revoked = true` and emits
`MandateRevoked`. **It flags. It does not delete.** So the reference is safe, and under
our permissive mode a revoked pair still reads `mandated == true`
(`GatedUSDRams.sol:142`) and is enforced, not waved through — asserted by
`test_PermissiveModeStillEnforcesExistingMandate`.

**Do not present this as a flaw you found in their implementation. You will be corrected
in public.** It survives only as spec hardening: `grep -n "revoked\|revocation"` across
the spec shows the struct carries a `revoked` flag (L206) and `canExecute` checks it
(L182), but **no clause requires that revocation preserve the record**. An implementer
who deletes on revoke gets a mandate-shaped hole that a permissive integrator falls
through. Proposing an explicit MUST is a real contribution — and you have the
`DelegationMirror` precedent (`repo-brief.md` §5.1) as evidence the trap is easy to fall
into.

### (d) `maxCumulativeValue` has no per-agent aggregate — **CONFIRMED structurally**

`AgentMandate.sol:31`: `mapping(address agent => mapping(address principal => Mandate)) private _mandates;`
`cumulativeUsed` is a field of that per-pair `Mandate` (`:85`, `:166-170`, `:185`). There
is no agent-level accumulator anywhere in the contract.

So an agent holding mandates from N principals has N independent budgets and no ceiling
on the sum. **Sharpen the framing before you post it.** Your phrasing — "an agent
spending a third party's approved balance is uncapped" — is wrong under RAMS: that spend
requires an `(agent, thirdParty)` mandate and is capped by *it*. The accurate claim is:
*RAMS caps per delegation, not per agent, so a single compromised agent's total blast
radius across all its principals is unbounded by the standard, and no principal can see
or limit the others' exposure.* That is a legitimate design question — per-principal
caps may well be the right answer, since each principal only controls their own risk —
so raise it as a question, not a defect.

The branch does **not** implement a per-agent aggregate. `repo-brief.md` §6.2 path 3 (the
VAR-side version of this hole) *is* closed by `GatedUSDRams` (§3.5).

---

## 7. Why it stalled

### 7.1 Nobody looked at it

```sh
gh pr view 11 --json state,reviews,comments,mergeable,mergeStateStatus,createdAt,updatedAt
```

```
number=11  state=OPEN  draft=false
created=2026-07-09T03:43:19Z  updated=2026-07-09T03:43:19Z
base=main  head=feat/rams-8226-integration
mergeable=MERGEABLE  mergeState=CLEAN
+7894/-66  files=41
reviews=0  comments=0
```

**Zero reviews, zero comments. `updatedAt` equals `createdAt`** — not one byte of
activity since the moment it was opened. **No blocking concern was ever raised, because
no one ever engaged.** There is nothing you have forgotten; there is nothing to
remember. It stalled by neglect.

(The PR's `+7894/-66 · 41 files` differs from my `+9346/-103 · 51 files` because the PR
diffs against `main` while I diffed against `f7bd69a` on `develop`.)

### 7.2 No merge conflict

```sh
git merge-tree --write-tree origin/main origin/feat/rams-8226-integration   # exit 0
git log --oneline origin/main --not origin/feat/rams-8226-integration        # (empty)
```

**Merges clean.** `origin/main` advancing three commits creates no conflict — the branch
already contains all of `main`'s history, having been cut from it. GitHub agrees
(`mergeStateStatus=CLEAN`). **Conflicting files: none.**

### 7.3 Licensing — a real obstacle to upstreaming

| Thing | License |
|---|---|
| This repo on the branch | **MIT** (`LICENSE` line 1: "MIT License") |
| Our new RAMS sources | **MIT** (SPDX header on `GatedUSDRams.sol`, `VARComplianceProviderAdapter.sol`) |
| PR #10 proposes | **Apache-2.0** (open, MERGEABLE, CLEAN) |
| Vendored reference | MIT (`AgentMandate.sol` SPDX; `pragma ^0.8.29`) |
| **`ethereum/ERCs`** | **CC0-1.0** (`gh api repos/ethereum/ERCs/license` → `spdx_id: CC0-1.0`) |

**Neither MIT nor Apache-2.0 is compatible with contributing to `ethereum/ERCs` as-is.**
EIP content and reference assets are CC0-1.0 — a public-domain dedication that waives all
rights. MIT and Apache-2.0 both *retain* copyright and impose conditions (attribution;
Apache-2.0 adds NOTICE preservation and patent terms). You cannot contribute
MIT- or Apache-licensed files into a CC0 tree without explicitly re-dedicating those
specific files to CC0.

**PR #10 makes this strictly worse.** Apache-2.0 is more onerous than MIT for this
purpose. If any part of this integration is destined for `assets/erc-8226/`, either
merge PR #10 *after* carving out an explicit CC0 dedication for the contributed files, or
hold PR #10. Nothing blocks you from *describing* the work publicly or pointing at the
branch — this only bites if you contribute code upstream.

---

## Safe public claims

Everything here survives a hostile reader with repo access, as of 2026-07-28.

1. There is a complete, independent, token-side ERC-8226 integration on a public branch:
   `Fairloom/verified-agent-rails` PR #11, `feat/rams-8226-integration` @ `da8f661`,
   41 files, opened 2026-07-09.
2. It **builds clean** on Foundry 1.5.1-stable and its suite is **99 passed / 0 failed /
   5 skipped of 104**, with the 5 skips being fork tests gated on an RPC env var.
   41 tests are new; 63 pre-existing VAR tests are unchanged.
3. It was built against the ERC-8226 spec as published, and the vendored copy is
   **byte-identical (SHA-256 `e48e336f…`) to the spec on `ethereum/ERCs` master today**.
   The spec has not changed since 2026-06-29, nine days before the branch.
4. `GatedUSDRams` composes two authorization layers keyed on different addresses: RAMS
   gates the **initiator** when `msg.sender != from`; VAR's `DelegationMirror` gates the
   **holder** regardless of initiator. Each covers the case the other passes through.
   Code: `GatedUSDRams.sol:134-162`. Tests: `test_HolderInitiatedTransferSkipsRamsLayer`,
   `test_BothLayersOnAgentInitiatedTransferFromMirrorAgent`.
5. The integration closes the spec's **grant-time-only compliance check** by re-calling
   `checkPrincipal` on the execution path (`GatedUSDRams.sol:151`, `:220-226`), which
   reduces the `PrincipalRevoked`→`freezeAgent` window to zero blocks *at that asset*
   without requiring an enforcer. Demonstrated in `CompromisedKey.t.sol` scenario C.
6. It works around `canExecute`'s bare-bool return with `ramsDiagnose`
   (`GatedUSDRams.sol:197-211`), re-deriving the failing check in the registry's own
   order and surfacing 10 machine-readable RAMS reason codes.
7. `VARComplianceProviderAdapter` implements `IComplianceProvider` including correct
   **ERC-165** (`:123-125`) and a genuine `(bool, ReasonCode, uint48)` triple whose
   `expiresAt` is sourced from live mirror state, saturated not truncated (`:103-104`,
   `:136-138`). Identity binding is **fully on-chain and proof-carrying** (`:71-80`).
8. Brickken's three contracts are confirmed live on **Ethereum Sepolia (11155111)** — not
   Base Sepolia — with 10,030 / 1,780 / 2,527 bytes of runtime code, and their
   `DOMAIN_SEPARATOR` is unchanged from what the branch recorded on July 8.
9. Independent review of their deployment found **no vulnerability in their contract
   code**; the reference implementation held up under our unit, fuzz and live-fork
   testing. (State this — it is generous, true, and verifiable.)
10. Two operational gaps in their live deployment **still reproduce today**: no
    `RECORDER_ROLE` holder (so `AgentExecutor.execute` cannot record) and no
    `ENFORCER_ROLE` holder (so `freezeAgent` is uncallable). Raise only after private
    notice — see below.

## Do not claim

1. **Do not claim the integration is verified against their live deployment today.** The
   one test that does that, `test_Fork_GatedUSDRamsAgainstLiveRegistry`, **fails** as of
   2026-07-28 with `OwnableUnauthorizedAccount`. It passed on July 8; their ownership
   moved.
2. **Do not claim anything is deployed.** No broadcast artifact exists on the branch and
   `shared/addresses.json` records `GatedUSDRams: null`,
   `VARComplianceProviderAdapter: null`. Nothing of ours is on any chain.
3. **Do not claim a live on-chain interaction with their registry.** No transaction
   exists in which any VAR contract called `canExecute` or `recordExecution`. All
   evidence is local-fork.
4. **Do not repeat "Etherscan-verified, Exact Match."** Unverifiable without an API key;
   Sourcify returns 404 for all three. Say "we could not independently confirm."
5. **Do not repeat "bytecode-identical to the EIP reference."** Not reproducible from
   this repo — the vendored artifacts carry no `deployedBytecode`, and it needs solc
   0.8.30, which is not installed. It may be true; it is not currently checkable.
6. **Do not say "36 RAMS tests"** (`INTEGRATION.md:18`). It is 41, of which 5 skip by
   default.
7. **Do not claim full `IComplianceProvider` conformance.** `grantPrincipal` and
   `revokePrincipal` revert unconditionally, and the adapter **never emits
   `PrincipalRevoked`**, so a spec-recommended freeze relay pointed at it would never
   fire (§3.7).
8. **Do not claim ERC-165 conformance for the token.** `GatedUSDRams` has no
   `supportsInterface`. Only the adapter does.
9. **Do not present finding (c) as a flaw in their implementation.** Their
   `revokeMandate` flags, it does not delete (`AgentMandate.sol:107`). Reframe as spec
   hardening or you will be publicly corrected.
10. **Do not use the phrase "an agent spending a third party's approved balance is
    uncapped"** for finding (d). Under RAMS that spend requires and is capped by an
    `(agent, principal)` mandate. The accurate claim is that there is no *per-agent
    aggregate* across principals.
11. **Do not state the live authority holders from `deployed-vs-spec.md`.** That table is
    stale: both the registry admin and the provider owner are now
    `0x6b017348…849a`, not `0xB610470a…faf1`.
12. **Do not claim the spec authors have not changed their position.** I verified the
    published EIP has not drifted; I did not read the Ethereum Magicians thread.

> ### UPDATE 2026-08-03 — status of the items above after the integration run
>
> | # | Was | Now |
> |---|---|---|
> | 4 | "Etherscan-verified, Exact Match" unverifiable | **Still unverifiable** (no API key). Say "executable code independently reproduced as byte-identical" instead — see §4.3 update. |
> | 5 | "bytecode-identical" not reproducible | **Now reproduced.** Built the reference out-of-tree with solc 0.8.30 (forge fetches it; it does not need a system install) and diffed runtime code. Claim is safe, in the precise form given in §4.3. |
> | 6 | "36 RAMS tests" → should be 41 | **Now 51** (41 before this run, +10 added in the ERC-165 / `PrincipalRevoked` work). Suite total **114, 0 skipped**. Docs corrected. |
> | 7 | adapter never emits `PrincipalRevoked` | **Fixed.** Supersession announces inside `bindIdentity`; mirror-revoke and expiry announce via permissionless `syncRevocation`, carrying the same `ReasonCode` `checkPrincipal` returns. Note honestly that this makes the event *reachable*, not automatic. `grantPrincipal`/`revokePrincipal` still revert — disclose that as a deliberate deviation. |
> | 8 | token has no `supportsInterface` | **Fixed.** `GatedUSDRams` advertises `IERC165`/`IERC20`/`IERC20Metadata`, ids derived from the interface definitions. It deliberately does **not** claim `IERC7943Fungible` (we implement 1 of its 6 functions). |
> | 11 | authority holders stale | **Confirmed correct.** Registry admin, provider owner and executor owner are all `0x6b0173489007dE9E2e619eccd98E8fa9c610849a`. |
>
> **New finding, not in the list above:** Brickken said they "are granting" `RECORDER_ROLE`
> to their executor and `ENFORCER_ROLE` to a separate enforcer. On-chain, both were granted
> **and revoked ~33 blocks later** — `ENFORCER_ROLE` to `0x3d51a03b…74b2` at block 11319144
> (tx `0x2acf6f77…`), revoked at 11319177 (tx `0x11ef2c5a…`); `RECORDER_ROLE` to the
> AgentExecutor at 11319145 (tx `0x18bdcede…`), revoked at 11319178 (tx `0xed3d2759…`).
> Net state today: **nobody holds either role**, so `freezeAgent` is still uncallable by
> anyone and the executor still cannot record. Ask them about this rather than assuming a
> pending grant — and note our security-review finding on the unbounded revocation window
> is therefore fully live, not stale.

## Blocking before publication

Ordered. Items 1–3 are hard blockers.

1. **Privately notify Brickken of the two live-config findings** — no `RECORDER_ROLE`
   (executor cannot record) and no `ENFORCER_ROLE` (freeze uncallable) — before
   mentioning either publicly. Neither is a vulnerability and neither needs an embargo,
   but `security-review-draft.md` is marked "private, not for distribution before the
   Brickken team has seen it" and that instruction is still unhonoured. Send it; it is
   also your best opening with them.
2. ~~**Fix `test_Fork_GatedUSDRamsAgainstLiveRegistry`.**~~ **DONE 2026-08-03.** The
   provider owner is now read at runtime, all 5 fork tests pass against live Sepolia, and
   the suite fails loudly rather than skipping when `ETH_SEPOLIA_RPC_URL` is unset. The
   test additionally asserts the token holds **no `RECORDER_ROLE`** before and after the
   transfer, so the successful `recordExecution` can only be the `msg.sender == m.asset`
   branch — which is the claim Brickken confirmed in writing.
3. **Deploy to Ethereum Sepolia and produce one real transaction.** Run
   `DeployRamsIntegration.s.sol`, grant a mandate, and land a single `transferFrom` in
   which `GatedUSDRams` calls their `canExecute` and `recordExecution`. This converts the
   entire post from "we wrote an integration" to "here is the transaction hash." You said
   that fact is worth more than the rest of the branch; it is also the cheapest item on
   this list. Commit the broadcast artifact and fill the three `null`s in
   `shared/addresses.json`.
4. ~~**Add `supportsInterface` to `GatedUSDRams`**~~ (§3.2). **DONE 2026-08-03.**
5. **Decide the `PrincipalRevoked` question** (§3.7): either emit it from the adapter on
   detected revocation, or document prominently that the adapter is not safe for
   third-party integration under the spec's relay pattern. Do not ship it silently.
6. **Reframe findings (c) and (d)** per §6 before they go in a post. Both are currently
   phrased in ways that will be corrected in public.
7. **Get the Etherscan verification status checked with an API key**, or drop the claim
   (§4.3).
8. **Resolve the license question before contributing anything upstream** (§7.3).
   `ethereum/ERCs` is CC0-1.0; the branch is MIT; PR #10 would make it Apache-2.0, which
   is worse for this purpose. Does not block a forum post — blocks a code contribution.
9. Correct `INTEGRATION.md:18` (36 → 41, note the 5 skips) and the stale authority table
   in `deployed-vs-spec.md:44-50`.

---

## Appendix A — the 41 new tests

`forge test --list --json`, suites matching `rams|demo`:

**`test/demo/CompromisedKey.t.sol::CompromisedKeyDemo` (3)** — `test_ScenarioA_AgentTransactsThroughExecutor`,
`test_ScenarioB_RawTransferFromBypassingExecutorStillLeashed`,
`test_ScenarioC_RevocationWindowClosedAtAsset`

**`test/rams/GatedUSDRams.t.sol::GatedUSDRamsTest` (19)** — `test_ActionNotEnabledReverts`,
`test_AgentTransferWithinCapsSucceeds`, `test_AllowanceStillRequiredAlongsideMandate`,
`test_BothLayersOnAgentInitiatedTransferFromMirrorAgent`, `test_CanTransferByReportsLayer`,
`test_ComplianceRevokedAfterGrantBlocksAtAsset`, `test_CumulativeCapBreachReverts`,
`test_ExpiredMandateReverts`, `test_FrozenAgentReverts`, `test_GrantMandateViaEip712Signature`,
`test_HolderInitiatedTransferSkipsRamsLayer`, `test_MirrorStillGatesMandatedAgentsOwnBalance`,
`test_PerTxCapBreachReverts`, `test_PermissiveModeAllowsMandatelessUnderPlainAllowance`,
`test_PermissiveModeStillEnforcesExistingMandate`, `test_ReasonCodeParity`,
`test_RevokedMandateReverts`, `test_StrictModeBlocksMandatelessAgentTransfer`,
`test_WrongAssetReverts`

**`test/rams/VARComplianceProviderAdapter.t.sol::VARComplianceProviderAdapterTest` (11)** —
`test_BindRejectsNonCurrentAttestation`, `test_ExpiryMapsToKycExpired`,
`test_IdentityRefConvention`, `test_LifecycleWritesRevert`, `test_LiveMandateIsCompliant`,
`test_MirrorRevokeMapsToAttestationRevoked`, `test_MirrorRevokePropagatesThroughRamsMandate`,
`test_SupersededAttestationMapsToRevoked`, `test_SupportsInterface`, `test_UnknownIdentityRef`,
`test_WrongPrincipalForIdentity`

**`test/rams/RamsFork.t.sol::RamsForkTest` (5, skip without `ETH_SEPOLIA_RPC_URL`)** —
`test_Fork_ChainAndDomain`, `test_Fork_Erc165Surfaces`, `test_Fork_ExecutorWiring`,
`test_Fork_GatedUSDRamsAgainstLiveRegistry` **(FAILS with RPC set)**, `test_Fork_ViewSurface`

**`test/rams/RamsFuzz.t.sol::RamsFuzzTest` (3)** — `testFuzz_CapsVsAmounts`,
`testFuzz_NonceMonotonicityOnSignedOps`, `testFuzz_ValidityWindowVsWarp`
