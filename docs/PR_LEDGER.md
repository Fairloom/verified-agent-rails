# Verified Agent Rails — Pull Request Ledger

**Repo:** [`a-laz/verified-agent-rails`](https://github.com/a-laz/verified-agent-rails) · **Generated:** 2026-06-13 · all times UTC

## Summary
| Metric | Value |
|---|---|
| Total PRs | **4** |
| ✅ Merged | **3** |
| 🟢 Open | **1** (#4) |
| 🔴 Closed (unmerged) | 0 |
| Contributors | 2 — **a-laz** (Laz), **SweePohLee** |
| Net change | **+6,344 / −249** across 4 PRs |
| Target branch | all → `develop` |

## All pull requests
| # | Title | State | Creator | Head → Base | Created | Merged / Closed | Δ (+/−) | Link |
|---|-------|-------|---------|-------------|---------|-----------------|---------|------|
| **4** | docs: PR ledger (all PRs — state, creator, branches) | 🟢 OPEN | SweePohLee | `sweepoh/pr-ledger` → `develop` | 2026-06-13 15:15 | — | +38 / −0 | [#4](https://github.com/a-laz/verified-agent-rails/pull/4) |
| **3** | feat(attestation): EIP-712 attestation builder + dry-run submitter | ✅ MERGED | a-laz (Laz) | `feat/attestation-builder` → `develop` | 2026-06-13 14:26 | 2026-06-13 14:50 | +1331 / −8 | [#3](https://github.com/a-laz/verified-agent-rails/pull/3) |
| **2** | feat(agent): Dynamic MPC agent wallet + World ID AgentBook identity | ✅ MERGED | a-laz (Laz) | `feat/agent-wallet` → `develop` | 2026-06-13 13:53 | 2026-06-13 13:54 | +3926 / −137 | [#2](https://github.com/a-laz/verified-agent-rails/pull/2) |
| **1** | feat: close mandate registry with attestor-signed EIP-712 attestations | ✅ MERGED | a-laz (Laz) | `feat/signed-attestation` → `develop` | 2026-06-13 12:40 | 2026-06-13 12:44 | +1049 / −104 | [#1](https://github.com/a-laz/verified-agent-rails/pull/1) |

## Grouped by state
- **✅ Merged (3):** #1, #2, #3
- **🟢 Open (1):** #4
- **🔴 Closed without merge (0):** —

## Grouped by creator
- **a-laz (Laz):** #1, #2, #3
- **SweePohLee:** #4 — *this ledger*

## What each PR delivered
- **#1 `feat/signed-attestation`** — closes the mandate registry: mandates can only be created via attestor-signed EIP-712 `submitAttestation` (strictly-increasing per-agent nonce); removes the permissionless `delegate()`. (Grew the Foundry suite to 48 tests.)
- **#2 `feat/agent-wallet`** — Dynamic MPC server wallet (`agent/`), `getAgentWallet`, and World ID `AgentBook` identity (registered on **World Chain**, not Base Sepolia).
- **#3 `feat/attestation-builder`** — EIP-712 attestation builder + dry-run submitter (`shared/attestation.ts`, `agent/attestation/*`, hash gate). ⚠️ Flags a BLOCKER: the Arc-deployed `DelegationMirror` is a *pre-EIP-712 build* and needs redeploy before real submits.
- **#4 `sweepoh/pr-ledger`** *(open)* — adds this PR ledger (`docs/PR_LEDGER.md`); docs-only, by SweePohLee.

## Notes
- `AristosMesotes/tao` (the tao verifier repo): **0 PRs** — tao changes land directly on `main` (gated by `tao gate` + `/diff-code-review`) per its own doctrine.
- SweePohLee has push/collaborator access to `a-laz/verified-agent-rails`; PR #4 is the first PR opened from this account.
