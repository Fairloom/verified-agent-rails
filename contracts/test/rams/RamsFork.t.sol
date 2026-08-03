// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {DelegationMirror} from "../../src/DelegationMirror.sol";
import {GatedUSDRams} from "../../src/GatedUSDRams.sol";
import {IAgentMandate} from "../../src/interfaces/rams/IAgentMandate.sol";
import {IComplianceProvider} from "../../src/interfaces/rams/IComplianceProvider.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Owner surface of the reference ComplianceProvider / AgentExecutor.
///      Read at runtime so a change of custody on the live deployment surfaces
///      as a test failure with the real holder named, never as a stale prank.
interface IOwnable {
    function owner() external view returns (address);
}

/// @dev AccessControl surface of the live registry, beyond IAgentMandate.
interface IRegistryRoles {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Fork tests against the LIVE ERC-8226 deployment on Ethereum
///         Sepolia (11155111) — the addresses provided by the Brickken team.
///         (The task brief said Base Sepolia; Phase 0 verification located the
///         deployment on Ethereum Sepolia, see docs/rams/verification-status.md.)
///
///         These tests REQUIRE ETH_SEPOLIA_RPC_URL. If it is unset the suite
///         fails loudly in setUp naming every claim that would go unproven —
///         it deliberately does NOT skip. See the revert text in setUp.
///         Read-only ABI-conformance checks run first; the state-changing
///         composition test only mutates the local fork.
contract RamsForkTest is Test {
    // Live deployment (Ethereum Sepolia).
    IAgentMandate internal constant LIVE_RAMS = IAgentMandate(0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e);
    IComplianceProvider internal constant LIVE_PROVIDER =
        IComplianceProvider(0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278);
    address internal constant LIVE_EXECUTOR = 0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952;
    /// @dev The EOA that deployed all three contracts (blocks 11215028-11215035)
    ///      and is the AgentExecutor's IMMUTABLE principal. This is a deploy-time
    ///      fact, not a position of authority: custody of every ownable/admin
    ///      position moved away from it on 2026-07-2x (registry DEFAULT_ADMIN_ROLE
    ///      at block 11334076, provider + executor owner likewise). Authority is
    ///      therefore always read at runtime below, never assumed from this value.
    address internal constant LIVE_DEPLOYER = 0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1;
    // DOMAIN_SEPARATOR captured during Phase 0 verification. Public EIP-712
    // domain value, readable from the live contract via DOMAIN_SEPARATOR().
    bytes32 internal constant EXPECTED_DOMAIN_SEPARATOR =
        0xae6058abd18e03ad7b88c512ba9d5d63492ae383ae54e0de103a578b8c90bec7; // pragma: allowlist secret

    bytes32 internal constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            revert(
                string.concat(
                    "ETH_SEPOLIA_RPC_URL is not set, so the ERC-8226 fork tests cannot run. ",
                    "This suite is the ONLY evidence for the following claims. Without it every one of them is ",
                    "UNVERIFIED, and a green run proves none of them: ",
                    "(1) GatedUSDRams enforces RAMS caps against the LIVE Sepolia AgentMandate at ",
                    "0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e; ",
                    "(2) our token's recordExecution call is accepted on the msg.sender == m.asset branch while ",
                    "holding NO RECORDER_ROLE; ",
                    "(3) cumulativeUsed actually increments on Brickken's registry; ",
                    "(4) the live registry and provider still match the ABI, ERC-165 ids and EIP-712 domain ",
                    "separator we compiled against; ",
                    "(5) the live ComplianceProvider returns the reason codes our adapter and diagnostics assume. ",
                    "FIX: export ETH_SEPOLIA_RPC_URL=<a Sepolia endpoint>. ",
                    "To exclude these tests on purpose, do it visibly on the command line with ",
                    "`forge test --no-match-contract RamsForkTest` -- never by reintroducing a silent skip."
                )
            );
        }
        vm.createSelectFork(rpc);
    }

    // ------------------------------------------------------------------
    // Read-only: confirm the ABI we compiled against matches the live code
    // ------------------------------------------------------------------

    function test_Fork_ChainAndDomain() public {
        assertEq(block.chainid, 11155111, "live RAMS deployment is on Ethereum Sepolia");
        assertEq(LIVE_RAMS.DOMAIN_SEPARATOR(), EXPECTED_DOMAIN_SEPARATOR, "EIP-712 domain (RAMS, 1) unchanged");
    }

    function test_Fork_Erc165Surfaces() public {
        assertTrue(IERC165(address(LIVE_RAMS)).supportsInterface(type(IAgentMandate).interfaceId));
        assertTrue(LIVE_PROVIDER.supportsInterface(type(IComplianceProvider).interfaceId));
    }

    function test_Fork_ViewSurface() public {
        address nobodyA = makeAddr("nobodyA");
        address nobodyB = makeAddr("nobodyB");

        IAgentMandate.Mandate memory m = LIVE_RAMS.getMandate(nobodyA, nobodyB);
        assertEq(m.principal, address(0), "no mandate for fresh pair");
        assertFalse(LIVE_RAMS.canExecute(nobodyA, nobodyB, address(0), bytes32(0), 0));
        assertFalse(LIVE_RAMS.isFrozen(nobodyA));
        assertFalse(LIVE_RAMS.isOperator(nobodyB, nobodyA));
        assertEq(LIVE_RAMS.nonces(nobodyB), 0);

        (bool eligible, IComplianceProvider.ReasonCode reason,) = LIVE_PROVIDER.checkPrincipal(nobodyB, bytes32("x"));
        assertFalse(eligible);
        assertEq(uint8(reason), uint8(IComplianceProvider.ReasonCode.IDENTITY_NOT_FOUND));
    }

    function test_Fork_ExecutorWiring() public {
        (bool ok, bytes memory ret) = LIVE_EXECUTOR.staticcall(abi.encodeWithSignature("rams()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), address(LIVE_RAMS), "executor bound to the live registry");

        // principal() is immutable on the executor, so this is a deploy-time
        // fact that ownership transfers cannot rot.
        (ok, ret) = LIVE_EXECUTOR.staticcall(abi.encodeWithSignature("principal()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), LIVE_DEPLOYER, "executor principal is the deployer EOA (immutable)");

        // Ownership, by contrast, is mutable and HAS moved. Read it, never assume it.
        address executorOwner = IOwnable(LIVE_EXECUTOR).owner();
        address providerOwner = IOwnable(address(LIVE_PROVIDER)).owner();
        assertTrue(executorOwner != address(0), "executor owner must exist");
        assertTrue(providerOwner != address(0), "provider owner must exist");
        console2.log("live executor owner:", executorOwner);
        console2.log("live provider owner:", providerOwner);
    }

    // ------------------------------------------------------------------
    // State-changing (fork-local only): our token composed with their live
    // registry state machine, end to end
    // ------------------------------------------------------------------

    function test_Fork_GatedUSDRamsAgainstLiveRegistry() public {
        DelegationMirror mirror = new DelegationMirror();
        GatedUSDRams gusd = new GatedUSDRams(address(mirror), LIVE_RAMS, true);

        address principal = makeAddr("forkPrincipal");
        address agent = makeAddr("forkAgent");
        address sink = makeAddr("forkSink");

        gusd.faucetMint(principal, 1_000e6);
        vm.prank(principal);
        gusd.approve(agent, type(uint256).max);

        // Eligibility on the LIVE provider requires its compliance operator.
        // Read the CURRENT owner from the fork rather than hardcoding one:
        // custody moved off the deployer EOA after 2026-07-08 and a pinned
        // address silently turns this test into a no-op the day it changes
        // again. Fork-local prank, nothing broadcast.
        address providerOwner = IOwnable(address(LIVE_PROVIDER)).owner();
        assertTrue(providerOwner != address(0), "live ComplianceProvider must have an owner to impersonate");
        console2.log("impersonating live ComplianceProvider owner:", providerOwner);

        bytes32 identityRef = keccak256("fork-attestation");
        vm.prank(providerOwner);
        LIVE_PROVIDER.grantPrincipal(principal, identityRef, uint48(block.timestamp + 30 days));

        bytes32[] memory actions = new bytes32[](1);
        actions[0] = bytes32(GatedUSDRams.transferFrom.selector);
        vm.prank(principal);
        LIVE_RAMS.grantMandate(
            IAgentMandate.GrantMandateParams({
                agent: agent,
                validFrom: uint48(block.timestamp),
                validUntil: uint48(block.timestamp + 1 days),
                principal: principal,
                complianceProvider: address(LIVE_PROVIDER),
                identityRef: identityRef,
                asset: address(gusd),
                maxTransactionValue: 100e6,
                maxCumulativeValue: 250e6,
                metadata: bytes32(0),
                actions: actions,
                deadline: block.timestamp + 1 hours
            }),
            ""
        );

        // The claim under review (Brickken, 2026-08): a RAMS-aware token needs
        // no RECORDER_ROLE because recordExecution admits it on the
        // msg.sender == m.asset branch. Assert the token holds no role BEFORE
        // the transfer, so the recordExecution below can only have succeeded on
        // that branch.
        assertFalse(
            IRegistryRoles(address(LIVE_RAMS)).hasRole(RECORDER_ROLE, address(gusd)),
            "token must hold NO RECORDER_ROLE: the asset branch is what we are proving"
        );

        vm.prank(agent);
        gusd.transferFrom(principal, sink, 90e6);
        assertEq(gusd.balanceOf(sink), 90e6);
        assertEq(LIVE_RAMS.getMandate(agent, principal).cumulativeUsed, 90e6, "recorded on the live registry");

        // Still no role afterwards: nothing granted one along the way.
        assertFalse(
            IRegistryRoles(address(LIVE_RAMS)).hasRole(RECORDER_ROLE, address(gusd)),
            "recordExecution succeeded on the msg.sender == m.asset branch, roleless"
        );

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, bytes32("RAMS_OVER_TX_CAP"))
        );
        gusd.transferFrom(principal, sink, 101e6);

        console2.log("fork: GatedUSDRams enforced caps against the live Sepolia AgentMandate");
    }
}
