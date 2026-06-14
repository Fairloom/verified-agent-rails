// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";

/// @notice Handler the invariant fuzzer drives. Holds the registered attestor key
///         and an unregistered attacker key, operates on a fixed agent set, and
///         tracks one ghost (which agents were written via a real attestor sig) so
///         the invariants can compare contract state to intent across any call order.
contract MirrorHandler is Test {
    DelegationMirror public mirror;
    address public token;
    uint256 internal attestorKey;
    address public attestor;
    uint256 internal attackerKey;

    address[3] public agents;
    address[3] public principals;
    mapping(address => bool) public attestedByAttestor; // ghost

    constructor(
        DelegationMirror _mirror,
        address _token,
        uint256 _attestorKey,
        address _attestor,
        uint256 _attackerKey
    ) {
        mirror = _mirror;
        token = _token;
        attestorKey = _attestorKey;
        attestor = _attestor;
        attackerKey = _attackerKey;
        for (uint256 i = 0; i < 3; i++) {
            agents[i] = address(uint160(0xA0000 + i));
            principals[i] = address(uint160(0xB0000 + i));
        }
    }

    function _sign(DelegationMirror.Attestation memory a, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, mirror.hashAttestation(a));
        return abi.encodePacked(r, s, v);
    }

    function _build(uint256 i, uint96 cap, uint64 expiry, uint256 nonce)
        internal
        view
        returns (DelegationMirror.Attestation memory a)
    {
        a = DelegationMirror.Attestation({
            agent: agents[i],
            principal: principals[i],
            proofRef: bytes32(0),
            kycRef: bytes32(0),
            spendCapPerTx: cap,
            spendCapPerPeriod: cap,
            periodLength: 1 days,
            allowedToken: token,
            expiry: expiry,
            nonce: nonce
        });
    }

    /// Legitimate write by the registered attestor; nonce always advances so it succeeds.
    function attest(uint256 agentSeed, uint96 cap, uint64 expiry) external {
        uint256 i = agentSeed % 3;
        uint256 nonce = mirror.lastNonce(agents[i]) + 1;
        DelegationMirror.Attestation memory a = _build(i, cap, expiry, nonce);
        mirror.submitAttestation(a, _sign(a, attestorKey));
        attestedByAttestor[agents[i]] = true;
    }

    /// Attacker attempt — signed by an unregistered key, must always revert; ghost never set.
    function attackerWrite(uint256 agentSeed, uint96 cap, uint64 expiry) external {
        uint256 i = agentSeed % 3;
        uint256 nonce = mirror.lastNonce(agents[i]) + 1;
        DelegationMirror.Attestation memory a = _build(i, cap, expiry, nonce);
        try mirror.submitAttestation(a, _sign(a, attackerKey)) {
            // Unreachable for an unregistered key; if it ever lands,
            // invariant_onlyAttestorEverWritesMandate catches it (ghost stays false).
        } catch {}
    }

    /// Principal revokes their own agent's mandate.
    function revokeAgent(uint256 agentSeed) external {
        uint256 i = agentSeed % 3;
        if (mirror.getMandate(agents[i]).principal == address(0)) return;
        vm.prank(principals[i]);
        mirror.revoke(agents[i]);
    }
}

/// @notice Workstream B (QA) — stateful invariants that must hold across ANY sequence
///         of attestor writes, attacker attempts, and revokes.
contract DelegationMirrorInvariantTest is StdInvariant, Test {
    DelegationMirror internal mirror;
    MirrorHandler internal handler;
    address internal token = makeAddr("token");

    function setUp() public {
        mirror = new DelegationMirror();
        (address attestor, uint256 attestorKey) = makeAddrAndKey("attestor");
        mirror.setAttestor(attestor, true);
        (, uint256 attackerKey) = makeAddrAndKey("attacker");
        handler = new MirrorHandler(mirror, token, attestorKey, attestor, attackerKey);
        targetContract(address(handler));
    }

    /// No agent ever has a mandate that wasn't written by the registered attestor
    /// (proves no permissionless creation survives any call sequence — the squatting fix).
    function invariant_onlyAttestorEverWritesMandate() public view {
        for (uint256 i = 0; i < 3; i++) {
            address agent = handler.agents(i);
            if (mirror.isRegistered(agent)) {
                assertTrue(handler.attestedByAttestor(agent), "mandate exists without an attestor write");
            }
        }
    }

    /// The stored mandate nonce always equals the agent's last consumed nonce.
    function invariant_mandateNonceEqualsLastNonce() public view {
        for (uint256 i = 0; i < 3; i++) {
            address agent = handler.agents(i);
            assertEq(mirror.getMandate(agent).nonce, mirror.lastNonce(agent), "nonce desync");
        }
    }

    /// A revoked mandate never clears a transfer (until reopened by a higher-nonce attestation).
    function invariant_revokedStaysBlocked() public view {
        for (uint256 i = 0; i < 3; i++) {
            address agent = handler.agents(i);
            if (mirror.getMandate(agent).revoked) {
                (bool ok,) = mirror.checkTransfer(agent, token, 1);
                assertFalse(ok, "a revoked mandate cleared a transfer");
            }
        }
    }

    /// One unit over the per-tx cap is always rejected, for every agent.
    function invariant_perTxCapNeverExceeded() public view {
        for (uint256 i = 0; i < 3; i++) {
            address agent = handler.agents(i);
            uint96 cap = mirror.getMandate(agent).spendCapPerTx;
            (bool ok,) = mirror.checkTransfer(agent, token, uint256(cap) + 1);
            assertFalse(ok, "cap+1 cleared a transfer");
        }
    }
}
