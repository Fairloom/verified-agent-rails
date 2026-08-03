// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {GatedUSD} from "./GatedUSD.sol";
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
/// VAR's DelegationMirror and the RAMS registry answer different questions
/// about the same transfer, so this token checks both and each must pass:
///
///  * DelegationMirror gates the **sender**: if `from` is a registered agent,
///    its attestor-signed mandate (caps, expiry, revocation) is enforced by
///    GatedUSD._update regardless of who initiated the transfer. This is the
///    agent-spends-its-own-balance leash.
///  * RAMS gates the **initiator**: if `msg.sender != from`, the transfer is
///    agent-initiated on someone else's balance and needs a valid
///    (msg.sender, from) mandate in the RAMS registry. This is the
///    agent-spends-the-principal's-balance leash.
///
/// Where both registries hold state about the same agent (e.g., a mirror-
/// registered agent initiating a transferFrom), both leashes apply: RAMS is
/// checked here, the mirror inside GatedUSD._update, and the ERC-20 allowance
/// in between. RAMS does not replace allowance; approvals are untouched.
///
/// # Strict vs permissive (constructor immutable)
///
/// The spec's example integration permissively falls through to plain
/// allowance when no mandate exists. The spec also explicitly permits a token
/// to require a mandate for every non-holder transfer; that is our default.
///
///  * strict:      every transferFrom by a non-holder requires a valid
///                 (msg.sender, from) RAMS mandate for this asset.
///  * permissive:  a pair with NO mandate falls through to plain allowance
///                 (the spec example's behavior). A pair that HAS a mandate
///                 is always enforced — including its asset scope — so a
///                 mandated agent can never do an end-run around its caps
///                 via a leftover allowance.
///
/// # Why RAMS's own gaps make the asset layer the right venue
///
/// ERC-8226 admits two gaps that this token closes on the execution path:
///
///  (a) The registry checks the ComplianceProvider at GRANT time only. This
///      token re-checks it at TRANSFER time: for every mandated transfer it
///      calls checkPrincipal(holder, mandate.identityRef) on the mandate's
///      own complianceProvider and reverts RamsComplianceBlocked with the
///      provider's ReasonCode if the principal is no longer eligible.
///  (b) There is a revocation window between a ComplianceProvider's
///      PrincipalRevoked and an enforcer's freezeAgent on the registry.
///      Because of (a), that window does not exist at this asset: the next
///      transfer after PrincipalRevoked reverts here even if no freeze ever
///      lands (on the live Sepolia deployment no enforcer exists at all, so
///      the window is otherwise unbounded).
///
/// The compliance provider is the one the principal committed to in the
/// signed grant (stored in the mandate), so this adds no new trust party.
/// A provider that reverts is treated as "not eligible / OTHER" rather than
/// bricking diagnosis: the failure mode is closed, not open.
///
/// # Dual-layer failure diagnosis (spec "Security Considerations" flags this)
///
/// Reverts identify the failing layer so an agent can machine-read the cause:
///  * VAR layer:  GatedUSD.TransferBlocked(reason) with mirror reason codes
///                (NO_MANDATE, REVOKED, EXPIRED, OVER_CAP, ...).
///  * RAMS layer: RamsMandateRequired / RamsBlocked(reason) with RAMS_*
///                reason codes derived by ramsDiagnose (the registry's
///                canExecute is a bare bool; the diagnosis view re-derives
///                which check failed, in the registry's own check order).
///  * Allowance:  OZ's standard ERC20InsufficientAllowance.
/// canTransferBy is the free pre-flight that composes all three-minus-
/// allowance layers for off-chain callers.
contract GatedUSDRams is GatedUSD {
    /// @notice RAMS action label for ERC-20 transferFrom, per the spec's
    ///         convention of bytes32(selector).
    bytes32 public constant ACTION_TRANSFER_FROM = bytes32(IERC20.transferFrom.selector);

    /// @dev RAMS-layer reason codes, one per registry check, in check order.
    bytes32 public constant RAMS_OK = "RAMS_OK";
    bytes32 public constant RAMS_NO_MANDATE = "RAMS_NO_MANDATE";
    bytes32 public constant RAMS_WRONG_ASSET = "RAMS_WRONG_ASSET";
    bytes32 public constant RAMS_NOT_YET_VALID = "RAMS_NOT_YET_VALID";
    bytes32 public constant RAMS_EXPIRED = "RAMS_EXPIRED";
    bytes32 public constant RAMS_REVOKED = "RAMS_REVOKED";
    bytes32 public constant RAMS_ACTION_DISABLED = "RAMS_ACTION_DISABLED";
    bytes32 public constant RAMS_FROZEN = "RAMS_FROZEN";
    bytes32 public constant RAMS_OVER_TX_CAP = "RAMS_OVER_TX_CAP";
    bytes32 public constant RAMS_OVER_CUM_CAP = "RAMS_OVER_CUM_CAP";
    /// @dev Runtime compliance re-check failed (the grant-time-only gap, closed).
    bytes32 public constant RAMS_PRINCIPAL_INELIGIBLE = "RAMS_PRINCIPAL_INELIGIBLE";

    /// @notice The ERC-8226 registry consulted for (initiator, holder) mandates.
    IAgentMandate public immutable rams;

    /// @notice True: every non-holder transferFrom requires a RAMS mandate
    ///         (spec-permitted strict mode). False: the spec example's
    ///         permissive fall-through to plain allowance for mandateless pairs.
    bool public immutable strictMandates;

    /// @notice Strict mode: agent-initiated transfer with no (agent, holder) mandate.
    error RamsMandateRequired(address agent, address holder);
    /// @notice A (agent, holder) mandate exists but blocks this transfer; reason
    ///         is a RAMS_* code identifying the failing registry check.
    error RamsBlocked(address agent, address holder, bytes32 reason);
    /// @notice The mandate's own ComplianceProvider no longer certifies the
    ///         holder: the execution-path compliance re-check (gap (a)) failed.
    ///         Carries the provider's structured ReasonCode for the agent.
    error RamsComplianceBlocked(address agent, address holder, IComplianceProvider.ReasonCode reason);

    constructor(address mirror_, IAgentMandate rams_, bool strictMandates_) GatedUSD(mirror_) {
        rams = rams_;
        strictMandates = strictMandates_;
    }

    /// @notice Agent-initiated transfers pass through the RAMS gate; the VAR
    ///         mirror gate and allowance then apply inside super.transferFrom
    ///         (GatedUSD._update). After balances settle, recordExecution makes
    ///         the registry's cumulative-cap accounting atomic with the
    ///         transfer — it re-checks and reverts on any cap breach, so a
    ///         race past canExecute still cannot settle.
    /// @dev The RAMS hook lives here rather than in _update because the
    ///      initiator (msg.sender != from) only exists on this entry point,
    ///      and GatedUSD._update stays untouched per the VAR core freeze.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        address agent = _msgSender();
        if (agent == from) {
            // Holder-initiated; VAR checks only (in GatedUSD._update).
            return super.transferFrom(from, to, value);
        }

        IAgentMandate.Mandate memory m = rams.getMandate(agent, from);
        bool mandated = m.principal != address(0);

        if (!mandated && strictMandates) revert RamsMandateRequired(agent, from);
        if (mandated) {
            if (!rams.canExecute(agent, from, address(this), ACTION_TRANSFER_FROM, value)) {
                revert RamsBlocked(agent, from, ramsDiagnose(agent, from, value));
            }
            // Execution-path compliance re-check: closes the spec's grant-time-
            // only gap and its PrincipalRevoked->freezeAgent window.
            (bool eligible, IComplianceProvider.ReasonCode cpReason) = _checkCompliance(m, from);
            if (!eligible) revert RamsComplianceBlocked(agent, from, cpReason);
        }

        bool ok = super.transferFrom(from, to, value);

        if (mandated) {
            // Reverts on cap breach: cap accounting is atomic with the transfer.
            rams.recordExecution(agent, from, ACTION_TRANSFER_FROM, value);
        }
        return ok;
    }

    /// @notice Initiator-aware pre-flight over both gates. Returns the first
    ///         failing layer's reason; allowance is intentionally out of scope
    ///         (standard ERC-20, queryable via allowance()).
    /// @return ok True if both the RAMS and VAR layers would pass.
    /// @return reason RAMS_* code, a mirror reason code, or "OK".
    function canTransferBy(address operator, address from, uint256 value)
        external
        view
        returns (bool ok, bytes32 reason)
    {
        if (operator != from) {
            bytes32 r = ramsDiagnose(operator, from, value);
            IAgentMandate.Mandate memory m = rams.getMandate(operator, from);
            bool mandated = m.principal != address(0);
            if (!mandated && strictMandates) return (false, RAMS_NO_MANDATE);
            if (mandated && r != RAMS_OK) return (false, r);
            if (mandated) {
                (bool eligible,) = _checkCompliance(m, from);
                if (!eligible) return (false, RAMS_PRINCIPAL_INELIGIBLE);
            }
        }
        if (from != address(0) && mirror.isRegistered(from)) {
            (bool mirrorOk, bytes32 mirrorReason) = mirror.checkTransfer(from, address(this), value);
            if (!mirrorOk) return (false, mirrorReason);
        }
        return (true, "OK");
    }

    /// @notice Re-derives which RAMS registry check fails for this transfer, in
    ///         the ERC-8226 spec's normative canExecute order (existence, asset,
    ///         window, revocation, action, freeze, per-tx cap, cumulative cap).
    ///         The registry itself only answers yes/no; this view gives agents
    ///         the why.
    /// @dev The DEPLOYED reference evaluates asset before existence
    ///      (AgentMandate.sol canExecute checks `asset != m.asset` first, then
    ///      delegates to _mandateAllows). Both orders return the same bool, so
    ///      this is only a reason-code question, and we follow the spec: for a
    ///      pair with no mandate at all, RAMS_NO_MANDATE is the more useful
    ///      answer than RAMS_WRONG_ASSET.
    function ramsDiagnose(address agent, address holder, uint256 value) public view returns (bytes32) {
        IAgentMandate.Mandate memory m = rams.getMandate(agent, holder);
        if (m.principal == address(0)) return RAMS_NO_MANDATE;
        if (m.asset != address(this)) return RAMS_WRONG_ASSET;
        if (block.timestamp < m.validFrom) return RAMS_NOT_YET_VALID;
        if (block.timestamp > m.validUntil) return RAMS_EXPIRED;
        if (m.revoked) return RAMS_REVOKED;
        if (!rams.isActionEnabled(agent, holder, ACTION_TRANSFER_FROM)) return RAMS_ACTION_DISABLED;
        if (rams.isFrozen(agent)) return RAMS_FROZEN;
        if (m.maxTransactionValue != type(uint256).max && value > m.maxTransactionValue) return RAMS_OVER_TX_CAP;
        if (m.maxCumulativeValue != type(uint256).max && m.cumulativeUsed + value > m.maxCumulativeValue) {
            return RAMS_OVER_CUM_CAP;
        }
        return RAMS_OK;
    }

    /// @notice ERC-165. ERC-8226 opens its Specification with "All
    ///         implementations MUST implement ERC-165", so a RAMS-aware asset
    ///         has to be discoverable as one.
    ///
    /// @dev Deliberately does NOT advertise `IERC7943Fungible`. GatedUSD exposes
    ///      `canTransfer` — 1 of that interface's 6 functions — and implements
    ///      none of `forcedTransfer`, `setFrozenTokens`, `canSend`, `canReceive`
    ///      or `getFrozenTokens`. Claiming the id would make ERC-165 discovery
    ///      lie to integrators, which is worse than not answering at all. If the
    ///      full ERC-7943 surface lands later, add the id then.
    ///
    ///      Ids are XORs of the selectors in each interface definition, not
    ///      literals: IERC165 0x01ffc9a7, IERC20 0x36372b07,
    ///      IERC20Metadata 0xa219a025. Asserted in test_SupportsInterface_Ids.
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC20).interfaceId
            || interfaceId == type(IERC20Metadata).interfaceId;
    }

    /// @dev Live checkPrincipal on the mandate's provider. A reverting or
    ///      broken provider maps to (false, OTHER): fail closed, still diagnosable.
    function _checkCompliance(IAgentMandate.Mandate memory m, address holder)
        private
        view
        returns (bool eligible, IComplianceProvider.ReasonCode reason)
    {
        try IComplianceProvider(m.complianceProvider).checkPrincipal(holder, m.identityRef) returns (
            bool ok, IComplianceProvider.ReasonCode r, uint48
        ) {
            return (ok, r);
        } catch {
            return (false, IComplianceProvider.ReasonCode.OTHER);
        }
    }
}
