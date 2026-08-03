# Running Verified Agent Rails

One Node workspace. The canonical line is the Foundry contracts (`contracts/`), the
Next.js dashboard with its API routes (`web/`), and the agent scripts (`agent/`).
There is no separate backend service; `web/` is frontend plus serverside API routes.

## Prerequisites

- Node 20+ and npm
- Foundry (`forge`) for the contracts
- Arc testnet USDC for gas in the deployer wallet: https://faucet.circle.com
- Env files (all gitignored; see each package's `.env.example`):
  - `contracts/.env`: `DEPLOYER_PRIVATE_KEY`, `ARC_TESTNET_RPC_URL`
  - `agent/.env`: `ATTESTOR_PRIVATE_KEY`, `DYNAMIC_ENVIRONMENT_ID`, `DYNAMIC_API_TOKEN`, `AGENT_WALLET_PASSWORD`, `ARC_TESTNET_RPC_URL`
  - `web/.env.local`: `NEXT_PUBLIC_DYNAMIC_ENVIRONMENT_ID`, `ATTESTOR_PRIVATE_KEY`, `DYNAMIC_ENVIRONMENT_ID`, `DYNAMIC_API_TOKEN`, `AGENT_WALLET_ID`, `GAS_FUNDER_PRIVATE_KEY`

## Install

```sh
npm install
```

## Contracts: test

```sh
# The 5 fork tests require a Sepolia RPC and FAIL (not skip) without one.
cd contracts && ETH_SEPOLIA_RPC_URL=<any sepolia rpc> forge test   # 114 passing, 0 skipped

# Local only, excluding the live-registry tests — deliberate and visible:
cd contracts && forge test --no-match-contract RamsForkTest        # 109 passing
```

## Contracts: deploy to Arc (writes shared/addresses.json)

Already deployed on Arc 5042002 (see `shared/addresses.json`). To redeploy:

```sh
cd contracts
set -a; source .env; set +a
forge script script/Deploy.s.sol --rpc-url "$ARC_TESTNET_RPC_URL" --broadcast

# register the attestor on the new mirror
MIRROR_ADDRESS=<new DelegationMirror> ATTESTOR_ADDRESS=<attestor address> \
  forge script script/SetAttestor.s.sol --rpc-url "$ARC_TESTNET_RPC_URL" --broadcast

# regenerate shared ABIs if the contract surface changed
npm run build:abis -w @var/shared
```

A redeploy rewrites `shared/addresses.json`; commit it. There is no
`npm run deploy:arc` on this line; deployment is `forge script` only.

## Dashboard (http://localhost:3100)

```sh
npm run build -w @var/web
PORT=3100 npm run start -w @var/web
# or dev mode: npm run dev -w @var/web
```

Connect a wallet (Dynamic), grant a mandate, then exercise the gate from the UI.

## Headless proof of the live arc

```sh
npx tsx agent/src/scripts/proveHappyPath.ts
```

Grants an attestor-signed mandate, then the agent's Dynamic MPC wallet pays the
ServiceSink through the gate. Reads the live addresses from `shared/addresses.json`.
