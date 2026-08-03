# VAR repo brief for ERC-8226 discussion

> ## ⛔ SUPERSEDED IN PART — DO NOT PUBLISH AS-IS
>
> **§4 ("ERC-8226 integration status") is false.** It claims no ERC-8226 work exists.
> It does: branch `origin/feat/rams-8226-integration` (`da8f661`, 2026-07-08), 51 files,
> +9,346 lines, open as **GitHub PR #11**. This brief was written against a clone that
> had not been fetched since 2026-06-14, three weeks before that branch was pushed, and
> it grepped only the working tree rather than all refs.
>
> Also affected: **§11 "Safe public claims" item 11** (repeats the same false claim);
> **§7** (the ReasonCode mapping was reasoned from first principles and is superseded by
> the real mapping in `contracts/src/rams/VARComplianceProviderAdapter.sol` on that
> branch); **§8/§6.2 path 3** (the ungated third-party-balance gap is addressed by
> `GatedUSDRams`).
>
> Sections 1–3, 5, 6 (except as noted) and 9 were verified independently against the
> live chain and a fresh test run and are unaffected.
>
> **See `docs/erc8226/rams-search.md` for the full evidence and recovery commands.**

**Purpose.** A factual account of what exists in this repository, for use in a public
Ethereum Magicians comment. No projections, no roadmap language. Every claim below
points at a file, a test name, a commit, a transaction, or a deployed address.

**Snapshot.** Branch `develop`, commit `f7bd69a`, working tree has 2 uncommitted
cosmetic edits (see §9.9). Test run and on-chain reads performed 2026-07-28.

**Scope limit.** This brief does not verify anything about the text of ERC-8226. The
`ReasonCode` enum members in §7 are taken as given from the request; the mapping
commentary describes *our* semantics, not a reading of the spec. Anyone using §7
should check our side against the spec's actual definitions.

---

## 1. What is actually deployed

### 1.1 Arc testnet (chainId 5042002) — confirmed

Four contracts, deployed by `contracts/script/Deploy.s.sol` in a single run.
Provenance: `contracts/broadcast/Deploy.s.sol/5042002/run-latest.json`
(= `run-1781390863203.json`), all four receipts `status 0x1`, block **46942616**.

| Contract | Address | Source | Broadcast artifact | Live bytecode |
|---|---|---|---|---|
| DelegationMirror | `0xAb47D44cb44d5F5b56E6AB976425cE7c861Cd100` | `contracts/src/DelegationMirror.sol` | yes | present |
| GatedUSD | `0x88b5421Ed0e784A21aBfF121B1a77bd76E9115c3` | `contracts/src/GatedUSD.sol` | yes | present |
| MockYieldVault | `0x746D4A3c3629DAF333c61b8d48B3ea30bC026f0F` | `contracts/src/MockYieldVault.sol` | yes | present |
| ServiceSink | `0x0B7EfBaeD5f01E54442c26520A728F859EA6a2bd` | `contracts/src/ServiceSink.sol` | yes | present |

"Live bytecode present" = `cast code <addr> --rpc-url https://rpc.testnet.arc.network`
returns non-empty, run 2026-07-28. `cast chain-id` on that RPC returns `5042002`.

Live state read from the mirror on 2026-07-28:

- `owner()` → `0x54E7B896Fe9a5f6A55551Bb4D15A4f1175891dec` (the deployer)
- `registeredAttestor(0x6331Afcd688b49019069DC7FD42D4FF10502779B)` → `true`
- `GatedUSD.mirror()` → `0xAb47D44c…Cd100` (wiring confirmed on-chain)
- `GatedUSD.symbol()/decimals()` → `gUSD` / `6`

Attestor registration transaction: `0xf3e8f98c85903645e27d5e29a9cffe44f408807cae71f94e4d7a1fa2df49e152`, <!-- pragma: allowlist secret -->
from `contracts/broadcast/SetAttestor.s.sol/5042002/run-latest.json`.

### 1.2 Superseded Arc deployments (still in the repo's broadcast history)

Two earlier full deploys exist as artifacts and are **not** the live set. Anyone
citing an address should check it against `shared/addresses.json`.

| Run | DelegationMirror | Block |
|---|---|---|
| `run-1781300213789.json` | `0x5b81dd7718f4c2eaed4626f39ee025940fbd1708` | 46786189 |
| `run-1781361068786.json` | `0xbe84ea9fd5bc15998bb4df266bc99aa3b19c1531` | 46890838 |
| `run-1781390863203.json` (live) | `0xab47d44cb44d5f5b56e6ab976425ce7c861cd100` | 46942616 |

`0xbe84ea…1531` also received a `setAttestor` call
(`0x362fc8fee651bdd4b4cb0572f3d89afc05b0faae8644006166834cc73b687512`). It is a <!-- pragma: allowlist secret -->
dead deployment; the README's "known-good pre-enforcement deployment … at the
`proven-live-v1` git tag" refers to this generation.

### 1.3 Recorded deployBlock is wrong by 8 blocks

`shared/addresses.json` records `deployBlock: 46942608` for all four contracts. The
actual receipts in `run-latest.json` are all block **46942616**. Cause:
`Deploy.s.sol:21-27` captures `block.number` during simulation, not from the mined
receipt. Minor, but anyone using `deployBlock` as a log-scan floor is starting 8
blocks early (harmless direction) — and the number as published is not the mined
block.

### 1.4 Explorer source verification — NOT established

There is **no evidence in this repo that any contract source is verified on any
explorer**, and the repo contains nothing that would have verified it:

- `contracts/foundry.toml` has no `[etherscan]` block and no verifier config.
- No `--verify` flag appears in `README.md`, `RUN.md`, or either script in
  `contracts/script/`.
- No broadcast artifact contains verification metadata.

Treat verification status as **unconfirmed**. It must be checked by hand on the Arc
explorer before being claimed either way.

### 1.5 Off-chain and third-party addresses (not deployed by this repo)

| Thing | Address / host | Status |
|---|---|---|
| AgentBook (World Chain, chainId 480) | `0xA23aB2712eA7BBa896930544C7d6636a96b944dA` | **Third-party contract**, not ours. Hardcoded at `agent/src/attestation/proofRef.ts:19`, `agent/src/scripts/proveLookupHuman.ts:45`, `web/app/api/var/grant/route.ts:35`. No broadcast artifact here; we only read `lookupHuman`. |
| Demo agent | `0x69e170Dd3B22f7C68cDDc31fb402b20f50eDcC54` | An externally-owned / MPC wallet, **not a contract**. `agent/src/scripts/proveHappyPath.ts:41`. |
| Attestor key | `0x6331Afcd688b49019069DC7FD42D4FF10502779B` | EOA. Registered on the live mirror (confirmed above). |
| Deployer / mirror owner | `0x54E7B896Fe9a5f6A55551Bb4D15A4f1175891dec` | EOA. Also used as `PRINCIPAL` in `agent/src/scripts/proveHappyPath.ts:42`. See §9.3. |
| Web dashboard | `var-dashboard.fly.dev` | Next.js app, `fly.toml`, commit `f7bd69a`. Deployment state not verified in this brief. |

### 1.6 Live mandate state, as of 2026-07-28

`getMandate(0x69e1…cC54)` on the live mirror returns:

```
principal          0x18e5B7AF636cb76B24Ba0F139306DE38BF2C2110
proofRef           0x594f7934f74a36ba3d98a2cfe25f79921d75bd08d9f621035b29007b02f46b79 <!-- pragma: allowlist secret -->
kycRef             0x0000…0000          <- zero; never populated (see §9.5)
spendCapPerTx      10000000             (10 gUSD)
spendCapPerPeriod  100000000            (100 gUSD)
periodLength       86400                (1 day)
allowedToken       0x88b5421Ed…115c3    (GatedUSD)
expiry             1784645185           = 2026-07-21T14:46:25Z
revoked            false
spentThisPeriod    5000000              (5 gUSD)
periodStart        1784641653           = 2026-07-21T13:47:33Z
nonce              5
```

`lastNonce(agent)` = 5. **The live mandate is expired.** A live call to
`checkTransfer(agent, gUSD, 1)` returns `(false, EXPIRED)` and
`GatedUSD.canTransfer(agent, …, 1)` returns `false`. The demo is not currently in a
state where an agent can spend. That is the gate working as designed, but it means
"live and spending right now" is not a true statement today.

---

## 2. Enforcement path, precisely

The gate is consulted from a single override: `GatedUSD._update`. Every ERC-20 path
(`transfer`, `transferFrom`, mint, burn) funnels through it, because OZ v5 routes
all balance changes through `_update`.

### 2.1 Full call trace (agent pays a service)

```
agent EOA
 └─> ServiceSink.pay(amount)                          contracts/src/ServiceSink.sol:20
      └─> GatedUSD.transferFrom(agent, sink, amount)   ServiceSink.sol:21  (msg.sender = agent, so from = agent)
           └─> ERC20.transferFrom -> _spendAllowance -> _transfer   (OZ v5)
                └─> GatedUSD._update(from, to, value)  contracts/src/GatedUSD.sol:30
                     ├─ (1) gate predicate             GatedUSD.sol:31
                     │      from != address(0) && mirror.isRegistered(from)
                     │      └─> DelegationMirror.isRegistered              DelegationMirror.sol:197
                     │           SLOAD mandates[from].principal
                     ├─ (2) if gated: authorization    GatedUSD.sol:33
                     │      └─> DelegationMirror.checkTransfer(from, address(this), value)
                     │                                                     DelegationMirror.sol:205
                     ├─ (3) if !ok: revert TransferBlocked(reason)         GatedUSD.sol:34
                     │      custom error declared at                       GatedUSD.sol:15
                     ├─ (4) super._update -> balances move                 GatedUSD.sol:36
                     └─ (5) if gated: DelegationMirror.recordSpend(from, value)
                                                        GatedUSD.sol:38 -> DelegationMirror.sol:236
```

### 2.2 `checkTransfer` — storage reads, in evaluation order

`DelegationMirror.sol:205-225`. `Mandate storage m = mandates[from]` (line 210), then:

| # | Line | Storage read | Returns on failure |
|---|---|---|---|
| 1 | 211 | `m.principal` | `(false, NO_MANDATE)` |
| 2 | 212 | `m.revoked` | `(false, REVOKED)` |
| 3 | 213 | `m.expiry` (vs `block.timestamp`, `>=` is expired) | `(false, EXPIRED)` |
| 4 | 214 | `m.spendCapPerTx` | `(false, OVER_CAP)` |
| 5 | 215 | `m.allowedToken` | `(false, TOKEN_NOT_ALLOWED)` |
| 6 | 220-223 | `m.spendCapPerPeriod`, `m.periodLength`, then via `_periodRolled` (252-254) `m.periodStart`; and `m.spentThisPeriod` | `(false, OVER_PERIOD_CAP)` |
| — | 224 | — | `(true, OK)` |

Order is load-bearing and is locked by tests: `test_checkTransfer_orderOverCapBeforeToken`
(`contracts/test/DelegationMirror.t.sol:154`) pins OVER_CAP ahead of TOKEN_NOT_ALLOWED;
`test_overPerTx_underPeriod_returnsOverCap` (`contracts/test/PeriodCap.t.sol:57`) pins
OVER_CAP ahead of OVER_PERIOD_CAP.

Step 6 rolls the window inside the **view**: if `periodStart == 0` or the window has
elapsed, effective spend is treated as 0 (`DelegationMirror.sol:221`), so the view
never reports stale period state ahead of `recordSpend`.

### 2.3 The revert

The revert is the custom error `GatedUSD.TransferBlocked(bytes32 reason)`, raised
inside `_update`, so the entire transaction reverts — including the outer
`ServiceSink.pay`. Note `ServiceSink.sol:21` checks `transferFrom`'s boolean return
and would raise `PaymentFailed()`; **that path is unreachable for a gate block**,
because the gate reverts rather than returning `false`.

TypeScript decoding of the reason is in `shared/src/reasonCodes.ts:25`
(`decodeTransferBlocked`).

### 2.4 Two deliberate asymmetries a spec author should know

1. **A sender with no mandate is ungated, not blocked.** `GatedUSD.sol:31` only gates
   when `mirror.isRegistered(from)` is true. `checkTransfer` would say
   `(false, NO_MANDATE)` for such a sender, but the token never asks. Tested:
   `test_noMandate_transfersFreely` (`contracts/test/GatedUSD.t.sol:92`) asserts a
   non-agent moves 500 gUSD freely *while* `checkTransfer` returns `NO_MANDATE`.
   So `NO_MANDATE` is a registry-level code that can never be the reason for a token
   revert. This is a deny-list model, not an allow-list model.
2. **`canTransfer` and `checkTransfer` disagree on unregistered senders by design.**
   `GatedUSD.canTransfer` (`GatedUSD.sol:43-49`) returns `true` for a sender with no
   mandate; `checkTransfer` returns `false`. Agreement for all *gated* cases is
   asserted by `test_canTransfer_agreesWithCheckTransfer` (`GatedUSD.t.sol:131`).

---

## 3. Test suite state

Fresh run, `forge clean && forge test`, foundry 1.5.1-stable, 2026-07-28:

```
Ran 8 test suites: 63 tests passed, 0 failed, 0 skipped (63 total tests)
```

**Exit code 0. 63 passed, 0 failed, 0 skipped.**

No test is skipped, `vm.skip` appears nowhere, and there are no commented-out test
functions (grep for `vm.skip`, `// function test`, `.skip(` across `contracts/test/`
and `contracts/src/` returns nothing).

Per-file counts: AttestationSecurity 12, DelegationMirror 16, DelegationMirrorFuzz 5,
DelegationMirrorInvariant 4, Eip712Coordination 4, GatedUSD 12, MockYieldVault 4,
PeriodCap 6.

> **Documentation is stale.** `README.md:13`, `README.md:108` and `RUN.md` all say
> "54 passing". The real number is 63. Do not quote 54.

### 3.1 Invariant tests

Config: `contracts/foundry.toml` — `runs = 256`, `depth = 50`, `fail_on_revert = false`.
Handler: `MirrorHandler` (`contracts/test/DelegationMirrorInvariant.t.sol:12`), which
drives 3 agents with a registered attestor key, an unregistered attacker key, and a
principal revoke. Each invariant ran 256 runs × 12800 calls.

| Invariant | Line | What it actually asserts |
|---|---|---|
| `invariant_onlyAttestorEverWritesMandate` | :112 | For each of 3 agents, if `isRegistered(agent)` then the ghost `attestedByAttestor[agent]` is true — i.e. no mandate exists that was not written by the registered attestor, under any call ordering. This is the squatting property. |
| `invariant_mandateNonceEqualsLastNonce` | :122 | `getMandate(agent).nonce == lastNonce(agent)` for all 3 agents — the stored mandate never desyncs from the nonce ledger. |
| `invariant_revokedStaysBlocked` | :130 | If `getMandate(agent).revoked`, then `checkTransfer(agent, token, 1)` returns `ok == false`. Note it asserts only `!ok`, **not** that the reason is `REVOKED`. |
| `invariant_perTxCapNeverExceeded` | :141 | `checkTransfer(agent, token, spendCapPerTx + 1)` is always `!ok`, for every agent. Note this passes trivially for an agent with no mandate (NO_MANDATE is also `!ok`). |

Handler caveat: `attackerWrite` (:75) wraps the call in `try/catch` and swallows the
revert, so a successful attacker write would not fail *that* call — it is caught by
the ghost check in `invariant_onlyAttestorEverWritesMandate`. That is deliberate and
documented in-file, but it means the attacker path's failure is proven indirectly.

### 3.2 Fuzz tests

Config: `runs = 10000` per property.

| Fuzz test | File:line | What it actually asserts |
|---|---|---|
| `testFuzz_capBoundary(uint96,uint256)` | `DelegationMirrorFuzz.t.sol:26` | `ok == (amount <= spendCapPerTx)` exactly, over the full `uint256` amount range; and when over, reason is `OVER_CAP`. |
| `testFuzz_nonAttestorCannotWrite(uint256)` | `:38` | For any key in `[1, 2^128)` that isn't the attestor: `submitAttestation` reverts `InvalidAttestor(badSigner)`, `lastNonce` stays 0, and no mandate is written. Proves a rejected write cannot burn the nonce (pre-emption guard). |
| `testFuzz_expiryBoundary(uint64,uint256)` | `:53` | `ok == !(block.timestamp >= expiry)` across warps — pins the `>=` edge (equality is expired). |
| `testFuzz_nonceMonotonic(uint256,uint256)` | `:65` | A second attestation reverts `StaleNonce` iff `n2 <= n1`, and `lastNonce` advances iff strictly higher. |
| `testFuzz_cumulativeNeverExceedsPeriodCap(uint96,uint96,uint96)` | `PeriodCap.t.sol:107` | Drives 3 real transfers through `GatedUSD`. Each clears iff cumulative stays `<= spendCapPerPeriod`; asserts `spentThisPeriod` always equals the cumulative of *cleared* transfers and never exceeds the cap. This is the only fuzz test that exercises the real token path rather than the view. |

Plus one non-fuzz boundary case, `test_expiryZero_isAlwaysExpired`
(`DelegationMirrorFuzz.t.sol:84`): a mandate signed with `expiry == 0` is dead on arrival.

### 3.3 Two tests that assert nothing

`test_logCoordinationVectors` (`Eip712Coordination.t.sol:66`) and
`test_logArcChainVectors` (`:84`) are `console2.log` emitters for cross-implementation
EIP-712 diffing. They contain no assertions. They count toward the 63.

---

## 4. ERC-8226 integration status

**It was never built. There is nothing to review.**

Checked, all negative:

- **Branch `feat/rams-8226-integration` does not exist.** `git for-each-ref` lists 7
  local branches, 8 remote branches and 1 tag. No branch or tag matches `*rams*` or
  `*8226*`. Full branch set: `develop`, `main`, `feat/agent-wallet`,
  `feat/attestation-bridge`, `feat/attestation-builder`, `feat/period-enforcement`,
  `feat/signed-attestation`, plus `origin/cj`, `origin/sweepoh/invariants`,
  `origin/sweepoh/pr-ledger`, and tag `proven-live-v1`.
- **`lib/rams-reference/` does not exist.** `contracts/lib/` contains exactly two
  submodules: `forge-std` and `openzeppelin-contracts`.
- **`docs/rams/` does not exist.** `docs/` contains one file: `PR_LEDGER.md`.
  (This brief is the second.)
- **`IAgentMandate` and `IComplianceProvider` appear nowhere** — not implemented, not
  adapted, not stubbed, not imported, not referenced in a comment. A case-insensitive
  grep across the whole repo returns zero hits for either name.
- **The string "8226" appears exactly once in the entire repository**, in a doc comment:

  ```solidity
  // contracts/src/DelegationMirror.sol:10
  ///         principal to an AI agent. Vocabulary aligned with ERC-8226 (RAMS, Draft):
  ///         mandate, principal, scoped authority. Acts as the transfer gate consulted
  ```

So the relationship to ERC-8226 is: **we borrowed three words of vocabulary**
(`mandate`, `principal`, scoped authority) **in a comment.** No interface, no
adapter, no reference implementation, no conformance test, no shared types.

Related: `README.md:99-101` positions VAR against ERC-8004 and mentions 8001 / 8126 /
8183, and states the reference implementation "will be published as an open spec and
submitted to the EIP process for a community-assigned number; it is not
self-numbered." That paragraph does not mention 8226.

---

## 5. Revocation semantics in our implementation

### 5.1 Flag, not delete

`DelegationMirror.revoke` (`DelegationMirror.sol:180-186`) sets `m.revoked = true` and
emits `Revoked(agent, principal)`. **It does not delete the record.** Every other
field — `principal`, `proofRef`, caps, `expiry`, `allowedToken`, `spentThisPeriod`,
`periodStart`, `nonce` — survives untouched.

Consequences, all intentional and all tested:

- `isRegistered(agent)` still returns `true` after revoke (`DelegationMirror.sol:197`
  keys on `principal != address(0)`), so the token keeps gating the agent rather than
  falling through to the ungated path. This is the reason revoke works at all — a
  `delete` would make the agent look like an ordinary unmandated address and its
  transfers would become **unrestricted**. Worth stating explicitly to spec authors:
  *in a deny-list gate, deleting a revoked record is a privilege escalation.*
- `checkTransfer` returns `(false, REVOKED)` — `DelegationMirror.sol:212`, second in
  precedence order, ahead of expiry and caps.
- Access control: only `m.principal` may revoke. Non-principal reverts
  `NotPrincipal` (`test_revoke_onlyPrincipal`, `DelegationMirror.t.sol:86`); an unknown
  agent reverts `NoMandateFor` (`test_revoke_unknownAgentReverts`, `:94`).
- Un-revocation is possible only by the attestor issuing a strictly higher nonce
  (`test_attestation_higherNonceReopensAfterRevoke`, `DelegationMirror.t.sol:66`;
  `test_attestorReopensWithHigherNonce`, `AttestationSecurity.t.sol:114`). A replay of
  the original signed attestation fails on nonce monotonicity
  (`test_replayAfterRevoke_reverts`, `AttestationSecurity.t.sol:85`), and a forged
  higher-nonce attestation fails signature recovery
  (`test_attackerCannotReopenAfterRevoke`, `:100`).

### 5.2 Does a stale token allowance still let the agent move funds? **No — and it is tested.**

This is the important question and the answer is clean, because the gate keys on
`from`, not on `msg.sender`. An ERC-20 allowance granted before revocation stays on
the books, but any `transferFrom` pulling the agent's balance still routes through
`_update` with `from == agent` and still hits `checkTransfer`.

**Proving test: `test_revokeMidFlow` — `contracts/test/GatedUSD.t.sol:103`.**
It approves `type(uint256).max` to `ServiceSink`, pays 40 gUSD successfully, revokes,
then re-attempts `sink.pay(40e6)` and asserts it reverts
`TransferBlocked(REVOKED)` — with the max allowance still standing.

I also confirmed the general spender case (arbitrary third-party spender, not just
the sink) with a throwaway PoC: allowance survives at `type(uint256).max`, and
`transferFrom(agent, payee, …)` by that spender reverts `TransferBlocked(REVOKED)`
after revocation. **That PoC is not in the repo** — the committed coverage is
`test_revokeMidFlow` via `ServiceSink` only.

### 5.3 Where revocation does *not* reach — verified

Revocation stops the agent from moving its own `GatedUSD` balance. It does not reach
value the agent has already routed elsewhere. Verified with a throwaway PoC (deleted;
**no committed test covers any of these**):

- **Vault-held assets survive revocation.** Agent deposits 10 gUSD into
  `MockYieldVault` (gated, increments), principal revokes, agent's direct transfer
  reverts `REVOKED` — and the agent still successfully calls `vault.redeem(...)` and
  gets the gUSD back. The outbound leg is `from == vault`, and the vault holds no
  mandate, so it is ungated.
- See also §6.3, which is the same root cause on the cap axis.

---

## 6. Cumulative cap accounting

### 6.1 Who increments, and who is allowed to

`DelegationMirror.recordSpend(address agent, uint256 amount)` — `DelegationMirror.sol:236-247`.

- **Called by:** `GatedUSD._update`, `GatedUSD.sol:38`, only when `gated` is true, and
  only *after* `super._update` has settled the balances.
- **Authorized by:** `if (msg.sender != m.allowedToken) revert NotGatedToken(...)` —
  `DelegationMirror.sol:239`. Authority is bound to the attestor-signed `allowedToken`
  field of that agent's own mandate. There is no owner-managed token registry and no
  separate wiring step. Design rationale is stated in the docstring at `:227-235`.
- **Effect:** if `_periodRolled(m)` (`:252`, true when `periodStart == 0` or the window
  has elapsed) then `periodStart = block.timestamp` and `spentThisPeriod = amount`;
  otherwise `spentThisPeriod += amount`. Emits `Spent`.
- **Window semantics:** the window opens on the *first spend*, not at mandate creation
  (`submitAttestation` writes `periodStart: 0`, `DelegationMirror.sol:171`). Windows
  are sliding-from-first-spend, not calendar-aligned.
- `spendCapPerPeriod == 0` disables enforcement but **accounting still runs** —
  `test_zeroPeriodCap_noLimit` (`PeriodCap.t.sol:95`) asserts `spentThisPeriod` reaches
  300 gUSD with the cap disabled.

Committed coverage of the accounting itself is good, and it is real-transfer coverage
rather than view assertions: `test_underBothCaps_clears` (`PeriodCap.t.sol:47`),
`test_cumulativeOverPeriod_returnsOverPeriodCap` (`:65`, including the exactly-at-cap
boundary and the assertion that a blocked transfer does **not** accumulate),
`test_periodRollover_resetsAndClears` (`:78`), and the fuzz property at `:107`.

### 6.2 Paths that do not increment — the gaps

The cap is enforced on one predicate: `from` has a mandate, on the token named in that
mandate. Anything that moves value without satisfying that predicate is neither capped
nor counted. Four such paths exist. **Each was verified with a throwaway PoC that
passed; none has a committed test.**

| # | Path | Result |
|---|---|---|
| 1 | **`faucetMint`** — `GatedUSD.sol:52`, unrestricted, callable by anyone. Mints with `from == address(0)`, which `GatedUSD.sol:31` explicitly excludes from gating. | A **revoked** agent whose own transfer reverts `REVOKED` can call `token.faucetMint(payee, 1_000_000e6)` and deliver a million gUSD to any address. `spentThisPeriod` stays 0. The cap is not merely bypassed; the token has no supply integrity at all. |
| 2 | **ERC-4626 vault shares** — `MockYieldVault` shares (`mygUSD`) are a plain ungated ERC-20. | Agent deposits 10 gUSD (gated, increments), then `vault.transfer(attacker, shares)` — no `checkTransfer`, no `recordSpend`, no cap. Attacker redeems; gUSD exits with `from == vault`, ungated. The claim on the asset moves freely even though the asset is gated. |
| 3 | **Agent as an approved spender of a non-agent's balance.** | A human approves the agent; agent calls `transferFrom(human, payee, 500e6)` — 50× the 10 gUSD per-tx cap. It clears, because `from == human` and the human has no mandate. `spentThisPeriod` stays 0. The mandate constrains the agent's *balance*, not the agent's *authority*. |
| 4 | **Re-attestation resets the meter.** `submitAttestation` writes `spentThisPeriod: 0, periodStart: 0` — `DelegationMirror.sol:170-171`. | The attestor can zero an agent's cumulative spend at any time by issuing a higher-nonce attestation. The per-period cap is not durable against attestor re-issuance. No test asserts either the reset or its absence; `test_higherNonceUpdatesActiveMandate` (`AttestationSecurity.t.sol:150`) checks only `spendCapPerTx` and `lastNonce`. |

Paths 1 and 2 are artifacts of demo contracts (`faucetMint`, `MockYieldVault`) and do
not indict the mirror's design. **Paths 3 and 4 do**, and they are the ones worth
putting in front of spec authors:

- **Path 3** is the structural point: a `from`-keyed asset-level gate cannot express
  "this agent may not move more than X," only "this address's balance may not decrease
  by more than X." Any spec that describes mandates as constraining an *agent* should
  be explicit about which of the two it means.
- **Path 4** is the durability point: if the cumulative meter lives in the same record
  the attestor rewrites, the attestor is implicitly trusted with the cap, not just with
  the grant.

### 6.3 The registry cannot enforce its own cumulative cap

`recordSpend` trusts its caller. The mirror has no way to verify that a `checkTransfer`
actually preceded the call, or that the reported `amount` matches what moved. Whatever
contract the attestor names as `allowedToken` is fully trusted to report honestly:

- A token that simply **never calls `recordSpend`** passes every per-tx check forever
  and accumulates nothing. Cumulative capping silently becomes a no-op.
- The downcast `uint96(amount)` at `DelegationMirror.sol:242` and `:244` is an
  unchecked truncation. The in-code comment at `:233-235` argues it is exact *because
  `checkTransfer` ran first* — which is true for `GatedUSD`, and is an assumption about
  the caller, not a property of the function.

For a spec: cumulative accounting is not enforceable by a registry alone. It requires
the asset to cooperate, which means either the asset must be in the trust boundary, or
the accounting must live in the asset.

---

## 7. Reason codes

### 7.1 Our full list

Declared as `bytes32` constants, `DelegationMirror.sol:61-67`, mirrored in TypeScript
at `shared/src/reasonCodes.ts:5-13` (right-padded `bytes32`, same wire values):

`OK`, `NO_MANDATE`, `REVOKED`, `EXPIRED`, `OVER_CAP`, `TOKEN_NOT_ALLOWED`,
`OVER_PERIOD_CAP` — seven total.

Of those, **five can ever surface as a token revert**: `REVOKED`, `EXPIRED`,
`OVER_CAP`, `TOKEN_NOT_ALLOWED`, `OVER_PERIOD_CAP`. `OK` is a pass. `NO_MANDATE` is
registry-only and unreachable through `GatedUSD` (§2.4.1).

### 7.2 Mapping onto the ERC-8226 `ReasonCode` enum

| Ours | Nearest 8226 member | Honest verdict |
|---|---|---|
| `OK` | `COMPLIANT` | Clean 1:1. The only unambiguous mapping in the table. |
| `REVOKED` | `ATTESTATION_REVOKED` | **Name matches, semantics differ.** Ours means *the principal revoked a spending mandate* — a delegation withdrawn by the delegator. `ATTESTATION_REVOKED` reads as *a compliance attestation was revoked by its issuer*. Different actor, different object. Mapping these together would conflate delegation withdrawal with credential revocation. |
| `EXPIRED` | `KYC_EXPIRED` | **Do not map.** Ours is mandate expiry (`Mandate.expiry`). It says nothing about KYC — our `kycRef` is `bytes32(0)` in every path (§9.5). Mapping this to `KYC_EXPIRED` would assert a KYC lifecycle we do not implement. |
| `NO_MANDATE` | `IDENTITY_NOT_FOUND` | **Do not map.** Superficially similar, opposite effect: in our token a missing mandate means the transfer *proceeds* (§2.4.1), whereas `IDENTITY_NOT_FOUND` presumably blocks. Same-sounding code, inverted outcome. |
| `OVER_CAP` | — | **No equivalent.** Falls to `OTHER`. |
| `OVER_PERIOD_CAP` | — | **No equivalent.** Falls to `OTHER`. |
| `TOKEN_NOT_ALLOWED` | — | **No equivalent.** Falls to `OTHER`. |

### 7.3 Members of theirs we cannot produce

`KYC_EXPIRED`, `AML_FLAG`, `NOT_ACCREDITED`, `NOT_QUALIFIED`, `JURISDICTION_BLOCKED`,
`IDENTITY_NOT_FOUND` — **six of nine.** We hold no KYC state (`kycRef` is always zero),
no AML signal, no accreditation or qualification status, and no jurisdiction data.
`IDENTITY_NOT_FOUND` is arguably reachable via World Chain `AgentBook.lookupHuman`
returning 0, but that check lives **off-chain in the granting API**
(`web/app/api/var/grant/route.ts:91`) and refuses to *issue* a mandate; it is never a
transfer-time verdict and never produces a reason code.

### 7.4 The substantive point for the spec discussion

Our codes and theirs are close to **disjoint**. Ours describe *scoped spending
authority* — is this delegation live, and is this amount within its bounds. Theirs
describe *compliance and identity status* — is this party permitted to hold or move
this asset. Three of our five revert codes have no expressible form in the enum
except `OTHER`, and six of their nine have no source of truth in our system.

That is not a defect on either side; it suggests the two are orthogonal axes. A single
flat `ReasonCode` enum that must carry both will either grow unboundedly on the
mandate axis or push every mandate failure into `OTHER`, which erases exactly the
information an agent operator needs to act on (retry later vs. reduce amount vs. stop).

---

## 8. Known weaknesses

Ranked roughly by how badly they'd land in review.

### 8.1 The granting API will sign a mandate for an unauthenticated caller

> **STATUS 2026-08-03 — the headline defect is FIXED for `/api/var/grant`; the
> sibling routes are hardened but NOT authenticated. Read both halves.**
>
> **Fixed.** The caller must now prove control of `principal` by signing a
> statement committing to `(agent, principal, spendCap, expiryMinutes, issuedAt)`;
> the server recovers it with `verifyMessage` (EOA and ERC-1271, so Dynamic MPC
> wallets work) and rejects unless the signer *is* `principal`
> (`web/lib/sameOrigin.ts` `principalProofInvalid`, wired at
> `web/app/api/var/grant/route.ts`). `crossOriginBlocked` no longer returns
> allow on a missing `Origin` header. Because the caps and expiry are inside the
> signed statement, a captured signature cannot be replayed for different terms,
> and the 5-minute `issuedAt` window bounds replay.
> Verified by signature roundtrip: identical client/server statements, the
> principal's own signature verifies, **an attacker's signature naming that
> principal is rejected**, and a tampered `spendCap` is rejected.
>
> **All four privileged routes now carry proof-of-control** (updated later the
> same day). The primitive is generalised: the caller signs a statement whose
> first line is the ACTION, so a signature captured from one route cannot be
> replayed against another.
>
> | Route | Required signer | Bound fields |
> |---|---|---|
> | `/api/var/grant` | the named `principal` | agent, principal, spendCap, expiryMinutes |
> | `/api/var/pay` | the **mandate's** principal, read from the mirror | agent, amount |
> | `/api/var/fund-gas` | the **mandate's** principal, read from the mirror | agent |
> | `/api/var/create-agent` | the `owner` it names | owner |
>
> `pay` and `fund-gas` bind to the principal recorded on-chain rather than one
> supplied in the request, so the caller cannot nominate themselves. `pay` puts
> the amount inside the signed bytes, so a captured signature cannot be reused
> for a larger spend. `create-agent` has no mandate to bind to — the agent does
> not exist yet — so it takes the weakest defensible gate: minting is no longer
> anonymous and is rate-limitable per identity instead of being an open faucet
> on our Dynamic quota. That is a real limit, not an authorisation.
>
> Verified by signature roundtrip, 22 checks: client and server statements are
> byte-identical for all four actions, the right signer verifies, an attacker's
> signature is rejected for each, **all twelve cross-route replays are
> rejected**, and a tampered `pay` amount is rejected.
>
> **Still true, do not overclaim.** Requiring an `Origin` header remains *not*
> authentication — `curl -H "Origin: https://<host>"` passes it trivially; the
> signature is what authenticates. §8.2 (single attestor key, single owner EOA,
> no multisig, no timelock) is untouched and still governs everything
> downstream. None of this makes the deployment production-grade.

`web/app/api/var/grant/route.ts`. The route holds `ATTESTOR_PRIVATE_KEY` and signs an
EIP-712 attestation on request. Its only gate is `crossOriginBlocked`
(`web/lib/sameOrigin.ts:9`), which **returns `null` — allow — when there is no `Origin`
header** (`sameOrigin.ts:11`). That is every non-browser caller, including `curl`. The
file's own comment says so: *"This is NOT a substitute for real authentication."*

With that, on any deployment where this route is reachable:

- `principal` is taken **verbatim from the request body** (`route.ts:70-74`). Nothing
  proves the caller controls it. Since `revoke` is principal-only, whoever names the
  principal owns the kill switch — a caller can name themselves, or name a third party.
- `spendCap` is caller-supplied and **unbounded** (`route.ts:75`, `:112`) —
  `parseUSDC` (`shared/src/parseUSDC.ts:9`) applies no ceiling.
- `expiryMinutes` is caller-supplied and unbounded (`route.ts:76`, `:122`).
- The only substantive check is `AgentBook.lookupHuman(agent) != 0` on World Chain
  (`route.ts:85-96`) — it verifies **the agent is human-backed**, not that *the
  requester* is that human, or any human.

So "a human verifies once with World ID and then delegates" is not enforced end to end
by this path. The World ID leg establishes that the agent has *a* registered human; it
does not authenticate the party requesting the mandate. I have not tested this against
the live Fly deployment — this is a code reading, deliberately not exercised against a
running host.

The same guard protects `/api/var/pay`, `/api/var/create-agent`, and `/api/var/fund-gas`.

### 8.2 Single attestor key, single owner EOA, no multisig

`registeredAttestor` is an owner-managed mapping (`DelegationMirror.sol:73`) and
`setAttestor` is `onlyOwner` (`:104`). Live owner is the deployer EOA
`0x54E7B896…1dec` — one key, no timelock, no multisig. The owner can register an
arbitrary attestor at any time and therefore mint arbitrary mandates for arbitrary
agents. Acknowledged in-repo: `// TODO(workstream-A): move attestor management behind
a multisig owner.` (`DelegationMirror.sol:103`), and `README.md:84`.

The trust statement is: *the mirror owner is fully trusted.* Every "the asset enforces
it, not the agent's good behavior" claim is downstream of that one key.

### 8.3 Role separation covers three roles; the fourth one collapses

`README.md:65` — "Three roles, cleanly separated: principal … is not the agent is not
the attestor." That claim is **true as stated**: in
`agent/src/scripts/proveHappyPath.ts:42` the principal is distinct from both the agent
and the attestor, and the comment on that line says so.

The unstated fourth role is the problem. That principal is `0x54E7B896…1dec` — **the
deployer, which is also the mirror `owner()`** (confirmed on-chain, §1.1). The owner
can register any attestor at will (§8.2), so in the headline proof the party holding
the kill switch is the same key that can mint a replacement mandate. Principal and
root authority are not separated. The current *live* mandate does use a distinct
principal (`0x18e5B7AF…2110`, §1.6), so this is a property of the demo script, not of
the deployment today.

### 8.4 Cap and revocation gaps (detail in §5.3, §6.2, §6.3)

- Cumulative accounting is only as good as the `allowedToken` contract; the registry
  cannot verify it (§6.3).
- The attestor can zero the cumulative meter by re-attesting (§6.2, path 4).
- The mandate constrains the agent's balance, not the agent's authority — the agent can
  spend a third party's approved balance uncapped (§6.2, path 3).
- Revocation does not reach value already parked in a vault (§5.3).
- **None of these four has a committed test.** Each was verified with a throwaway PoC.

### 8.5 Hackathon leftovers on the enforcement surface

- `GatedUSD.faucetMint` (`GatedUSD.sol:52`) — unrestricted mint, `public`, no access
  control. Comment says "hackathon demo token only." It is deployed on the live token
  and it defeats every cap (§6.2, path 1). `test_faucetMint_unrestricted`
  (`GatedUSD.t.sol:155`) asserts this as *intended* behavior.
- `MockYieldVault.sync()` (`MockYieldVault.sol:36`) calls `faucetMint` to fabricate
  yield. Vault "yield" is minted from nothing, 1bp/block.
- `MockYieldVault` shares are ungated (§6.2, path 2).

### 8.6 ERC-7943 claim is thinner than it reads

`GatedUSD.sol:11` — "Exposes the ERC-7943 canTransfer surface (Final)". What exists is
one function, `canTransfer(address,address,uint256) returns (bool)` (`:43`), whose
second parameter is discarded (`to; // unused`, `:44`). The contract imports no
ERC-7943 interface, declares no interface type, implements no ERC-165
`supportsInterface`, and no test checks conformance against an ERC-7943 interface.
Describing this as "exposes the ERC-7943 surface" in a standards venue will invite a
correction. It is one similarly-named function.

### 8.7 Unaudited, and the schema is self-declared consensus

No audit, no external review. `contracts/src/DelegationMirror.sol:39` carries
`// TODO(workstream-A): replace this local copy with the shared schema module`, and the
struct comment at `:37-38` says field order is "consensus-locked with CJ's TS signer
and Vlad's pipeline signer; do not reorder unilaterally" — i.e. the canonical schema is
a social agreement across three implementations, not a single source of truth. The
typehash is pinned by `test_typehash_matchesLockedSchema` (`Eip712Coordination.t.sol:51`),
which is the mitigation, and it is a good one.

### 8.8 Two invariants are weaker than their names suggest

- `invariant_revokedStaysBlocked` asserts only `!ok`, not `reason == REVOKED`. An
  implementation bug that returned `EXPIRED` for a revoked mandate would pass.
- `invariant_perTxCapNeverExceeded` calls `checkTransfer(agent, cap + 1)` — for an
  agent with no mandate, `cap` is 0 and the call returns `!ok` via `NO_MANDATE`, so the
  assertion is vacuous for unmandated agents.

Neither is wrong; both are looser than a reader would assume from the name.

### 8.9 Documentation drift

- The **54 tests** figure appears in five places — `README.md:13`, `:19`, `:20`, `:108`
  and `RUN.md:26`. The real count is **63**.
- `shared/addresses.json` `deployBlock` is 46942608; receipts say 46942616 (§1.3).
- `README.md:17` describes the grant as "cap 10/tx, period cap 15, 1h window". **No
  default code path in this repo produces those numbers**: the web route hardcodes
  `spendCapPerPeriod = spendCapPerTx * 10` and `periodLength = 86400`
  (`web/app/api/var/grant/route.ts:119-120`), and `proveHappyPath.ts:115` does the same.
  Only `agent/src/scripts/attest.ts` could, via explicit `--cap-period 15 --period 3600`
  flags (defaults there are 100 / 86400, `attest.ts:198-200`). The cited tx hashes in
  the README table are **truncated** (`0xcd81d357…`, `0x537e1c08…`, `0x11443139…`) and
  appear nowhere else in the repo, so none of that table is verifiable from this
  repository. Do not cite it.
- The working tree carries 2 uncommitted edits removing an **"ERC-5604 · Console"**
  label from `web/app/var/VarDashboard.tsx:173` and
  `web/app/var/ui/RegisterGate.tsx:203`. ERC-5604 is unrelated to this work; the
  dashboard was displaying an incorrect ERC number and the fix is not yet committed.

---

## Safe public claims

Each of these is backed by something a reader can check.

1. Four contracts are deployed on Arc testnet (chainId 5042002) at the addresses in
   §1.1, from `contracts/broadcast/Deploy.s.sol/5042002/run-latest.json`, all receipts
   successful at block 46942616. Live bytecode is present at all four addresses, and
   `GatedUSD.mirror()` on-chain returns the live `DelegationMirror` address.
2. The transfer gate is a single external view call, `DelegationMirror.checkTransfer`,
   invoked from `GatedUSD._update`; a failure reverts the whole transaction with the
   custom error `TransferBlocked(bytes32 reason)`. Trace and storage reads: §2.
3. Reason codes are evaluated in a fixed order — NO_MANDATE, REVOKED, EXPIRED,
   OVER_CAP, TOKEN_NOT_ALLOWED, OVER_PERIOD_CAP — and that ordering is pinned by
   `test_checkTransfer_orderOverCapBeforeToken` and
   `test_overPerTx_underPeriod_returnsOverCap`.
4. `forge test` on commit `f7bd69a` runs **63 tests, 63 passing, 0 failing, 0 skipped**,
   across 8 suites, with no skipped or commented-out tests. Fuzz runs are 10,000 per
   property; invariant runs are 256 × depth 50.
5. Mandates can be created only through `submitAttestation` with a registered
   attestor's EIP-712 signature and a strictly increasing per-agent nonce. There is no
   permissionless creation path. Held under 12,800-call stateful fuzzing by
   `invariant_onlyAttestorEverWritesMandate`, and over the keyspace by
   `testFuzz_nonAttestorCannotWrite`.
6. A rejected attestation does not advance the agent's nonce — asserted in
   `testFuzz_nonAttestorCannotWrite`.
7. Revocation sets a flag; it does not delete the record. Keeping the record is what
   makes revocation effective: deleting it would return the agent to the ungated path.
   `DelegationMirror.sol:180-186`, `:197`.
8. A stale ERC-20 allowance does **not** survive revocation as a spending path: the
   gate keys on `from`, so `transferFrom` pulling a revoked agent's balance still
   reverts `REVOKED` with a `type(uint256).max` allowance outstanding. Proven by
   `test_revokeMidFlow` (`contracts/test/GatedUSD.t.sol:103`).
9. Cumulative per-period spend is accumulated in the registry by
   `DelegationMirror.recordSpend`, callable only by the agent's own attestor-signed
   `allowedToken`. Covered by real-transfer tests including a fuzz property
   (`PeriodCap.t.sol:107`) asserting `spentThisPeriod` always equals the cumulative of
   cleared transfers and never exceeds the cap. A blocked transfer does not accumulate.
10. Our seven reason codes and the ERC-8226 `ReasonCode` enum are largely disjoint.
    Only `OK`/`COMPLIANT` maps cleanly. Three of our five revert codes (`OVER_CAP`,
    `OVER_PERIOD_CAP`, `TOKEN_NOT_ALLOWED`) have no equivalent, and six of the nine
    enum members have no source of truth in our system. Detail and reasoning: §7.
11. **The ERC-8226 integration was planned but never built.** No branch, no
    `lib/rams-reference/`, no `docs/rams/`, no `IAgentMandate`, no `IComplianceProvider`.
    The only trace of 8226 in the repository is a single doc comment at
    `DelegationMirror.sol:10` noting shared vocabulary.
12. Known limitations we are raising ourselves, all in §8: single trusted attestor and a
    single EOA owner with no multisig; an unauthenticated granting API; unrestricted
    `faucetMint` on the demo token; ungated ERC-4626 shares; the cumulative meter reset
    on re-attestation; the registry's inability to enforce its own cumulative cap
    without a cooperating asset; no audit.

---

## Do not claim

1. **Do not say "54 tests."** It is 63. `README.md` and `RUN.md` are stale.
2. **Do not say the contracts are verified on the explorer.** Nothing in this repo
   verified them and no verification config exists. Status is unconfirmed until checked
   by hand (§1.4).
3. **Do not claim any ERC-8226 implementation, integration, adapter, or conformance
   work.** None exists. Do not imply `IAgentMandate` or `IComplianceProvider` are
   stubbed — they are absent entirely (§4).
4. **Do not cite the README's "Proven live on Arc" table.** Its tx hashes are truncated
   and appear nowhere else in the repo, and its stated parameters ("period cap 15, 1h
   window") match no default code path (§8.9).
5. **Do not say the demo is live and spending right now.** The live mandate for agent
   `0x69e1…cC54` expired 2026-07-21; `checkTransfer` currently returns `EXPIRED` (§1.6).
6. **Do not say "the asset enforces the cap" without qualification.** It enforces it on
   the mandated address's own balance of that one token. It does not stop the agent
   spending a third party's approved balance, does not cover ungated ERC-4626 shares
   claiming the same asset, and is defeated outright by the demo token's unrestricted
   `faucetMint` (§6.2).
7. **Do not say the cumulative cap is tamper-proof.** The attestor zeroes it on every
   re-attestation, and the registry cannot verify that the `allowedToken` reports spends
   honestly (§6.2 path 4, §6.3).
8. **Do not say revocation freezes the agent.** It blocks the agent from moving its own
   gUSD balance. It does not claw back or freeze value already deposited into the vault
   (§5.3).
9. **Do not describe World ID as gating the grant.** The granting API checks that the
   *agent* is human-backed; it does not authenticate the requester, and it accepts an
   arbitrary caller-supplied `principal`, `spendCap`, and expiry (§8.1).
10. **Do not claim ERC-7943 compliance or implementation.** One similarly-named function
    exists, with no interface, no ERC-165, and no conformance test (§8.6).
11. **Do not claim "three roles cleanly separated" while pointing at
    `proveHappyPath.ts`.** In that script the principal is the deployer, which is also
    the mirror owner (§8.3).
12. **Do not claim audit, external review, or production readiness.** There is none
    (§8.7).
