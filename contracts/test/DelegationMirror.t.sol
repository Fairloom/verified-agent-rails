// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AttestationHelper} from "./AttestationHelper.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";

contract DelegationMirrorTest is AttestationHelper {
    DelegationMirror internal mirror;

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal token = makeAddr("token");
    address internal otherToken = makeAddr("otherToken");

    bytes32 internal constant PROOF_REF = keccak256("worldid-proof");
    uint96 internal constant CAP = 100e6;
    uint64 internal expiry;

    function setUp() public {
        mirror = new DelegationMirror();
        _registerAttestor(mirror);
        expiry = uint64(block.timestamp + 1 days);
    }

    /// Creates a mandate for `agent` via a signed attestation at the given nonce.
    function _delegate() internal {
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 1);
    }

    function test_attestation_storesMandate() public {
        _delegate();

        DelegationMirror.Mandate memory m = mirror.getMandate(agent);
        assertEq(m.principal, principal);
        assertEq(m.proofRef, PROOF_REF);
        assertEq(m.kycRef, bytes32(0));
        assertEq(m.spendCapPerTx, CAP);
        assertEq(m.spendCapPerPeriod, CAP);
        assertEq(m.periodLength, 1 days);
        assertEq(m.allowedToken, token);
        assertEq(m.expiry, expiry);
        assertFalse(m.revoked);
        assertEq(m.spentThisPeriod, 0);
        assertEq(m.periodStart, 0);
        assertEq(m.nonce, 1);
        assertEq(mirror.lastNonce(agent), 1);
    }

    function test_attestation_emitsEvents() public {
        vm.expectEmit(true, true, true, true);
        emit DelegationMirror.AttestationSubmitted(agent, principal, attestor, 1);
        vm.expectEmit(true, true, false, true);
        emit DelegationMirror.Delegated(agent, principal, PROOF_REF, CAP, expiry, token);
        _delegate();
    }

    /// Replacing the rejected old "MandateActive" path: a reused nonce reverts.
    function test_attestation_reusedNonceReverts() public {
        _delegate(); // nonce 1
        DelegationMirror.Attestation memory a = _buildAttestation(agent, principal, PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attestorKey);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.StaleNonce.selector, agent, uint256(1), uint256(1)));
        mirror.submitAttestation(a, sig);
    }

    function test_attestation_higherNonceReopensAfterRevoke() public {
        _delegate(); // nonce 1
        vm.prank(principal);
        mirror.revoke(agent);
        assertTrue(mirror.getMandate(agent).revoked);

        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 2);
        assertFalse(mirror.getMandate(agent).revoked);
        (bool ok,) = mirror.checkTransfer(agent, token, 1);
        assertTrue(ok);
    }

    function test_attestation_reopensAfterExpiry() public {
        _delegate(); // nonce 1
        vm.warp(uint256(expiry));
        _attest(mirror, agent, principal, PROOF_REF, CAP, uint64(block.timestamp + 1 days), token, 2);
        (bool ok,) = mirror.checkTransfer(agent, token, 1);
        assertTrue(ok);
    }

    function test_revoke_onlyPrincipal() public {
        _delegate();
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.NotPrincipal.selector, agent, attacker));
        mirror.revoke(agent);
    }

    function test_revoke_unknownAgentReverts() public {
        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.NoMandateFor.selector, agent));
        mirror.revoke(agent);
    }

    function test_revoke_setsFlagAndEmits() public {
        _delegate();
        vm.expectEmit(true, true, false, false);
        emit DelegationMirror.Revoked(agent, principal);
        vm.prank(principal);
        mirror.revoke(agent);
        assertTrue(mirror.getMandate(agent).revoked);
    }

    function test_checkTransfer_ok() public {
        _delegate();
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, CAP);
        assertTrue(ok);
        assertEq(reason, mirror.OK());
    }

    function test_checkTransfer_noMandate() public view {
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, 1);
        assertFalse(ok);
        assertEq(reason, mirror.NO_MANDATE());
    }

    function test_checkTransfer_revoked() public {
        _delegate();
        vm.prank(principal);
        mirror.revoke(agent);
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, 1);
        assertFalse(ok);
        assertEq(reason, mirror.REVOKED());
    }

    function test_checkTransfer_expired() public {
        _delegate();
        vm.warp(uint256(expiry));
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, 1);
        assertFalse(ok);
        assertEq(reason, mirror.EXPIRED());
    }

    function test_checkTransfer_overCap() public {
        _delegate();
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, uint256(CAP) + 1);
        assertFalse(ok);
        assertEq(reason, mirror.OVER_CAP());
    }

    function test_checkTransfer_tokenNotAllowed() public {
        _delegate();
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, otherToken, 1);
        assertFalse(ok);
        assertEq(reason, mirror.TOKEN_NOT_ALLOWED());
    }

    /// OVER_CAP is evaluated before TOKEN_NOT_ALLOWED per the declared order.
    function test_checkTransfer_orderOverCapBeforeToken() public {
        _delegate();
        (, bytes32 reason) = mirror.checkTransfer(agent, otherToken, uint256(CAP) + 1);
        assertEq(reason, mirror.OVER_CAP());
    }

    function test_setAttestor_onlyOwner() public {
        address newAttestor = makeAddr("newAttestor");
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        mirror.setAttestor(newAttestor, true);

        // owner (this test contract) can register and deregister
        mirror.setAttestor(newAttestor, true);
        assertTrue(mirror.registeredAttestor(newAttestor));
        mirror.setAttestor(newAttestor, false);
        assertFalse(mirror.registeredAttestor(newAttestor));
    }
}
