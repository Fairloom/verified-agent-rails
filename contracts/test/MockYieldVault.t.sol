// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AttestationHelper} from "./AttestationHelper.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";
import {GatedUSD} from "../src/GatedUSD.sol";
import {MockYieldVault} from "../src/MockYieldVault.sol";

contract MockYieldVaultTest is AttestationHelper {
    DelegationMirror internal mirror;
    GatedUSD internal token;
    MockYieldVault internal vault;

    address internal human = makeAddr("human");
    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");

    function setUp() public {
        mirror = new DelegationMirror();
        token = new GatedUSD(address(mirror));
        vault = new MockYieldVault(token);
        token.setMinter(address(vault), true);
        _registerAttestor(mirror);
        token.faucetMint(human, 1_000e6);
    }

    /// Priority 6: deposit and withdraw round-trip.
    function test_depositWithdrawRoundTrip() public {
        vm.startPrank(human);
        token.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(500e6, human);
        assertGt(shares, 0);

        vm.roll(block.number + 100);

        uint256 assetsOut = vault.redeem(shares, human, human);
        vm.stopPrank();

        // yield accrued over 100 blocks, so the round-trip returns more than deposited
        assertGt(assetsOut, 500e6);
        assertEq(token.balanceOf(human), 1_000e6 - 500e6 + assetsOut);
    }

    function test_exchangeRateTicksUpPerBlock() public {
        vm.startPrank(human);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(500e6, human);
        vm.stopPrank();

        uint256 rate0 = vault.convertToAssets(1e6);
        vm.roll(block.number + 1);
        uint256 rate1 = vault.convertToAssets(1e6);
        vm.roll(block.number + 1);
        uint256 rate2 = vault.convertToAssets(1e6);

        assertGt(rate1, rate0);
        assertGt(rate2, rate1);
    }

    function test_emptyVaultAccruesNothing() public {
        vm.roll(block.number + 1000);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.pendingYield(), 0);
    }

    /// An agent under mandate can sweep idle balance into the vault when the
    /// amount is within cap and the mandate token is gUSD.
    function test_agentSweepToVaultRespectsGate() public {
        token.faucetMint(agent, 200e6);
        _attest(mirror, agent, principal, keccak256("n"), 100e6, uint64(block.timestamp + 1 days), address(token), 1);

        vm.startPrank(agent);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(80e6, agent); // under cap, allowed
        vm.stopPrank();
        assertEq(vault.maxWithdraw(agent), 80e6);

        bytes32 reason = mirror.OVER_CAP();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, reason));
        vault.deposit(120e6, agent); // over cap, blocked by the gate
    }
}
