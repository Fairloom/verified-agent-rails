// Top up the agent's native USDC (gas) so it can sign its own gated spends.
// Done server-side from a funder key (the deployer treasury) rather than the
// connected wallet, because Dynamic's send-confirm dialog misrenders Arc's
// 18-decimal native token (shows it with 6 decimals -> an alarming amount). The
// gUSD budget still comes from the user's wallet; only this tiny gas top-up is
// server-funded. No-op if the agent already has enough gas.
import { NextResponse } from "next/server";
import {
  createPublicClient,
  createWalletClient,
  getAddress,
  http,
  isAddress,
  parseEther,
  zeroAddress,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet, DELEGATION_MIRROR_ADDRESS, DelegationMirrorAbi } from "@var/shared";
import { ACTION_FUND_GAS, crossOriginBlocked, proofOfControlInvalid } from "@/lib/sameOrigin";

export const runtime = "nodejs";

const PRIVATE_KEY_RE = /^0x[0-9a-fA-F]{64}$/;
const GAS_MIN = parseEther("0.02"); // top up only if the agent is below this
const GAS_TOPUP = parseEther("0.05"); // ~100x a typical Arc tx fee

export async function POST(req: Request) {
  const blocked = crossOriginBlocked(req);
  if (blocked) return blocked;

  const key = process.env.GAS_FUNDER_PRIVATE_KEY;
  if (!key || !PRIVATE_KEY_RE.test(key)) {
    return NextResponse.json(
      { error: "Gas funder not configured. Set GAS_FUNDER_PRIVATE_KEY in web/.env.local." },
      { status: 500 },
    );
  }

  let body: { agent?: string; issuedAt?: number; signature?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }
  if (!body.agent || !isAddress(body.agent)) {
    return NextResponse.json({ error: "Missing or invalid agent address." }, { status: 400 });
  }
  const agent = getAddress(body.agent);

  const transport = process.env.ARC_TESTNET_RPC_URL ? http(process.env.ARC_TESTNET_RPC_URL) : http();
  const pub = createPublicClient({ chain: arcTestnet, transport });
  try {
    // Only fund agents that already hold a mandate. Mandates are attestor-gated,
    // so an attacker can't fabricate one — this binds the funder's spend to
    // legitimately-granted agents and prevents draining it to arbitrary
    // addresses. (In the grant flow the mandate exists before this is called.)
    const mandate = await pub.readContract({
      address: DELEGATION_MIRROR_ADDRESS,
      abi: DelegationMirrorAbi,
      functionName: "getMandate",
      args: [agent],
    });
    if (mandate.principal === zeroAddress) {
      return NextResponse.json(
        { error: "Agent has no mandate; nothing to fund. Grant first." },
        { status: 403 },
      );
    }

    // Finding 8.1: the mandate's existence bounds WHICH agents can be funded,
    // but not WHO may trigger it. Without this, anyone could drain the funder
    // in GAS_TOPUP increments across every mandated agent. Require the
    // mandate's own principal -- the party that granted the leash and holds the
    // kill switch -- to have signed this exact request.
    const unauthorized = await proofOfControlInvalid(
      {
        expectedSigner: mandate.principal,
        action: ACTION_FUND_GAS,
        fields: [["agent", agent.toLowerCase()]],
        issuedAt: body.issuedAt,
        signature: body.signature,
        role: "mandate principal",
      },
      ({ address, message, signature }) => pub.verifyMessage({ address, message, signature }),
    );
    if (unauthorized) return unauthorized;

    const balance = await pub.getBalance({ address: agent });
    if (balance >= GAS_MIN) {
      return NextResponse.json({ funded: false, reason: "already has gas", balance: balance.toString() });
    }
    const account = privateKeyToAccount(key as Hex);
    const wallet = createWalletClient({ account, chain: arcTestnet, transport });
    const hash = await wallet.sendTransaction({ account, chain: arcTestnet, to: agent, value: GAS_TOPUP });
    await pub.waitForTransactionReceipt({ hash });
    return NextResponse.json({ funded: true, txHash: hash });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 502 });
  }
}
