"use client";

import { useState } from "react";
import { DynamicWidget, useDynamicContext } from "@dynamic-labs/sdk-react-core";
import type { Address } from "viem";
import { parseUSDC } from "@var/shared";
import { DEFAULT_AGENT, readAgentFunds, shortAddr } from "@/lib/var";
import { useVar } from "@/lib/useVar";
import {
  faucetMintTo,
  relaySubmitAttestation,
  revokeMandate,
  signVarStatement,
  ACTION_GRANT,
  ACTION_PAY,
  ACTION_FUND_GAS,
  type SignedAttestationWire,
} from "@/lib/wallet";
import { WidgetCard } from "./ui/WidgetCard";
import { MandateWidget } from "./ui/MandateWidget";
import { AgentStatusWidget } from "./ui/AgentStatusWidget";
import { GrantRevokePanel } from "./ui/GrantRevokePanel";
import { TxFeedWidget } from "./ui/TxFeedWidget";
import { RegisterGate } from "./ui/RegisterGate";

export function VarDashboard() {
  const { primaryWallet } = useDynamicContext();
  const connected = !!primaryWallet;

  // Gate: the dashboard is only reachable once the agent is a verified human on
  // World Chain (proven via RegisterGate's World App scan).
  const [entered, setEntered] = useState(false);
  const [activeAgent, setActiveAgent] = useState<Address>(DEFAULT_AGENT);
  const [humanId, setHumanId] = useState<string | null>(null);
  // walletId of a runtime-created agent so the pay route can sign as it; null
  // for the default configured agent (the server uses AGENT_WALLET_ID then).
  const [activeWalletId, setActiveWalletId] = useState<string | null>(null);
  const agent = activeAgent;

  const [amount, setAmount] = useState("25");
  const [spendCap, setSpendCap] = useState("10");
  const [fundBudget, setFundBudget] = useState("50");
  const [expiryMinutes, setExpiryMinutes] = useState("60");
  const [busy, setBusy] = useState<string | null>(null);
  const [toast, setToast] = useState<{ ok: boolean; text: string } | null>(null);

  const { mandate, feed, status, refresh, refreshStatus } = useVar(agent, amount);

  const handleCheck = async () => {
    setBusy("check");
    try {
      await refreshStatus();
    } finally {
      setBusy(null);
    }
  };

  const handleGrant = async () => {
    setBusy("grant");
    setToast(null);
    try {
      const principal = (primaryWallet?.address as Address | undefined) ?? agent;
      // Prove control of `principal` before the server signs anything with the
      // attestor key. Naming an address is not sufficient (finding 8.1).
      const issuedAt = Date.now();
      const principalSignature = await signVarStatement(
        primaryWallet,
        ACTION_GRANT,
        [
          ["agent", agent.toLowerCase()],
          ["principal", principal.toLowerCase()],
          ["spendCap", spendCap],
          ["expiryMinutes", String(Number(expiryMinutes))],
        ],
        issuedAt,
      );
      const res = await fetch("/api/var/grant", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          agent,
          principal,
          spendCap,
          expiryMinutes: Number(expiryMinutes),
          issuedAt,
          principalSignature,
        }),
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error ?? "grant failed");
      const tx = await relaySubmitAttestation(primaryWallet, body as SignedAttestationWire);

      // Provision the agent so it can actually pay. The gUSD budget is minted
      // from the connected wallet (a clean contract call); the tiny native-USDC
      // gas top-up is done server-side (Dynamic's send dialog misrenders Arc's
      // 18-decimal native token, so we keep it out of the wallet UI).
      setToast({ ok: true, text: "Mandate granted. Provisioning the agent…" });
      const funds = await readAgentFunds(agent);
      const budget = parseUSDC(fundBudget && fundBudget !== "" ? fundBudget : "0");
      if (budget > funds.gusd) {
        await faucetMintTo(primaryWallet, agent, budget - funds.gusd);
      }
      const gasIssuedAt = Date.now();
      const gasSignature = await signVarStatement(
        primaryWallet,
        ACTION_FUND_GAS,
        [["agent", agent.toLowerCase()]],
        gasIssuedAt,
      );
      const gasRes = await fetch("/api/var/fund-gas", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ agent, issuedAt: gasIssuedAt, signature: gasSignature }),
      });
      if (!gasRes.ok) {
        const gasBody = await gasRes.json().catch(() => ({}));
        throw new Error(gasBody.error ?? "agent gas top-up failed");
      }

      setToast({ ok: true, text: `Mandate granted & agent funded. tx ${tx}` });
      await refresh();
    } catch (e) {
      setToast({ ok: false, text: (e as Error).message });
    } finally {
      setBusy(null);
    }
  };

  const handlePay = async () => {
    setBusy("pay");
    setToast(null);
    try {
      // The mandate's principal must authorise this exact payment; the amount
      // is inside the signed statement (finding 8.1).
      const payIssuedAt = Date.now();
      const paySignature = await signVarStatement(
        primaryWallet,
        ACTION_PAY,
        [
          ["agent", agent.toLowerCase()],
          ["amount", amount],
        ],
        payIssuedAt,
      );
      const res = await fetch("/api/var/pay", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          agent,
          amount,
          walletId: activeWalletId ?? undefined,
          issuedAt: payIssuedAt,
          signature: paySignature,
        }),
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error ?? "pay failed");
      if (body.blocked) {
        setToast({ ok: false, text: `Gate blocked the payment: ${body.reason} — no funds moved.` });
      } else {
        setToast({ ok: true, text: `Agent paid ${body.amount} gUSD through the gate. tx ${body.txHash}` });
      }
      await Promise.all([refresh(), refreshStatus()]);
    } catch (e) {
      setToast({ ok: false, text: (e as Error).message });
    } finally {
      setBusy(null);
    }
  };

  const handleRevoke = async () => {
    setBusy("revoke");
    setToast(null);
    try {
      const tx = await revokeMandate(primaryWallet, agent);
      setToast({ ok: true, text: `Mandate revoked. tx ${tx}` });
      await refresh();
    } catch (e) {
      setToast({ ok: false, text: (e as Error).message });
    } finally {
      setBusy(null);
    }
  };

  // Hooks above always run; gate the rendered output (Rules of Hooks safe).
  if (!entered) {
    return (
      <RegisterGate
        defaultAgent={DEFAULT_AGENT}
        onEnter={(a, hid, wid) => {
          setActiveAgent(a);
          setHumanId(hid);
          setActiveWalletId(wid);
          setEntered(true);
        }}
      />
    );
  }

  return (
    <main style={{ maxWidth: "1100px", margin: "0 auto", padding: "var(--sp-5)" }}>
      <header
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          gap: "var(--sp-3)",
          marginBottom: "var(--sp-5)",
          flexWrap: "wrap",
        }}
      >
        <div>
          <div
            style={{
              fontFamily: "var(--font-data)",
              fontSize: "var(--type-xs)",
              color: "var(--text-accent)",
              textTransform: "uppercase",
              letterSpacing: "var(--tracking-caps)",
              marginBottom: "var(--sp-1)",
            }}
          >
            ERC-5604 · Console
          </div>
          <h1
            style={{
              margin: 0,
              fontFamily: "var(--font-display)",
              fontSize: "var(--type-2xl)",
              fontWeight: 700,
              letterSpacing: "-0.02em",
            }}
          >
            Verified Agent Rails
          </h1>
          <p style={{ margin: "var(--sp-1) 0 0", color: "var(--muted)", fontSize: "var(--type-base)" }}>
            Scoped onchain authority for AI agents, verified by World ID, enforced on Arc.
          </p>
        </div>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: "var(--sp-2)" }}>
          <DynamicWidget />
          <div
            style={{
              display: "inline-flex",
              alignItems: "center",
              gap: "var(--sp-1)",
              padding: "2px var(--sp-2)",
              borderRadius: "var(--r-pill)",
              background: "var(--success-soft)",
              color: "var(--success)",
              fontSize: "var(--type-xs)",
              fontWeight: 600,
            }}
            title={`Agent ${agent} is human-backed on World Chain${humanId ? ` (humanId ${humanId})` : ""}`}
          >
            <span style={{ width: "6px", height: "6px", borderRadius: "50%", background: "var(--success)" }} />
            Verified human · {shortAddr(agent)}
          </div>
          <button
            type="button"
            onClick={() => setEntered(false)}
            style={{
              background: "none",
              border: "none",
              color: "var(--subtle)",
              fontSize: "var(--type-xs)",
              fontFamily: "var(--font-ui)",
              cursor: "pointer",
              padding: 0,
            }}
          >
            ← change agent
          </button>
        </div>
      </header>

      {toast ? (
        <div
          style={{
            marginBottom: "var(--sp-4)",
            padding: "var(--sp-2) var(--sp-3)",
            borderRadius: "var(--r-control)",
            background: toast.ok ? "var(--success-soft)" : "var(--danger-soft)",
            color: toast.ok ? "var(--success)" : "var(--danger)",
            border: `1px solid ${toast.ok ? "var(--success)" : "var(--danger)"}`,
            fontSize: "var(--type-sm)",
            fontFamily: "var(--font-data)",
            wordBreak: "break-all",
          }}
        >
          {toast.text}
        </div>
      ) : null}

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))", gap: "var(--sp-4)" }}>
        <div style={{ display: "flex", flexDirection: "column", gap: "var(--sp-4)" }}>
          <WidgetCard title="Mandate Control">
            <GrantRevokePanel
              mandate={mandate}
              spendCap={spendCap}
              setSpendCap={setSpendCap}
              fundBudget={fundBudget}
              setFundBudget={setFundBudget}
              expiryMinutes={expiryMinutes}
              setExpiryMinutes={setExpiryMinutes}
              onGrant={handleGrant}
              onRevoke={handleRevoke}
              busy={busy}
              connected={connected}
            />
          </WidgetCard>
          <WidgetCard title="Agent Status">
            <AgentStatusWidget
              status={status}
              amount={amount}
              setAmount={setAmount}
              onCheck={handleCheck}
              onPay={handlePay}
              busy={busy === "check"}
              payBusy={busy === "pay"}
            />
          </WidgetCard>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: "var(--sp-4)" }}>
          <WidgetCard title="Active Mandate">
            <MandateWidget mandate={mandate} />
          </WidgetCard>
          <WidgetCard title="Mandate Events">
            <TxFeedWidget feed={feed} />
          </WidgetCard>
        </div>
      </div>
    </main>
  );
}
