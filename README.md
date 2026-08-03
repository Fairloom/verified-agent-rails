# Verified Agent Rails (VAR)

**Give an AI agent a leash, not your wallet. Enforced by the asset itself.**

An autonomous agent cannot touch compliant finance, because nothing links it to an accountable human and nothing stops it from overspending. VAR fixes both at the layer where it matters: the asset. A human verifies once with World ID, an attestor signs a scoped on-chain mandate (per-transaction cap, cumulative cap, expiry, revocable), and a compliant token refuses to move unless the agent holds a valid mandate. Revoke, and the next transfer reverts. Accountability with one click, enforced by the money, not by the agent's good behavior.

ERC-8004 says who the agent is. ERC-8226 (RAMS) says what it was mandated to do. VAR makes the asset itself enforce it — including the cases the other layers admit they can't: a compromised agent key that bypasses every venue, and the window between a compliance revocation and an enforcer's freeze.

- **Live on Arc testnet (5042002)** — the original VAR stack: `GatedUSD` + `DelegationMirror`, attestor-signed EIP-712 mandates, personhood-rooted principals.
- **First independent ERC-8226 token-side integration** — `GatedUSDRams` enforces Brickken's Regulated Agent Mandate registry (live on Ethereum Sepolia) in the token's own transfer path, and closes both gaps the spec admits. See [the integration guide](docs/rams/INTEGRATION.md).
- **114 Foundry tests** — unit, fuzz, invariant, a narrated compromised-key demo, and fork tests that run against the live RAMS deployment. The fork tests are not optional: without `ETH_SEPOLIA_RPC_URL` the suite fails rather than skipping.

---

## Repo layout

```
contracts/           Foundry project (solc 0.8.26, OZ 5.6.1)
  src/               DelegationMirror, GatedUSD, GatedUSDRams, ServiceSink, MockYieldVault
  src/interfaces/rams/   ERC-8226 interfaces (verbatim from the EIP assets)
  src/rams/          VARComplianceProviderAdapter (VAR attestations behind IComplianceProvider)
  test/              13 suites; test/demo/CompromisedKey.t.sol is the narrated demo
  test/rams-artifacts/   prebuilt ERC-8226 reference bytecode for the tests
  lib/rams-reference/    vendored EIP reference implementation (read-only)
  script/            Deploy.s.sol (Arc), DeployRamsIntegration.s.sol (Ethereum Sepolia)
agent/               agent scripts (Dynamic MPC wallet driver)
web/                 Next.js dashboard + API routes (no separate backend)
shared/addresses.json  address book for both chains, written by the deploy scripts
docs/rams/           ERC-8226 verification trail, integration guide, security review draft
```

## Quickstart

```sh
git clone <repo> && cd verified-agent-rails
git submodule update --init --recursive

cd contracts && ETH_SEPOLIA_RPC_URL=<any sepolia rpc> forge test   # 114 passing, 0 skipped

# the compromised-key demo, with narration
forge test --match-contract CompromisedKeyDemo -vv

# fork tests against the live ERC-8226 registry on Ethereum Sepolia
ETH_SEPOLIA_RPC_URL=<any sepolia rpc> forge test --match-contract RamsForkTest -vv
```

Dashboard and agent runbooks are in [`RUN.md`](RUN.md). Make targets for the RAMS work (`make test-rams`, `make demo-compromised-key`, `make deploy-rams`, `make verify-rams`) are in the root [`Makefile`](Makefile).

---

## How it works

Two authorization layers, one composition rule — each answers a different question about the same transfer, and each must pass:

```
Human --World ID (orb)--> AgentBook (World Chain) --lookupHuman--> attestor
                                                                      |
                                          signs EIP-712 Attestation   |
                                                                      v
   Agent (Dynamic MPC wallet)                          DelegationMirror
        |                                                  mandate: caps, expiry,
        |  attempt transfer                                revoked, allowedToken
        v                                                       ^
   GatedUSD._update --calls--> checkTransfer (one VIEW) --------+
        |  reverts with machine-readable reason on fail
        v
   ServiceSink (paid)  /  MockYieldVault (idle funds, on-leash)
```

- **The DelegationMirror leashes the sender**: if `from` is a registered agent, its attestor-signed mandate is enforced no matter who initiated the transfer. Reason codes: `OK, NO_MANDATE, REVOKED, EXPIRED, OVER_CAP, TOKEN_NOT_ALLOWED, OVER_PERIOD_CAP`.
- **RAMS (ERC-8226) leashes the initiator** (`GatedUSDRams` only): if `msg.sender != from`, the transfer is agent-initiated on someone else's balance and requires a valid `(initiator, holder)` mandate in the RAMS registry — checked, compliance-re-verified, and recorded atomically inside the transfer.
- ERC-20 allowance is required regardless. Neither layer replaces it.

Mandates in the mirror can only be created through a registered attestor's EIP-712 signature with a strictly-increasing nonce — no permissionless path, no agent squatting, no reopening a revoked mandate. The asset holds no mandate state; each registry is the single source of its own truth.

Three roles, cleanly separated: principal (the verified human) is not the agent is not the attestor.

---

## The ERC-8226 (RAMS) integration

[ERC-8226](https://eips.ethereum.org/EIPS/eip-8226) is Brickken's Draft standard for compliance-delegated agent mandates. VAR ships the first independent token-side integration, built against the EIP reference implementation and verified against the team's live deployment on **Ethereum Sepolia (11155111)** — which we confirmed is bytecode-identical to the reference ([verification trail](docs/rams/verification-status.md), [deployed-vs-spec diff](docs/rams/deployed-vs-spec.md)).

What `GatedUSDRams` adds on top of the registry, in code:

1. **Strict mode** (constructor immutable): every non-holder `transferFrom` needs a mandate — the spec-permitted hard line. Permissive mode (the spec example's allowance fall-through) is also implemented for comparison, and a mandated pair is enforced in *both* modes, so a leftover approval never becomes a cap end-run.
2. **Execution-path compliance**: the registry checks the ComplianceProvider only at grant time; this token re-checks it on every mandated transfer. The spec's admitted `PrincipalRevoked → freezeAgent` window is zero blocks here.
3. **Atomic cap accounting**: `recordExecution` runs inside the transfer and reverts on breach.
4. **Dual-layer failure diagnosis**: distinct machine-readable errors per layer (mirror codes, `RAMS_*` codes, provider `ReasonCode`s), plus free pre-flight views (`canTransferBy`, `ramsDiagnose`).

The [compromised-key demo](contracts/test/demo/CompromisedKey.t.sol) tells the whole story in three scenarios: the executor happy path, a stolen agent key bypassing the executor and hitting the same caps at the asset, and a compliance revocation blocking in the same block with no enforcer anywhere. Run it:

```sh
make demo-compromised-key
```

A [draft security review](docs/rams/security-review-draft.md) of the live deployment (private, peer-tone) accompanies the integration.

---

## Deployed on Arc (chainId 5042002)

The VAR stack is deployed on Arc testnet and its state is readable right now. Every
claim below is a live read you can reproduce; nothing here is quoted from a past run.

| What | Value | Reproduce |
|---|---|---|
| DelegationMirror | `0xAb47D44cb44d5F5b56E6AB976425cE7c861Cd100` (block 46942616) | `cast code <addr> --rpc-url $ARC_TESTNET_RPC_URL` |
| GatedUSD | `0x88b5421Ed0e784A21aBfF121B1a77bd76E9115c3` (block 46942616) | ditto |
| Demo agent | `0x69e170Dd3B22f7C68cDDc31fb402b20f50eDcC54` | `cast call $MIRROR "getMandate(address)" $AGENT` |
| Its mandate | principal `0x18e5B7AF…2110`, cap 10 gUSD/tx, period cap 100 gUSD / 24h, nonce 5, `revoked=false` | ditto |
| **Its current verdict** | **`(false, "EXPIRED")`** — the mandate expired 2026-07-21 14:46 UTC | `cast call $MIRROR "checkTransfer(address,address,uint256)(bool,bytes32)" $AGENT $GUSD 1000000` |

The compliance decision is a single on-chain VIEW call (`checkTransfer`) on the hot
path. No paymaster, no relayer, no off-chain trust on the spend path.

**The demo is not spending today** — the mandate above is expired, and the gate says so.
Re-running the demo requires a fresh attestation with a higher nonce.

> A previous version of this section was a "Proven live on Arc" table citing five demo
> transactions. It has been removed: the hashes were recorded truncated to 8 hex
> characters, appear nowhere else in the repo, and cannot be verified; two of its five
> rows were `checkTransfer` view results rather than transactions at all; and its stated
> parameters (period cap 15, 1h window) do not match the live mandate (100, 24h). The
> enforcement behaviour it described is real and is covered by the test suite — but the
> table was not evidence for it. A known-good pre-enforcement Arc deployment is
> preserved at the `proven-live-v1` git tag.

Contract addresses for both chains live in [`shared/addresses.json`](shared/addresses.json):
the Arc stack at the top level, the Ethereum Sepolia RAMS section under `eth-sepolia`.

---

## Testing

```sh
cd contracts
ETH_SEPOLIA_RPC_URL=… forge test              # the whole suite: 114 tests, 0 skipped
forge test --no-match-contract RamsForkTest   # local only, 109 tests — excludes the
                                              # 5 live-registry tests, deliberately
forge test --match-path 'test/rams/*'         # ERC-8226 integration suites
forge test --match-contract CompromisedKeyDemo -vv
ETH_SEPOLIA_RPC_URL=… forge test --match-contract RamsForkTest -vv
```

Coverage spans the original VAR gate (attestation security, period caps, EIP-712 signer parity, fuzz + stateful invariants) and the RAMS integration (every registry lifecycle state driven through the token, caps-vs-amounts and validity-window fuzz, nonce monotonicity with replay rejection, live-fork ABI conformance). The RAMS reference contracts deploy in tests from prebuilt artifacts — rebuild them with `scripts/build-rams-ref-artifacts.sh` if the vendored reference changes.

## Deploying

```sh
# Arc (original VAR stack)
cd contracts && set -a; source .env; set +a
forge script script/Deploy.s.sol --rpc-url "$ARC_TESTNET_RPC_URL" --broadcast

# Ethereum Sepolia (RAMS integration: mirror + GatedUSDRams strict + adapter)
export DEPLOYER_PRIVATE_KEY=… ETH_SEPOLIA_RPC_URL=…
make deploy-rams        # includes post-deploy sanity checks
make verify-rams MIRROR=… TOKEN=… ADAPTER=…   # Etherscan verification
```

---

## Real vs local (honest scope)

The enforcement path is fully real. Deliberately scoped for now, each with a clear swap point:

| Real today | Scoped for build | Swap point |
|---|---|---|
| World ID orb verification + AgentBook on World Chain | | live |
| Dynamic MPC agent wallet, real on-chain signing | | live |
| Attestor-signed mandates, on-chain enforcement on Arc | | live |
| ERC-8226 enforcement against the live Sepolia registry | | live (fork-verified; deploy pending) |
| | Agent loop driven via orchestration API | autonomous loop next; contracts and identity are agent-ready |
| | Attestor is a single operator key | move behind a Safe multisig |
| | KYC reference (kycRef = 0) | compose a regulated KYC provider into the attestation |

## Standards position

VAR is an asset-layer spending-mandate primitive that composes with the agent-standards stack rather than competing with it. ERC-8004 (Trustless Agents) covers identity, reputation, and validation and leaves payments out of scope. ERC-8118 and MetaMask's ERC-7710/7715 express scoped delegation at the wallet/account layer. ERC-8226 (RAMS) defines the mandate registry and compliance delegation semantics. VAR's contribution is *where* it enforces: at the token, via the ERC-7943 `canTransfer` surface — so the cap holds even if the agent's signing key is fully compromised and every account-layer venue is bypassed. Personhood-rooted principals (World ID) are the second differentiator.

The ERC-8226 integration here is offered as evidence for that position: same mandate semantics, enforced one layer down, with the spec's own admitted gaps closed on the execution path.

## Ecosystem

- **World** — proof-of-human via World ID orb + AgentBook on World Chain; a human-backed agent is the root of every mandate.
- **Dynamic** — the agent acts through a real Dynamic MPC server wallet.
- **Arc / Circle** — settlement in a stablecoin-gated token with the compliance decision as one on-chain view; USDC-native gas.
- **Brickken / ERC-8226** — mandate registry semantics; GatedUSDRams is the token-side counterpart.

## Documentation

| Doc | What's in it |
|---|---|
| [`docs/rams/INTEGRATION.md`](docs/rams/INTEGRATION.md) | Architecture, the strict-mode decision, ten-minute reproduction |
| [`docs/rams/verification-status.md`](docs/rams/verification-status.md) | How the live deployment was located and verified (it's on Ethereum Sepolia, not Base Sepolia) |
| [`docs/rams/deployed-vs-spec.md`](docs/rams/deployed-vs-spec.md) | Bytecode-equivalence proof vs the EIP reference; live role state |
| [`docs/rams/security-review-draft.md`](docs/rams/security-review-draft.md) | DRAFT, private — deployment-config findings for the Brickken team |
| [`RUN.md`](RUN.md) | Full runbook: dashboard, agent scripts, redeploys |

## License

MIT
