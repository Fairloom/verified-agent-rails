# ERC-8226 (RAMS) Phase 0 Verification Status

**Date:** 2026-07-08
**Status: RESOLVED — Phase 0 gate passed after retargeting.** Both blockers
below were resolved same-day: the VAR repo was provided and cloned, and the
integration was retargeted to Ethereum Sepolia (11155111) where the verified
deployment actually lives (Option 1 below, as recommended). All three
contracts are bytecode-identical to the EIP reference implementation — see
`deployed-vs-spec.md`. The original findings are preserved below.

## 1. Spec and reference implementation: REAL

- ERC-8226 "Regulated Agent Mandate" exists as a Draft Standards Track ERC,
  created 2026-04-12, authored by the Brickken team (Ludovico Rossi et al.).
  https://eips.ethereum.org/EIPS/eip-8226
- The reference implementation exists in the ethereum/ERCs repo under
  `assets/erc-8226/` (IAgentMandate registry, ComplianceProvider reference,
  optional AgentExecutor, ERC-7943/uRWA-20 integration example).
- Ethereum Magicians discussion thread:
  https://ethereum-magicians.org/t/erc-8226-regulated-agent-mandate/28208
  (opened 2026-04-12 by `Ludovico.r`, last author update 2026-06-29).
  **The thread publishes no deployment addresses on any network.**

## 2. BLOCKER A — the stated "Base Sepolia deployment" does not exist on Base Sepolia

The task brief lists these as a Base Sepolia (chain id 84532) deployment:

| Contract           | Address                                      |
|--------------------|----------------------------------------------|
| AgentMandate       | `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e` |
| ComplianceProvider | `0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278` |
| AgentExecutor      | `0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952` |

Checked via the official public RPC `https://sepolia.base.org`
(chain id confirmed `0x14a34` = 84532):

- `eth_getCode` → `0x` (no bytecode) for **all three** addresses
- `eth_getTransactionCount` → 0 and `eth_getBalance` → 0 for all three
- Sourcify (chain 84532): no match for any address
- Blockscout base-sepolia: no contract known at any address

The addresses are completely untouched on Base Sepolia. Also checked Base
mainnet (8453): no code there either.

## 3. The deployment actually lives on ETHEREUM SEPOLIA (11155111), fully verified

The same three addresses hold code on Ethereum Sepolia and are
**source-verified on Etherscan with "Exact Match"**:

| Contract           | Address (eth-sepolia)                        | Etherscan name     | Compiler            |
|--------------------|----------------------------------------------|--------------------|---------------------|
| AgentMandate       | `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e` | AgentMandate       | v0.8.30+commit.73712a01 |
| ComplianceProvider | `0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278` | ComplianceProvider | v0.8.30+commit.73712a01 |
| AgentExecutor      | `0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952` | AgentExecutor      | v0.8.30+commit.73712a01 |

Live on-chain probes of the AgentMandate (read-only `eth_call`):

- `supportsInterface(0x01ffc9a7)` → `true` (ERC-165 present)
- `DOMAIN_SEPARATOR()` → `0xae6058abd18e03ad7b88c512ba9d5d63492ae383ae54e0de103a578b8c90bec7`
- `eip712Domain()` decodes to:
  - name: `RAMS` ✓ (matches spec)
  - version: `1` ✓ (matches spec)
  - **chainId: `11155111`** — Ethereum Sepolia, NOT Base Sepolia
  - verifyingContract: `0xd68e1bb972ca4ef7f5764fbf6d685a6dfc26778e` ✓

So the deployment is real and conforms to the spec's EIP-712 domain — the
task brief simply has the wrong chain. (Same-address deployment across chains
suggests a fresh deployer key with matching nonces, so a future Base Sepolia
deployment at these addresses is plausible, but it has not happened yet.)

Impact if we retarget to Ethereum Sepolia: fork tests need
`ETH_SEPOLIA_RPC_URL` and chain id 11155111; EIP-712 signatures in fork tests
must use chainId 11155111; deploy scripts, `shared/addresses.json`, and all
docs need the chain corrected. Alternatively we wait for / ask Brickken about
an actual Base Sepolia deployment.

## 4. BLOCKER B — the VAR repo is not present in this workspace

The working directory `/Users/user/rams-8226` was **empty** (not a git
repository, no Foundry project, no `src/GatedUSD.sol`, no DelegationMirror,
no attestation layer, no tests). Phases 1–5 all build on existing VAR
contracts, so nothing beyond Phase 0 can proceed until the
`verified-agent-rails` repo is available here (clone it into this directory
or point the session at the correct checkout). The branch
`feat/rams-8226-integration` could not be created for the same reason.

## 5. Verification methods used

- JSON-RPC (`eth_chainId`, `eth_getCode`, `eth_getTransactionCount`,
  `eth_getBalance`, `eth_call`) against `sepolia.base.org`,
  `mainnet.base.org`, `ethereum-sepolia.publicnode.com`
- Etherscan V2 API (blocked: requires API key — none in env; consider adding
  `ETHERSCAN_API_KEY` for source download in Phase 0 rerun)
- Sourcify v2 API and Blockscout API (chains 84532 and 11155111)
- Etherscan web UI for verification status (all three Exact Match on 11155111)
- eips.ethereum.org, ethereum-magicians.org, github.com/ethereum/ERCs for
  spec/reference-implementation existence

## 6. What is needed to proceed

1. The `verified-agent-rails` repo checked out in this directory (Blocker B).
2. A decision on the chain target (Blocker A):
   - **Option 1 (recommended):** retarget integration + fork tests to
     Ethereum Sepolia 11155111 where the verified deployment actually lives;
     deploy GatedUSDRams there too.
   - Option 2: keep Base Sepolia as the deploy target for our contracts, run
     fork tests against Ethereum Sepolia, and note the split in docs.
   - Option 3: hold until Brickken deploys to Base Sepolia.
3. Optional: `ETHERSCAN_API_KEY` in env so the deployed-source-vs-spec diff
   (Phase 0 step 3) can pull full verified sources via API.
