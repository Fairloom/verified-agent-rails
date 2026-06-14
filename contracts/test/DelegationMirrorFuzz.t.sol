// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AttestationHelper} from "./AttestationHelper.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";

/// @notice Workstream B (QA) — property/fuzz coverage for the signed-attestation gate.
///         Locks four boundaries the unit tests only spot-check at single points:
///         the OVER_CAP threshold across the full uint range, the EXPIRED `>=` edge,
///         strict nonce monotonicity, and that NO non-attestor key anywhere in the
///         secp256k1 keyspace can create a mandate (the squatting attack, generalized).
contract DelegationMirrorFuzzTest is AttestationHelper {
    DelegationMirror internal mirror;

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal token = makeAddr("token");
    bytes32 internal constant PROOF_REF = keccak256("worldid-proof");

    function setUp() public {
        mirror = new DelegationMirror();
        _registerAttestor(mirror);
    }

    /// ok must track `amount <= spendCapPerTx` exactly, across the whole range.
    function testFuzz_capBoundary(uint96 cap, uint256 amount) public {
        uint64 expiry = uint64(block.timestamp + 365 days);
        _attest(mirror, agent, principal, PROOF_REF, cap, expiry, token, 1);
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, amount);
        assertEq(ok, amount <= cap, "ok must equal amount<=cap");
        if (amount > cap) {
            assertEq(reason, mirror.OVER_CAP(), "over-cap must report OVER_CAP");
        }
    }

    /// Any key that is NOT the registered attestor must fail to create a mandate,
    /// and the rejected attempt must NOT advance the agent's nonce (pre-emption guard).
    function testFuzz_nonAttestorCannotWrite(uint256 badKey) public {
        // Any valid secp256k1 key works; a uint128 upper bound stays inside the curve order.
        badKey = bound(badKey, 1, type(uint128).max);
        address badSigner = vm.addr(badKey);
        vm.assume(badSigner != attestor);
        uint64 expiry = uint64(block.timestamp + 1 days);
        DelegationMirror.Attestation memory a = _buildAttestation(agent, principal, PROOF_REF, 100e6, expiry, token, 1);
        bytes memory sig = _sign(mirror, a, badKey);
        vm.expectRevert(abi.encodeWithSelector(DelegationMirror.InvalidAttestor.selector, badSigner));
        mirror.submitAttestation(a, sig);
        assertEq(mirror.lastNonce(agent), 0, "a rejected write must not burn the nonce");
        assertEq(mirror.getMandate(agent).principal, address(0), "no mandate may exist after a rejected write");
    }

    /// EXPIRED iff `block.timestamp >= expiry` — equality is expired (the `>=` edge).
    function testFuzz_expiryBoundary(uint64 expiry, uint256 warpTo) public {
        vm.assume(expiry > 0); // expiry==0 is dead-on-arrival; see test_expiryZero_isAlwaysExpired
        _attest(mirror, agent, principal, PROOF_REF, 100e6, expiry, token, 1);
        warpTo = bound(warpTo, 1, type(uint64).max);
        vm.warp(warpTo);
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, 1);
        bool expired = block.timestamp >= expiry;
        assertEq(ok, !expired, "ok iff not yet expired");
        if (expired) assertEq(reason, mirror.EXPIRED(), "expired must report EXPIRED");
    }

    /// A second attestation reverts StaleNonce iff its nonce <= the last consumed.
    function testFuzz_nonceMonotonic(uint256 n1, uint256 n2) public {
        n1 = bound(n1, 1, type(uint256).max - 1);
        uint64 expiry = uint64(block.timestamp + 1 days);
        _attest(mirror, agent, principal, PROOF_REF, 100e6, expiry, token, n1);
        assertEq(mirror.lastNonce(agent), n1);

        DelegationMirror.Attestation memory a2 = _buildAttestation(agent, principal, PROOF_REF, 100e6, expiry, token, n2);
        bytes memory sig2 = _sign(mirror, a2, attestorKey);
        if (n2 <= n1) {
            vm.expectRevert(abi.encodeWithSelector(DelegationMirror.StaleNonce.selector, agent, n2, n1));
            mirror.submitAttestation(a2, sig2);
            assertEq(mirror.lastNonce(agent), n1, "stale nonce must not advance");
        } else {
            mirror.submitAttestation(a2, sig2);
            assertEq(mirror.lastNonce(agent), n2, "a strictly-higher nonce advances");
        }
    }

    /// Documented edge: a mandate signed with expiry==0 is always EXPIRED.
    function test_expiryZero_isAlwaysExpired() public {
        _attest(mirror, agent, principal, PROOF_REF, 100e6, 0, token, 1);
        (bool ok, bytes32 reason) = mirror.checkTransfer(agent, token, 1);
        assertFalse(ok);
        assertEq(reason, mirror.EXPIRED());
    }
}
