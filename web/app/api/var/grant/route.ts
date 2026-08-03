// Server-side grant: an attestor signs a mandate attestation with a key that
// never reaches the browser, and returns it for the client to relay (gas paid by
// the connected wallet, since submitAttestation is permissionless). The EIP-712
// type definition comes from @var/shared, so this signing path matches the
// builder and the contract exactly.
import { NextResponse } from "next/server";
import {
  createPublicClient,
  getAddress,
  http,
  isAddress,
  keccak256,
  toHex,
  zeroHash,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { worldchain } from "viem/chains";
import {
  arcTestnet,
  ADDRESSES,
  ARC_CHAIN_ID,
  ATTESTATION_PRIMARY_TYPE,
  ATTESTATION_TYPES,
  buildDelegationMirrorDomain,
  DELEGATION_MIRROR_ADDRESS,
  DelegationMirrorAbi,
  parseUSDC,
} from "@var/shared";
import { ACTION_GRANT, crossOriginBlocked, proofOfControlInvalid } from "@/lib/sameOrigin";

export const runtime = "nodejs";

const AGENT_BOOK_ADDRESS: Address = "0xA23aB2712eA7BBa896930544C7d6636a96b944dA";
const AGENT_BOOK_ABI = [
  {
    type: "function",
    name: "lookupHuman",
    stateMutability: "view",
    inputs: [{ name: "", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

const PRIVATE_KEY_RE = /^0x[0-9a-fA-F]{64}$/;

export async function POST(req: Request) {
  // This route signs an EIP-712 mandate with a server-held attestor key.
  // Origin is anti-CSRF only; proof of control over `principal` is checked
  // below, once the body is parsed. See finding 8.1 in
  // docs/erc8226/repo-brief.md.
  const blocked = crossOriginBlocked(req);
  if (blocked) return blocked;

  const key = process.env.ATTESTOR_PRIVATE_KEY;
  if (!key || !PRIVATE_KEY_RE.test(key)) {
    return NextResponse.json(
      { error: "Server attestor key not configured. Set ATTESTOR_PRIVATE_KEY in web/.env.local." },
      { status: 500 },
    );
  }

  let body: {
    agent?: string;
    principal?: string;
    spendCap?: string;
    expiryMinutes?: number;
    issuedAt?: number;
    principalSignature?: string;
  };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body." }, { status: 400 });
  }

  if (!body.agent || !isAddress(body.agent)) {
    return NextResponse.json({ error: "Missing or invalid agent address." }, { status: 400 });
  }
  if (!body.principal || !isAddress(body.principal)) {
    return NextResponse.json({ error: "Missing or invalid principal address." }, { status: 400 });
  }
  const agent = getAddress(body.agent);
  const principal = getAddress(body.principal);
  const spendCap = body.spendCap && body.spendCap !== "" ? body.spendCap : "10";
  const expiryMinutes = Number.isFinite(body.expiryMinutes) ? Number(body.expiryMinutes) : 60;

  // Finding 8.1: prove the caller controls `principal` before signing anything
  // with the attestor key. verifyMessage handles EOAs and (via ERC-1271)
  // contract wallets, which matters because Dynamic MPC wallets are used here.
  const proofFailed = await proofOfControlInvalid(
    {
      expectedSigner: principal,
      action: ACTION_GRANT,
      fields: [
        ["agent", agent.toLowerCase()],
        ["principal", principal.toLowerCase()],
        ["spendCap", spendCap],
        ["expiryMinutes", String(expiryMinutes)],
      ],
      issuedAt: body.issuedAt,
      signature: body.principalSignature,
      role: "principal",
    },
    ({ address, message, signature }) =>
      createPublicClient({
        chain: arcTestnet,
        transport: process.env.ARC_TESTNET_RPC_URL ? http(process.env.ARC_TESTNET_RPC_URL) : http(),
      }).verifyMessage({ address, message, signature }),
  );
  if (proofFailed) return proofFailed;

  try {
    // proofRef from the agent's World Chain identity (raw read; lookupHuman is
    // single-arg and the verifier defaults to World Chain).
    const worldClient = createPublicClient({
      chain: worldchain,
      transport: process.env.WORLDCHAIN_RPC_URL ? http(process.env.WORLDCHAIN_RPC_URL) : http(),
    });
    const humanId = await worldClient.readContract({
      address: AGENT_BOOK_ADDRESS,
      abi: AGENT_BOOK_ABI,
      functionName: "lookupHuman",
      args: [agent],
    });
    if (humanId === 0n) {
      return NextResponse.json(
        { error: `Agent ${agent} is not human-backed on World Chain; cannot grant.` },
        { status: 409 },
      );
    }
    const proofRef = keccak256(toHex(humanId, { size: 32 }));

    // Live nonce from the mirror (strictly increasing).
    const arcClient = createPublicClient({
      chain: arcTestnet,
      transport: process.env.ARC_TESTNET_RPC_URL ? http(process.env.ARC_TESTNET_RPC_URL) : http(),
    });
    const lastNonce = await arcClient.readContract({
      address: DELEGATION_MIRROR_ADDRESS,
      abi: DelegationMirrorAbi,
      functionName: "lastNonce",
      args: [agent],
    });
    const nonce = lastNonce + 1n;

    const spendCapPerTx = parseUSDC(spendCap);
    const attestation = {
      agent,
      principal,
      proofRef,
      kycRef: zeroHash as Hex,
      spendCapPerTx,
      spendCapPerPeriod: spendCapPerTx * 10n,
      periodLength: 86_400n,
      allowedToken: ADDRESSES.GatedUSD.address,
      expiry: BigInt(Math.floor(Date.now() / 1000) + expiryMinutes * 60),
      nonce,
    };

    const account = privateKeyToAccount(key as Hex);
    const signature = await account.signTypedData({
      domain: buildDelegationMirrorDomain(DELEGATION_MIRROR_ADDRESS, ARC_CHAIN_ID),
      types: ATTESTATION_TYPES,
      primaryType: ATTESTATION_PRIMARY_TYPE,
      message: attestation,
    });

    // Serialize bigints for the wire; the client revives them before submitting.
    return NextResponse.json({
      attestation: {
        agent: attestation.agent,
        principal: attestation.principal,
        proofRef: attestation.proofRef,
        kycRef: attestation.kycRef,
        spendCapPerTx: attestation.spendCapPerTx.toString(),
        spendCapPerPeriod: attestation.spendCapPerPeriod.toString(),
        periodLength: attestation.periodLength.toString(),
        allowedToken: attestation.allowedToken,
        expiry: attestation.expiry.toString(),
        nonce: attestation.nonce.toString(),
      },
      signature,
      attestor: account.address,
    });
  } catch (e) {
    return NextResponse.json({ error: (e as Error).message }, { status: 500 });
  }
}
