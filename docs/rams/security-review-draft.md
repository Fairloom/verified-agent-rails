# ERC-8226 deployed contracts — security review notes

**Status: DRAFT — private. Not for distribution before the Brickken team has seen it.**
**Tone: peer implementer.** We built a token-side integration against these
contracts (see `INTEGRATION.md`); these notes are what we verified and what we
would want to know if the deployment were ours.

**Scope:** the three contracts on Ethereum Sepolia (11155111), deployed
2026-07-06 by `0xB610470a…faf1`:

| Contract | Address |
|---|---|
| AgentMandate | `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e` |
| ComplianceProvider | `0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278` |
| AgentExecutor | `0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952` |

Baseline: all three are **bytecode-identical to the EIP reference
implementation** (`docs/rams/deployed-vs-spec.md`), so code-level analysis of
the reference applies verbatim to the deployment. Every on-chain claim below
was checked live during Phase 0 (block ~11233510) or exercised in our Foundry
suites against the same bytecode.

---

## 1. recordExecution caller restriction — enforced, one operational surprise

**Code:** callers other than the mandate's `asset`, the `principal`, or a
`RECORDER_ROLE` holder revert `UnauthorizedRecorder`. The arbitrary-caller
cap-exhaustion DoS the spec warns about is closed. `recordExecution` also
re-runs the full `_mandateAllows` gate plus both cap checks (shared with
`canExecute`, so read and write paths cannot drift) — good design.

**Finding (live config): the deployed AgentExecutor cannot record.** No
`RECORDER_ROLE` has ever been granted (zero `RoleGranted` events beyond the
constructor's admin grant), and the executor is neither an asset nor a
principal. Every `AgentExecutor.execute` on the live deployment therefore
reverts `UnauthorizedRecorder` at the recording step — we hit exactly this in
our test fixture until we granted the executor `RECORDER_ROLE`. If the
executor is meant to be usable as deployed, it needs the role; worth a line in
the deployment runbook.

**Note (by design, worth documenting):** the `principal` may call
`recordExecution` directly and can therefore burn down their own agent's
cumulative headroom without any transfer occurring. Self-inflicted and
arguably a feature (an emergency "spend the cap to zero" brake), but
integrators reconciling `cumulativeUsed` against actual transfers should know
executions and transfers are not 1:1.

## 2. Admin / enforcer separation — enforced in code, vacuous in deployment

**Code:** the `_grantRole` override rejects overlap in both directions
(`AdminEnforcerOverlap`), covering the constructor grant and later
`grantRole` calls. Conformant with the spec's "admin MUST NOT be an enforcer".

**Finding (live config): there is no enforcer at all.** The only role ever
granted is `DEFAULT_ADMIN_ROLE` → deployer. Consequences:

- `freezeAgent` is currently uncallable by anyone. The spec's mitigation for
  the PrincipalRevoked→freeze window assumes an enforcer exists; on this
  deployment the freeze lever is unwired and the window is unbounded (see §6).
- The separation guarantee is technically satisfied but only because one side
  of it is empty. The admin can mint an enforcer at any time — the separation
  is per-address, not per-party, so a second key held by the same operator
  satisfies the code while defeating the intent. That's inherent to
  AccessControl and fine for a testnet; a production deployment would want the
  admin behind a multisig and the enforcer demonstrably independent.

**Concentration note:** one EOA is simultaneously registry admin, compliance
operator (ComplianceProvider owner), executor owner, and executor principal.
Fine for a demo; any real pilot should split these before external users hold
mandates.

## 3. AgentExecutor action registry — correct, but blind

The selector→amount-position registry is owner-only (`setAction`), and the
executor reads the gated amount from forwarded calldata rather than trusting
the caller — the right call. Three observations:

- **`setAction` emits no event.** A wrong `amountIndex` silently mis-gates
  caps (e.g., `transferFrom` gated on the `from` address reinterpreted as an
  amount, if the index were 0 instead of 2), and with no event there is no
  off-chain trail to audit or alert on. We confirmed the live registry is
  empty by direct storage reads only — nothing else would have told us.
  Suggest: emit `ActionSet(selector, supported, hasAmount, amountIndex)`.
- `_amountArg` indexes head words of the ABI encoding, which is correct for
  amounts in static positions (and your uRWA20 `swap` test covers a dynamic
  arg sitting before the amount). A one-line NatSpec warning that
  `amountIndex` counts head slots, not "argument number", would help future
  action registrars.
- `hasAmount = false` gates at amount 0: such actions bypass value caps by
  construction while still requiring the action bit. Correct per spec, worth
  a doc note since a mis-registered value-bearing selector with
  `hasAmount = false` would move value uncapped (owner error, but silent).

## 4. grantMandate guards — both required reverts present

Verified in code and exercised in tests:

- `complianceProvider == address(0)` reverts `ZeroComplianceProvider`
  (first check in the function).
- `eligible == false` from `checkPrincipal` reverts `PrincipalNotEligible`.
- `MandateAlreadyActive` blocks silent replacement of a live mandate;
  revoked/expired mandates can be re-granted, with `_clearActions` correctly
  clearing stale action bits (duplicates in `actions` are handled harmlessly).

Minor footguns, all principal-side and non-exploitable: `asset` is not
zero-checked (a 0-asset mandate is inert), zero caps produce a mandate that
can never move value, and `validFrom == 0` means immediately-active — all
reasonable defaults, maybe worth NatSpec.

## 5. EIP-712 / signature path — conformant on the live deployment

Verified live during Phase 0 and in fork tests:

- `eip712Domain()` → name `RAMS`, version `1`, chainId `11155111`,
  verifyingContract = the registry. `DOMAIN_SEPARATOR()` =
  `0xae6058ab…8c90bec7`, and our locally-computed digests verify against it
  (fork test grants a mandate on the live registry via our own signer).
- Per-principal nonces bind every signed struct and increment only on the
  signature path; our fuzz suite confirms strict monotonicity and rejection
  of replayed grant AND revoke signatures across grant/revoke cycles.
- `deadline` is enforced (`SignatureExpired`) before recovery;
  `SignatureChecker` gives the EIP-1271 path for contract principals.

Two UX-grade notes: (a) direct calls (empty signature) consume no nonce, so a
pre-signed grant can be invalidated by any intervening signed operation from
the same principal — correct, but relayers should expect it; (b) `deadline`
is unbounded, so signers should keep deadlines short since a leaked signed
grant stays valid until its deadline or a nonce move.

## 6. The PrincipalRevoked → freeze window

The spec admits the window; the deployment currently cannot close it at all
(no enforcer, §2), and we found no evidence of a freeze relay — no freeze
events, no enforcer to send them. Even fully wired, the window is
detection latency + inclusion latency, and `canExecute` consults only
registry state: we confirmed on the live bytecode that after
`PrincipalRevoked`, `canExecute` still returns true until a freeze or mandate
revocation lands.

This is the gap our integration closes at the asset layer (execution-path
`checkPrincipal` re-check; `test/demo/CompromisedKey.t.sol` scenario C shows
zero-block closure on your own registry bytecode). For registry-only
integrations we'd suggest the deployment runbook at minimum: grant an
enforcer, and consider a PrincipalRevoked→freezeAgent relay with an alert on
relay lag.

## 7. Items checked with no findings

- Reentrancy: no external calls in `recordExecution`/`grantMandate` state
  paths; executor is `nonReentrant` and records before forwarding.
- `canExecute` vs `recordExecution` drift: impossible by construction
  (shared `_mandateAllows`); caps checked identically in both.
- `extendMandate` cannot resurrect revoked/expired mandates and preserves
  `cumulativeUsed` per spec; `newValidUntil` must strictly extend.
- ComplianceProvider: `ZeroIdentityRef` guard present; identityRef mismatch
  returns `IDENTITY_NOT_FOUND` (no oracle for which side mismatched);
  revoked records return the stored revocation reason. One nit: for
  ineligible results `expiresAt` is 0, which collides with the "0 = no
  expiry" convention — harmless since `eligible` is false, but integrators
  should not read meaning into `expiresAt` on the false branch.
- ERC-165: registry answers `IAgentMandate`, provider answers
  `IComplianceProvider` (checked live).

## Summary for the team

The code is the reference implementation, and the reference is solid: caller
restrictions, role-overlap guards, shared check/record gate, and the EIP-712
surface all held up under our unit, fuzz, and live-fork testing. Everything
we'd flag is deployment configuration, not code: grant `RECORDER_ROLE` to the
executor (it cannot record today), grant an enforcer (freeze is uncallable
today), split the single-EOA authority before external pilots, and consider
an event on `setAction`. The revocation window is real but closable at the
asset layer — that's the integration we'd like to compare notes on.
