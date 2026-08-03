// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IComplianceProvider} from "../interfaces/rams/IComplianceProvider.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {DelegationMirror} from "../DelegationMirror.sol";

/// @title VARComplianceProviderAdapter
/// @notice ERC-8226 IComplianceProvider (spec section "Compliance Provider")
///         fronting VAR's attestation layer. VAR's source of eligibility truth
///         is the DelegationMirror: a mandate exists only if a registered
///         attestor signed an EIP-712 attestation for a personhood-verified
///         principal, so "the principal holds a live attestor-signed mandate"
///         is VAR's equivalent of "the principal is compliant".
///
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
///
///         identityRef convention (spec: "keccak256 of a DID or attestation
///         ID"): VAR's attestation ID is the EIP-712 hashStruct of the
///         Attestation that created the mandate (address-independent, exposed
///         by DelegationMirror.hashStruct), and
///         identityRef = keccak256(abi.encode(attestationId)).
///
///         Binding is permissionless but proof-carrying: bindIdentity takes
///         the full Attestation, recomputes its hashStruct, and only accepts
///         it if that attestation is the one currently live in the mirror
///         (same agent, same nonce). Nobody can bind an identityRef to a
///         mandate that the attestation does not describe, so the adapter
///         adds no new trust assumptions on top of the mirror's attestor set.
contract VARComplianceProviderAdapter is IComplianceProvider {
    DelegationMirror public immutable mirror;

    struct Binding {
        address agent;
        // Principal at bind time. Stored (rather than re-read from the mirror)
        // so PrincipalRevoked can name the right subject even after a newer
        // attestation has moved the mirror on to a different principal.
        address principal;
        uint256 nonce; // mirror nonce at bind time; a higher mirror nonce means superseded
        // Set once PrincipalRevoked has been emitted for this ref, so the event
        // fires exactly once per identityRef and freeze relays cannot be spammed.
        bool revocationAnnounced;
    }

    mapping(bytes32 identityRef => Binding) private _bindings;
    /// @dev The identityRef currently bound for an agent, so a superseding bind
    ///      can announce the revocation of the one it displaces.
    mapping(address agent => bytes32 identityRef) private _currentRefOf;

    error UnknownMandate(address agent);
    error AttestationNotCurrent(address agent, uint256 attestationNonce, uint256 mirrorNonce);
    /// @dev The spec's grant/revoke lifecycle is owned by VAR's attestor flow
    ///      (DelegationMirror.submitAttestation / revoke), not by this adapter.
    error LifecycleManagedByMirror();
    error UnknownIdentityRef(bytes32 identityRef);
    error RevocationAlreadyAnnounced(bytes32 identityRef);
    error PrincipalStillEligible(bytes32 identityRef);
    /// @dev Binding is only meaningful for a mandate that is live right now.
    error MandateNotLive(address agent, ReasonCode reason);

    constructor(DelegationMirror mirror_) {
        mirror = mirror_;
    }

    /// @notice Derive the identityRef for an attestation, per the convention above.
    function identityRefFor(DelegationMirror.Attestation calldata a) public pure returns (bytes32) {
        // hashStruct is pure in the mirror; recomputing here keeps this function pure too.
        return keccak256(abi.encode(keccak256(abi.encode(_typeHash(), a.agent, a.principal, a.proofRef, a.kycRef,
            a.spendCapPerTx, a.spendCapPerPeriod, a.periodLength, a.allowedToken, a.expiry, a.nonce))));
    }

    /// @notice Bind an identityRef to the mirror mandate its attestation created.
    ///         Permissionless: the attestation itself is the proof of authority,
    ///         and it must be the one currently live in the mirror.
    function bindIdentity(DelegationMirror.Attestation calldata a) external returns (bytes32 identityRef) {
        DelegationMirror.Mandate memory m = mirror.getMandate(a.agent);
        if (m.principal == address(0)) revert UnknownMandate(a.agent);
        if (m.nonce != a.nonce || m.principal != a.principal) {
            revert AttestationNotCurrent(a.agent, a.nonce, m.nonce);
        }
        // DelegationMirror.revoke sets `revoked` but leaves `nonce` untouched,
        // so the nonce test above does NOT reject a revoked mandate. Without
        // this an already-dead mandate could be (re)bound, emitting
        // PrincipalGranted for an ineligible principal and clearing the
        // revocationAnnounced latch so PrincipalRevoked could fire twice —
        // exactly the confusion a freeze relay must not be fed.
        if (m.revoked) revert MandateNotLive(a.agent, ReasonCode.ATTESTATION_REVOKED);
        if (block.timestamp >= m.expiry) revert MandateNotLive(a.agent, ReasonCode.KYC_EXPIRED);

        identityRef = identityRefFor(a);

        // Binding a fresh attestation displaces whatever ref was current for
        // this agent. Reaching here means the mirror already moved to a higher
        // nonce, so the displaced ref is ineligible as of now: announce it,
        // otherwise a freeze relay watching PrincipalRevoked never learns.
        bytes32 prior = _currentRefOf[a.agent];
        if (prior != bytes32(0) && prior != identityRef) {
            _announceRevocation(prior, ReasonCode.ATTESTATION_REVOKED);
        }

        _bindings[identityRef] =
            Binding({agent: a.agent, principal: a.principal, nonce: a.nonce, revocationAnnounced: false});
        _currentRefOf[a.agent] = identityRef;
        emit PrincipalGranted(a.principal, identityRef);
    }

    /// @notice Announce that a bound identityRef has become ineligible, emitting
    ///         the spec's PrincipalRevoked with the ReasonCode that
    ///         checkPrincipal now returns.
    ///
    ///         Permissionless and idempotent-by-revert. This exists because
    ///         VAR's ineligibility transitions (DelegationMirror.revoke, mandate
    ///         expiry, supersession by a newer attestation) happen in the mirror,
    ///         not in this adapter, so no adapter call site observes them
    ///         synchronously. ERC-8226 Security Considerations recommends a
    ///         freeze relay that monitors PrincipalRevoked and calls freezeAgent;
    ///         without this entry point that relay would never fire when pointed
    ///         at this provider.
    ///
    ///         NOTE: this makes the event reachable, not automatic. The
    ///         authoritative answer is always the live checkPrincipal read
    ///         (which is why GatedUSDRams re-checks on the execution path and
    ///         needs no relay at all). A relay that wants push notification must
    ///         either watch DelegationMirror's own Revoked/Delegated events or
    ///         poke this function.
    /// @return reason The ReasonCode reported in the emitted event.
    function syncRevocation(bytes32 identityRef) external returns (ReasonCode reason) {
        Binding memory b = _bindings[identityRef];
        if (b.agent == address(0)) revert UnknownIdentityRef(identityRef);
        if (b.revocationAnnounced) revert RevocationAlreadyAnnounced(identityRef);

        bool eligible;
        (eligible, reason,) = _evaluate(identityRef, b.principal);
        if (eligible) revert PrincipalStillEligible(identityRef);

        _announceRevocation(identityRef, reason);
    }

    /// @dev Emits PrincipalRevoked once per identityRef and latches it.
    function _announceRevocation(bytes32 identityRef, ReasonCode reason) private {
        Binding storage b = _bindings[identityRef];
        if (b.agent == address(0) || b.revocationAnnounced) return;
        b.revocationAnnounced = true;
        emit PrincipalRevoked(b.principal, identityRef, reason);
    }

    /// @notice Whether PrincipalRevoked has already been emitted for a ref.
    function revocationAnnounced(bytes32 identityRef) external view returns (bool) {
        return _bindings[identityRef].revocationAnnounced;
    }

    /// @inheritdoc IComplianceProvider
    /// @dev Reads eligibility live from the mirror on every call, which is the
    ///      point of the adapter: RAMS checks compliance at grant time only,
    ///      and VAR closes that gap by keeping the runtime answer fresh here
    ///      and at the asset layer.
    function checkPrincipal(address principal, bytes32 identityRef)
        external
        view
        returns (bool eligible, ReasonCode reason, uint48 expiresAt)
    {
        return _evaluate(identityRef, principal);
    }

    /// @dev Single evaluation used by both the external read and the
    ///      PrincipalRevoked announcement, so the emitted ReasonCode can never
    ///      drift from the one checkPrincipal reports.
    function _evaluate(bytes32 identityRef, address principal)
        private
        view
        returns (bool eligible, ReasonCode reason, uint48 expiresAt)
    {
        Binding memory b = _bindings[identityRef];
        if (b.agent == address(0)) return (false, ReasonCode.IDENTITY_NOT_FOUND, 0);

        DelegationMirror.Mandate memory m = mirror.getMandate(b.agent);
        if (m.principal == address(0) || m.principal != principal) {
            return (false, ReasonCode.IDENTITY_NOT_FOUND, 0);
        }
        // A newer attestation replaced the one this identityRef refers to: the
        // attested credential is no longer the live one.
        if (m.nonce != b.nonce) return (false, ReasonCode.ATTESTATION_REVOKED, 0);
        if (m.revoked) return (false, ReasonCode.ATTESTATION_REVOKED, 0);
        if (block.timestamp >= m.expiry) return (false, ReasonCode.KYC_EXPIRED, _toUint48(m.expiry));
        return (true, ReasonCode.COMPLIANT, _toUint48(m.expiry));
    }

    /// @inheritdoc IComplianceProvider
    /// @dev VAR grants eligibility exclusively through the mirror's attestor-signed
    ///      flow; a direct grant here would bypass the personhood root. Use
    ///      bindIdentity with a live attestation instead.
    function grantPrincipal(address, bytes32, uint48) external pure {
        revert LifecycleManagedByMirror();
    }

    /// @inheritdoc IComplianceProvider
    /// @dev Revocation belongs to the principal via DelegationMirror.revoke; the
    ///      adapter reflects it on the next checkPrincipal read, with no window.
    function revokePrincipal(address, ReasonCode) external pure {
        revert LifecycleManagedByMirror();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IComplianceProvider).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Mirrors DelegationMirror.ATTESTATION_TYPEHASH; asserted equal in tests.
    function _typeHash() private pure returns (bytes32) {
        return keccak256(
            "Attestation(address agent,address principal,bytes32 proofRef,bytes32 kycRef,uint96 spendCapPerTx,uint96 spendCapPerPeriod,uint64 periodLength,address allowedToken,uint64 expiry,uint256 nonce)"
        );
    }

    /// @dev Mirror expiries are uint64; the spec surface is uint48. Saturate far
    ///      futures instead of truncating (uint48 covers timestamps to year ~8.9M).
    function _toUint48(uint64 t) private pure returns (uint48) {
        return t > type(uint48).max ? type(uint48).max : uint48(t);
    }
}
