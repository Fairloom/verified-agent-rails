// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";

/// @notice Shared test fixture. Registers a test attestor and signs attestations
///         so suites create mandates through the signed path. The attestor key
///         comes from the forge fixture (makeAddrAndKey), never from the repo.
abstract contract AttestationHelper is Test {
    uint256 internal attestorKey;
    address internal attestor;

    /// Register the test attestor on `mirror`. The caller (the test contract)
    /// must be the mirror owner, which it is when it deployed the mirror.
    function _registerAttestor(DelegationMirror mirror) internal {
        (attestor, attestorKey) = makeAddrAndKey("attestor");
        mirror.setAttestor(attestor, true);
    }

    function _buildAttestation(
        address agent,
        address principal,
        bytes32 proofRef,
        uint96 capPerTx,
        uint64 expiry,
        address token,
        uint256 nonce
    ) internal pure returns (DelegationMirror.Attestation memory a) {
        a = DelegationMirror.Attestation({
            agent: agent,
            principal: principal,
            proofRef: proofRef,
            kycRef: bytes32(0),
            spendCapPerTx: capPerTx,
            spendCapPerPeriod: capPerTx,
            periodLength: 1 days,
            allowedToken: token,
            expiry: expiry,
            nonce: nonce
        });
    }

    function _sign(DelegationMirror mirror, DelegationMirror.Attestation memory a, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = mirror.hashAttestation(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Build, sign with the registered test attestor, and submit.
    function _attest(
        DelegationMirror mirror,
        address agent,
        address principal,
        bytes32 proofRef,
        uint96 capPerTx,
        uint64 expiry,
        address token,
        uint256 nonce
    ) internal {
        DelegationMirror.Attestation memory a =
            _buildAttestation(agent, principal, proofRef, capPerTx, expiry, token, nonce);
        mirror.submitAttestation(a, _sign(mirror, a, attestorKey));
    }

    /// Full variant exposing the per-period cap and period length, for the
    /// period-enforcement suite. The compact _buildAttestation/_attest above keep
    /// capPerPeriod == capPerTx for suites that only exercise the per-tx cap.
    function _attestFull(
        DelegationMirror mirror,
        address agent,
        address principal,
        bytes32 proofRef,
        uint96 capPerTx,
        uint96 capPerPeriod,
        uint64 periodLength,
        uint64 expiry,
        address token,
        uint256 nonce
    ) internal {
        DelegationMirror.Attestation memory a = DelegationMirror.Attestation({
            agent: agent,
            principal: principal,
            proofRef: proofRef,
            kycRef: bytes32(0),
            spendCapPerTx: capPerTx,
            spendCapPerPeriod: capPerPeriod,
            periodLength: periodLength,
            allowedToken: token,
            expiry: expiry,
            nonce: nonce
        });
        mirror.submitAttestation(a, _sign(mirror, a, attestorKey));
    }
}
