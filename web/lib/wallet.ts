"use client";

import type { Address, Hex } from "viem";
import type { Wallet } from "@dynamic-labs/sdk-react-core";
import { isEthereumWallet } from "@dynamic-labs/ethereum";
import { arcTestnet, DelegationMirrorAbi, GatedUSDAbi } from "@var/shared";
import { arcPublic, GUSD, MIRROR } from "./var";

// A raw attestation as it crosses the API boundary: uint fields are decimal
// strings (JSON cannot carry bigint). revive() turns them back into bigints for
// the contract call.
export interface SignedAttestationWire {
  attestation: {
    agent: Address;
    principal: Address;
    proofRef: Hex;
    kycRef: Hex;
    spendCapPerTx: string;
    spendCapPerPeriod: string;
    periodLength: string;
    allowedToken: Address;
    expiry: string;
    nonce: string;
  };
  signature: Hex;
}

function reviveAttestation(a: SignedAttestationWire["attestation"]) {
  return {
    agent: a.agent,
    principal: a.principal,
    proofRef: a.proofRef,
    kycRef: a.kycRef,
    spendCapPerTx: BigInt(a.spendCapPerTx),
    spendCapPerPeriod: BigInt(a.spendCapPerPeriod),
    periodLength: BigInt(a.periodLength),
    allowedToken: a.allowedToken,
    expiry: BigInt(a.expiry),
    nonce: BigInt(a.nonce),
  };
}

// Dynamic gives us a viem WalletClient for the connected EVM wallet. Throws a
// clear message if no EVM wallet is connected.
async function clientFor(primaryWallet: Wallet | null) {
  if (!primaryWallet || !isEthereumWallet(primaryWallet)) {
    throw new Error("Connect an Ethereum wallet (top right) to send the transaction.");
  }
  const walletClient = await primaryWallet.getWalletClient();
  const account = walletClient.account;
  if (!account) throw new Error("Connected wallet has no account.");
  return { walletClient, account };
}

// Prove control of an address before the server acts with a key it holds
// (finding 8.1). The connected wallet is the principal in the dashboard flow.
//
// The action string is part of the signed bytes, so a signature captured from
// one route cannot be replayed against another. Field order must match
// web/lib/sameOrigin.ts varStatement exactly.
export const ACTION_GRANT = "authorize a mandate";
export const ACTION_PAY = "authorize an agent payment";
export const ACTION_FUND_GAS = "authorize a gas top-up";
export const ACTION_CREATE_AGENT = "authorize agent creation";

export async function signVarStatement(
  primaryWallet: Wallet | null,
  action: string,
  fields: Array<[string, string]>,
  issuedAt: number,
): Promise<Hex> {
  const { walletClient, account } = await clientFor(primaryWallet);
  const message = [`VAR: ${action}`, ...fields.map(([k, v]) => `${k}: ${v}`), `issuedAt: ${issuedAt}`].join("\n");
  return walletClient.signMessage({ account, message });
}

/** The address the dashboard signs as; also the principal it names. */
export async function signerAddress(primaryWallet: Wallet | null): Promise<Address> {
  const { account } = await clientFor(primaryWallet);
  return account.address;
}

// Relay a server-signed attestation. submitAttestation is permissionless, so the
// connected wallet only pays gas; the attestor's signature carries the authority.
export async function relaySubmitAttestation(
  primaryWallet: Wallet | null,
  signed: SignedAttestationWire,
): Promise<Hex> {
  const { walletClient, account } = await clientFor(primaryWallet);
  const hash = await walletClient.writeContract({
    account,
    chain: arcTestnet,
    address: MIRROR,
    abi: DelegationMirrorAbi,
    functionName: "submitAttestation",
    args: [reviveAttestation(signed.attestation), signed.signature],
  });
  // Wait for inclusion so a follow-up read reflects the new mandate (writeContract
  // only broadcasts; Arc finality is sub-second).
  await arcPublic.waitForTransactionReceipt({ hash });
  return hash;
}

// Revoke is principal-only: the connected wallet must be the mandate's principal.
export async function revokeMandate(primaryWallet: Wallet | null, agent: Address): Promise<Hex> {
  const { walletClient, account } = await clientFor(primaryWallet);
  const hash = await walletClient.writeContract({
    account,
    chain: arcTestnet,
    address: MIRROR,
    abi: DelegationMirrorAbi,
    functionName: "revoke",
    args: [agent],
  });
  await arcPublic.waitForTransactionReceipt({ hash });
  return hash;
}

// Fund-on-grant: the connected (funded) wallet provisions the agent so it can
// actually spend. faucetMint gives the agent its gUSD budget; a small native
// USDC transfer covers the agent's gas (Arc gas is native USDC). Both are paid
// by the connected wallet, sidestepping the agent's gas chicken-and-egg.
export async function faucetMintTo(
  primaryWallet: Wallet | null,
  agent: Address,
  amount: bigint,
): Promise<Hex> {
  const { walletClient, account } = await clientFor(primaryWallet);
  const hash = await walletClient.writeContract({
    account,
    chain: arcTestnet,
    address: GUSD,
    abi: GatedUSDAbi,
    functionName: "faucetMint",
    args: [agent, amount],
  });
  await arcPublic.waitForTransactionReceipt({ hash });
  return hash;
}

export async function sendNativeToAgent(
  primaryWallet: Wallet | null,
  agent: Address,
  value: bigint,
): Promise<Hex> {
  const { walletClient, account } = await clientFor(primaryWallet);
  const hash = await walletClient.sendTransaction({
    account,
    chain: arcTestnet,
    to: agent,
    value,
  });
  await arcPublic.waitForTransactionReceipt({ hash });
  return hash;
}
