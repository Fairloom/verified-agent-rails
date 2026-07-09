// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {RamsTestBase} from "../rams/RamsTestBase.sol";
import {GatedUSDRams} from "../../src/GatedUSDRams.sol";
import {IAgentMandate} from "../../src/interfaces/rams/IAgentMandate.sol";
import {IAgentExecutor} from "../../src/interfaces/rams/IAgentExecutor.sol";
import {IComplianceProvider} from "../../src/interfaces/rams/IComplianceProvider.sol";

/// @title THE COMPROMISED-KEY DEMO
/// @notice Three scenarios showing why mandate enforcement must live at the
///         asset, not only at the execution venue. Runs against the exact
///         ERC-8226 reference bytecode deployed on Ethereum Sepolia.
///
///         Cast:
///           principal  — verified human, holds 1,000 gUSD
///           agent      — AI agent EOA, mandated: 100/tx, 250 cumulative
///           executor   — reference AgentExecutor, the spec's intended venue,
///                        itself mandated as an initiator (strict token: every
///                        non-holder initiator needs its own leash)
///
///         Run with -vv to read the story:
///           forge test --match-contract CompromisedKeyDemo -vv
contract CompromisedKeyDemo is RamsTestBase {
    address internal principal;
    uint256 internal principalKey;
    address internal agent = makeAddr("agent");
    address internal merchant = makeAddr("merchant");
    address internal attackerSink = makeAddr("attackerSink");

    IAgentExecutor internal executor;

    function setUp() public {
        (principal, principalKey) = makeAddrAndKey("principal");
        _deployRamsStack();

        gusd.faucetMint(principal, 1_000e6);

        executor = _deployExecutor(principal, principal);
        vm.startPrank(principal);
        gusd.approve(address(executor), type(uint256).max);
        gusd.approve(agent, type(uint256).max); // the approval a compromised key would abuse
        vm.stopPrank();

        // M1: the agent's leash — checked by the executor pre-forward, and by
        // the token whenever this key initiates directly.
        _grantDirect(_defaultParams(agent, principal, address(gusd)));
        // M2: the venue's leash — checked by the token when the executor routes.
        _grantDirect(_defaultParams(address(executor), principal, address(gusd)));
    }

    /// SCENARIO A: the happy path the spec intends. The agent routes through
    /// the AgentExecutor; executor and asset each verify a mandate; both
    /// ledgers record atomically.
    function test_ScenarioA_AgentTransactsThroughExecutor() public {
        console2.log("=== SCENARIO A: mandated agent pays a merchant via the AgentExecutor ===");
        console2.log("  principal balance:", gusd.balanceOf(principal) / 1e6, "gUSD");
        console2.log("  mandate (agent):    100/tx, 250 cumulative");

        vm.prank(agent);
        executor.execute(
            address(gusd), abi.encodeWithSelector(gusd.transferFrom.selector, principal, merchant, 40e6)
        );

        console2.log("  PAID 40 gUSD to merchant, on-leash");
        console2.log("  merchant balance:", gusd.balanceOf(merchant) / 1e6, "gUSD");
        console2.log("  agent leash used (registry):", rams.getMandate(agent, principal).cumulativeUsed / 1e6);
        console2.log("  venue leash used (registry):", rams.getMandate(address(executor), principal).cumulativeUsed / 1e6);

        assertEq(gusd.balanceOf(merchant), 40e6);
        assertEq(rams.getMandate(agent, principal).cumulativeUsed, 40e6, "executor recorded the agent's spend");
        assertEq(rams.getMandate(address(executor), principal).cumulativeUsed, 40e6, "token recorded the venue's spend");
    }

    /// SCENARIO B: the agent's key is compromised. The attacker skips the
    /// executor entirely and signs a raw transferFrom for the full balance.
    /// The spec's venue can't help — it was bypassed. The asset can: GatedUSDRams
    /// runs the same mandate checks in the token's own transfer path.
    function test_ScenarioB_RawTransferFromBypassingExecutorStillLeashed() public {
        console2.log("=== SCENARIO B: compromised agent key bypasses the executor ===");
        console2.log("  attacker holds the agent key AND an unlimited ERC-20 allowance");
        console2.log("  attacker tries: raw transferFrom(principal -> attacker, 1,000 gUSD)");

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_OVER_TX_CAP)
        );
        gusd.transferFrom(principal, attackerSink, 1_000e6);
        console2.log("  BLOCKED at the asset: RamsBlocked(RAMS_OVER_TX_CAP)");

        // Even patient, cap-sized theft stays inside the leash: the token
        // records every raw spend against the same mandate the executor uses.
        vm.startPrank(agent);
        gusd.transferFrom(principal, attackerSink, 100e6);
        gusd.transferFrom(principal, attackerSink, 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_OVER_CUM_CAP)
        );
        gusd.transferFrom(principal, attackerSink, 100e6);
        vm.stopPrank();
        console2.log("  cap-sized theft capped at the cumulative limit: 200 of 1,000 gUSD max exposure");
        console2.log("  attacker take:", gusd.balanceOf(attackerSink) / 1e6, "gUSD (the mandate cap, not the balance)");

        assertEq(gusd.balanceOf(attackerSink), 200e6, "exposure bounded by cumulative cap");
        assertEq(gusd.balanceOf(principal), 800e6);

        // And the principal's kill switch works mid-incident, no enforcer needed:
        vm.prank(principal);
        rams.revokeMandate(agent, principal, 0, "");
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, RAMS_REVOKED)
        );
        gusd.transferFrom(principal, attackerSink, 1e6);
        console2.log("  principal revokes the mandate: next raw transfer reverts RAMS_REVOKED");
    }

    /// SCENARIO C: the spec's admitted revocation window. The compliance
    /// provider revokes the principal (PrincipalRevoked), but freezeAgent has
    /// not been called — on the live Sepolia deployment it CANNOT be called,
    /// since no enforcer role was ever granted. The registry keeps saying yes.
    /// The asset-layer runtime re-check says no, in the same block.
    function test_ScenarioC_RevocationWindowClosedAtAsset() public {
        console2.log("=== SCENARIO C: PrincipalRevoked -> freezeAgent window ===");

        vm.prank(complianceOperator);
        refProvider.revokePrincipal(principal, IComplianceProvider.ReasonCode.AML_FLAG);
        console2.log("  ComplianceProvider: PrincipalRevoked(AML_FLAG) emitted");
        console2.log("  freezeAgent: NOT called (live deployment has no enforcer at all)");

        // The spec's gap, demonstrated on their own registry bytecode:
        bool registrySaysYes = rams.canExecute(agent, principal, address(gusd), ACTION_TRANSFER_FROM, 10e6);
        console2.log("  registry canExecute still returns:", registrySaysYes);
        assertTrue(registrySaysYes, "grant-time-only compliance: the registry does not see the revocation");
        assertFalse(rams.isFrozen(agent), "no freeze ever landed");

        // Both routes hit the asset's execution-path re-check:
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                GatedUSDRams.RamsComplianceBlocked.selector, agent, principal, IComplianceProvider.ReasonCode.AML_FLAG
            )
        );
        gusd.transferFrom(principal, merchant, 10e6);
        console2.log("  raw path:      BLOCKED at asset, RamsComplianceBlocked(AML_FLAG)");

        vm.prank(agent);
        vm.expectRevert(); // executor forwards, token reverts inside the call
        executor.execute(
            address(gusd), abi.encodeWithSelector(gusd.transferFrom.selector, principal, merchant, 10e6)
        );
        console2.log("  executor path: BLOCKED at asset (revert bubbles through execute)");
        console2.log("  window between PrincipalRevoked and freeze: zero blocks at this asset");

        assertEq(gusd.balanceOf(merchant), 0, "no funds moved during the 'window'");
    }
}
