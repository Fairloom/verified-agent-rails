// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RamsTestBase} from "./RamsTestBase.sol";
import {GatedUSDRams} from "../../src/GatedUSDRams.sol";
import {IAgentMandate} from "../../src/interfaces/rams/IAgentMandate.sol";

/// @notice Property coverage of the RAMS gate: caps vs amounts, validity
///         windows vs warp, and nonce monotonicity on signed operations.
contract RamsFuzzTest is RamsTestBase {
    address internal principal;
    uint256 internal principalKey;
    address internal agent = makeAddr("agent");
    address internal sink = makeAddr("sink");

    uint256 internal constant SUPPLY = type(uint96).max;

    function setUp() public {
        (principal, principalKey) = makeAddrAndKey("principal");
        _deployRamsStack();
        gusd.faucetMint(principal, SUPPLY);
        vm.prank(principal);
        gusd.approve(agent, type(uint256).max);
    }

    /// forge-config: default.fuzz.runs = 2000
    /// @dev A transfer settles iff amount <= per-tx cap AND amount fits the
    ///      remaining cumulative headroom; on settle, cumulativeUsed advances
    ///      by exactly the amount (recordExecution atomicity).
    function testFuzz_CapsVsAmounts(uint96 txCap, uint96 cumCap, uint96 first, uint96 second) public {
        txCap = uint96(bound(txCap, 1, SUPPLY / 4));
        cumCap = uint96(bound(cumCap, txCap, SUPPLY / 2));
        first = uint96(bound(first, 1, txCap)); // always settles
        second = uint96(bound(second, 1, SUPPLY / 4));

        IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, address(gusd));
        p.maxTransactionValue = txCap;
        p.maxCumulativeValue = cumCap;
        _grantDirect(p);

        vm.prank(agent);
        gusd.transferFrom(principal, sink, first);
        assertEq(rams.getMandate(agent, principal).cumulativeUsed, first);

        bool fitsTx = second <= txCap;
        bool fitsCum = uint256(first) + second <= cumCap;

        vm.prank(agent);
        if (fitsTx && fitsCum) {
            gusd.transferFrom(principal, sink, second);
            assertEq(rams.getMandate(agent, principal).cumulativeUsed, uint256(first) + second);
            assertEq(gusd.balanceOf(sink), uint256(first) + second);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    GatedUSDRams.RamsBlocked.selector,
                    agent,
                    principal,
                    fitsTx ? RAMS_OVER_CUM_CAP : RAMS_OVER_TX_CAP
                )
            );
            gusd.transferFrom(principal, sink, second);
            assertEq(rams.getMandate(agent, principal).cumulativeUsed, first, "blocked tx records nothing");
        }
    }

    /// forge-config: default.fuzz.runs = 2000
    /// @dev The gate is open exactly inside [validFrom, validUntil]; the
    ///      compliance provider's own expiry gates independently after it.
    function testFuzz_ValidityWindowVsWarp(uint32 startIn, uint32 duration, uint32 probeIn) public {
        uint48 t0 = uint48(block.timestamp);
        uint48 validFrom = t0 + uint48(bound(startIn, 1, 30 days));
        uint48 validUntil = validFrom + uint48(bound(duration, 1, 365 days));
        uint48 probe = t0 + uint48(bound(probeIn, 0, 500 days));

        IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, address(gusd));
        p.validFrom = validFrom;
        p.validUntil = validUntil;
        // Keep the provider's expiry out of the fuzzed window so only the
        // mandate window decides the verdict.
        vm.prank(complianceOperator);
        refProvider.grantPrincipal(principal, p.identityRef, uint48(t0 + 1000 days));
        vm.prank(principal);
        rams.grantMandate(p, "");

        vm.warp(probe);
        vm.prank(agent);
        if (probe >= validFrom && probe <= validUntil) {
            gusd.transferFrom(principal, sink, 1e6);
            assertEq(gusd.balanceOf(sink), 1e6);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    GatedUSDRams.RamsBlocked.selector,
                    agent,
                    principal,
                    probe < validFrom ? RAMS_NOT_YET_VALID : RAMS_EXPIRED
                )
            );
            gusd.transferFrom(principal, sink, 1e6);
        }
    }

    /// forge-config: default.fuzz.runs = 512
    /// @dev Every signed operation consumes exactly one principal nonce, and a
    ///      consumed signature can never be replayed — including a
    ///      grant/revoke/grant cycle over the same pair.
    function testFuzz_NonceMonotonicityOnSignedOps(uint8 cycles) public {
        cycles = uint8(bound(cycles, 1, 5));

        vm.prank(complianceOperator);
        refProvider.grantPrincipal(
            principal, keccak256("test-attestation-id"), uint48(block.timestamp + 1000 days)
        );

        for (uint256 i = 0; i < cycles; i++) {
            uint256 n0 = rams.nonces(principal);

            IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, address(gusd));
            bytes memory grantSig = _signDigest(principalKey, _grantDigest(p));
            rams.grantMandate(p, grantSig);
            assertEq(rams.nonces(principal), n0 + 1, "grant consumed one nonce");

            // Replaying the consumed grant signature must fail (nonce moved on).
            vm.expectRevert();
            rams.grantMandate(p, grantSig);

            uint256 deadline = block.timestamp + 1 hours;
            bytes memory revokeSig = _signDigest(principalKey, _revokeDigest(agent, principal, deadline));
            rams.revokeMandate(agent, principal, deadline, revokeSig);
            assertEq(rams.nonces(principal), n0 + 2, "revoke consumed one nonce");

            // Replaying the revoke signature must fail too (and the mandate is gone).
            vm.expectRevert();
            rams.revokeMandate(agent, principal, deadline, revokeSig);
        }
        assertEq(rams.nonces(principal), uint256(cycles) * 2, "strictly monotonic across cycles");
    }
}
