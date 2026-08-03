// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RamsTestBase} from "./RamsTestBase.sol";
import {DelegationMirror} from "../../src/DelegationMirror.sol";
import {GatedUSDRams} from "../../src/GatedUSDRams.sol";
import {VARComplianceProviderAdapter} from "../../src/rams/VARComplianceProviderAdapter.sol";
import {IAgentMandate} from "../../src/interfaces/rams/IAgentMandate.sol";
import {IComplianceProvider} from "../../src/interfaces/rams/IComplianceProvider.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice VARComplianceProviderAdapter: VAR's attestation layer behind the
///         ERC-8226 IComplianceProvider surface, including the full mapping of
///         mirror states onto the spec's ReasonCode enum.
contract VARComplianceProviderAdapterTest is RamsTestBase {
    VARComplianceProviderAdapter internal adapter;

    address internal principal;
    uint256 internal principalKey;
    address internal varAgent = makeAddr("varAgent");

    uint64 internal expiry;

    function setUp() public {
        (principal, principalKey) = makeAddrAndKey("principal");
        _deployRamsStack();
        adapter = new VARComplianceProviderAdapter(mirror);
        expiry = uint64(block.timestamp + 3 days);
    }

    function _liveAttestation(uint256 nonce) internal view returns (DelegationMirror.Attestation memory) {
        return _buildAttestation(varAgent, principal, bytes32("proof"), 10e6, expiry, address(gusd), nonce);
    }

    function _attestAndBind() internal returns (bytes32 identityRef) {
        DelegationMirror.Attestation memory a = _liveAttestation(1);
        mirror.submitAttestation(a, _sign(mirror, a, attestorKey));
        identityRef = adapter.bindIdentity(a);
    }

    function test_IdentityRefConvention() public {
        DelegationMirror.Attestation memory a = _liveAttestation(1);
        // identityRef = keccak256(attestation ID), attestation ID = EIP-712 hashStruct.
        assertEq(adapter.identityRefFor(a), keccak256(abi.encode(mirror.hashStruct(a))));
    }

    function test_LiveMandateIsCompliant() public {
        bytes32 ref = _attestAndBind();
        (bool ok, IComplianceProvider.ReasonCode reason, uint48 expiresAt) = adapter.checkPrincipal(principal, ref);
        assertTrue(ok);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.COMPLIANT));
        assertEq(expiresAt, uint48(expiry), "spec: expiresAt returned, not a binary verdict");
    }

    function test_UnknownIdentityRef() public view {
        (bool ok, IComplianceProvider.ReasonCode reason,) = adapter.checkPrincipal(principal, bytes32("nope"));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.IDENTITY_NOT_FOUND));
    }

    function test_WrongPrincipalForIdentity() public {
        bytes32 ref = _attestAndBind();
        (bool ok, IComplianceProvider.ReasonCode reason,) = adapter.checkPrincipal(makeAddr("impostor"), ref);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.IDENTITY_NOT_FOUND));
    }

    function test_MirrorRevokeMapsToAttestationRevoked() public {
        bytes32 ref = _attestAndBind();
        vm.prank(principal);
        mirror.revoke(varAgent);

        (bool ok, IComplianceProvider.ReasonCode reason,) = adapter.checkPrincipal(principal, ref);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.ATTESTATION_REVOKED));
    }

    function test_ExpiryMapsToKycExpired() public {
        bytes32 ref = _attestAndBind();
        vm.warp(uint256(expiry)); // mirror treats >= expiry as expired

        (bool ok, IComplianceProvider.ReasonCode reason, uint48 expiresAt) = adapter.checkPrincipal(principal, ref);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.KYC_EXPIRED));
        assertEq(expiresAt, uint48(expiry));
    }

    function test_SupersededAttestationMapsToRevoked() public {
        bytes32 refOld = _attestAndBind();

        // A fresh attestation (higher nonce) replaces the mandate.
        DelegationMirror.Attestation memory a2 = _liveAttestation(2);
        mirror.submitAttestation(a2, _sign(mirror, a2, attestorKey));

        (bool ok, IComplianceProvider.ReasonCode reason,) = adapter.checkPrincipal(principal, refOld);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.ATTESTATION_REVOKED));

        // The new attestation binds and reads compliant.
        bytes32 refNew = adapter.bindIdentity(a2);
        (ok,,) = adapter.checkPrincipal(principal, refNew);
        assertTrue(ok);
    }

    function test_BindRejectsNonCurrentAttestation() public {
        DelegationMirror.Attestation memory a = _liveAttestation(1);
        mirror.submitAttestation(a, _sign(mirror, a, attestorKey));

        DelegationMirror.Attestation memory stale = _liveAttestation(99); // never submitted
        vm.expectRevert(
            abi.encodeWithSelector(VARComplianceProviderAdapter.AttestationNotCurrent.selector, varAgent, 99, 1)
        );
        adapter.bindIdentity(stale);
    }

    function test_LifecycleWritesRevert() public {
        vm.expectRevert(VARComplianceProviderAdapter.LifecycleManagedByMirror.selector);
        adapter.grantPrincipal(principal, bytes32("x"), 0);
        vm.expectRevert(VARComplianceProviderAdapter.LifecycleManagedByMirror.selector);
        adapter.revokePrincipal(principal, IComplianceProvider.ReasonCode.OTHER);
    }

    function test_SupportsInterface() public view {
        assertTrue(adapter.supportsInterface(type(IComplianceProvider).interfaceId));
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
        assertFalse(adapter.supportsInterface(0xdeadbeef));
    }

    /// @notice Pin the adapter's ids to the values derived from the SPEC's own
    ///         interface declarations (XOR of the selectors it lists), not to
    ///         whatever solc happens to compute for our local copy. 0xfa2a39b3
    ///         is grantPrincipal(address,bytes32,uint48) ^
    ///         revokePrincipal(address,uint8) ^ checkPrincipal(address,bytes32),
    ///         and the LIVE Sepolia ComplianceProvider at 0xa90D2503… answers
    ///         true for it (see RamsFork test_Fork_Erc165Surfaces).
    function test_SupportsInterface_IdsMatchSpec() public view {
        assertEq(type(IComplianceProvider).interfaceId, bytes4(0xfa2a39b3), "IComplianceProvider id per spec");
        assertEq(type(IERC165).interfaceId, bytes4(0x01ffc9a7), "IERC165 id");
        assertTrue(adapter.supportsInterface(0xfa2a39b3));
        assertTrue(adapter.supportsInterface(0x01ffc9a7));
        // ERC-165 requires 0xffffffff to be false.
        assertFalse(adapter.supportsInterface(0xffffffff), "ERC-165: 0xffffffff MUST be false");
    }

    // ------------------------------------------------------------------
    // PrincipalRevoked: the spec's freeze-relay signal (Security
    // Considerations). Every path that makes a principal ineligible must
    // be able to reach it, with the same ReasonCode checkPrincipal reports.
    // ------------------------------------------------------------------

    function test_PrincipalRevoked_OnMirrorRevoke() public {
        bytes32 ref = _attestAndBind();
        vm.prank(principal);
        mirror.revoke(varAgent);

        assertFalse(adapter.revocationAnnounced(ref));
        vm.expectEmit(true, true, false, true, address(adapter));
        emit IComplianceProvider.PrincipalRevoked(principal, ref, IComplianceProvider.ReasonCode.ATTESTATION_REVOKED);
        IComplianceProvider.ReasonCode reason = adapter.syncRevocation(ref);

        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.ATTESTATION_REVOKED));
        assertTrue(adapter.revocationAnnounced(ref));
    }

    function test_PrincipalRevoked_OnExpiryCarriesKycExpired() public {
        bytes32 ref = _attestAndBind();
        vm.warp(uint256(expiry));

        vm.expectEmit(true, true, false, true, address(adapter));
        emit IComplianceProvider.PrincipalRevoked(principal, ref, IComplianceProvider.ReasonCode.KYC_EXPIRED);
        IComplianceProvider.ReasonCode reason = adapter.syncRevocation(ref);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.KYC_EXPIRED));
    }

    /// @notice Supersession is the one ineligibility path that happens INSIDE
    ///         the adapter, so it announces without any poke.
    function test_PrincipalRevoked_OnSupersedingBind() public {
        bytes32 refOld = _attestAndBind();

        DelegationMirror.Attestation memory a2 = _liveAttestation(2);
        mirror.submitAttestation(a2, _sign(mirror, a2, attestorKey));

        vm.expectEmit(true, true, false, true, address(adapter));
        emit IComplianceProvider.PrincipalRevoked(
            principal, refOld, IComplianceProvider.ReasonCode.ATTESTATION_REVOKED
        );
        bytes32 refNew = adapter.bindIdentity(a2);

        assertTrue(adapter.revocationAnnounced(refOld), "displaced ref announced");
        assertFalse(adapter.revocationAnnounced(refNew), "fresh ref is live");
    }

    /// @dev The emitted ReasonCode must equal what checkPrincipal returns, for
    ///      every ineligibility path — that is what makes the event auditable.
    function test_PrincipalRevoked_ReasonMatchesCheckPrincipal() public {
        bytes32 ref = _attestAndBind();
        vm.warp(uint256(expiry));

        (bool ok, IComplianceProvider.ReasonCode readReason,) = adapter.checkPrincipal(principal, ref);
        assertFalse(ok);
        IComplianceProvider.ReasonCode emittedReason = adapter.syncRevocation(ref);
        assertEq(uint8(emittedReason), uint8(readReason), "event ReasonCode == checkPrincipal ReasonCode");
    }

    /// @notice Regression: DelegationMirror.revoke leaves `nonce` unchanged, so
    ///         bindIdentity's current-attestation test alone does not reject a
    ///         revoked mandate. Re-binding one would emit PrincipalGranted for
    ///         an ineligible principal and reset the revocationAnnounced latch,
    ///         letting PrincipalRevoked fire twice for the same ref.
    function test_BindRejectsRevokedMandate_LatchCannotBeReset() public {
        bytes32 ref = _attestAndBind();
        vm.prank(principal);
        mirror.revoke(varAgent);
        adapter.syncRevocation(ref);
        assertTrue(adapter.revocationAnnounced(ref));

        DelegationMirror.Attestation memory a = _liveAttestation(1); // still "current" by nonce
        vm.expectRevert(
            abi.encodeWithSelector(
                VARComplianceProviderAdapter.MandateNotLive.selector,
                varAgent,
                IComplianceProvider.ReasonCode.ATTESTATION_REVOKED
            )
        );
        adapter.bindIdentity(a);

        assertTrue(adapter.revocationAnnounced(ref), "latch survives the re-bind attempt");
    }

    function test_BindRejectsExpiredMandate() public {
        DelegationMirror.Attestation memory a = _liveAttestation(1);
        mirror.submitAttestation(a, _sign(mirror, a, attestorKey));
        vm.warp(uint256(expiry));

        vm.expectRevert(
            abi.encodeWithSelector(
                VARComplianceProviderAdapter.MandateNotLive.selector,
                varAgent,
                IComplianceProvider.ReasonCode.KYC_EXPIRED
            )
        );
        adapter.bindIdentity(a);
    }

    function test_SyncRevocation_RejectsEligibleUnknownAndDuplicate() public {
        bytes32 ref = _attestAndBind();

        // Still live: nothing to announce.
        vm.expectRevert(abi.encodeWithSelector(VARComplianceProviderAdapter.PrincipalStillEligible.selector, ref));
        adapter.syncRevocation(ref);

        // Never bound.
        vm.expectRevert(
            abi.encodeWithSelector(VARComplianceProviderAdapter.UnknownIdentityRef.selector, bytes32("nope"))
        );
        adapter.syncRevocation(bytes32("nope"));

        // Announce once, then refuse to spam the relay.
        vm.prank(principal);
        mirror.revoke(varAgent);
        adapter.syncRevocation(ref);
        vm.expectRevert(
            abi.encodeWithSelector(VARComplianceProviderAdapter.RevocationAlreadyAnnounced.selector, ref)
        );
        adapter.syncRevocation(ref);
    }

    /// @notice End-to-end: the adapter as complianceProvider inside a RAMS
    ///         mandate. VAR's one-click mirror revoke propagates through the
    ///         adapter into the token's execution-path re-check — no enforcer,
    ///         no freeze, no window.
    function test_MirrorRevokePropagatesThroughRamsMandate() public {
        bytes32 ref = _attestAndBind();

        address agent = makeAddr("ramsAgent");
        address sink = makeAddr("sink");
        gusd.faucetMint(principal, 100e6);
        vm.prank(principal);
        gusd.approve(agent, type(uint256).max);

        IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, address(gusd));
        p.complianceProvider = address(adapter);
        p.identityRef = ref;
        vm.prank(principal);
        rams.grantMandate(p, ""); // grant-time check passes against the adapter

        vm.prank(agent);
        gusd.transferFrom(principal, sink, 10e6); // live check passes too

        vm.prank(principal);
        mirror.revoke(varAgent); // the VAR kill switch

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                GatedUSDRams.RamsComplianceBlocked.selector,
                agent,
                principal,
                IComplianceProvider.ReasonCode.ATTESTATION_REVOKED
            )
        );
        gusd.transferFrom(principal, sink, 10e6);
    }
}
