# Exhaustive search: ERC-8226 / RAMS work in this repository

**Date:** 2026-07-28 · **Clone:** `/Users/user/VAR` · **HEAD:** `f7bd69a` (develop)

## Result up front

**RAMS work exists.** It is substantial, complete through a self-declared Phase 5,
and open as PR #11 on GitHub. Recovery command in the Conclusion.

The previous audit (`docs/erc8226/repo-brief.md` §4) concluded no RAMS work existed.
That conclusion was **wrong**. Root cause, stated plainly, in §0.

---

## 0. Why the previous audit missed it

Two independent failures. Both mine.

**Failure 1 — the branch had never been fetched into this clone.** The prior audit ran
`git for-each-ref` and got 17 refs, none matching `rams` or `8226`. That output was
accurate *for the clone as it stood*, and the branch genuinely was not in it: it was
pushed to `origin` on 2026-07-08, three weeks after this clone's last fetch on
2026-06-14. The audit never ran `git fetch`, so it reported the state of a stale clone
as the state of the repository. The very first command in this search —
`git fetch --all --prune --tags` — produced:

```
 * [new branch]      chore/relicense-apache-2.0 -> origin/chore/relicense-apache-2.0
 * [new branch]      feat/rams-8226-integration -> origin/feat/rams-8226-integration
   0855080..493df15  main       -> origin/main
 - [deleted]         (none)     -> origin/sweepoh/invariants
```

**Failure 2 — the prior audit only grepped the working tree, never other refs.** Even
without fetching, `origin/cj` was already in the clone and already contained a
dedicated `docs/verified-agent-rails/research/eip8226.md`. A ref-wide grep would have
surfaced it. The audit's claim that "the string 8226 appears exactly once in the entire
repository" was true only of the checked-out tree at `f7bd69a`, not of the repository.

**A third failure occurred during *this* search and was caught before it propagated.**
My first Tier-1 sweep reported 17 clean zeros. They were fabricated by my own command:
zsh does not word-split unquoted variables, so `git grep -i "$t" $REFS` collapsed 18
refs into a single bogus argument, git aborted with `fatal: ambiguous argument`, and
`2>/dev/null` swallowed the error while `wc -l` dutifully counted zero lines. Every
search in this document was re-run with a zsh array (`REFS=(${(f)"$(...)"})`) and
validated against a known-present term before its results were trusted. Any negative
below that was not preceded by such a positive control should be treated as untested.
(A related zsh trap bit twice more: `$B:contracts/...` applies the `:c` history
modifier and silently eats a character. The brace form `${B}:contracts/...` is used
throughout.)

---

## 1. Refs after fetch

`git for-each-ref --format='%(refname) %(committerdate:iso) %(subject)'` — 18 refs.

| Ref | Date | Subject |
|---|---|---|
| `refs/heads/develop` | 2026-06-14 | chore(deploy): add Fly.io deploy config |
| `refs/heads/feat/agent-wallet` | 2026-06-13 | fix(agent): point lookupHuman proof at World Chain |
| `refs/heads/feat/attestation-bridge` | 2026-06-13 | feat(agent): lookupHuman proof script (Base Sepolia) |
| `refs/heads/feat/attestation-builder` | 2026-06-13 | test(agent): live on-chain proof of happy path |
| `refs/heads/feat/period-enforcement` | 2026-06-13 | chore(shared): regenerate DelegationMirror ABI |
| `refs/heads/feat/signed-attestation` | 2026-06-13 | chore: regenerate shared ABI |
| `refs/heads/main` | 2026-06-13 | chore: remove GitHub Actions workflows |
| `refs/remotes/origin/chore/relicense-apache-2.0` | **2026-06-18** | chore: relicense MIT → Apache-2.0 under Fairloom |
| `refs/remotes/origin/cj` | 2026-06-13 | Add Verified Agent Rails: end-to-end app |
| `refs/remotes/origin/develop` | 2026-06-14 | (= local develop) |
| `refs/remotes/origin/feat/agent-wallet` | 2026-06-13 | (= local) |
| `refs/remotes/origin/feat/attestation-builder` | 2026-06-13 | (= local) |
| `refs/remotes/origin/feat/period-enforcement` | 2026-06-13 | (= local) |
| **`refs/remotes/origin/feat/rams-8226-integration`** | **2026-07-08** | **docs: rewrite README around the two-layer enforcement story** |
| `refs/remotes/origin/feat/signed-attestation` | 2026-06-13 | (= local) |
| `refs/remotes/origin/main` | **2026-06-15** | finalize |
| `refs/remotes/origin/sweepoh/pr-ledger` | 2026-06-13 | docs: add PR #4 to the ledger |
| `refs/tags/proven-live-v1` | — | Live-proven core loop |

**Remote branches with no local counterpart** (4):

- `origin/feat/rams-8226-integration` ← **the RAMS work**
- `origin/chore/relicense-apache-2.0` (relicense to Apache-2.0; unrelated to RAMS)
- `origin/cj` (unrelated root history; RAMS *research*, see §11)
- `origin/sweepoh/pr-ledger`

Also: `origin/main` advanced `0855080..493df15` ("finalize") and
`origin/sweepoh/invariants` was **deleted upstream** (pruned by the fetch).

---

## 2. Search results table

Positive control run before trusting any negative. "pairs" = ref:file matches.

### Tier 1 — all 18 ref tips
`git grep -i -l "<term>" $REFS` where `REFS=(${(f)"$(git for-each-ref --format='%(refname)')"})`

| Term | pairs | Refs with hits |
|---|---|---|
| `8226` | 85 | all 18 (see note) |
| `RAMS` | 117 | all 18 (see note) |
| `IAgentMandate` | 25 | `o/feat/rams-8226-integration`, `o/cj` |
| `IComplianceProvider` | 26 | `o/feat/rams-8226-integration`, `o/cj` |
| `AgentExecutor` | 15 | `o/feat/rams-8226-integration` |
| `grantMandate` | 37 | `o/feat/rams-8226-integration`, `o/cj` |
| `recordExecution` | 33 | `o/feat/rams-8226-integration`, `o/cj` |
| `canExecute` | 16 | `o/feat/rams-8226-integration` |
| `extendMandate` | 19 | `o/feat/rams-8226-integration`, `o/cj` |
| `freezeAgent` | 17 | `o/feat/rams-8226-integration`, `o/cj` |
| `complianceProvider` | 35 | `o/feat/rams-8226-integration`, `o/cj` |
| `identityRef` | 27 | `o/feat/rams-8226-integration`, `o/cj` |
| `maxCumulativeValue` | 12 | `o/feat/rams-8226-integration`, `o/cj` |
| `maxTransactionValue` | 12 | `o/feat/rams-8226-integration`, `o/cj` |
| `cumulativeUsed` | 16 | `o/feat/rams-8226-integration`, `o/cj` |
| **`principalEligibleUntil`** | **0** | **NONE — true negative, only Tier-1 term with zero hits anywhere** |
| `brickken` | 11 | `o/feat/rams-8226-integration`, `o/cj` |

> **Note on `8226` / `RAMS` hitting all 18 refs.** These are substring false positives
> under `-i`. `RAMS` matches `params` (`GetAgentWalletParams` in `agent/src/agentWallet.ts`);
> `8226` matches integrity hashes in `package-lock.json`. Re-run word-boundary
> (`git grep -i -w -l`, package-lock excluded): the real distribution is **1–2 files** on
> every legacy branch (just the `DelegationMirror.sol:10` comment and README), **26–30
> files** on `o/feat/rams-8226-integration`, and **31 files** on `o/cj`.

### Tier 2 — Brickken addresses, all 18 ref tips

| Term | pairs | Refs with hits |
|---|---|---|
| `0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e` (AgentMandate) | 7 | `o/feat/rams-8226-integration` only |
| `0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278` (ComplianceProvider) | 6 | `o/feat/rams-8226-integration` only |
| `0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952` (AgentExecutor) | 6 | `o/feat/rams-8226-integration` only |
| `DfC26778e` (last-8 truncation) | 7 | same as full address — no extra truncated refs |
| `8C02f278` (last-8) | 6 | same |
| `b4B59952` (last-8) | 6 | same |
| `84532` | 27 | 13 refs — **all pre-existing Base Sepolia config, not RAMS** (see §11) |
| `base-sepolia` | 1 | `o/feat/rams-8226-integration` |
| `base sepolia` | 75 | 15 refs — pre-existing prose |

**The Tier-2 addresses were the decisive tool, exactly as predicted.** They appear on
one ref and nowhere else in the repository or its history.

### Locations 2–12

| # | Location | Command | Hits |
|---|---|---|---|
| 2 | Pickaxe (all history) | `git log --all --oneline -S'<term>' --pickaxe-regex -i` | **12 commits** — see §4 |
| 3 | Commit messages | `git log --all --oneline --grep='<term>' -i` | **6 commits** (`rams`), 3 (`8226`), 1 (`compliance`), 2 (`executor`) |
| 3b | Ref names | `git for-each-ref --format='%(refname)' \| grep -iE 'rams\|8226\|mandate\|brickken'` | **1** — `refs/remotes/origin/feat/rams-8226-integration` |
| 4 | Stashes | `git stash list` | **0 stashes.** Nothing to inspect. |
| 5 | Dangling / unreachable | `git fsck --lost-found --unreachable --dangling` | 49 unreachable commits, 7 blobs, 22 trees, **0 dangling**. Each commit patch and each blob body grepped for all Tier-1+Tier-2 terms: **0 hits.** |
| 6 | Reflog | `git reflog --all --date=iso` (189 entries) | **No orphaned RAMS work.** Only `rams` reference is the 2026-07-28 fetch that stored `da8f661`. No reset/rebase discarded RAMS content. |
| 7 | Deleted files | `git log --all --diff-filter=D --name-only --oneline` | 2 deleted files total in all history; **0** match `rams\|8226\|mandate\|compliance\|executor\|adapter\|interfaces/`. |
| 8 | Worktrees | `git worktree list` | **1** — `/Users/user/VAR f7bd69a [develop]`. No additional worktrees. |
| 9 | Untracked | `git status --porcelain -uall`; `git clean -nd` | 2 modified (`VarDashboard.tsx`, `RegisterGate.tsx`), 1 untracked (`docs/erc8226/repo-brief.md` — written by the prior audit). `git clean -nd` → `Would remove docs/erc8226/`. **No untracked RAMS artifacts.** |
| 10 | Non-Solidity artifacts / deps | grep of `package.json`×4 and `package-lock.json` for `brickken\|rams\|8226` | **0 dependencies.** But 4 vendored ABI JSONs exist on the branch — see §5. |
| 11 | GitHub (`gh`) | `gh pr list --state all --limit 100`; `gh api .../branches`; `.../forks` | **PR #11 OPEN.** 10 remote branches, all now fetched. **0 forks.** |
| 12 | Sibling clones | `find ~ -maxdepth 4 -type d -name '.git'` | **`/Users/user/rams-8226`** — second clone, same origin. Reported only, not searched (per instruction). |

---

## 3. The branch: `origin/feat/rams-8226-integration`

- **Tip:** `da8f661`, 2026-07-08 23:39:08 -0400
- **Merge-base with develop:** `f7bd69a` (branches directly off the current HEAD)
- **Size:** `git diff --stat f7bd69a origin/feat/rams-8226-integration` → **51 files changed, 9,346 insertions(+), 103 deletions(-)**
- **GitHub:** PR **#11**, state **OPEN**, opened 2026-07-09T03:43:19Z —
  *"ERC-8226 (RAMS) integration: GatedUSDRams, adapter, compromised-key demo, security review"*

Seven commits, phase-structured:

| SHA | Subject |
|---|---|
| `9ffde3f` | feat(rams): phase 0 — verify ERC-8226 deployment, vendor reference implementation |
| `9eb098f` | feat(rams): phase 1 — spec interfaces and VAR compliance provider adapter |
| `5817b1c` | feat(rams): phase 2 — GatedUSDRams, strict RAMS-aware token |
| `37ca801` | test(rams): phase 3 — unit, compromised-key demo, fork, and fuzz suites |
| `b83898c` | feat(rams): phase 4 — deploy script, address book, Makefile targets |
| `99b6588` | docs(rams): phase 5 — security review draft and integration guide |
| `da8f661` | docs: rewrite README around the two-layer enforcement story |

Every one of the five things the prior audit declared absent is present:

| Prior audit claim | Reality on this branch |
|---|---|
| "`lib/rams-reference/` does not exist" | 16 files under `contracts/lib/rams-reference/`, incl. `erc-8226-spec.md` (539 lines) |
| "`docs/rams/` does not exist" | 4 files: `INTEGRATION.md`, `deployed-vs-spec.md`, `security-review-draft.md`, `verification-status.md` |
| "`IAgentMandate` appears nowhere" | `contracts/src/interfaces/rams/IAgentMandate.sol` (189 lines) + reference copy (184 lines) |
| "`IComplianceProvider` appears nowhere" | `contracts/src/interfaces/rams/IComplianceProvider.sol` (51 lines) + reference copy (46 lines) |
| "only a doc comment mentions 8226" | 26 files match `8226` word-boundary |

---

## 4. Pickaxe: is anything history-only?

`git log --all --oneline -S'<term>' --pickaxe-regex -i` per term. Commits touching RAMS content:

```
da8f661 docs: rewrite README around the two-layer enforcement story
99b6588 docs(rams): phase 5 — security review draft and integration guide
b83898c feat(rams): phase 4 — deploy script, address book, Makefile targets
37ca801 test(rams): phase 3 — unit, compromised-key demo, fork, and fuzz suites
5817b1c feat(rams): phase 2 — GatedUSDRams, strict RAMS-aware token
9eb098f feat(rams): phase 1 — spec interfaces and VAR compliance provider adapter
9ffde3f feat(rams): phase 0 — verify ERC-8226 deployment, vendor reference implementation
493df15 finalize                                    (origin/main)
f4a86cb docs: replace README with VAR pitch          (develop — the one-line comment)
2601200 Add Verified Agent Rails: end-to-end app     (origin/cj — research corpus)
2b3f891 feat: DelegationMirror registry              (develop — the one-line comment)
0d348ae init: verified agent rails                   (earliest root)
```

**Live-vs-history status of every hit:**

| Hit group | Status |
|---|---|
| All 7 phase commits | **LIVE** on `origin/feat/rams-8226-integration` tip |
| `origin/cj` research corpus | **LIVE** on `origin/cj` tip |
| `DelegationMirror.sol:10` comment | **LIVE** on all branch tips |
| — | **Nothing is history-only.** No RAMS content was added and later deleted. |

`principalEligibleUntil` is the single Tier-1 term with **zero hits across every ref
tip, all history, all unreachable objects, and all commit messages.** It does not exist
in this repository in any form. If you remember that identifier, it is from the spec
text or another codebase, not from here.

---

## 5. Hits, with context

### 5.1 Tier-2 addresses — `contracts/test/rams/RamsFork.t.sol:20-32`

`git show "${B}:contracts/test/rams/RamsFork.t.sol"` (B = the branch ref). **LIVE on tip.**

```solidity
///         Gated behind ETH_SEPOLIA_RPC_URL; without it the suite skips.
///         Read-only ABI-conformance checks run first; the state-changing
///         composition test only mutates the local fork.
contract RamsForkTest is Test {
    // Live deployment (Ethereum Sepolia).
    IAgentMandate internal constant LIVE_RAMS = IAgentMandate(0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e);
    IComplianceProvider internal constant LIVE_PROVIDER =
        IComplianceProvider(0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278);
    address internal constant LIVE_EXECUTOR = 0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952;
    // Deployer/admin observed on-chain during Phase 0 verification.
    address internal constant LIVE_ADMIN = 0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1;
    // DOMAIN_SEPARATOR captured during Phase 0 verification.
    bytes32 internal constant EXPECTED_DOMAIN_SEPARATOR =
        0xae6058abd18e03ad7b88c512ba9d5d63492ae383ae54e0de103a578b8c90bec7; // pragma: allowlist secret
```

### 5.2 Tier-2 addresses — `contracts/script/DeployRamsIntegration.s.sol:33-45`

**LIVE on tip.**

```solidity
///   forge verify-contract --chain sepolia <TOKEN> src/GatedUSDRams.sol:GatedUSDRams \
///     --constructor-args $(cast abi-encode "constructor(address,address,bool)" <MIRROR> <REGISTRY> true)
///   forge verify-contract --chain sepolia <ADAPTER> src/rams/VARComplianceProviderAdapter.sol:...
contract DeployRamsIntegration is Script {
    /// Live AgentMandate on Ethereum Sepolia (Brickken, bytecode == EIP reference).
    address internal constant DEFAULT_RAMS_REGISTRY = 0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e;
    address internal constant LIVE_COMPLIANCE_PROVIDER = 0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278;
    address internal constant LIVE_AGENT_EXECUTOR = 0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        IAgentMandate registry = IAgentMandate(vm.envOr("RAMS_REGISTRY", DEFAULT_RAMS_REGISTRY));
```

Full Tier-2 hit list (`git grep -i -n "<addr>" $B`), all **LIVE on tip**:

| File:line | Address |
|---|---|
| `Makefile:11` | AgentMandate |
| `contracts/script/DeployRamsIntegration.s.sol:39,40,41` | all three |
| `contracts/test/rams/RamsFork.t.sol:22,24,25` | all three |
| `docs/rams/deployed-vs-spec.md:22,23,24` | all three |
| `docs/rams/security-review-draft.md:13,14,15` | all three |
| `docs/rams/verification-status.md:30,31,32,52,53,54,64` | all three |
| `shared/addresses.json:20,21,22` | all three |

### 5.3 `contracts/src/GatedUSDRams.sol:1-33` — the integration itself

**LIVE on tip.** 228 lines.

```solidity
import {IAgentMandate} from "./interfaces/rams/IAgentMandate.sol";
import {IComplianceProvider} from "./interfaces/rams/IComplianceProvider.sol";

/// @title GatedUSDRams
/// @notice ERC-8226 (RAMS) aware variant of GatedUSD: the first independent
///         token-side integration of the RAMS registry. The original GatedUSD
///         is untouched and remains the standalone VAR reference; this
///         contract extends it and adds the spec's regulated-asset integration
///         pattern (ERC-8226 "Integration with regulated assets", the
///         ERC-7943 example) in its strict variant.
///
/// # Two authorization layers, one composition rule
///
///  * DelegationMirror gates the **sender**: if `from` is a registered agent,
///    its attestor-signed mandate (caps, expiry, revocation) is enforced by
///    GatedUSD._update regardless of who initiated the transfer.
///  * RAMS gates the **initiator**: if `msg.sender != from`, the transfer is
///    agent-initiated on someone else's balance and needs a valid
///    (msg.sender, from) mandate in the RAMS registry.
```

> Directly relevant to the prior brief: this closes the exact gap flagged as
> `repo-brief.md` §6.2 path 3 (agent spending a third party's approved balance was
> ungated and unrecorded).

### 5.4 `contracts/src/rams/VARComplianceProviderAdapter.sol:1-30` — the ReasonCode mapping

**LIVE on tip.** 139 lines. Supersedes the speculative mapping in `repo-brief.md` §7.

```solidity
/// @notice ERC-8226 IComplianceProvider (spec section "Compliance Provider")
///         fronting VAR's attestation layer. VAR's source of eligibility truth
///         is the DelegationMirror ...
///         The spec requires a structured verdict — a binary oracle is
///         non-conformant — so this adapter returns (eligible, ReasonCode,
///         expiresAt), mapping VAR attestation states onto the spec enum:
///
///           mirror state                          -> ReasonCode
///           -------------------------------------------------------------
///           unknown identityRef / no mandate      -> IDENTITY_NOT_FOUND
///           bound agent's principal != principal  -> IDENTITY_NOT_FOUND
///           binding superseded by newer nonce     -> ATTESTATION_REVOKED
///           mandate revoked by principal          -> ATTESTATION_REVOKED
///           mandate expired                       -> KYC_EXPIRED
///           live mandate                          -> COMPLIANT
```

### 5.5 `docs/rams/verification-status.md:24-45` — the Base Sepolia premise is wrong

**LIVE on tip.** Important correction to the search brief's own premise: the three
Brickken addresses are **not on Base Sepolia**. The branch documents checking and
retargeting.

```markdown
## 2. BLOCKER A — the stated "Base Sepolia deployment" does not exist on Base Sepolia

Checked via the official public RPC `https://sepolia.base.org`
(chain id confirmed `0x14a34` = 84532):

- `eth_getCode` → `0x` (no bytecode) for **all three** addresses
- `eth_getTransactionCount` → 0 and `eth_getBalance` → 0 for all three
- Sourcify (chain 84532): no match for any address
- Blockscout base-sepolia: no contract known at any address

## 3. The deployment actually lives on ETHEREUM SEPOLIA (11155111), fully verified
| AgentMandate  | 0xD68E1bb9…778e | AgentMandate | v0.8.30+commit.73712a01 |
```

`shared/addresses.json` on the branch records them under an `"eth-sepolia"` key with
`"chainId": 11155111`, with `DelegationMirror`, `GatedUSDRams`, and
`VARComplianceProviderAdapter` all `null` — i.e. **our side was never deployed there.**

### 5.6 Vendored ABI artifacts (search location 10)

**LIVE on tip.** Exactly the "ABI JSON before a contract" artifact predicted:

```
contracts/test/rams-artifacts/AgentMandate.json        (1086 lines)
contracts/test/rams-artifacts/uRWA20.json              (1064 lines)
contracts/test/rams-artifacts/AgentExecutor.json        (268 lines)
contracts/test/rams-artifacts/ComplianceProvider.json   (247 lines)
scripts/build-rams-ref-artifacts.sh                      (32 lines)
```

No npm dependency named `brickken`, `rams`, or `8226` exists in any `package.json` or
in `package-lock.json`.

### 5.7 Test files added

```
contracts/test/rams/GatedUSDRams.t.sol                 (306 lines)
contracts/test/rams/RamsTestBase.sol                   (178 lines)
contracts/test/rams/VARComplianceProviderAdapter.t.sol (165 lines)
contracts/test/rams/RamsFork.t.sol                     (143 lines)
contracts/test/rams/RamsFuzz.t.sol                     (139 lines)
contracts/test/demo/CompromisedKey.t.sol               (158 lines)
```

`docs/rams/INTEGRATION.md:18` claims *"63 pre-existing VAR tests + 36 RAMS integration
tests"*. The 63 matches the count I measured independently on `develop`. **I did not
check out the branch or run its suite**, so the 36 is an unverified claim from the
branch's own docs.

---

## 6. Conclusion

**RAMS work exists. Here is where.**

| What | Where |
|---|---|
| Primary body of work | `origin/feat/rams-8226-integration` @ `da8f661` |
| Size | 51 files, +9,346 / −103 vs `f7bd69a` |
| GitHub | PR **#11**, **OPEN**, since 2026-07-09 |
| Secondary (research only) | `origin/cj` @ `2601200` — `docs/verified-agent-rails/research/eip8226.md` |
| History-only / recoverable-from-dangling | **None.** Everything is live on a ref tip. |
| Second clone, not yet searched | `/Users/user/rams-8226` |

### Recovery commands

```sh
# Inspect without disturbing the current tree:
git log --oneline origin/feat/rams-8226-integration --not develop
git diff --stat f7bd69a origin/feat/rams-8226-integration

# Check it out locally (branch is remote-only; this creates the local tracking branch):
git checkout -b feat/rams-8226-integration origin/feat/rams-8226-integration
git submodule update --init --recursive   # lib/rams-reference is vendored

# Or review in place on GitHub:
gh pr view 11 --web

# Or extract a single file without checking out (note the ${B} braces — zsh eats $B:c):
B=refs/remotes/origin/feat/rams-8226-integration
git show "${B}:contracts/src/GatedUSDRams.sol" > /tmp/GatedUSDRams.sol
git show "${B}:docs/rams/INTEGRATION.md" > /tmp/INTEGRATION.md
```

The working tree is currently modified (`VarDashboard.tsx`, `RegisterGate.tsx`) and has
one untracked file (`docs/erc8226/`). Commit, stash, or accept carrying them before
checking out.

### Immediate correction required

`docs/erc8226/repo-brief.md` §4 ("ERC-8226 integration status") is **false in its
entirety** and its §11 "Safe public claims" item 11 asserts the same falsehood. Do not
post anything built on it. §7's ReasonCode mapping was reasoned from first principles
and is superseded by the real mapping in `VARComplianceProviderAdapter.sol` (§5.4
above). Several §8 weaknesses — notably §6.2 path 3 — are addressed by `GatedUSDRams`.

---

## 7. Adjacent work that is not the RAMS integration

Listed because you may be remembering one of these instead of, or in addition to, PR #11.

| Item | Ref | What it is |
|---|---|---|
| **RAMS research dossier** | `origin/cj` @ `2601200` | Unrelated root history (**no merge-base with develop**). 31 files match `8226`, incl. a dedicated `docs/verified-agent-rails/research/eip8226.md` tracing a 5-round verification of whether ERC-8226 exists, pinning `isActiveForAmount` and PR #1679 @ `3edf21b`. Research and architecture only — **no integration code.** |
| **`EligibilityResolver.sol`** | `origin/cj` | A *second registry*, separate from `DelegationMirror`. Header at line 8 reads: *"VAR's self-defined eligibility resolver. NOT 'ERC-8226' (which does not…"* — written when 8226 was believed not to exist. Line 115: *"ERC-8226-SHAPED wrapper documenting the composition."* Adjacent, pre-dates the real integration. |
| **`origin/chore/relicense-apache-2.0`** | 2026-06-18 | Relicense MIT → Apache-2.0 under Fairloom. Remote-only, **open as PR #10**. Nothing to do with RAMS, but it is unmerged work you may be carrying. |
| **`origin/main` moved** | `0855080..493df15` | Advanced to "finalize" on 2026-06-15; this clone was 3 commits behind. |
| **`origin/sweepoh/invariants`** | deleted upstream | Pruned by this fetch. Its content is merged (commit `f00596f`, PR #5). |
| **`feat/attestation-bridge`** | local only, 2026-06-13 | Local-only branch, never pushed. Touches the AgentBook lookup on Base Sepolia — this is the origin of most `84532` hits, and is **not** RAMS. |
| **Interface directory** | `origin/feat/rams-8226-integration` | `contracts/src/interfaces/rams/` — the only `interfaces/` directory anywhere in the repository. Did not exist before this branch. |
| **Branch touching the Mandate struct that never merged** | none | No unmerged branch modifies `DelegationMirror.Mandate` except `feat/rams-8226-integration` (16 lines changed in `DelegationMirror.sol`). |

---

## 8. The 12 places checked

For the record, each location was checked and each produced the result stated in §2:
(1) all 18 ref tips, (2) pickaxe across all history, (3) commit messages and ref names,
(4) stashes — zero, (5) dangling/unreachable objects — 78 objects, zero hits,
(6) reflog — 189 entries, zero orphans, (7) deleted files — zero matching,
(8) worktrees — one, (9) untracked and `git clean -nd` — zero RAMS artifacts,
(10) non-Solidity artifacts and package deps — zero deps, four vendored ABIs on the
branch, (11) GitHub PRs, branches and forks — PR #11 open, zero forks,
(12) sibling clones — `/Users/user/rams-8226` found and reported, not searched.
