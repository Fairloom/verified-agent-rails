# Verified Agent Rails (VAR)

**Give an AI agent a leash, not your wallet. Enforced by the asset itself.**

An autonomous agent cannot touch compliant finance, because nothing links it to an accountable human and nothing stops it from overspending. VAR fixes both at the layer where it matters: the asset. A human verifies once with World ID, an attestor signs a scoped on-chain mandate (per-transaction cap, cumulative cap, expiry, revocable), and a compliant token refuses to move unless the agent holds a valid mandate. Revoke, and the next transfer reverts. Accountability with one click, enforced by the money, not by the agent's good behavior.

This is the missing primitive next to ERC-8004. ERC-8004 says who the agent is. VAR says what it is allowed to spend, and makes the asset enforce it.

---

## Proven live on Arc (chainId 5042002)

Every leg below is real on Arc this session. Grant, pay, and revoke are settled transactions signed by the real attestor key and the agent's real Dynamic MPC wallet. The cap rows are the on-chain gate verdict (`checkTransfer`, a view), with the `GatedUSD` revert covered by 54 Foundry tests. No mocks on the enforcement path.

| Step | Result | On-chain |
|---|---|---|
| Grant mandate (attestor-signed EIP-712) | AttestationSubmitted + Delegated, cap 10/tx, period cap 15, 1h window | tx 0xcd81d357… |
| Agent pays a service, under cap | settled, ServiceSink.Paid fired, agent 50 to 40, sink 0 to 10 | tx 0x537e1c08… |
| Agent tries to exceed cumulative cap (10+10 > 15) | BLOCKED, OVER_PERIOD_CAP, no funds moved | gate verdict (checkTransfer; revert in 54 tests) |
| Agent tries to exceed per-tx cap (11 > 10) | BLOCKED, OVER_CAP, no funds moved | gate verdict (checkTransfer; revert in 54 tests) |
| Human revokes, next transfer blocked | Revoked event, gate then returns REVOKED | tx 0x11443139… |

The whole compliance decision is a single on-chain VIEW call (`checkTransfer`) on the hot path. No paymaster, no relayer, no off-chain trust on the spend path.

Contracts (Arc testnet, deployBlock 46942608):
- DelegationMirror `0xAb47D44cb44d5F5b56E6AB976425cE7c861Cd100`
- GatedUSD `0x88b5421Ed0e784A21aBfF121B1a77bd76E9115c3`
- MockYieldVault `0x746D4A3c3629DAF333c61b8d48B3ea30bC026f0F`
- ServiceSink `0x0B7EfBaeD5f01E54442c26520A728F859EA6a2bd`

A known-good pre-enforcement deployment is preserved at the `proven-live-v1` git tag.

---

## The demo arc (what a judge sees)

```
①  Agent tries to pay        -> REJECTED, no mandate, the token refuses
②  Human verifies + grants   -> CLEARED, mandate on-chain (caps, expiry)
③  Agent pays a service      -> PAID, settled in stablecoin, on-leash
    Agent tries to overspend  -> BLOCKED, over per-tx cap (OVER_CAP)
    Agent keeps spending      -> BLOCKED, over cumulative cap (OVER_PERIOD_CAP)
④  Human clicks Revoke       -> REVOKED, locked out, next transfer reverts
```

---

## How it works

```
Human --World ID (orb)--> AgentBook (World Chain) --lookupHuman--> attestor
                                                                      |
                                          signs EIP-712 Attestation   |
                                                                      v
   Agent (Dynamic MPC wallet)                          DelegationMirror (Arc)
        |                                                  mandate: caps, expiry,
        |  attempt transfer                                revoked, allowedToken
        v                                                       ^
   GatedUSD._update --calls--> checkTransfer (one VIEW) --------+
        |  reverts with machine-readable reason on fail
        v
   ServiceSink (paid)  /  MockYieldVault (idle funds, on-leash)
```

Three roles, cleanly separated: principal (the verified human) is not the agent is not the attestor.

Reason codes (the gate's machine-readable verdict): OK, NO_MANDATE, REVOKED, EXPIRED, OVER_CAP, TOKEN_NOT_ALLOWED, OVER_PERIOD_CAP.

The mandate can only be created by an attestor's EIP-712 signature with a strictly-increasing nonce. There is no permissionless path: a third party cannot squat an agent or reopen a revoked mandate. The asset holds no mandate state; the mirror is the single source of truth, and the gated token records cumulative spend back to it only for its own attested mandates.

---

## Real vs local (honest scope)

The enforcement path is fully real. Three things are deliberately scoped for the build, each with a clear swap point.

| Real today | Scoped for build | Swap point |
|---|---|---|
| World ID orb verification + AgentBook on World Chain | (real) | live |
| Dynamic MPC agent wallet, real on-chain signing | (real) | live |
| Attestor-signed mandates, on-chain enforcement on Arc | (real) | live |
| Per-tx and cumulative period caps, expiry, revoke | (real) | live |
| | Agent loop driven via orchestration API | autonomous loop is the next step; the contracts and identity are agent-ready |
| | Attestor is a single operator key | move behind a Safe multisig (roadmap) |
| | KYC reference (kycRef = 0) | compose a regulated KYC provider into the attestation |

We would rather show you exactly what is real than overclaim. The leash, the identity, and the signing are real and live; the autonomy and the production trust hardening are the named next steps.

---

## Sponsor tracks

- **World**: proof-of-human via World ID orb + AgentKit AgentBook on World Chain. A human-backed agent is the root of every mandate; no human, no leash.
- **Dynamic**: the agent acts through a real Dynamic MPC server wallet. Every on-chain spend in the proof above was signed by it, not by a deployer key.
- **Arc / Circle**: settlement in a stablecoin-gated token on Arc, with the compliance decision as a single on-chain view on the hot path. USDC-native gas, dual-decimal handling throughout.

---

## Standards position

VAR is an asset-layer spending-mandate primitive that composes with ERC-8004 (Trustless Agents). Where ERC-8004 covers agent identity, reputation, and validation — and explicitly leaves payments out of scope — VAR covers scoped, revocable spend, and is distinguished by *where* it enforces: at the asset. ERC-8118 (Agent Authorization) and MetaMask's ERC-7710/7715 delegation already express scoped, capped, revocable mandates at the wallet/account layer; VAR's contribution is to enforce the same constraint at the token via ERC-7943 `canTransfer`, so the cap holds even if the agent's signing key is fully compromised. Biometric (World ID) rooting of the human→agent binding is the second differentiator; none of the account-layer stacks are personhood-rooted.

Rather than self-number a competing EIP, VAR positions as the open-source reference implementation of asset-layer enforcement and seeks to contribute that layer into the ERC-8118 / ERC-8004 line (and the x402 payment companion being co-developed with the 8004 authors). The spec text here is published openly; any EIP number is community-assigned, not self-numbered.

---

## Run it

```sh
# contracts (54 passing: gate, attestation security, period caps, fuzz)
cd contracts && forge test

# deploy to Arc (already live on 5042002; see shared/addresses.json)
cd contracts && set -a; source .env; set +a
forge script script/Deploy.s.sol --rpc-url "$ARC_TESTNET_RPC_URL" --broadcast

# dashboard on :3100 (Next.js app: frontend + API routes, no separate backend)
npm run build -w @var/web && PORT=3100 npm run start -w @var/web

# headless proof of the live arc
npx tsx agent/src/scripts/proveHappyPath.ts
```

Full run and redeploy steps are in `RUN.md`. Live contract addresses are in `shared/addresses.json`.

## License

MIT
