# VAR x ERC-8226: independent implementation and review

Prepared for the Brickken team (Ludovico Rossi, Thamer Dridi)
Fairloom / Refi Technologies · Alex Lazarev
2026-08-03

This covers our ERC-8226 integration, what it deploys, what we found in your Sepolia deployment, and what we found in our own. Findings about our code are included at the same level of detail as findings about yours. Every claim points to an address, a transaction, a file, or a test.

---

## 1. Summary

We built a token-side ERC-8226 integration on 2026-07-08, from the published spec, with no contact with your team. It is now deployed on Ethereum Sepolia and transacting against your registry at `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e`.

The integration is three contracts: a RAMS-aware ERC-20 (`GatedUSDRams`), an `IComplianceProvider` implementation (`VARComplianceProviderAdapter`), and the delegation registry the adapter reads from (`DelegationMirror`, pre-existing VAR infrastructure).

Two findings on your deployment, both configuration rather than code. Four observations on the spec, three of which we implemented workarounds for and can therefore describe concretely. Five limitations of our own, listed in section 6.

We found no vulnerability in your contract code. The deployed contracts are the reference implementation and the reference held up under our unit, fuzz, and live-fork testing.

---

## 2. What is deployed

Ethereum Sepolia (chainId 11155111). All three source-verified on Etherscan.

| Contract | Address | Deploy block |
|---|---|---|
| GatedUSDRams | `0xd501D68214503Fa03B5179F556029CD15D7f7cAa` | 11411019 |
| VARComplianceProviderAdapter | `0x7302C8ee3E3f53cD85E0BAF1bDe8479DD19575EB` | 11411020 |
| DelegationMirror | `0x415e267C3C2B1835667b4aDda731599a4B847A3b` | 11411018 |

Deploy transactions:

| Contract | Transaction |
|---|---|
| DelegationMirror | `0x20883526bfc9de3b47ee81aaf0da0b10ba7143742f57149b2a1eb45142dca96c` <!-- pragma: allowlist secret --> |
| GatedUSDRams | `0x4ec0afcb1a86d68ac3da6f4ae5f7428d35667524f224648c375c510c9e17af7a` <!-- pragma: allowlist secret --> |
| VARComplianceProviderAdapter | `0x8b5febd3b498db23d35ebfe69d1a13b8de5ac80f15d6666dd96c73183c0b1309` <!-- pragma: allowlist secret --> |

Source: `Fairloom/verified-agent-rails`, branch `feat/rams-8226-integration`, PR #11.

---

## 3. The end-to-end flow against your registry

Nine transactions, blocks 11411035 to 11411044. The two that matter:

| Call | Transaction | Block |
|---|---|---|
| `grantMandate` (your registry) | `0xe5dfe2fbf900d41e0122743bf7a36ab7c4b1bfdd4aa82af6ee3a9ebd9b78ec54` | 11411043 <!-- pragma: allowlist secret --> |
| `transferFrom` (cleared) | `0x796a690853f9c79b71c6dd52892c9e42da447eac9a08fca7329528236869ec6c` | 11411044 <!-- pragma: allowlist secret --> |

Mandate granted on your `AgentMandate` with our adapter as the `complianceProvider`. Agent `0x0358da4d…CF29`, principal `0x6aB89F85…c8fC`.

**The readback.** `cumulativeUsed` (field 11 of the `getMandate` tuple) read at block 11411043, after the grant and before the transfer: `0`. Read at latest: `90000000`. The block boundary isolates the transfer as the cause.

Corroborated by your own event at block 11411044:

```
ExecutionRecorded(agent, principal, action, amount, cumulativeUsed)
emitter  0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e
action   0x23b872dd  (transferFrom)
amount   90000000    cumulativeUsed  90000000
```

**Blocked case**, `0xdfd1877a8e5fed2c910f9ec0bcab93c8409d015ff38ea2cb80feb40931f51d74`, block 11411052, status 0. Reverts `RamsBlocked(agent, holder, reason)` with reason `RAMS_OVER_TX_CAP`. `cumulativeUsed` stayed at 90000000 and the sink balance did not move. <!-- pragma: allowlist secret -->

**On the recorder question.** Thamer confirmed by email that the mandate's asset is accepted implicitly. Verified on chain: `hasRole(RECORDER_ROLE, 0xd501D682…7cAa)` is `false`, and `recordExecution` succeeded anyway. The only path available is the `msg.sender == m.asset` branch. This is now asserted in CI before and after the transfer.

Worth stating for the spec discussion: an outside integrator needs no privileges on the registry to conform. That is a good property and it is not obvious from the spec text alone.

We also confirmed independently that your deployed code is the reference implementation. Rebuilt the vendored reference out-of-tree with the deployed toolchain (solc 0.8.30, optimizer 200, OZ 5.6.1) and diffed runtime bytecode against `eth_getCode`. AgentMandate 9,977 executable bytes with 7 immutables masked, ComplianceProvider 1,727 with 0, AgentExecutor 2,474 with 6. All three identical. Only the 51-byte CBOR metadata tail differs, which carries no semantics.

---

## 4. Findings on your Sepolia deployment

Neither is a vulnerability. Both are configuration, both were sent privately before this document, and both still reproduce.

### 4.1 No RECORDER_ROLE holder

`hasRole(RECORDER_ROLE, ·)` returns false for the deployer, the current admin, and the AgentExecutor. Your executor is neither the mandate's asset nor the principal, so every `AgentExecutor.execute` reverts at the record step. The code enforces the spec correctly; nothing has been granted the role.

### 4.2 No ENFORCER_ROLE holder

`freezeAgent` is uncallable by any address. The spec's mitigation for the `PrincipalRevoked` to freeze window assumes an enforcer exists, so on this deployment that window is currently unbounded.

### 4.3 Timeline, for accuracy

Both roles were granted and then revoked before your email, not after it.

```
ENFORCER_ROLE  → 0x3d51a03b…74b2   granted block 11319144  (0x2acf6f77…)
                                    revoked block 11319177  (0x11ef2c5a…)
RECORDER_ROLE  → AgentExecutor      granted block 11319145  (0x18bdcede…)
                                    revoked block 11319178  (0xed3d2759…)
```

Roughly twelve days before our deploy. Reads like a rehearsal that was rolled back, and we mention it only because the current state matters: nobody holds either role today.

### 4.4 Authority has moved

Registry `DEFAULT_ADMIN_ROLE`, provider `owner()`, and executor owner are all `0x6b0173489007dE9E2e619eccd98E8fa9c610849a`, transferred from `0xB610470a…faf1` after 2026-07-08. Still a single EOA holding all three. Noted as an observation, not a criticism, since ours is worse (section 6.2).

### 4.5 Checked clean

Reentrancy. `canExecute` / `recordExecution` drift, which is impossible given the shared `_mandateAllows` gate. `extendMandate` cannot resurrect a revoked mandate and preserves `cumulativeUsed`. ERC-165 on both interfaces. Nonce monotonicity and deadline handling on signed operations.

---

## 5. Observations on the spec

### 5.1 `canExecute` returns a bare bool

Eight distinct failure branches collapse into `false`. An integrator who fails cannot tell expired from not-yet-valid from action-disabled from frozen from over-per-transaction-cap from over-cumulative-cap, and those demand opposite responses from an agent operator: re-issue, wait, fix a bug, retry smaller, or stop until the next mandate.

Security Considerations asks frontends and agents to pre-verify both layers for clear diagnostics. The interface does not currently give them enough to do that.

Our workaround, `GatedUSDRams.ramsDiagnose`, re-derives the failing check in your evaluation order and returns one of ten `bytes32` reason codes. It is in the blocked transaction above.

The cost is the argument. It needs a second `getMandate` read plus up to three more external calls on the revert path, it works only because the mandate struct is fully public, and it silently rots if your check order ever changes. An integrator should not have to mirror your control flow to tell a user why a transfer failed. A `checkExecute(...) returns (bool, MandateReason)` alongside the existing bool would remove the need.

### 5.2 `checkPrincipal`'s `expiresAt` is discarded

`AgentMandate.sol:69`:

```solidity
(bool eligible,,) = IComplianceProvider(p.complianceProvider).checkPrincipal(p.principal, p.identityRef);
```

Both `reason` and `expiresAt` are dropped, and the `Mandate` struct has no field for the latter. Storing it and checking it in `canExecute` would bound the revocation window to the KYC expiry your provider already publishes, without requiring an enforcer and without an extra runtime external call. It does not solve mid-attestation revocation, so a relay still has work to do.

Our integration takes the other route and re-checks `checkPrincipal` live on the execution path, closing the window to zero blocks at that asset. Both approaches seem worth having: yours would help every integrator, ours works with no registry change.

### 5.3 Revocation and record persistence

Your `revokeMandate` flags rather than deletes, which is correct and is what makes the permissive integration pattern safe. We raise this only because the spec does not require it.

The reference `canTransfer` falls through to plain allowance rules when `getMandate(msg.sender, from).principal == address(0)`. An implementer who deletes the struct on revoke, which is the obvious gas optimization, turns revocation into a permission upgrade for any agent still holding an allowance. We hit exactly this in our own registry design and kept the record for that reason.

A normative line ("MUST NOT delete the mandate record on revoke") or a Security Considerations note would close it.

### 5.4 No per-agent aggregate across principals

`cumulativeUsed` is a field of the per-`(agent, principal)` mandate. An agent holding mandates from N principals has N independent budgets and no ceiling on the sum, and no principal can see or limit the others' exposure.

This may well be the right design, since per-principal caps mean each principal controls only their own risk, and a per-agent aggregate would cut against the segregation properties raised earlier in the Magicians thread. Raising it as a question rather than a defect. If it is deliberate, one sentence in Rationale would save integrators the derivation.

### 5.5 Smaller items

`recordExecution` is callable by the principal directly, so `cumulativeUsed` is not one-to-one with transfers. Integrators reconciling the two should know. Explicitly permitted by the spec, so this is a documentation request.

`expiresAt == 0` on the ineligible branch collides with the "0 means no expiry" convention. Our adapter has the identical pattern, so this is a shared observation.

`setAction` on the executor emits no event, so a wrong `amountIndex` silently mis-gates caps with no off-chain audit trail. Reference-implementation quality item.

---

## 6. Our implementation, and its limits

### 6.1 What it does

`GatedUSDRams.transferFrom` composes two authorization layers keyed on different addresses.

When `msg.sender == from` the agent is spending its own balance. RAMS is skipped, matching your model, where this is not an agent-initiated transfer. VAR's own gate still runs, because it is keyed on `from` and is initiator-independent.

When `msg.sender != from` the RAMS mandate is enforced, then VAR's holder-keyed gate also runs, then the ERC-20 allowance. Three layers.

Each layer covers the case the other passes through. The reason we think this composition is worth reporting: the agent-custodied case, where the agent holds the funds and `msg.sender == from`, is the one your reference `canTransfer` waves through, and it is the primary case for autonomous agent payments. The spec says custody-agnostic in prose and Thamer confirmed that in the thread, but the published integration pattern only demonstrates principal-custodied. We are a working counterexample and would be glad to contribute the second pattern with tests if it is useful.

`VARComplianceProviderAdapter` implements `IComplianceProvider` with ERC-165 and a real `(bool, ReasonCode, uint48)` triple. `expiresAt` comes from live mandate state, saturated rather than truncated at `type(uint48).max`. Principal eligibility maps onto your enum; mandate and spend failures go to a separate `bytes32` channel rather than being forced into `OTHER`.

Suite is 114 tests, 0 skipped, including five fork tests that run against your live deployment. Fork tests fail loudly rather than skipping when no RPC is configured, so the live-registry claims cannot silently go unverified.

### 6.2 Limits, stated plainly

**Personhood is attested, not proven.** `checkPrincipal` enforces a registered attestor's signed assertion that `AgentBook.lookupHuman(agent) == humanId` on World Chain 480, with expiry and revocation, re-checked on every evaluation. The asserted `humanId` binds to the mandate's `proofRef` via `keccak256(bytes32(humanId))`.

The correct claim is "personhood-attested and enforced at evaluation time," not "trustlessly World-ID-verified on-chain." AgentBook is on World Chain mainnet, this adapter is on Ethereum Sepolia, and World Chain settles to Ethereum mainnet, so no canonical state root of 480 exists on Sepolia. No storage proof or bridge can carry `lookupHuman` here. Only deploying the stack on World Chain would earn the stronger claim.

**The attestor is a single key.** `registeredAttestor` is an owner-managed mapping on `DelegationMirror`, `setAttestor` is `onlyOwner`, and the owner is a single EOA with no multisig or timelock. So the personhood attestation, and every eligibility verdict downstream of it, is bounded by one key. Moving attestor management behind a multisig is open work.

**Two `IComplianceProvider` functions are non-functional.** `grantPrincipal` and `revokePrincipal` revert unconditionally, because eligibility lifecycle is delegated to the mirror's attestor-signed flow. The spec declares both without optionality, so this is a deliberate deviation rather than conformance.

**`PrincipalRevoked` is reachable, not automatic.** The adapter now announces supersession inside `bindIdentity` and mirror-revocation or expiry via a permissionless `syncRevocation`, carrying the same `ReasonCode` that `checkPrincipal` returns. But nothing forces the call, so a relay watching only for the event may still miss a revocation until someone syncs. Our own token is unaffected because it re-checks on the execution path. A third party integrating our adapter under the spec's relay pattern should know this.

**Unaudited.** No external review. The token also carries a demo faucet mint and other testnet scaffolding that we would not ship to mainnet.

### 6.3 One thing we caught in our own code during this work

Our `DelegationMirror.revoke()` leaves the mandate nonce unchanged, so the adapter's `bindIdentity` current-attestation test did not reject revoked mandates. Anyone could re-bind a dead mandate, re-emit `PrincipalGranted` for an ineligible principal, and reset the revocation latch so `PrincipalRevoked` fired twice. Fixed, with two regression tests.

Mentioning it because it is the same class of trap as 5.3: state that looks current because one field was not advanced.

---

## 7. What we would like to contribute

Any of these, in whatever order is useful to you.

A PR against the reference implementation adding `expiresAt` to the mandate struct and the corresponding check in `canExecute`, with tests (5.2).

A mandate-axis reason-code view alongside `canExecute`, based on what `ramsDiagnose` already does (5.1).

The agent-custodied integration pattern as a second documented example, with tests (6.1).

Text for the record-persistence clause (5.3).

We would also like to describe this work on the Magicians thread once you have both had a chance to read this, and would rather you see the findings here first.

---

## Appendix: verification commands

Paste-and-run. Every command below was executed against the stated RPC before
this document was sent; the expected output is given inline.

**One prerequisite:** step 2's historical read needs an **archive** node.
`ethereum-sepolia-rpc.publicnode.com` is not archive and returns
`-32000: historical state ... is not available`. `sepolia.drpc.org` serves it.
Everything else works on any Sepolia endpoint.

```sh
RPC=https://sepolia.drpc.org      # archive; required for step 2

REGISTRY=0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e   # your AgentMandate
TOKEN=0xd501D68214503Fa03B5179F556029CD15D7f7cAa      # our GatedUSDRams
AGENT=0x0358da4d5d9324556b3fCA2c5e7fcDeb5612CF29
PRINCIPAL=0x6aB89F85cA075595d94BB0Be545ff54eE796c8fC
RECORDER_ROLE=0xf996da754c790e95d5c7ca3330cfcad529487fe9d1d8edb7afc65076fdf9adb4   # pragma: allowlist secret
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000      # pragma: allowlist secret
MANDATE_TUPLE='getMandate(address,address)((address,uint48,uint48,address,bool,address,bytes32,address,uint256,uint256,uint256,bytes32))'

# 1. our contracts exist  -> long hex, not "0x"
cast code $TOKEN --rpc-url $RPC

# 2. the readback. Field 11 of the tuple is cumulativeUsed.
#    BEFORE, at block 11411043 (after the grant, before the transfer) -> 0
cast call $REGISTRY "$MANDATE_TUPLE" $AGENT $PRINCIPAL --block 11411043 --rpc-url $RPC

#    AFTER, at latest -> 90000000
cast call $REGISTRY "$MANDATE_TUPLE" $AGENT $PRINCIPAL --rpc-url $RPC

# 3. your own event, emitted by your registry
#    -> action topic 0x23b872dd, data decodes to amount 90000000, cumulativeUsed 90000000
cast logs --address $REGISTRY \
  "ExecutionRecorded(address,address,bytes32,uint256,uint256)" \
  --from-block 11411044 --to-block 11411044 --rpc-url $RPC

# 4. our token holds no recorder role -> false
cast call $REGISTRY "hasRole(bytes32,address)(bool)" $RECORDER_ROLE $TOKEN --rpc-url $RPC
#    control, a role that IS held (your DEFAULT_ADMIN_ROLE holder) -> true
cast call $REGISTRY "hasRole(bytes32,address)(bool)" \
  $ADMIN_ROLE 0x6b0173489007de9e2e619eccd98e8fa9c610849a --rpc-url $RPC

# 5. the blocked case -> status 0 (failed)
BLOCKED_TX=0xdfd1877a8e5fed2c910f9ec0bcab93c8409d015ff38ea2cb80feb40931f51d74   # pragma: allowlist secret
cast receipt $BLOCKED_TX --rpc-url $RPC

#    and the reason our diagnostic returns
#    -> false, 0x52414d535f4f5645525f54585f434150... = "RAMS_OVER_TX_CAP"
cast call $TOKEN "canTransferBy(address,address,uint256)(bool,bytes32)" \
  $AGENT $PRINCIPAL 101000000 --rpc-url $RPC
```
