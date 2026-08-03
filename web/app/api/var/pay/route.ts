// The agent spends, through the gate. The agent's own MPC wallet pays the
// ServiceSink via ServiceSink.pay (approve + pay) so the ServiceSink.Paid event
// fires; the mirror's mandate caps it. We pre-check the mirror's gate
// (checkTransfer) so an over-cap or over-period attempt returns the exact reason
// without a failed tx, then the agent sends the real payment. This is the
// "leash holds even if the agent is compromised" demonstration.
import { NextResponse } from "next/server";
import { createPublicClient, getAddress, http, isAddress, zeroAddress, type Address } from "viem";
import {
  arcTestnet,
  ADDRESSES,
  DELEGATION_MIRROR_ADDRESS,
  DelegationMirrorAbi,
  GatedUSDAbi,
  ServiceSinkAbi,
  decodeReason,
  parseUSDC,
} from "@var/shared";
import { getAgentSigner } from "@/lib/agentWallet.server";
import { ACTION_PAY, crossOriginBlocked, proofOfControlInvalid } from "@/lib/sameOrigin";

export const runtime = "nodejs";

const GUSD: Address = ADDRESSES.GatedUSD.address;
const SERVICE_SINK: Address = ADDRESSES.ServiceSink.address;

function arcPublic() {
  return createPublicClient({
    chain: arcTestnet,
    transport: process.env.ARC_TESTNET_RPC_URL ? http(process.env.ARC_TESTNET_RPC_URL) : http(),
  });
}

export async function POST(req: Request) {
  const blocked = crossOriginBlocked(req);
  if (blocked) return blocked;

  let body: {
    agent?: string;
    amount?: string;
    walletId?: string;
    issuedAt?: number;
    signature?: string;
  };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }
  if (!body.agent || !isAddress(body.agent)) {
    return NextResponse.json({ error: "Missing or invalid agent address." }, { status: 400 });
  }
  const agent = getAddress(body.agent);
  // Optional: sign as a wallet created at runtime ("create new agent" flow).
  // Without it, the server signs as the default configured agent. The
  // address check below rejects any walletId that does not match the agent.
  const walletId = typeof body.walletId === "string" && body.walletId !== "" ? body.walletId : undefined;
  const amount = body.amount && body.amount !== "" ? body.amount : "5";
  const amountWei = parseUSDC(amount);

  const pub = arcPublic();
  try {
    // 0. Finding 8.1: the on-chain leash caps HOW MUCH this can move, but it
    //    does not say WHO may move it. Without this an anonymous caller could
    //    drain the agent's budget to the sink, up to the cap, repeatedly.
    //    Require the mandate's principal to have signed this exact payment.
    //    The amount is inside the signed statement, so a captured signature
    //    cannot be reused for a larger spend.
    const payMandate = await pub.readContract({
      address: DELEGATION_MIRROR_ADDRESS,
      abi: DelegationMirrorAbi,
      functionName: "getMandate",
      args: [agent],
    });
    if (payMandate.principal === zeroAddress) {
      return NextResponse.json({ error: "Agent has no mandate; nothing to authorise." }, { status: 403 });
    }
    const unauthorized = await proofOfControlInvalid(
      {
        expectedSigner: payMandate.principal,
        action: ACTION_PAY,
        fields: [
          ["agent", agent.toLowerCase()],
          ["amount", amount],
        ],
        issuedAt: body.issuedAt,
        signature: body.signature,
        role: "mandate principal",
      },
      ({ address, message, signature }) => pub.verifyMessage({ address, message, signature }),
    );
    if (unauthorized) return unauthorized;

    // 1. Ask the mirror's own gate first — authoritative, never reverts.
    const [ok, reasonRaw] = await pub.readContract({
      address: DELEGATION_MIRROR_ADDRESS,
      abi: DelegationMirrorAbi,
      functionName: "checkTransfer",
      args: [agent, GUSD, amountWei],
    });
    const reason = decodeReason(reasonRaw);
    if (!ok) {
      // The leash holds: report the reason, move no funds.
      return NextResponse.json({ ok: false, blocked: true, reason, amount });
    }

    // 2. Recover the agent's MPC wallet (it must be the sender the gate checks).
    //    A walletId from the request signs as a runtime-created agent; otherwise
    //    the default configured agent. Either way the recovered address must
    //    equal the requested agent, so a wrong/missing walletId is rejected.
    const { walletClient, address: signerAddress } = await getAgentSigner(walletId);
    if (getAddress(signerAddress) !== agent) {
      return NextResponse.json(
        {
          error: walletId
            ? `walletId resolves to ${signerAddress}, not the requested agent (${agent}).`
            : `No walletId given and the configured agent (${signerAddress}) is not the requested agent (${agent}). Pass the created agent's walletId.`,
        },
        { status: 409 },
      );
    }

    // 3. Funding checks with actionable messages (fund via Grant).
    const [gas, gusdBal] = await Promise.all([
      pub.getBalance({ address: agent }),
      pub.readContract({ address: GUSD, abi: GatedUSDAbi, functionName: "balanceOf", args: [agent] }),
    ]);
    if (gas === 0n) {
      return NextResponse.json(
        { error: "Agent has no native USDC for gas. Grant the leash to provision it." },
        { status: 409 },
      );
    }
    if (gusdBal < amountWei) {
      return NextResponse.json(
        { error: "Agent's gUSD balance is below this amount. Grant a larger budget." },
        { status: 409 },
      );
    }

    // 4. The agent pays the service via ServiceSink.pay so ServiceSink.Paid fires.
    //    pay() pulls funds with transferFrom, so the agent approves first; both
    //    calls are agent-signed and the transferFrom (from == agent) hits the
    //    mirror gate, so the mandate still caps the spend.
    const approveHash = await walletClient.writeContract({
      account: walletClient.account!,
      chain: arcTestnet,
      address: GUSD,
      abi: GatedUSDAbi,
      functionName: "approve",
      args: [SERVICE_SINK, amountWei],
    });
    await pub.waitForTransactionReceipt({ hash: approveHash });

    const hash = await walletClient.writeContract({
      account: walletClient.account!,
      chain: arcTestnet,
      address: SERVICE_SINK,
      abi: ServiceSinkAbi,
      functionName: "pay",
      args: [amountWei],
    });
    await pub.waitForTransactionReceipt({ hash });
    return NextResponse.json({ ok: true, reason, amount, txHash: hash, approveTxHash: approveHash, to: SERVICE_SINK });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 502 });
  }
}
