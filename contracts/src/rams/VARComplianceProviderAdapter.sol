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
        uint256 nonce; // mirror nonce at bind time; a higher mirror nonce means superseded
    }

    mapping(bytes32 identityRef => Binding) private _bindings;

    error UnknownMandate(address agent);
    error AttestationNotCurrent(address agent, uint256 attestationNonce, uint256 mirrorNonce);
    /// @dev The spec's grant/revoke lifecycle is owned by VAR's attestor flow
    ///      (DelegationMirror.submitAttestation / revoke), not by this adapter.
    error LifecycleManagedByMirror();

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
        identityRef = identityRefFor(a);
        _bindings[identityRef] = Binding({agent: a.agent, nonce: a.nonce});
        emit PrincipalGranted(a.principal, identityRef);
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
