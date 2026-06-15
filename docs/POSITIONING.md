# VAR — Positioning

> Working strategy doc. How VAR is differentiated, who it competes with, and how it
> earns the canonical-reference position under an MIT license. Sourced from two
> adversarially-verified research passes (2026-06); claims below carry their support.

## The one sentence

**VAR enforces a human's scoped, revocable spending mandate for an AI agent at the
*asset layer* (a gated ERC-20 via ERC-7943 `canTransfer`), rooted in *biometric
proof-of-personhood* (World ID) — so the cap holds even if the agent's signing key is
fully compromised, and the authority traces to an accountable human.**

Everything else in the space enforces at the wallet/account/signature layer. That one
architectural difference, plus personhood rooting, is the whole moat. Lead with it.

## What is NOT the differentiator (be honest about this internally)

The research killed three things we might be tempted to claim as novel:

- **The onchain scoped-mandate pattern is published.** TIVA (arXiv 2511.15712) already
  describes onchain, scoped, signed-mandate verification. "Revocable, capped, onchain
  mandate" is not new ground.
- **A competing EIP already exists.** ERC-8118 (Agent Authorization, WORLD3, Jan 2026)
  specifies scoped/revocable/capped onchain authorization via EIP-712, and is
  co-developing an x402 payment companion with the ERC-8004 authors. Do **not**
  self-number a rival EIP — contribute the asset-layer enforcement piece into that line.
- **MetaMask ships a delegation stack.** Smart Accounts Kit (ERC-7710/7715, "caveat
  enforcers") does scoped, capped, revocable delegation and is marketed for AI agents.
  Note: ERC-7710 is **not** smart-account-only — it works with EOAs too, so we can't
  wave it off as "only for smart accounts."

## The competitive map

| Layer | Who owns it | What it answers |
|---|---|---|
| Identity / trust | ERC-8004 (Trustless Agents); World AgentKit | "Who is behind this agent?" |
| Authorization (account/signature layer) | ERC-8118; MetaMask 7710/7715; Google AP2 signed mandates | "Is this action permitted?" — checked by the wallet/account |
| Payment rails | x402 (Coinbase, → Linux Foundation); AP2 (Google → FIDO); ACP; Skyfire; Nevermined | "How does value move?" |
| **Authorization (asset layer) ← VAR** | **VAR / DelegationMirror + GatedUSD (ERC-7943)** | **"Will the *token itself* move?" — holds even if the agent key is compromised** |

ERC-8004 explicitly marks payments out of scope and points to x402 — confirming the
authority/enforcement layer is open. VAR slots there, composing with (not competing
against) identity above and payment rails beside.

## Why asset-layer enforcement is a real, defensible property

Account-layer authorization (8118, MetaMask caveats, AP2) trusts the wallet to refuse a
bad action. If the agent's key/LLM is hijacked, the attacker signs as the agent. VAR's
constraint lives in the token's `_update` hook: a transfer that violates the mandate
reverts regardless of who signed it. Concrete relevance:

- **Prompt-injection containment.** An injected agent (cf. the Grok/X case that drained
  ~$150k from an AI wallet) still cannot exceed the onchain cap. The blast radius is
  bounded by the mandate, not by the agent's good behavior. **This is the single most
  persuasive demo we can ship: a hijacked agent hitting the gate and reverting `OVER_CAP`.**
- **Key compromise containment.** MPC-wallet or session-key theft does not unlock
  unlimited spend; the cap is external to the signer.

Honest limits to state up front (credibility comes from naming them): asset-layer
enforcement only covers transfers of the *gated* token. It does not by itself constrain
ungated assets (native gas), or non-token actions. Full threat model, the verified
"sound to best-in-class" verdict, the reference checklist (VAR meets items 1–10), and the
containment boundary are in [SECURITY.md](./SECURITY.md).

## The standards play (revised)

1. **Drop ERC-8226 (RAMS).** Could not be substantiated as an adopted spec; we were
   anchoring to a ghost. Done in code/README — vocabulary now follows ERC-8004 / 8118.
2. **Engage ERC-8118 + the x402 companion working group** (8118 author + 8004 authors)
   as the *asset-layer-enforcement reference implementation*, not a rival. Our name goes
   on the canonical line without forking the community.
3. **Be the reference implementation others cite**: best-in-class docs, a live Arc demo,
   an importable SDK, audited security properties. Authors and reference impls — not EIP
   editors — are the durable owners of a standard.
4. **Trademark the name** (legally distinct from MIT). Stops a same-name clone; the
   durable defense against an honest rebrand is being first, owning the reference, and
   holding the contributor community.
5. **Foundation donation is a capstone, not an opener.** Donating cedes real control
   (verified: originators do *not* retain de-facto authorship post-donation). Build
   authorship + adoption + community first.

## Framing the long-term vision (doors, voting) — handle with care

The food-money use case is the strength. The physical-access and voting extensions are a
**liability if led with**, and the risk audit gives a principled boundary: **the primitive
generalizes only to authorities whose worst-case failure is recoverable.** Money is
capped and recoverable → shippable. A cast vote is irreversible ("no means to make voters
whole again after a compromised election," MIT/Harvard) → an explicit non-goal. Physical
access is intermediate → guarded research track behind hardware fail-safes.

A second audit finding strengthens the *today* product: personhood is already pluggable
in the code (`proofRef`/`kycRef` are generic `bytes32`), so VAR is issuer-agnostic by
construction — World ID is one issuer, not a biometric root. That defuses the Worldcoin
regulatory/centralization critique. Present personhood as a pluggable interface, never as
"requires iris scans."

Rule: **the leash, not the ballot.** Full analysis, tiers, and citations in
[SCOPE-AND-RISK.md](./SCOPE-AND-RISK.md).
