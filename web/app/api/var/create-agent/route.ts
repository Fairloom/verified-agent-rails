// Mint a fresh Dynamic MPC server wallet to back a new agent, then the gate
// registers it via World ID. Mirrors agent/src/createAgentWallet.ts but is
// non-idempotent (each call is a new wallet) and sources credentials from
// web/.env.local. Server-only; secrets never reach the browser.
import { NextResponse } from "next/server";
import { createPublicClient, getAddress, http, isAddress } from "viem";
import { DynamicEvmWalletClient } from "@dynamic-labs-wallet/node-evm";
import { ThresholdSignatureScheme } from "@dynamic-labs-wallet/core";
import { arcTestnet } from "@var/shared";
import { ACTION_CREATE_AGENT, crossOriginBlocked, proofOfControlInvalid } from "@/lib/sameOrigin";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const blocked = crossOriginBlocked(req);
  if (blocked) return blocked;

  // Finding 8.1. Unlike the other routes there is no mandate to bind to yet --
  // the agent does not exist. So the weakest defensible gate: the caller must
  // prove control of the address it names as `owner`. That does not authorise
  // anything on-chain, but it makes wallet minting non-anonymous and
  // rate-limitable per identity instead of an open faucet on our Dynamic quota.
  let body: { owner?: string; issuedAt?: number; signature?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }
  if (!body.owner || !isAddress(body.owner)) {
    return NextResponse.json({ error: "Missing or invalid owner address." }, { status: 400 });
  }
  const owner = getAddress(body.owner);

  const unauthorized = await proofOfControlInvalid(
    {
      expectedSigner: owner,
      action: ACTION_CREATE_AGENT,
      fields: [["owner", owner.toLowerCase()]],
      issuedAt: body.issuedAt,
      signature: body.signature,
      role: "owner",
    },
    ({ address, message, signature }) =>
      createPublicClient({
        chain: arcTestnet,
        transport: process.env.ARC_TESTNET_RPC_URL ? http(process.env.ARC_TESTNET_RPC_URL) : http(),
      }).verifyMessage({ address, message, signature }),
  );
  if (unauthorized) return unauthorized;

  const environmentId = process.env.DYNAMIC_ENVIRONMENT_ID;
  const apiToken = process.env.DYNAMIC_API_TOKEN ?? process.env.DYNAMIC_AUTH_TOKEN;
  const password = process.env.AGENT_WALLET_PASSWORD;
  if (!environmentId || !apiToken || !password) {
    return NextResponse.json(
      {
        error:
          "Missing Dynamic config in web/.env.local (DYNAMIC_ENVIRONMENT_ID, DYNAMIC_API_TOKEN, AGENT_WALLET_PASSWORD).",
      },
      { status: 500 },
    );
  }

  try {
    const client = new DynamicEvmWalletClient({ environmentId });
    await client.authenticateApiToken(apiToken);

    const { walletMetadata } = await client.createWalletAccount({
      thresholdSignatureScheme: ThresholdSignatureScheme.TWO_OF_TWO,
      // Back the server key share up to Dynamic (password-encrypted) so the
      // wallet stays recoverable for signing without persisting a secret.
      password,
      backUpToDynamic: true,
    });

    const address = walletMetadata.accountAddress;
    if (!isAddress(address)) {
      return NextResponse.json({ error: `Dynamic returned an invalid address: ${address}` }, { status: 502 });
    }
    return NextResponse.json({ walletId: walletMetadata.walletId, address: getAddress(address) });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 502 });
  }
}
