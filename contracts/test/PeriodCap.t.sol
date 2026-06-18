// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AttestationHelper} from "./AttestationHelper.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";
import {GatedUSD} from "../src/GatedUSD.sol";

/// @notice Per-period spend cap enforcement on the live gate. Exercises real
///         transfers through GatedUSD._update -> mirror.recordSpend, so cumulative
///         accounting is on-chain rather than asserted on a view alone.
contract PeriodCapTest is AttestationHelper {
    DelegationMirror internal mirror;
    GatedUSD internal token;

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal payee = makeAddr("payee");

    bytes32 internal constant PROOF_REF = keccak256("worldid-proof");
    uint64 internal expiry;

    function setUp() public {
        mirror = new DelegationMirror();
        token = new GatedUSD(address(mirror));
        _registerAttestor(mirror);
        expiry = uint64(block.timestamp + 365 days);
        token.faucetMint(agent, _usd(10_000));
    }

    /// parseUSDC semantics: gUSD has 6 decimals, so n gUSD == n * 1e6 base units.
    function _usd(uint256 n) internal pure returns (uint96) {
        return uint96(n * 1e6);
    }

    function _pay(uint256 amount) internal {
        vm.prank(agent);
        token.transfer(payee, amount);
    }

    function _expectBlocked(uint256 amount, bytes32 reason) internal {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, reason));
        token.transfer(payee, amount);
    }

    /// Under both caps: two transfers summing below the period cap both clear.
    function test_underBothCaps_clears() public {
        _attestFull(mirror, agent, principal, PROOF_REF, _usd(50), _usd(100), 1 days, expiry, address(token), 1);
        _pay(_usd(40));
        _pay(_usd(40)); // cumulative 80 <= 100
        assertEq(token.balanceOf(payee), _usd(80));
        assertEq(mirror.getMandate(agent).spentThisPeriod, _usd(80));
    }

    /// Over the per-tx cap but under the period cap returns OVER_CAP: the per-tx
    /// check runs first and the period check never changes that outcome.
    function test_overPerTx_underPeriod_returnsOverCap() public {
        _attestFull(mirror, agent, principal, PROOF_REF, _usd(50), _usd(1000), 1 days, expiry, address(token), 1);
        _expectBlocked(_usd(51), mirror.OVER_CAP());
    }

    /// Each transfer is under the per-tx cap, but the one that crosses the period
    /// cap returns OVER_PERIOD_CAP and does not accumulate. The boundary (exactly
    /// at the cap) is allowed.
    function test_cumulativeOverPeriod_returnsOverPeriodCap() public {
        _attestFull(mirror, agent, principal, PROOF_REF, _usd(50), _usd(80), 1 days, expiry, address(token), 1);
        _pay(_usd(50)); // spent 50
        _expectBlocked(_usd(40), mirror.OVER_PERIOD_CAP()); // 50 + 40 = 90 > 80
        assertEq(mirror.getMandate(agent).spentThisPeriod, _usd(50)); // blocked tx did not accumulate
        _pay(_usd(30)); // 50 + 30 = 80, exactly at the cap, allowed
        assertEq(mirror.getMandate(agent).spentThisPeriod, _usd(80));
        _expectBlocked(_usd(1), mirror.OVER_PERIOD_CAP()); // 80 + 1 > 80
    }

    /// Period rollover: a spend that would exceed the cap in the open window clears
    /// in a fresh window after periodLength elapses, and spentThisPeriod resets to
    /// the new spend rather than carrying the old total.
    function test_periodRollover_resetsAndClears() public {
        uint64 periodLength = 1 hours;
        _attestFull(mirror, agent, principal, PROOF_REF, _usd(50), _usd(80), periodLength, expiry, address(token), 1);
        _pay(_usd(50)); // window opens, spent 50
        uint64 firstStart = mirror.getMandate(agent).periodStart;
        _expectBlocked(_usd(40), mirror.OVER_PERIOD_CAP()); // 50 + 40 > 80 in this window

        vm.warp(block.timestamp + periodLength); // window elapses
        _pay(_usd(50)); // fresh window: 0 + 50 <= 80
        DelegationMirror.Mandate memory m = mirror.getMandate(agent);
        assertEq(m.spentThisPeriod, _usd(50)); // reset, not 100
        assertGt(m.periodStart, firstStart); // window re-opened
        assertEq(token.balanceOf(payee), _usd(100));
    }

    /// spendCapPerPeriod == 0 means no period limit (per-tx only). Back-compat with
    /// mandates that predate per-period enforcement.
    function test_zeroPeriodCap_noLimit() public {
        _attestFull(mirror, agent, principal, PROOF_REF, _usd(50), 0, 1 days, expiry, address(token), 1);
        for (uint256 i = 0; i < 6; i++) {
            _pay(_usd(50)); // 300 cumulative, far above any single-window total
        }
        assertEq(token.balanceOf(payee), _usd(300));
        assertEq(mirror.getMandate(agent).spentThisPeriod, _usd(300)); // accounted, never enforced
    }

    /// Fuzz: a random sequence of sub-per-tx transfers within one window. A transfer
    /// succeeds exactly when it keeps cumulative <= the period cap, and the mirror's
    /// spentThisPeriod always equals the cumulative of the cleared transfers.
    function testFuzz_cumulativeNeverExceedsPeriodCap(uint96 a1, uint96 a2, uint96 a3) public {
        uint96 capPerTx = _usd(50);
        uint96 capPerPeriod = _usd(100);
        _attestFull(mirror, agent, principal, PROOF_REF, capPerTx, capPerPeriod, 365 days, expiry, address(token), 1);

        uint96[3] memory amts =
            [uint96(bound(a1, 1, capPerTx)), uint96(bound(a2, 1, capPerTx)), uint96(bound(a3, 1, capPerTx))];
        uint256 cumulative = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint256 amt = amts[i];
            if (cumulative + amt <= capPerPeriod) {
                _pay(amt);
                cumulative += amt;
            } else {
                _expectBlocked(amt, mirror.OVER_PERIOD_CAP());
            }
            assertEq(mirror.getMandate(agent).spentThisPeriod, cumulative);
            assertLe(cumulative, capPerPeriod);
        }
    }
}
