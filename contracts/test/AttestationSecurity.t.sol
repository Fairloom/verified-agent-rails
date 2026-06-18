// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AttestationHelper} from "./AttestationHelper.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";

/// @notice Attack-vector coverage for the signed attestation path: only a
///         registered attestor can create a mandate, tampering or replay
///         reverts, and a revoked mandate cannot be reopened without a fresh
///         higher-nonce attestation. These are the assertions that must hold for
///         Sweepoh's squatting and pre-emption tests to flip from pass to revert.
contract AttestationSecurityTest is AttestationHelper {
    DelegationMirror internal mirror;

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal token = makeAddr("token");

    address internal attacker;
    uint256 internal attackerKey;

    bytes32 internal constant PROOF_REF = keccak256("worldid-proof");
    uint96 internal constant CAP = 100e6;
    uint64 internal expiry;

    function setUp() public {
        mirror = new DelegationMirror();
        _registerAttestor(mirror);
        (attacker, attackerKey) = makeAddrAndKey("attacker");
        expiry = uint64(block.timestamp + 1 days);
    }

    function test_validAttestation_setsNonceAndMandate() public {
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 1);
        assertEq(mirror.getMandate(agent).principal, principal);
        assertEq(mirror.lastNonce(agent), 1);
    }

    // --- unauthorized creation (the squatting attack) ---

    function test_squatting_unclaimedAgent_reverts() public {
        // Attacker signs an otherwise-valid attestation with their own key.
        DelegationMirror.Attestation memory a = _buildAttestation(agent, attacker, PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attackerKey);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.InvalidAttestor.selector, attacker));
        mirror.submitAttestation(a, sig);
        // No mandate was written.
        assertEq(mirror.getMandate(agent).principal, address(0));
    }

    function test_deregisteredAttestor_reverts() public {
        mirror.setAttestor(attestor, false);
        DelegationMirror.Attestation memory a = _buildAttestation(agent, principal, PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attestorKey);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.InvalidAttestor.selector, attestor));
        mirror.submitAttestation(a, sig);
    }

    // --- tampering: any changed field recovers a different signer ---

    function test_tamperedField_reverts() public {
        DelegationMirror.Attestation memory a = _buildAttestation(agent, principal, PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attestorKey);
        // Mutate a field after signing; the submitted struct hashes differently,
        // so recover() returns an address that is not a registered attestor.
        a.spendCapPerTx = CAP + 1;
        // Recovered signer is an unpredictable address, so match on selector only.
        vm.expectPartialRevert(DelegationMirror.InvalidAttestor.selector);
        mirror.submitAttestation(a, sig);
    }

    // --- nonce replay and pre-emption after revoke ---

    function test_reusedNonce_reverts() public {
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 1);
        DelegationMirror.Attestation memory a = _buildAttestation(agent, principal, PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attestorKey);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.StaleNonce.selector, agent, uint256(1), uint256(1)));
        mirror.submitAttestation(a, sig);
    }

    /// The core revoke-reopen attack: a third party replays the principal's
    /// original, validly-signed attestation after a revoke. Nonce monotonicity
    /// rejects it; only the attestor issuing a higher nonce can reopen.
    function test_replayAfterRevoke_reverts() public {
        DelegationMirror.Attestation memory a = _buildAttestation(agent, principal, PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attestorKey);
        mirror.submitAttestation(a, sig);

        vm.prank(principal);
        mirror.revoke(agent);

        // Anyone can call submitAttestation; the replayed nonce 1 reverts.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.StaleNonce.selector, agent, uint256(1), uint256(1)));
        mirror.submitAttestation(a, sig);
        assertTrue(mirror.getMandate(agent).revoked);
    }

    function test_attackerCannotReopenAfterRevoke() public {
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 1);
        vm.prank(principal);
        mirror.revoke(agent);

        // Attacker forges a fresh higher-nonce attestation but cannot sign as the
        // attestor, so it reverts before any state change.
        DelegationMirror.Attestation memory a = _buildAttestation(agent, attacker, PROOF_REF, CAP, expiry, token, 2);
        bytes memory sig = _sign(mirror, a, attackerKey);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.InvalidAttestor.selector, attacker));
        mirror.submitAttestation(a, sig);
        assertTrue(mirror.getMandate(agent).revoked);
    }

    function test_attestorReopensWithHigherNonce() public {
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 1);
        vm.prank(principal);
        mirror.revoke(agent);
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 2);
        assertFalse(mirror.getMandate(agent).revoked);
        assertEq(mirror.lastNonce(agent), 2);
    }

    // --- zero-value guards ---

    function test_zeroAgent_reverts() public {
        DelegationMirror.Attestation memory a =
            _buildAttestation(address(0), principal, PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attestorKey);
        vm.expectRevert(DelegationMirror.ZeroAgent.selector);
        mirror.submitAttestation(a, sig);
    }

    function test_zeroPrincipal_reverts() public {
        DelegationMirror.Attestation memory a = _buildAttestation(agent, address(0), PROOF_REF, CAP, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, attestorKey);
        vm.expectRevert(DelegationMirror.ZeroPrincipal.selector);
        mirror.submitAttestation(a, sig);
    }

    // --- nonce is per-agent, and may jump ---

    function test_noncesArePerAgent() public {
        address agent2 = makeAddr("agent2");
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 1);
        _attest(mirror, agent2, principal, PROOF_REF, CAP, expiry, token, 1);
        assertEq(mirror.lastNonce(agent), 1);
        assertEq(mirror.lastNonce(agent2), 1);
    }

    function test_higherNonceUpdatesActiveMandate() public {
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, token, 1);
        _attest(mirror, agent, principal, PROOF_REF, 2 * CAP, expiry, token, 5);
        assertEq(mirror.getMandate(agent).spendCapPerTx, 2 * CAP);
        assertEq(mirror.lastNonce(agent), 5);
    }
}
