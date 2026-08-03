import { NextResponse } from "next/server";

// CSRF / drive-by guard for privileged mutating routes (mint wallet, sign
// mandate, spend). Rejects cross-origin browser requests AND requests with no
// Origin header at all.
//
// READ THIS BEFORE TREATING IT AS AUTHENTICATION -- IT IS NOT.
// Origin is set by browsers; any non-browser client can send whatever it likes
// (`curl -H "Origin: https://your-host"` passes this check trivially). Requiring
// Origin removes drive-by and naive scripted access; it does NOT establish who
// the caller is. Routes that sign with a server-held key MUST additionally call
// requireApiToken() below, which is a real shared-secret credential.
//
// Previously this returned null (ALLOW) when Origin was absent, which admitted
// every non-browser caller including curl. That was finding 8.1 in
// docs/erc8226/repo-brief.md.
export function crossOriginBlocked(req: Request): NextResponse | null {
  const origin = req.headers.get("origin");
  if (!origin) {
    return NextResponse.json(
      {
        error:
          "Missing Origin header. This endpoint does not serve non-browser callers. " +
          "Server-to-server integrations must present the Authorization bearer token.",
      },
      { status: 403 },
    );
  }
  let originHost: string;
  try {
    originHost = new URL(origin).host;
  } catch {
    return NextResponse.json({ error: "Malformed Origin header." }, { status: 403 });
  }
  const host = req.headers.get("host");
  if (host && originHost !== host) {
    return NextResponse.json({ error: "Cross-origin request blocked." }, { status: 403 });
  }
  return null;
}

// Proof that the caller controls the `principal` it is asking us to bind a
// mandate to. This is the substantive half of finding 8.1: `principal` was
// taken verbatim from the request body, so anyone could name any address --
// including a third party's -- and since DelegationMirror.revoke is
// principal-only, whoever names the principal owns the kill switch.
//
// The caller signs a deterministic statement over the exact grant parameters.
// We recover the signer and require it to equal `principal`. A shared bearer
// token would NOT work here: this route is called from the browser
// (VarDashboard is "use client"), so any token it could hold would be public.
//
// Replay is bounded by the issuedAt window; the statement also commits to the
// agent, caps and expiry, so a captured signature cannot be replayed for
// different terms.
export const GRANT_STATEMENT_WINDOW_MS = 5 * 60 * 1000;

// The statement a caller signs. The ACTION is part of the signed bytes, so a
// signature captured from one route cannot be replayed against another -- a
// gas-top-up signature is not a payment authorisation. Field order is fixed and
// must match web/lib/wallet.ts exactly; a mismatch fails every request.
export function varStatement(action: string, fields: Array<[string, string]>, issuedAt: number): string {
  return [`VAR: ${action}`, ...fields.map(([k, v]) => `${k}: ${v}`), `issuedAt: ${issuedAt}`].join("\n");
}

export const ACTION_GRANT = "authorize a mandate";
export const ACTION_PAY = "authorize an agent payment";
export const ACTION_FUND_GAS = "authorize a gas top-up";
export const ACTION_CREATE_AGENT = "authorize agent creation";

/**
 * Require that `expectedSigner` personally signed this exact action with these
 * exact parameters, recently.
 *
 * `verify` is injected so the route supplies its own chain client; viem's
 * verifyMessage handles EOAs and ERC-1271 contract wallets, which matters
 * because the dashboard uses Dynamic MPC wallets.
 */
export async function proofOfControlInvalid(
  p: {
    expectedSigner: string;
    action: string;
    fields: Array<[string, string]>;
    issuedAt?: number;
    signature?: string;
    /** What the signer represents, for the error message. */
    role?: string;
  },
  verify: (args: { address: `0x${string}`; message: string; signature: `0x${string}` }) => Promise<boolean>,
): Promise<NextResponse | null> {
  const role = p.role ?? "principal";
  if (!p.signature || !/^0x[0-9a-fA-F]+$/.test(p.signature)) {
    return NextResponse.json(
      {
        error:
          `Missing signature. The caller must prove control of the ${role} by signing the ` +
          `"${p.action}" statement; naming an address is not sufficient.`,
      },
      { status: 401 },
    );
  }
  if (typeof p.issuedAt !== "number" || !Number.isFinite(p.issuedAt)) {
    return NextResponse.json({ error: "Missing or invalid issuedAt." }, { status: 400 });
  }
  if (Math.abs(Date.now() - p.issuedAt) > GRANT_STATEMENT_WINDOW_MS) {
    return NextResponse.json(
      { error: "Statement expired or clock-skewed; re-sign and retry." },
      { status: 401 },
    );
  }

  const message = varStatement(p.action, p.fields, p.issuedAt);
  let ok = false;
  try {
    ok = await verify({
      address: p.expectedSigner as `0x${string}`,
      message,
      signature: p.signature as `0x${string}`,
    });
  } catch {
    ok = false;
  }
  if (!ok) {
    return NextResponse.json(
      { error: `Signature does not recover to the ${role} (${p.expectedSigner}).` },
      { status: 401 },
    );
  }
  return null;
}
