// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RamsTestBase} from "./RamsTestBase.sol";
import {GatedUSD} from "../../src/GatedUSD.sol";
import {DelegationMirror} from "../../src/DelegationMirror.sol";
import {GatedUSDRams} from "../../src/GatedUSDRams.sol";
import {IAgentMandate} from "../../src/interfaces/rams/IAgentMandate.sol";
import {IComplianceProvider} from "../../src/interfaces/rams/IComplianceProvider.sol";

/// @notice Unit coverage of GatedUSDRams against a LOCAL deployment of the
///         ERC-8226 reference implementation (the exact bytecode running on
///         Ethereum Sepolia). Every mandate lifecycle state the registry can
///         reach is driven through the token's transferFrom gate.
contract GatedUSDRamsTest is RamsTestBase {
    address internal principal;
    uint256 internal principalKey;
    address internal agent = makeAddr("agent");
    address internal sink = makeAddr("sink");

    function setUp() public {
        (principal, principalKey) = makeAddrAndKey("principal");
        _deployRamsStack();
        gusd.faucetMint(principal, 1_000e6);
        vm.prank(principal);
        gusd.approve(agent, type(uint256).max); // RAMS composes with allowance, never replaces it
    }

    // ------------------------------------------------------------------
    // Grant paths
    // ------------------------------------------------------------------

    function test_GrantMandateViaEip712Signature() public {
        IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, address(gusd));
        uint256 nonceBefore = rams.nonces(principal);
        _grantSigned(p, principalKey); // submitted by an unrelated relayer

        IAgentMandate.Mandate memory m = rams.getMandate(agent, principal);
        assertEq(m.principal, principal, "mandate stored");
        assertEq(rams.nonces(principal), nonceBefore + 1, "principal nonce consumed");
        assertTrue(rams.canExecute(agent, principal, address(gusd), ACTION_TRANSFER_FROM, 1e6));
    }

    function test_AgentTransferWithinCapsSucceeds() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd)));

        vm.prank(agent);
        gusd.transferFrom(principal, sink, 90e6);

        assertEq(gusd.balanceOf(sink), 90e6);
        assertEq(rams.getMandate(agent, principal).cumulativeUsed, 90e6, "recordExecution atomic with transfer");
    }

    function test_PerTxCapBreachReverts() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd))); // 100e6 per tx

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_OVER_TX_CAP)
        );
        gusd.transferFrom(principal, sink, 100e6 + 1);
    }

    function test_CumulativeCapBreachReverts() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd))); // 250e6 cumulative

        vm.startPrank(agent);
        gusd.transferFrom(principal, sink, 100e6);
        gusd.transferFrom(principal, sink, 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_OVER_CUM_CAP)
        );
        gusd.transferFrom(principal, sink, 51e6); // 200 + 51 > 250
        vm.stopPrank();

        assertEq(rams.getMandate(agent, principal).cumulativeUsed, 200e6, "failed tx recorded nothing");
    }

    function test_ExpiredMandateReverts() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd))); // 7 days validity

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_EXPIRED)
        );
        gusd.transferFrom(principal, sink, 1e6);
    }

    function test_RevokedMandateReverts() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd)));

        vm.prank(principal);
        rams.revokeMandate(agent, principal, 0, "");

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_REVOKED)
        );
        gusd.transferFrom(principal, sink, 1e6);
    }

    function test_FrozenAgentReverts() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd)));

        vm.prank(enforcer);
        (bool ok,) = address(rams).call(abi.encodeWithSignature("freezeAgent(address)", agent));
        require(ok, "freeze failed");
        assertTrue(rams.isFrozen(agent));

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_FROZEN)
        );
        gusd.transferFrom(principal, sink, 1e6);
    }

    function test_WrongAssetReverts() public {
        // Mandate scoped to a different asset: the pair is mandated, so even in
        // strict OR permissive mode this token refuses rather than falling
        // through to allowance (no cap end-run via a leftover approval).
        IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, makeAddr("otherAsset"));
        _grantDirect(p);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_WRONG_ASSET)
        );
        gusd.transferFrom(principal, sink, 1e6);
    }

    function test_ActionNotEnabledReverts() public {
        IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, address(gusd));
        p.actions = new bytes32[](1);
        p.actions[0] = bytes32("some-other-action");
        _grantDirect(p);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_ACTION_DISABLED)
        );
        gusd.transferFrom(principal, sink, 1e6);
    }

    // ------------------------------------------------------------------
    // Strict vs permissive (the spec's MAY, both demonstrable)
    // ------------------------------------------------------------------

    function test_StrictModeBlocksMandatelessAgentTransfer() public {
        // No mandate at all; allowance alone is not enough in strict mode.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSDRams.RamsMandateRequired.selector, agent, principal));
        gusd.transferFrom(principal, sink, 1e6);
    }

    function test_PermissiveModeAllowsMandatelessUnderPlainAllowance() public {
        GatedUSDRams permissive = new GatedUSDRams(address(mirror), rams, false);
        permissive.faucetMint(principal, 100e6);
        vm.prank(principal);
        permissive.approve(agent, 40e6);

        vm.prank(agent);
        permissive.transferFrom(principal, sink, 40e6); // spec example's fall-through

        assertEq(permissive.balanceOf(sink), 40e6);
    }

    function test_PermissiveModeStillEnforcesExistingMandate() public {
        GatedUSDRams permissive = new GatedUSDRams(address(mirror), rams, false);
        permissive.faucetMint(principal, 1_000e6);
        vm.prank(principal);
        permissive.approve(agent, type(uint256).max);

        IAgentMandate.GrantMandateParams memory p = _defaultParams(agent, principal, address(permissive));
        _grantDirect(p);

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_OVER_TX_CAP
            )
        );
        permissive.transferFrom(principal, sink, 101e6);
    }

    // ------------------------------------------------------------------
    // Execution-path compliance re-check (spec gap (a) closed)
    // ------------------------------------------------------------------

    function test_ComplianceRevokedAfterGrantBlocksAtAsset() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd)));

        vm.prank(complianceOperator);
        refProvider.revokePrincipal(principal, IComplianceProvider.ReasonCode.AML_FLAG);

        // The registry still says yes (grant-time-only compliance)...
        assertTrue(rams.canExecute(agent, principal, address(gusd), ACTION_TRANSFER_FROM, 1e6));

        // ...the asset does not.
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                GatedUSDRams.RamsComplianceBlocked.selector,
                agent,
                principal,
                IComplianceProvider.ReasonCode.AML_FLAG
            )
        );
        gusd.transferFrom(principal, sink, 1e6);
    }

    function test_HolderInitiatedTransferSkipsRamsLayer() public {
        vm.prank(principal);
        gusd.transfer(sink, 5e6); // no mandate anywhere; humans move freely
        assertEq(gusd.balanceOf(sink), 5e6);
    }

    // ------------------------------------------------------------------
    // Composition with the VAR mirror (both leashes on the same transfer)
    // ------------------------------------------------------------------

    function test_MirrorStillGatesMandatedAgentsOwnBalance() public {
        // The agent is ALSO a VAR mirror agent holding its own funds.
        gusd.faucetMint(agent, 50e6);
        _attest(mirror, agent, principal, bytes32("proof"), 10e6, uint64(block.timestamp + 1 days), address(gusd), 1);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, VAR_OVER_CAP));
        gusd.transfer(sink, 11e6); // holder-initiated, VAR layer blocks
    }

    function test_BothLayersOnAgentInitiatedTransferFromMirrorAgent() public {
        // `from` is a mirror-registered agent; `msg.sender` is a RAMS-mandated
        // agent. RAMS gates the initiator, the mirror gates the sender.
        address fundManager = makeAddr("fundManager");
        gusd.faucetMint(fundManager, 500e6);
        _attest(
            mirror, fundManager, principal, bytes32("proof"), 60e6, uint64(block.timestamp + 1 days), address(gusd), 1
        );
        vm.prank(fundManager);
        gusd.approve(agent, type(uint256).max);
        _grantDirect(_defaultParams(agent, fundManager, address(gusd)));

        // Within RAMS caps (100e6/tx) but over the mirror's 60e6 per-tx cap:
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(GatedUSD.TransferBlocked.selector, VAR_OVER_CAP));
        gusd.transferFrom(fundManager, sink, 70e6);

        // Under both caps: passes both layers, both ledgers record.
        vm.prank(agent);
        gusd.transferFrom(fundManager, sink, 50e6);
        assertEq(rams.getMandate(agent, fundManager).cumulativeUsed, 50e6);
        assertEq(mirror.getMandate(fundManager).spentThisPeriod, 50e6);
    }

    // ------------------------------------------------------------------
    // Pre-flight views
    // ------------------------------------------------------------------

    function test_CanTransferByReportsLayer() public {
        (bool ok, bytes32 reason) = gusd.canTransferBy(agent, principal, 1e6);
        assertFalse(ok);
        assertEq(reason, RAMS_NO_MANDATE);

        _grantDirect(_defaultParams(agent, principal, address(gusd)));
        (ok, reason) = gusd.canTransferBy(agent, principal, 1e6);
        assertTrue(ok);
        assertEq(reason, bytes32("OK"));

        (ok, reason) = gusd.canTransferBy(agent, principal, 101e6);
        assertFalse(ok);
        assertEq(reason, RAMS_OVER_TX_CAP);

        vm.prank(complianceOperator);
        refProvider.revokePrincipal(principal, IComplianceProvider.ReasonCode.KYC_EXPIRED);
        (ok, reason) = gusd.canTransferBy(agent, principal, 1e6);
        assertFalse(ok);
        assertEq(reason, RAMS_PRINCIPAL_INELIGIBLE);
    }

    /// @dev The base's local reason-code copies must match the contract's.
    function test_ReasonCodeParity() public view {
        assertEq(gusd.ACTION_TRANSFER_FROM(), ACTION_TRANSFER_FROM);
        assertEq(gusd.RAMS_NO_MANDATE(), RAMS_NO_MANDATE);
        assertEq(gusd.RAMS_WRONG_ASSET(), RAMS_WRONG_ASSET);
        assertEq(gusd.RAMS_NOT_YET_VALID(), RAMS_NOT_YET_VALID);
        assertEq(gusd.RAMS_EXPIRED(), RAMS_EXPIRED);
        assertEq(gusd.RAMS_REVOKED(), RAMS_REVOKED);
        assertEq(gusd.RAMS_ACTION_DISABLED(), RAMS_ACTION_DISABLED);
        assertEq(gusd.RAMS_FROZEN(), RAMS_FROZEN);
        assertEq(gusd.RAMS_OVER_TX_CAP(), RAMS_OVER_TX_CAP);
        assertEq(gusd.RAMS_OVER_CUM_CAP(), RAMS_OVER_CUM_CAP);
        assertEq(gusd.RAMS_PRINCIPAL_INELIGIBLE(), RAMS_PRINCIPAL_INELIGIBLE);
        assertEq(mirror.OVER_CAP(), VAR_OVER_CAP);
    }

    function test_AllowanceStillRequiredAlongsideMandate() public {
        _grantDirect(_defaultParams(agent, principal, address(gusd)));
        vm.prank(principal);
        gusd.approve(agent, 0); // mandate alone must not move funds

        vm.prank(agent);
        vm.expectRevert(); // OZ ERC20InsufficientAllowance
        gusd.transferFrom(principal, sink, 1e6);
    }

    // ------------------------------------------------------------------
    // ERC-165. ERC-8226 Specification, first line: "All implementations
    // MUST implement ERC-165."
    // ------------------------------------------------------------------

    /// @dev Ids are asserted against values XORed from the interface
    ///      DEFINITIONS, so a wrong literal cannot pass by agreeing with
    ///      itself: IERC165 = supportsInterface(bytes4) = 0x01ffc9a7;
    ///      IERC20 = totalSupply ^ balanceOf ^ transfer ^ allowance ^ approve ^
    ///      transferFrom = 0x36372b07; IERC20Metadata = name ^ symbol ^
    ///      decimals = 0xa219a025.
    function test_SupportsInterface_IdsMatchDefinitions() public view {
        bytes4 erc165 = bytes4(keccak256("supportsInterface(bytes4)"));
        bytes4 erc20 = bytes4(keccak256("totalSupply()")) ^ bytes4(keccak256("balanceOf(address)"))
            ^ bytes4(keccak256("transfer(address,uint256)")) ^ bytes4(keccak256("allowance(address,address)"))
            ^ bytes4(keccak256("approve(address,uint256)"))
            ^ bytes4(keccak256("transferFrom(address,address,uint256)"));
        bytes4 erc20meta =
            bytes4(keccak256("name()")) ^ bytes4(keccak256("symbol()")) ^ bytes4(keccak256("decimals()"));

        assertEq(erc165, bytes4(0x01ffc9a7), "IERC165 id derived from its definition");
        assertEq(erc20, bytes4(0x36372b07), "IERC20 id derived from its definition");
        assertEq(erc20meta, bytes4(0xa219a025), "IERC20Metadata id derived from its definition");

        assertTrue(gusd.supportsInterface(erc165), "MUST advertise ERC-165");
        assertTrue(gusd.supportsInterface(erc20));
        assertTrue(gusd.supportsInterface(erc20meta));
    }

    function test_SupportsInterface_NegativeCases() public view {
        assertFalse(gusd.supportsInterface(0xffffffff), "ERC-165: 0xffffffff MUST be false");
        assertFalse(gusd.supportsInterface(0xdeadbeef));

        // We expose canTransfer but NOT the rest of IERC7943Fungible
        // (forcedTransfer, setFrozenTokens, canSend, canReceive,
        // getFrozenTokens), so we must not claim that id.
        bytes4 erc7943Fungible = bytes4(keccak256("forcedTransfer(address,address,uint256)"))
            ^ bytes4(keccak256("setFrozenTokens(address,uint256)")) ^ bytes4(keccak256("canSend(address)"))
            ^ bytes4(keccak256("canReceive(address)")) ^ bytes4(keccak256("getFrozenTokens(address)"))
            ^ bytes4(keccak256("canTransfer(address,address,uint256)"));
        assertFalse(gusd.supportsInterface(erc7943Fungible), "must not claim a surface we only partly implement");
    }
}
