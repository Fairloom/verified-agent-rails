// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {AttestationHelper} from "./AttestationHelper.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";
import {GatedUSD} from "../src/GatedUSD.sol";
import {ServiceSink} from "../src/ServiceSink.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GatedUSDTest is AttestationHelper {
    DelegationMirror internal mirror;
    GatedUSD internal token;
    ServiceSink internal sink;

    address internal principal = makeAddr("principal");
    address internal agent = makeAddr("agent");
    address internal payee = makeAddr("payee");
    address internal human = makeAddr("human");

    bytes32 internal constant PROOF_REF = keccak256("worldid-proof");
    uint96 internal constant CAP = 100e6;
    uint64 internal expiry;

    function setUp() public {
        mirror = new DelegationMirror();
        token = new GatedUSD(address(mirror));
        sink = new ServiceSink(IERC20(address(token)));
        _registerAttestor(mirror);
        expiry = uint64(block.timestamp + 1 days);
        token.faucetMint(agent, 1_000e6);
        token.faucetMint(human, 1_000e6);
    }

    function _delegate() internal {
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, address(token), 1);
    }

    function test_metadata() public view {
        assertEq(token.decimals(), 6);
        assertEq(token.name(), "Gated USD");
        assertEq(token.symbol(), "gUSD");
    }

    /// Priority 1: delegate, agent transfers under cap to payee, succeeds.
    function test_happyPath_agentPaysUnderCap() public {
        _delegate();
        vm.prank(agent);
        token.transfer(payee, 50e6);
        assertEq(token.balanceOf(payee), 50e6);
    }

    /// Reason codes are read into locals before vm.prank: calling a mirror getter
    /// inside the expectRevert argument would consume the prank.
    function test_blocked_revoked() public {
        _delegate();
        vm.prank(principal);
        mirror.revoke(agent);
        bytes32 reason = mirror.REVOKED();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, reason));
        token.transfer(payee, 1e6);
    }

    function test_blocked_expired() public {
        _delegate();
        vm.warp(uint256(expiry));
        bytes32 reason = mirror.EXPIRED();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, reason));
        token.transfer(payee, 1e6);
    }

    function test_blocked_overCap() public {
        _delegate();
        bytes32 reason = mirror.OVER_CAP();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, reason));
        token.transfer(payee, uint256(CAP) + 1);
    }

    function test_blocked_tokenNotAllowed() public {
        // mandate scoped to a different token, so moving gUSD is out of scope
        _attest(mirror, agent, principal, PROOF_REF, CAP, expiry, makeAddr("someOtherToken"), 1);
        bytes32 reason = mirror.TOKEN_NOT_ALLOWED();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, reason));
        token.transfer(payee, 1e6);
    }

    /// NO_MANDATE never surfaces through the token: senders without a mandate are
    /// not agents and transfer freely. The code is only reachable via the mirror.
    function test_noMandate_transfersFreely() public {
        vm.prank(human);
        token.transfer(payee, 500e6);
        assertEq(token.balanceOf(payee), 500e6);
        (bool ok, bytes32 reason) = mirror.checkTransfer(human, address(token), 500e6);
        assertFalse(ok);
        assertEq(reason, mirror.NO_MANDATE());
        assertTrue(token.canTransfer(human, payee, 500e6));
    }

    /// Priority 3: delegate, pay once, revoke, second pay reverts REVOKED.
    function test_revokeMidFlow() public {
        _delegate();
        vm.startPrank(agent);
        token.approve(address(sink), type(uint256).max);
        sink.pay(40e6);
        vm.stopPrank();
        assertEq(token.balanceOf(address(sink)), 40e6);

        vm.prank(principal);
        mirror.revoke(agent);

        bytes32 reason = mirror.REVOKED();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, reason));
        sink.pay(40e6);
    }

    function test_sink_emitsPaid() public {
        _delegate();
        vm.startPrank(agent);
        token.approve(address(sink), 40e6);
        vm.expectEmit(true, false, false, true);
        emit ServiceSink.Paid(agent, 40e6);
        sink.pay(40e6);
        vm.stopPrank();
    }

    /// Priority 4: canTransfer agrees with checkTransfer for every gated case.
    function test_canTransfer_agreesWithCheckTransfer() public {
        _delegate();
        _assertAgreement(agent, 50e6); // OK
        _assertAgreement(agent, uint256(CAP) + 1); // OVER_CAP

        vm.warp(uint256(expiry));
        _assertAgreement(agent, 1e6); // EXPIRED
        vm.warp(uint256(expiry) - 1);

        vm.prank(principal);
        mirror.revoke(agent);
        _assertAgreement(agent, 1e6); // REVOKED

        // TOKEN_NOT_ALLOWED: fresh agent with a mandate scoped to another token
        address agent2 = makeAddr("agent2");
        _attest(mirror, agent2, principal, PROOF_REF, CAP, expiry, makeAddr("someOtherToken"), 1);
        _assertAgreement(agent2, 1e6);
    }

    function _assertAgreement(address from, uint256 amount) internal view {
        (bool ok,) = mirror.checkTransfer(from, address(token), amount);
        assertEq(token.canTransfer(from, payee, amount), ok);
    }

    function test_faucetMint_onlyOwnerOrMinter() public {
        // A random caller cannot mint.
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSignature("NotMinter(address)", anyone));
        token.faucetMint(payee, 123e6);

        // The owner (this test, the deployer) can.
        token.faucetMint(payee, 123e6);
        assertEq(token.balanceOf(payee), 123e6);

        // A registered minter can; revoking the grant blocks it again.
        address minter = makeAddr("minter");
        token.setMinter(minter, true);
        vm.prank(minter);
        token.faucetMint(payee, 1e6);
        assertEq(token.balanceOf(payee), 124e6);

        token.setMinter(minter, false);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSignature("NotMinter(address)", minter));
        token.faucetMint(payee, 1e6);
    }

    /// Minting to an agent is not gated; only outbound transfers from agents are.
    function test_mintToAgent_notGated() public {
        _delegate();
        vm.prank(principal);
        mirror.revoke(agent);
        token.faucetMint(agent, 1e6);
    }
}
