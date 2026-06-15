# VAR — Security Model & Reference Checklist

> What a definitive reference implementation of delegated onchain agent spending must
> get right, what VAR gets right today, and the exact boundary of what asset-layer
> enforcement does and does not contain. Sourced from an adversarially-verified security
> research pass (2026-06) and a line-by-line audit of the contracts. Load-bearing
> external claims carry citations.

## Threat model in one line

The agent's signing authority (a Dynamic MPC server wallet, or any key) is assumed
**hijackable** — by prompt injection (cf. the Grok/X incident that drained ~$150k from an
AI wallet), key theft, or a malicious delegation. The design goal is that a fully
compromised agent key **cannot exceed the human's signed mandate** on the gated asset.

## Why asset-layer enforcement is the right call (verified)

The dominant real-world failure in delegated spending is **unscoped delegation**:
EIP-7702 single-tuple delegation has been weaponized at scale — roughly half of observed
7702 authorizations are crime-linked, draining wallets via sweeper contracts
("CrimeEnjoyor") (arXiv 2512.12174). The fix the literature converges on is *scoped*
authorization bound to chain, contract, and nonce — which is exactly VAR's EIP-712
mandate. And because enforcement lives in the token (ERC-7943 `canTransfer`, Final
2026-05-27: transfers revert when `canTransfer` is false), the cap holds **even if the
agent key is fully compromised** — strictly stronger than account/signature-layer schemes
(MetaMask ERC-7710/7715 caveats, AP2 signed mandates) that trust the wallet to refuse.

Research verdict: *"VAR's scoped-delegation + asset-layer design is sound to best-in-class;
the ERC-7943 gated ERC-20 contains spending even if the agent key is fully compromised."*

## Reference checklist — VAR status

| # | Requirement | Status | Where |
|---|---|---|---|
| 1 | Scoped mandate (per-tx + period cap, expiry, allowed token, revoke) | ✅ | `DelegationMirror.sol:22` |
| 2 | EIP-712 domain separation binds `chainId` + `verifyingContract` | ✅ | OZ `_hashTypedDataV4` `:143` |
| 3 | Per-owner nonce, strictly increasing (replay protection) | ✅ | `lastNonce` `:160` |
| 4 | Forbid `chainId = 0`; dynamic `block.chainid` (no static cache) | ✅ | OZ EIP712 |
| 5 | Gate runs on the **`transferFrom`/allowance** path, not just `transfer` | ✅ | single `_update` chokepoint `GatedUSD.sol:30` |
| 6 | Period-cap accounting correct under `transferFrom` and window rollover | ✅ | `recordSpend` + `_periodRolled` `:242,258` |
| 7 | Revocation effective **same block** | ✅ | `revoke` → live read in `checkTransfer` `:186,218` |
| 8 | Reentrancy-safe `_update` (no external callback mid-state) | ✅ | plain ERC20; trailing trusted call |
| 9 | `recordSpend` authorization bound to the signed token | ✅ | `msg.sender != m.allowedToken` reverts `:245` |
| 10 | Fail-closed defaults (cap 0 → blocked, expiry 0 → expired) | ✅ | reason-code order `:217` |
| 11 | Attestor key behind a multisig | ⚠️ TODO | single owner key today `:109` |
| 12 | No unrestricted mint in production | ⚠️ DEMO | `faucetMint` is public `GatedUSD.sol:52` |
| 13 | Monitoring/alerting on mandates, spends, revocations | ◻️ events exist, pipeline TBD | `Spent`/`Revoked` events |

Items 1–10 are best-practice and met. 11–13 are the gap between "great hackathon build"
and "citable reference implementation," and should be closed before VAR is presented as
the canonical reference.

## The containment boundary — state this honestly, always

Asset-layer enforcement contains value **only through the gated token**. A hijacked agent
is *not* constrained by the mandate when it:

1. **Moves a non-gated asset.** Native gas (USDC on Arc), or any ERC-20 that is not
   `GatedUSD`, is outside the gate. **Mitigation: keep the agent's non-gated balances
   minimal** — fund only enough native gas for operation, or pay gas via a separate
   relayer/submitter so the agent key never holds spendable non-gated value. This is the
   single most important operational rule.
2. **Takes a non-token action.** Arbitrary contract calls or message signing are not
   constrained by a token gate. The mandate scopes *spending of the gated token*, nothing
   more. Do not over-claim it as a general agent sandbox.
3. **Sets an allowance.** `approve()` does not pass through `_update`, so an agent can
   approve a spender — but the eventual `transferFrom` **still** routes through the gate
   and is capped, so value is bounded by the mandate. Worth noting in audits; not a cap
   bypass.

Trust assumptions to document: (a) the **attestor** can sign a mandate with any cap for
any agent, so attestor-key compromise is high-impact → multisig + monitoring (item 11);
(b) `recordSpend` trusts the signed `allowedToken` to have validated first, so only
legitimate gated tokens should ever be signed as `allowedToken`.

## Implementation pitfalls VAR already avoids (from the audit)

- **Signature replay** is widespread (~19.6% of signature-verifying contracts show
  replay vulnerabilities; arXiv 2511.09134) — VAR's strictly-increasing per-agent nonce
  plus full EIP-712 domain binding closes cross-chain, cross-contract, and replay vectors.
- **EIP-712 "message"-field UI injection** across 27+ wallets makes "approved ≠ signed"
  (Coinspect) — VAR signs a typed `Attestation` struct, not free-form display data.
- **ERC-4337 / ERC-1271 pitfalls** (signature replay, 7702 init front-run; Trail of Bits,
  "Six mistakes in ERC-4337 smart accounts", 2026-03) — VAR's MPC-wallet + asset-layer
  model sidesteps the smart-account-init front-run class entirely.

## Open items worth a dedicated pass

- Quantify MPC-custody blast radius and revocation latency vs an ERC-4337 alternative
  (the audit left this unquantified).
- Decide and document the production gas-funding pattern that keeps rule #1 above true.
- Formal/property tests asserting the boundary: "no sequence of gated-token transfers by
  `agent` exceeds `spendCapPerPeriod` within any `periodLength` window."

## The demo that proves it

Build the **hijacked-agent demo**: a prompt-injected agent attempts to overspend and the
gated transfer reverts `OVER_CAP`. It is the single most persuasive artifact VAR can ship,
because it turns the verified central claim — *onchain caps make agent hijacking
economically bounded rather than catastrophic* — into something a reviewer can watch.
