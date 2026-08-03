"use client";

import { useCallback, useEffect, useState } from "react";
import dynamic from "next/dynamic";
import { DynamicWidget, useDynamicContext } from "@dynamic-labs/sdk-react-core";
import { getAddress, isAddress, type Address } from "viem";
import type { ISuccessResult } from "@worldcoin/idkit";
import {
  ACTION,
  APP_ID,
  buildSignal,
  normalizeProof,
  type AgentStatus,
} from "@/lib/worldid";
import { shortAddr } from "@/lib/var";
import { ACTION_CREATE_AGENT, signVarStatement, signerAddress } from "@/lib/wallet";

// World ID modal is browser-only (WASM + window); load it client-side.
const IDKitWidget = dynamic(() => import("@worldcoin/idkit").then((m) => m.IDKitWidget), {
  ssr: false,
});

type Phase = "idle" | "scanning" | "relaying" | "confirming" | "done" | "error";

const card: React.CSSProperties = {
  background: "var(--panel)",
  border: "1px solid var(--border)",
  borderRadius: "var(--r-card)",
  boxShadow: "var(--shadow-e2)",
  padding: "var(--sp-5)",
  width: "100%",
  maxWidth: "520px",
};

const eyebrow: React.CSSProperties = {
  fontFamily: "var(--font-data)",
  fontSize: "var(--type-xs)",
  color: "var(--text-accent)",
  textTransform: "uppercase",
  letterSpacing: "var(--tracking-caps)",
};

const labelStyle: React.CSSProperties = {
  fontSize: "var(--type-xs)",
  color: "var(--muted)",
  textTransform: "uppercase",
  letterSpacing: "var(--tracking-wide)",
};

const inputStyle: React.CSSProperties = {
  width: "100%",
  padding: "var(--sp-2)",
  borderRadius: "var(--r-control)",
  border: "1px solid var(--border-control)",
  background: "var(--panel)",
  color: "var(--text)",
  fontSize: "var(--type-sm)",
  fontFamily: "var(--font-data)",
};

export function RegisterGate({
  defaultAgent,
  onEnter,
}: {
  defaultAgent: Address;
  onEnter: (agent: Address, humanId: string | null, walletId: string | null) => void;
}) {
  const { primaryWallet } = useDynamicContext();
  const [agentInput, setAgentInput] = useState<string>(defaultAgent);
  const [status, setStatus] = useState<AgentStatus | null>(null);
  const [loading, setLoading] = useState(false);
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  // walletId of an agent minted via "Create new agent", so the console can sign
  // pays as it. Cleared when the address is edited by hand (then only the
  // default configured agent can pay).
  const [createdWalletId, setCreatedWalletId] = useState<string | null>(null);

  const valid = isAddress(agentInput);
  const agent = valid ? getAddress(agentInput) : null;

  const fetchStatus = useCallback(async (addr: Address): Promise<AgentStatus | null> => {
    const res = await fetch(`/api/var/agent?address=${addr}`);
    const body = await res.json();
    if (!res.ok) throw new Error(body.error ?? "status lookup failed");
    return body as AgentStatus;
  }, []);

  // Load status whenever a valid agent address is entered.
  useEffect(() => {
    if (!agent) {
      setStatus(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    fetchStatus(agent)
      .then((s) => {
        if (!cancelled) setStatus(s);
      })
      .catch((e) => {
        if (!cancelled) setError((e as Error).message);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [agent, fetchStatus]);

  // World App returned a proof → relay register() → poll until World Chain shows
  // the agent as human-backed.
  const handleProof = useCallback(
    async (result: ISuccessResult) => {
      if (!agent || !status) return;
      setError(null);
      setPhase("relaying");
      const proof = normalizeProof(result);
      if (!proof) {
        setError("Unexpected proof format returned by IDKit.");
        setPhase("error");
        return;
      }
      try {
        const res = await fetch("/api/var/register", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            agent,
            root: result.merkle_root,
            nonce: status.nextNonce,
            nullifierHash: result.nullifier_hash,
            proof,
          }),
        });
        const body = await res.json();
        if (!res.ok) throw new Error(body.error ?? "registration failed");
        setTxHash(body.txHash ?? null);
        setPhase("confirming");

        // Poll World Chain until lookupHuman resolves (relay tx mined).
        const deadline = Date.now() + 90_000;
        for (;;) {
          const s = await fetchStatus(agent);
          if (s?.registered) {
            setStatus(s);
            setPhase("done");
            return;
          }
          if (Date.now() > deadline) {
            setError("Submitted, but World Chain hasn't shown the registration yet. Try Refresh.");
            setPhase("error");
            return;
          }
          await new Promise((r) => setTimeout(r, 3_000));
        }
      } catch (e) {
        setError((e as Error).message);
        setPhase("error");
      }
    },
    [agent, status, fetchStatus],
  );

  // Mint a fresh Dynamic MPC wallet, then drop its address into the field so it
  // can be registered via World ID.
  const handleCreateAgent = useCallback(async () => {
    setCreating(true);
    setError(null);
    try {
      // Minting a wallet spends our Dynamic quota, so it cannot be anonymous
      // (finding 8.1). No mandate exists yet to bind to, so the caller proves
      // control of the connected wallet and that address is recorded as owner.
      const owner = await signerAddress(primaryWallet);
      const issuedAt = Date.now();
      const signature = await signVarStatement(
        primaryWallet,
        ACTION_CREATE_AGENT,
        [["owner", owner.toLowerCase()]],
        issuedAt,
      );
      const res = await fetch("/api/var/create-agent", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ owner, issuedAt, signature }),
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error ?? "could not create agent");
      setAgentInput(body.address as string);
      setCreatedWalletId((body.walletId as string) ?? null);
      setPhase("idle");
      setTxHash(null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setCreating(false);
    }
  }, [primaryWallet]);

  const busy = phase === "relaying" || phase === "confirming";
  const registered = status?.registered ?? false;

  return (
    <main
      style={{
        minHeight: "100vh",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: "var(--sp-4)",
        padding: "var(--sp-5)",
      }}
    >
      <div style={card}>
        <div style={eyebrow}>ERC-5604 · Console</div>
        <h1
          style={{
            margin: "var(--sp-1) 0 0",
            fontFamily: "var(--font-display)",
            fontSize: "var(--type-2xl)",
            fontWeight: 700,
            letterSpacing: "-0.02em",
          }}
        >
          Verified Agent Rails
        </h1>
        <p style={{ margin: "var(--sp-2) 0 var(--sp-5)", color: "var(--muted)", fontSize: "var(--type-base)" }}>
          Before an agent can hold a mandate, prove there is a real, unique human behind it. Scan with
          the World App to register the agent on World Chain.
        </p>

        {/* Step 1 — agent identity */}
        <div style={{ display: "flex", flexDirection: "column", gap: "var(--sp-1)", marginBottom: "var(--sp-4)" }}>
          <label style={labelStyle}>Agent wallet address</label>
          <input
            value={agentInput}
            onChange={(e) => {
              setAgentInput(e.target.value.trim());
              setCreatedWalletId(null); // typed address is not a wallet we can sign for
              setPhase("idle");
              setTxHash(null);
            }}
            spellCheck={false}
            style={inputStyle}
          />
          {!valid && agentInput !== "" ? (
            <span style={{ color: "var(--danger)", fontSize: "var(--type-xs)" }}>
              Not a valid Ethereum address.
            </span>
          ) : null}
          <button
            type="button"
            onClick={handleCreateAgent}
            disabled={creating}
            style={{
              alignSelf: "flex-start",
              background: "none",
              border: "1px solid var(--border-control)",
              borderRadius: "var(--r-control)",
              color: "var(--text-accent)",
              fontSize: "var(--type-xs)",
              fontFamily: "var(--font-ui)",
              fontWeight: 600,
              padding: "var(--sp-1) var(--sp-2)",
              cursor: creating ? "wait" : "pointer",
              marginTop: "var(--sp-1)",
              opacity: creating ? 0.6 : 1,
            }}
          >
            {creating ? "Creating MPC wallet…" : "+ Create new agent wallet"}
          </button>
        </div>

        {/* Status / actions */}
        <div
          style={{
            borderTop: "1px solid var(--border)",
            paddingTop: "var(--sp-4)",
            minHeight: "120px",
            display: "flex",
            flexDirection: "column",
            gap: "var(--sp-3)",
          }}
        >
          {loading ? (
            <span style={{ color: "var(--muted)", fontSize: "var(--type-sm)" }}>
              Checking World Chain…
            </span>
          ) : registered ? (
            <>
              <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-2)" }}>
                <span
                  style={{
                    width: "10px",
                    height: "10px",
                    borderRadius: "50%",
                    background: "var(--success)",
                    flexShrink: 0,
                  }}
                />
                <span style={{ fontWeight: 700, color: "var(--success)", fontSize: "var(--type-lg)" }}>
                  Verified human
                </span>
              </div>
              <div style={{ fontSize: "var(--type-sm)", color: "var(--muted)", fontFamily: "var(--font-data)" }}>
                humanId {shortAddr(status?.humanId ?? undefined)} · World Chain
              </div>
              {txHash ? (
                <div
                  style={{
                    fontSize: "var(--type-xs)",
                    color: "var(--subtle)",
                    fontFamily: "var(--font-data)",
                    wordBreak: "break-all",
                  }}
                >
                  registered tx {txHash}
                </div>
              ) : null}
              <button
                type="button"
                onClick={() => onEnter(agent as Address, status?.humanId ?? null, createdWalletId)}
                style={primaryBtn}
              >
                Enter console →
              </button>
            </>
          ) : agent && status ? (
            <>
              <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-2)" }}>
                <span
                  style={{
                    width: "10px",
                    height: "10px",
                    borderRadius: "50%",
                    background: "var(--warning)",
                    flexShrink: 0,
                  }}
                />
                <span style={{ fontWeight: 700, color: "var(--warning)", fontSize: "var(--type-lg)" }}>
                  Not yet verified
                </span>
              </div>

              {phase === "relaying" || phase === "confirming" ? (
                <span style={{ color: "var(--muted)", fontSize: "var(--type-sm)" }}>
                  {phase === "relaying"
                    ? "Proof received. Relaying register() to World Chain…"
                    : "Submitted. Waiting for World Chain to confirm…"}
                </span>
              ) : (
                <IDKitWidget
                  app_id={APP_ID}
                  action={ACTION}
                  signal={buildSignal(agent, status.nextNonce)}
                  onSuccess={handleProof}
                >
                  {({ open }: { open: () => void }) => (
                    <button type="button" onClick={open} disabled={busy} style={primaryBtn}>
                      Verify with World App
                    </button>
                  )}
                </IDKitWidget>
              )}
              <span style={{ fontSize: "var(--type-xs)", color: "var(--subtle)" }}>
                One World ID human backs one agent. Registration is gasless (hosted relay).
              </span>
            </>
          ) : (
            <span style={{ color: "var(--muted)", fontSize: "var(--type-sm)" }}>
              Enter an agent address to check its status.
            </span>
          )}

          {error ? (
            <div
              style={{
                padding: "var(--sp-2) var(--sp-3)",
                borderRadius: "var(--r-control)",
                background: "var(--danger-soft)",
                color: "var(--danger)",
                border: "1px solid var(--danger)",
                fontSize: "var(--type-xs)",
                fontFamily: "var(--font-data)",
                wordBreak: "break-word",
              }}
            >
              {error}
            </div>
          ) : null}
        </div>

        {/* Wallet — needed later to grant/revoke as principal */}
        <div
          style={{
            marginTop: "var(--sp-4)",
            borderTop: "1px solid var(--border)",
            paddingTop: "var(--sp-4)",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: "var(--sp-3)",
            flexWrap: "wrap",
          }}
        >
          <span style={{ fontSize: "var(--type-xs)", color: "var(--muted)" }}>
            Connect a wallet to grant or revoke once verified.
          </span>
          <DynamicWidget />
        </div>
      </div>
    </main>
  );
}

const primaryBtn: React.CSSProperties = {
  padding: "var(--sp-3)",
  borderRadius: "var(--r-control)",
  border: "1px solid var(--accent)",
  background: "var(--accent)",
  color: "var(--text-on-accent)",
  fontSize: "var(--type-lg)",
  fontWeight: 700,
  fontFamily: "var(--font-ui)",
  cursor: "pointer",
  transition: "background var(--dur-fast) var(--ease-standard)",
};
