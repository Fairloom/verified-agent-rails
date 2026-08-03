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

export function grantStatement(p: {
  agent: string;
  principal: string;
  spendCap: string;
  expiryMinutes: number;
  issuedAt: number;
}): string {
  return [
    "VAR: authorize a mandate",
    `agent: ${p.agent.toLowerCase()}`,
    `principal: ${p.principal.toLowerCase()}`,
    `spendCap: ${p.spendCap}`,
    `expiryMinutes: ${p.expiryMinutes}`,
    `issuedAt: ${p.issuedAt}`,
  ].join("\n");
}

export async function principalProofInvalid(
  p: {
    agent: string;
    principal: string;
    spendCap: string;
    expiryMinutes: number;
    issuedAt?: number;
    principalSignature?: string;
  },
  verify: (args: { address: `0x${string}`; message: string; signature: `0x${string}` }) => Promise<boolean>,
): Promise<NextResponse | null> {
  if (!p.principalSignature || !/^0x[0-9a-fA-F]+$/.test(p.principalSignature)) {
    return NextResponse.json(
      {
        error:
          "Missing principalSignature. The caller must prove control of `principal` by signing the " +
          "grant statement; naming an address is not sufficient.",
      },
      { status: 401 },
    );
  }
  if (typeof p.issuedAt !== "number" || !Number.isFinite(p.issuedAt)) {
    return NextResponse.json({ error: "Missing or invalid issuedAt." }, { status: 400 });
  }
  const skew = Math.abs(Date.now() - p.issuedAt);
  if (skew > GRANT_STATEMENT_WINDOW_MS) {
    return NextResponse.json(
      { error: "Grant statement expired or clock-skewed; re-sign and retry." },
      { status: 401 },
    );
  }

  const message = grantStatement({
    agent: p.agent,
    principal: p.principal,
    spendCap: p.spendCap,
    expiryMinutes: p.expiryMinutes,
    issuedAt: p.issuedAt,
  });

  let ok = false;
  try {
    ok = await verify({
      address: p.principal as `0x${string}`,
      message,
      signature: p.principalSignature as `0x${string}`,
    });
  } catch {
    ok = false;
  }
  if (!ok) {
    return NextResponse.json(
      { error: "principalSignature does not recover to `principal`." },
      { status: 401 },
    );
  }
  return null;
}
