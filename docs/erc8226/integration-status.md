# ERC-8226 (RAMS) integration status

**Run date:** 2026-08-03
**Branch:** `feat/rams-8226-integration`
**Trigger:** Brickken (Thamer) confirmed our findings and answered the `recordExecution`
authorization question that was blocking the end-to-end test.

**Status: phases 1–4 and 6 green. Phase 5 BLOCKED on two missing credentials.**

Every claim below points to a file, line, test name, or transaction hash, with the exact
command used. Zero-result searches were validated against a known-present control term.

---

## Phase 1 — verify their answer against deployed bytecode

**Result: their answer is exactly correct. Their role claim is not.**

### 1.1 The caller check matches the quote, verified three independent ways

Thamer's quoted check:

```solidity
if (msg.sender != m.asset && msg.sender != principal &&
    !hasRole(RECORDER_ROLE, msg.sender)) revert;
```

**(a) Source.** `contracts/lib/rams-reference/contracts/AgentMandate.sol:159` is
character-for-character identical, principal branch included.

**(b) Deployed bytecode.** Rebuilt the vendored reference out-of-tree with the deployed
toolchain (solc 0.8.30, optimizer 200, OZ 5.6.1) and diffed runtime code against
`eth_getCode`:

| Contract | Address | Executable body | Immutables masked | Result |
|---|---|---|---|---|
| AgentMandate | `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e` | 9,977 B | 7 | **identical** |
| ComplianceProvider | `0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278` | 1,727 B | 0 | **identical** |
| AgentExecutor | `0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952` | 2,474 B | 6 | **identical** |

Only the 51-byte CBOR metadata tail differs (source-path IPFS hash, no semantics).

> **Precision note:** `docs/rams/deployed-vs-spec.md:31` says "byte-for-byte". The exact
> claim is *executable-code*-identical with a differing metadata hash. Corrected in the
> review doc.

**(c) Live behavioural branch probes — the decisive evidence.** Against the live
registry with an empty mandate (so `m.asset == address(0)`):

| Probe | `--from` | Returned | Meaning |
|---|---|---|---|
| A | `0x3333…3333` (unrelated) | `0xb199d472` `UnauthorizedRecorder` | check rejects |
| B | the `principal` argument itself | `0x47ee14ea` `NotExecutable` | **principal branch passed** |
| C | `address(0)` (`== m.asset`) | `0x47ee14ea` `NotExecutable` | **asset branch passed** |

B and C get *past* the caller gate and fail at the next check (`_mandateAllows`). That is
live proof both branches exist in deployed code.

```sh
cast call 0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e \
  "recordExecution(address,address,bytes32,uint256)" \
  $AGENT $PRINCIPAL $(cast keccak "transfer") 1 \
  --from <varies> --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

### 1.2 GatedUSDRams passes on the `msg.sender == m.asset` branch — traced

1. `contracts/src/GatedUSDRams.sol:159` calls `rams.recordExecution(...)`, so the
   registry sees `msg.sender ==` the token.
2. Line 159 is reachable only past `GatedUSDRams.sol:146`, which calls
   `rams.canExecute(agent, from, address(this), ACTION_TRANSFER_FROM, value)`.
3. `AgentMandate.sol:182` — `if (asset != m.asset) return false;`
4. Therefore `canExecute == true` ⟹ `m.asset == address(this) == msg.sender` at line 159.
   The first branch short-circuits. **Our token needs no `RECORDER_ROLE`.**

Now asserted in CI: `test_Fork_GatedUSDRamsAgainstLiveRegistry` checks
`hasRole(RECORDER_ROLE, address(gusd)) == false` both before and after the transfer, so a
successful `recordExecution` can *only* be the asset branch.

### 1.3 Role state — they were granted, then revoked

Full `RoleGranted`/`RoleRevoked` sweep from deployment block 11215020 to head, in
9,900-block chunks (drpc caps free-tier ranges at 10,000):

| Block | Transaction | Event |
|---|---|---|
| 11215028 | `0xd42639e58c1c6782ba44e286aae1fcbd43fb297de842091d0505880b9b840abb` | `DEFAULT_ADMIN_ROLE` → deployer `0xB610470a…fAf1` <!-- pragma: allowlist secret -->|
| 11319144 | `0x2acf6f7797e42e3ac9e5a4bceebc191da3b446e6e860039a66cc48eeecccb489` | `ENFORCER_ROLE` → `0x3d51a03b519dba67768f6168296462d57b3074b2` <!-- pragma: allowlist secret -->|
| 11319145 | `0x18bdcede89f3e4a11172c1d53cae0c926a9e3fd1f371acb0c3062b32b6a55893` | `RECORDER_ROLE` → AgentExecutor `0xc81949Cf…9952` <!-- pragma: allowlist secret -->|
| **11319177** | `0x11ef2c5aa68745b3b0753a65a915fa794b5f5a702392316265da15afdde101a7` | **`ENFORCER_ROLE` REVOKED** <!-- pragma: allowlist secret -->|
| **11319178** | `0xed3d2759ddbe410456970da0a46cdb5f995f9de0e5bc8c10cbf6be2d35619604` | **`RECORDER_ROLE` REVOKED** <!-- pragma: allowlist secret -->|
| 11334076 | `0xb3450aa118aa2f5f176e0c185245731087edb4bde3c7c2c4de1ec91f099b9851` | `DEFAULT_ADMIN_ROLE` → `0x6b0173489007de9e2e619eccd98e8fa9c610849a` <!-- pragma: allowlist secret -->|
| 11334077 | `0xd3fb82035e41d4a191b6576cf78a0d61f07abc0a2dde37d854b0deccedbc1ba5` | old admin's `DEFAULT_ADMIN_ROLE` revoked <!-- pragma: allowlist secret -->|

Net state at block 11410673, cross-checked on **two independent RPCs** (drpc + publicnode):

```
hasRole(RECORDER_ROLE, AgentExecutor)        = false
hasRole(ENFORCER_ROLE, 0x3d51a03b…74b2)      = false
hasRole(DEFAULT_ADMIN_ROLE, 0x6b017348…849a) = true
hasRole(DEFAULT_ADMIN_ROLE, 0xB610470a…fAf1) = false
```

**Both roles were granted and rolled back ~33 blocks (≈7 min) later.** This reads as a
rehearsal that was reverted, not a pending grant. Consequences:

- `freezeAgent` is **still uncallable by anyone** — the enforcer lever is unwired, so our
  security-review finding on the unbounded revocation window is fully live.
- Their standalone `AgentExecutor` **still cannot record executions**.
- Neither affects us: our token uses the asset branch.

**Ask Thamer about this directly rather than assuming a pending grant.**

---

## Phase 2 — fork tests fixed, silent skips eliminated

### 2.1 The rot was real, proven before fixing

```sh
cast call 0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278 \
  "grantPrincipal(address,bytes32,uint48)" 0x1111…1111 $(cast keccak "x") 4102444800 \
  --from 0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1 --rpc-url <sepolia>
# → reverted 0x118cdaa7 = OwnableUnauthorizedAccount(0xb610470a…)

# same call from the current owner 0x6b0173489007dE9E2e619eccd98E8fa9c610849a → 0x
```

The hardcoded prank at the old `RamsFork.t.sol:106` was dead.

### 2.2 Fixes (`contracts/test/rams/RamsFork.t.sol`)

- Provider owner read at runtime via a local `IOwnable`, asserted non-zero before
  impersonation, and logged. Live run printed
  `impersonating live ComplianceProvider owner: 0x6b0173489007dE9E2e619eccd98E8fa9c610849a`.
- `LIVE_ADMIN` → `LIVE_DEPLOYER`: it is the executor's **immutable** `principal()`, a
  deploy-time fact, not authority. `test_Fork_ExecutorWiring` now also reads both live
  owners at runtime.
- Added the roleless-`recordExecution` assertion described in §1.2.

### 2.3 Loud failure replaces `vm.skip`

`setUp` now reverts, naming all five claims that would go unproven, the fix, and the
deliberate opt-out. There is **no env escape hatch** — an opt-out flag would recreate the
silent-green path. The visible opt-out is `forge test --no-match-contract RamsForkTest`.

Verified: with the variable unset, `forge test --match-contract RamsForkTest` → `EXIT=1`,
`Suite result: FAILED`.

`grep -rn 'vm.skip\|envOr' test/ src/ script/` (control `vm.prank`: 87 hits) confirms no
other silent skip remains; surviving `envOr` calls are deploy-script config defaults.

### 2.4 Results

All five fork tests pass against live Sepolia:

| Test | Result |
|---|---|
| `test_Fork_ChainAndDomain` | PASS (gas 3,748) |
| `test_Fork_Erc165Surfaces` | PASS (gas 7,060) |
| `test_Fork_ExecutorWiring` | PASS (gas 17,134) |
| `test_Fork_GatedUSDRamsAgainstLiveRegistry` | PASS (gas 3,508,400) |
| `test_Fork_ViewSurface` | PASS (gas 50,559) |

**Before this phase:** `forge test` without the RPC → `99 passed, 5 skipped`, **exit 0**.
**After:** see Phase 3 for final counts; skipping is impossible without an explicit flag.

---

## Phase 3 — our own interop gaps closed

**Premise correction:** the adapter already had `supportsInterface`
(`VARComplianceProviderAdapter.sol:123`). Only `GatedUSDRams` lacked one. I verified the
adapter's ids rather than adding them.

### 3.1 Interface ids — derived from the spec, not guessed

| Interface | Id | Derivation |
|---|---|---|
| `IComplianceProvider` | `0xfa2a39b3` | `grantPrincipal(address,bytes32,uint48)` ^ `revokePrincipal(address,uint8)` ^ `checkPrincipal(address,bytes32)` |
| `IERC165` | `0x01ffc9a7` | `supportsInterface(bytes4)` |
| `IERC20` | `0x36372b07` | 6-selector XOR |
| `IERC20Metadata` | `0xa219a025` | `name` ^ `symbol` ^ `decimals` |

Cross-checked against the **live deployed** provider:
`supportsInterface(0xfa2a39b3) → true`, `(0x01ffc9a7) → true`, `(0xdeadbeef) → false`,
`(0xffffffff) → false`. Tests assert against re-derived XORs so a wrong literal cannot
pass by agreeing with itself.

`GatedUSDRams.supportsInterface` **deliberately does not claim `IERC7943Fungible`**:
`GatedUSD` implements 1 of its 6 functions (`canTransfer` only). A test asserts we return
`false` for it. Related: `GatedUSD.sol:12` ("Exposes the ERC-7943 canTransfer surface
(Final)") overstates and should be softened.

### 3.2 `PrincipalRevoked` now reachable on every ineligibility path

VAR's ineligibility transitions happen in `DelegationMirror`, not the adapter, so no
adapter call site observes them synchronously.

- **Supersession** — inside `bindIdentity`, announces automatically.
- **Mirror revoke / expiry** — via permissionless, latched `syncRevocation(bytes32)`.

`checkPrincipal` and the announcement now share one `_evaluate`, so the emitted
`ReasonCode` cannot drift from the read. Documented plainly that this makes the event
**reachable, not automatic**: a push-based relay must watch the mirror's own
`Revoked`/`Delegated` events or poke us.

### 3.3 Bug found and fixed during the re-audit

`DelegationMirror.revoke()` (`src/DelegationMirror.sol:190`) sets `revoked = true` but
**leaves `nonce` unchanged**. `bindIdentity` only tested `m.nonce == a.nonce &&
m.principal == a.principal`, so **a revoked mandate could be re-bound by anyone** —
re-emitting `PrincipalGranted` for an ineligible principal and clearing the
`revocationAnnounced` latch so `PrincipalRevoked` could fire twice for the same ref.
Exactly the confusion a freeze relay must not be fed.

Fixed with an explicit liveness check (`MandateNotLive`) plus two regression tests:
`test_BindRejectsRevokedMandate_LatchCannotBeReset`, `test_BindRejectsExpiredMandate`.

### 3.4 MUST-clause re-audit

Clean on: ERC-165 (line 42) · structured `checkPrincipal` verdict (line 59) ·
`COMPLIANT` only when eligible (line 105) · real `expiresAt` (line 106) ·
agent-initiated transfers satisfy the mandate (line 423) · allowance still required
(line 425, tested) · `metadata` never read for enforcement (line 535, verified).

`ramsDiagnose` matches the spec's normative `canExecute` order. The **deployed**
reference checks asset before existence, unlike its own spec — same bool either way, so
it is only a reason-code question. Stale code comment corrected.

**To disclose, not fix:** our `grantPrincipal`/`revokePrincipal` revert
`LifecycleManagedByMirror`. Defensible, but a real deviation from "the compliance
provider manages granting and revoking." State it in the review.

---

## Phase 4 — the World ID path

### 4.1 Where the personhood check happens in `checkPrincipal`: **nowhere**

Neither on-chain against AgentBook, nor via an off-chain API call. `checkPrincipal`
performs **no personhood check at all**. It is a Solidity `view` — it cannot call an API —
and it does not read AgentBook.

`_evaluate` (`VARComplianceProviderAdapter.sol:184-196`) reads exactly four mirror
fields: `principal`, `nonce`, `revoked`, `expiry`. It **never reads `proofRef` or
`kycRef`** — the only fields carrying personhood evidence.

Verified: `grep -n 'proofRef\|kycRef'` on the adapter returns two hits, both
non-evaluative (line 79, the `identityRef` hash preimage; line 222, the typehash string).
Control `identityRef`: 39 hits. **`proofRef` is committed to but never checked.**

The check happens once, earlier, off-chain:

```
web/app/api/var/grant/route.ts:88   AgentBook.lookupHuman(agent) on World Chain (480)
        ↓  proofRef = keccak256(bytes32(humanId))       [TypeScript]
        ↓  attestor signs EIP-712                        [route.ts:127]
DelegationMirror.submitAttestation   stores proofRef UNVERIFIED
        ↓  checks only registeredAttestor[ecrecover(...)]  (DelegationMirror.sol:157-158)
VARComplianceProviderAdapter.checkPrincipal   never reads it
```

### 4.2 §8.1 is live and load-bearing — stated without softening

Re-verified against code, not taken from the prior write-up:

- `web/lib/sameOrigin.ts:11` — `if (!origin) return null;` **allows every non-browser
  caller**, including `curl`. The file's own comment: *"This is NOT a substitute for real
  authentication."*
- `grant/route.ts:70-74` — `principal` taken verbatim from the request body. Since
  `revoke` is principal-only, whoever names the principal owns the kill switch.
- `:75-76` — `spendCap`, `expiryMinutes` caller-supplied and unbounded.
- `:88` — `lookupHuman` proves **the agent is human-backed. It does not authenticate the
  requester as that human, or as any human.**

`branch-review.md:243` was headed *"Identity resolution — on-chain, and §8.1 is NOT
reintroduced"*. Every clause was literally true and the section did concede a caveat, but
the heading read as an all-clear. **Rewritten** — the finding stays live, and the section
now leads with the fact that `checkPrincipal` performs no personhood check.

### 4.3 What an on-chain version would require

AgentBook is on World Chain (480); a `complianceProvider` must be synchronously callable
by the registry, so it must live on the registry's chain. That rules out "just read
AgentBook."

1. **Verify World ID on the RAMS chain** (cleanest; what "on-chain personhood" means).
   World ID router + Groth16 verifier on Sepolia, principal submits the semaphore proof
   with `signal = principal` at grant time, nullifier stored and uniqueness enforced. No
   bridge, no attestor. Cost: real verifier deployment; the agent-registration model
   changes because the principal must hold the credential.
2. **Prove World Chain state on the RAMS chain.** World Chain is OP Stack; output roots
   post to L1, so a storage proof of `lookupHuman(agent)` can be verified against a
   posted root. Faithful to current architecture but heavy — needs the finalization
   window (or an optimistic/ZK path) and proof plumbing per check.
3. **Harden, don't fix.** Threshold/multisig attestor set, AgentBook read published as a
   verifiable signed statement. Reduces single-key blast radius; **does not make
   personhood on-chain** and must not be described as if it does.

### 4.4 Sources of the `(bool, ReasonCode, uint48)` return

| Element | Source | Verdict |
|---|---|---|
| `eligible` | binding exists, `m.principal == principal`, `m.nonce == b.nonce`, `!m.revoked`, `now < m.expiry` | Real on-chain state — **no personhood input** |
| `reason` | which check failed | Real, but only **4 of the spec's 9 codes** reachable: `COMPLIANT`, `KYC_EXPIRED`, `ATTESTATION_REVOKED`, `IDENTITY_NOT_FOUND`. `AML_FLAG`, `NOT_ACCREDITED`, `NOT_QUALIFIED`, `JURISDICTION_BLOCKED`, `OTHER` can never be returned. Disclose. |
| `expiresAt` | `DelegationMirror.Mandate.expiry`, set from the signed attestation (`DelegationMirror.sol:172`) | **REAL** — not hardcoded, not zero, not a placeholder |

`expiresAt` is genuinely **enforced** — by `DelegationMirror.checkTransfer:219` and by
`_evaluate:195` → `KYC_EXPIRED`, which `GatedUSDRams` turns into a revert on the
execution path. Saturated via `_toUint48`, not truncated.

Two caveats, disclosable rather than fatal:
- It returns `0` on the `IDENTITY_NOT_FOUND` and `ATTESTATION_REVOKED` branches,
  colliding with the spec's "0 = no expiry" convention. **The reference implementation
  does exactly the same thing** (`ComplianceProvider.sol:52-54`) — raise as a shared
  observation, never as a criticism of their code.
- Its *value* is attestor-chosen and unbounded (§8.1), so it is a real enforced number
  whose magnitude is only as trustworthy as the grant route.

---

## Phase 5 — BLOCKED. Not attempted.

Two independent hard blockers. Per instruction, stopped rather than worked around.

### 5.1 No `ETHERSCAN_API_KEY`

Absent from the shell environment and from every `.env` in the repo (`contracts/.env`,
`web/.env.local`, `agent/.env` — variable names inspected, never values). Sourcify is not
an alternative: v2 returns `{"match":null}` for all three addresses and v1 is in a
scheduled brownout until 2027-01-08.

Deploying unverified was explicitly ruled out.

### 5.2 The deployer has zero Sepolia ETH — independently fatal

```
deployer (DEPLOYER_PRIVATE_KEY): 0x54E7B896Fe9a5f6A55551Bb4D15A4f1175891dec
balance: 0.000000000000000000 ETH    nonce: 0
(confirmed on publicnode AND drpc)
```

`nonce: 0` means this key has **never transacted on Sepolia**.
`script/DeployRamsIntegration.s.sol:44` broadcasts with exactly this key, so neither the
deploy nor any part of the end-to-end flow can begin.

Note this is also the address flagged in `repo-brief.md` §8.2/§8.3 as the mirror owner
and headline principal. Consider a **separate** key for Sepolia rather than extending
that key's blast radius to a third chain.

### 5.3 What is needed

1. `ETHERSCAN_API_KEY` — free tier; one key covers Sepolia via the V2 API.
2. **Sepolia ETH** for the deployer, ≈0.05 ETH for both deploys plus the full e2e flow
   with margin. Either fund `0x54E7B896…1dec` or supply a different key.
3. `ETH_SEPOLIA_RPC_URL` — optional but advisable for broadcasting; it is also the
   variable the fork tests now require.

### 5.4 Transaction hashes captured

**None from this phase.** `shared/addresses.json` still has `GatedUSDRams: null`,
`VARComplianceProviderAdapter: null`, `DelegationMirror: null` under `eth-sepolia`.
No `cumulativeUsed` readback exists. No blocked-case demonstration exists.

The only transaction hashes in this document are **Brickken's own role
grants/revokes** (§1.3), read from their registry's event log.

---

## Phase 6 — doc corrections

| Correction | Status | Evidence |
|---|---|---|
| `deployBlock` 46942608 → **46942616** (×4) | Done | Broadcast receipts `broadcast/Deploy.s.sol/5042002/run-latest.json` **and** live Arc `cast receipt` → `blockNumber 46942616`, `status 1` |
| Test count "36" → **51** RAMS tests | Done | `docs/rams/INTEGRATION.md:14`. 41 was correct before this run; +10 added in Phase 3 |
| "54"/"63"/"99"/"104" count drift | Done | `README.md:11,38,138-139`, `RUN.md:27,30` → **114 total / 109 local-only**, both re-run and confirmed |
| "Proven live on Arc" table | Rewritten | Replaced with live, reproducible reads; removal rationale kept inline |
| Distribution banner | Updated | `docs/rams/security-review-draft.md` — records Brickken's 2026-08-03 request, notes the embargo is **not** lifted for anyone else |
| Granting-API finding | **Left LIVE** | Re-verified unfixed; `branch-review.md` §3.4 rewritten |

Verification: `grep -rnE '\b(36|54|99|104)\b'` filtered to test contexts across
`README.md`, `RUN.md`, `INTEGRATION.md` returns **empty**; the control grep for
`114|109|51` returns the expected 7 hits.

### On the "Proven live on Arc" table

Removed rather than patched. Its five demo transaction hashes were recorded truncated to
8 hex characters, appear nowhere else in the repo, and cannot be verified; two of its
five rows were `checkTransfer` *view* results, not transactions; and its stated
parameters do not match live state. Confirmed live on Arc today:

```
mandate for agent 0x69e170Dd3B22f7C68cDDc31fb402b20f50eDcC54:
  principal 0x18e5B7AF…2110, cap 10 gUSD/tx, period cap 100 gUSD / 86400s, nonce 5
  expiry 1784645185 = 2026-07-21 14:46 UTC
checkTransfer(...) → (false, "EXPIRED")     # now = 1785765158
```

The table claimed "period cap 15, 1h window"; live state is **100 gUSD / 24h**. The
enforcement behaviour it described is real and covered by tests — but the table was not
evidence for it.

---

## Final test counts

```
cd contracts && ETH_SEPOLIA_RPC_URL=<sepolia rpc> forge test
→ 13 test suites: 114 tests passed, 0 failed, 0 skipped (114 total)

cd contracts && forge test --no-match-contract RamsForkTest
→ 12 test suites: 109 tests passed, 0 failed, 0 skipped (109 total)

cd contracts && forge test          # no RPC set
→ EXIT=1, Suite result: FAILED — names the 5 claims that would go unproven
```

Breakdown: 63 pre-existing VAR tests + 51 RAMS integration tests
(`GatedUSDRams` 21, `VARComplianceProviderAdapter` 19, `RamsFork` 5, `RamsFuzz` 3,
`CompromisedKey` 3).

---

## What you can now claim publicly that you could not before

**Newly claimable, each backed by evidence in this document:**

1. **Brickken's `recordExecution` authorization model is confirmed against deployed
   bytecode, not just their word.** Three independent methods, including live probes that
   distinguish the asset branch from the principal branch from the reject path by revert
   selector (§1.1).

2. **A RAMS-aware token needs no `RECORDER_ROLE`, and we have proven it against their
   live registry** — not merely reasoned it. The fork test asserts the token holds no role
   at the moment `recordExecution` succeeds (§1.2, §2.2).

3. **The deployed contracts' executable code is byte-identical to the EIP reference
   implementation, independently reproduced from source.** Say it in that precise form.
   Do **not** say "Etherscan-verified Exact Match" — still unconfirmable (§1.1, §5.1).

4. **Our integration test suite proves what it claims to prove.** The suite can no longer
   report green while skipping the tests that carry the central claim; without an RPC it
   fails and names the unproven claims (§2.3).

5. **`GatedUSDRams` is ERC-165 conformant**, with ids derived from the spec's interface
   definitions and cross-checked against live deployed code — and honestly scoped, since
   it declines to claim a surface it only partly implements (§3.1).

6. **Our compliance provider emits `PrincipalRevoked`**, so a spec-recommended freeze
   relay pointed at it can fire. State the caveat: reachable, not automatic (§3.2).

7. **`expiresAt` is real and enforced**, not hardcoded or zero (§4.4).

8. **The live Arc deployment's current state**, with reproducible commands — including
   that the demo mandate is expired and the gate correctly says so (§6).

**Newly claimable about their deployment — send privately first:**

9. **`RECORDER_ROLE` and `ENFORCER_ROLE` were granted and revoked ~33 blocks later; nobody
   holds either today**, with all seven transaction hashes (§1.3). `freezeAgent` remains
   uncallable by anyone. Raise with Thamer before any public mention.

**Still NOT claimable — do not say these:**

- ❌ **Anything involving a live transaction of ours on Sepolia.** Nothing is deployed;
  no `cumulativeUsed` readback exists; no blocked-case demonstration exists. Every
  interaction of ours remains fork-local (§5).
- ❌ **"Etherscan-verified" / "Exact Match"** for their contracts (§5.1).
- ❌ **That our compliance provider performs a personhood check.** It does not — at all
  (§4.1).
- ❌ **That the granting-API weakness (§8.1) is fixed or being fixed.** It is live and
  unfixed, and it is load-bearing for the adapter's verdict (§4.2).
- ❌ **The old "Proven live on Arc" table** (§6).
- ❌ **Full `IComplianceProvider` lifecycle conformance** — `grantPrincipal` and
  `revokePrincipal` revert by design (§3.4).
