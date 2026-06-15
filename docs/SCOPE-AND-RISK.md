# VAR — Scope, Non-Goals, and Risk

> A serious infrastructure project states what it will **not** do as clearly as what it
> will. This document exists because the same delegation primitive that safely caps an
> agent's *spending* would be dangerous if naively pointed at *votes* or *physical
> locks*. The boundary is principled, not arbitrary, and it is the line that separates a
> credible vision from a reckless one. Sourced from an adversarially-verified research
> pass (2026-06); every load-bearing claim carries a citation.

## The governing principle: recoverability

VAR's safety story is **caps + revocation + recoverability**. A capped, revocable,
*financial* mandate is safe to delegate because financial harm is bounded and
**recoverable** — banks, merchants, and insurers absorb losses, and an over-spend is at
most the cap. The MIT/Harvard election-security analysis draws the line precisely:

> "for elections, there can be no insurance or recourse against a failure of democracy:
> there is no means to make voters whole again after a compromised election" — contrasted
> explicitly with financial systems where losses can be absorbed.
> (Park, Specter, Narula, Rivest — *Journal of Cybersecurity* 2021)

**Therefore the primitive generalizes only to authorities whose worst-case failure is
recoverable.** Money: yes. Irreversible acts (a cast vote, a door opened to an intruder):
no — or only behind hardware fail-safes and human-present confirmation. This single test
decides what we build.

## Scope tiers

### ✅ Tier 1 — Shipping today: scoped agent spending
World-ID-rooted, scoped/revocable/capped onchain spending delegation, enforced at the
asset layer. Worst case is bounded by the mandate and financially recoverable. Defensible.

### 🟡 Tier 2 — Guarded research track: physical access (doors/IoT)
Plausibly shippable **only** with hardware fail-safes, human-present confirmation, and
time-locked/quorum overrides — never as pure software authority. It shares the coercion
("$5 wrench") and irreversibility problems (a door opened to an intruder cannot be
un-opened). *Note: the agent-security/embodied-jailbreak sources for this tier went
unverified in research (rate-limited), so this analysis rests on analogy to the voting
and device-hijack literature and is flagged for a dedicated follow-up.* Frame
conservatively; do not headline.

### ⛔ Tier 3 — Explicit NON-GOAL: delegating votes
VAR does **not** aim to let agents cast votes on legislation or governance. The
election-security consensus is strong and near-unanimous, and it condemns the whole
shape of "an agent votes remotely on your behalf":

- **Coercion & vote-buying.** Remote voting destroys the polling-booth seclusion that
  makes coercion and vote-buying hard; receipt-freeness cannot be guaranteed, enabling
  *automated mass vote-buying.* (Princeton CITP, Appel 2026; EPFL, IEEE S&P 2024;
  MIT/Harvard 2021.)
- **Hijackable endpoints.** Internet voting runs on devices that malware/insiders can
  silently subvert at scale; **an AI agent endpoint is exactly such a hijackable device**,
  and a coerced or prompt-injected agent inherits every one of these failure modes.
  (Princeton CITP 2026; Halderman OmniBallot, USENIX 2021.)
- **Irreversibility.** Per the governing principle above — no recourse, no recovery.
- **Blockchain does not fix this.** The MIT/Harvard analysis is explicit that putting
  voting onchain does not solve the device-and-coercion problem and can slow security
  patching.

Serious academic proposals for AI political delegation exist (e.g. "One Person, One
Bot," Lavi 2025) — we cite them as *a research direction others are exploring*, not as
license to ship. The literature weighs heavily against deployment.

## Personhood is a pluggable issuer, not a biometric root

The audit's strongest critique of the *today* product is that rooting authority in
Worldcoin's Orb imports real liabilities:

- **Regulatory.** Multiple DPAs took enforcement action against Worldcoin for GDPR-grade
  failures (transparency, minors' data, no erasure/withdrawal): Spain & Portugal ordered
  a 90-day halt (Mar 2024); Hong Kong an enforcement notice (May 2024); Germany's BayLDA
  ordered deletion (Dec 2024); Kenya's High Court ordered biometric deletion (May 2025).
  (KU Leuven CiTiP.)
- **Trust.** The Orb is an unverifiable hardware oracle — "even if the software layer is
  perfect and fully decentralized, the Worldcoin Foundation still has the ability to
  insert a backdoor," and one malicious/hacked manufacturer can mint unlimited fake
  identities. (Buterin, 2023.)
- **Non-revocability & coercion.** An iris cannot be rotated like a key; a coerced scan
  cannot be cleanly revoked, and even proponents concede the forced-scan problem is "tough
  to outright prevent." (Buterin, 2023.)
- **It need not be biometric at all.** The peer-reviewed Personhood Credentials paper
  (OpenAI/MIT/Microsoft/Harvard, arXiv 2408.07892) defines privacy-preserving, unlinkable
  human credentials that "[do] not need to be biometrics-based," issuable by "a range of
  trusted institutions."

**VAR's design already answers this.** The `Mandate` struct references personhood as
generic `proofRef` / `kycRef` (`bytes32`) fields — the contract is **issuer-agnostic by
construction**; World ID is the *current* off-chain issuer, not a hardwired root. The
strategic posture is therefore: **present personhood as a pluggable issuer interface**
(World ID as one option among PHCs, government eID, etc.), never as "VAR requires iris
scans." This both defuses the regulatory/centralization critique and is the honest
description of the architecture. The remaining work is keeping the off-chain attestor's
issuer integration swappable and documented.

## One-line framing rules

- **Lead** with capped, revocable, recoverable agent *spending*.
- **Personhood:** "pluggable proof-of-personhood (World ID today, PHCs/eID tomorrow)."
- **Physical access:** "a guarded research direction, only with hardware fail-safes."
- **Voting:** a documented **non-goal** the literature says should not be built.
- The leash, not the ballot.
