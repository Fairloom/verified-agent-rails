// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {DelegationMirror} from "../../src/DelegationMirror.sol";
import {GatedUSDRams} from "../../src/GatedUSDRams.sol";
import {IAgentMandate} from "../../src/interfaces/rams/IAgentMandate.sol";
import {IComplianceProvider} from "../../src/interfaces/rams/IComplianceProvider.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Fork tests against the LIVE ERC-8226 deployment on Ethereum
///         Sepolia (11155111) — the addresses provided by the Brickken team.
///         (The task brief said Base Sepolia; Phase 0 verification located the
///         deployment on Ethereum Sepolia, see docs/rams/verification-status.md.)
///
///         Gated behind ETH_SEPOLIA_RPC_URL; without it the suite skips.
///         Read-only ABI-conformance checks run first; the state-changing
///         composition test only mutates the local fork.
contract RamsForkTest is Test {
    // Live deployment (Ethereum Sepolia).
    IAgentMandate internal constant LIVE_RAMS = IAgentMandate(0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e);
    IComplianceProvider internal constant LIVE_PROVIDER =
        IComplianceProvider(0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278);
    address internal constant LIVE_EXECUTOR = 0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952;
    // Deployer/admin observed on-chain during Phase 0 verification.
    address internal constant LIVE_ADMIN = 0xB610470ae0fEa78A1B27cD3F0D4011eb5361fAf1;
    // DOMAIN_SEPARATOR captured during Phase 0 verification.
    bytes32 internal constant EXPECTED_DOMAIN_SEPARATOR =
        0xae6058abd18e03ad7b88c512ba9d5d63492ae383ae54e0de103a578b8c90bec7;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // suite skips itself test-by-test
        vm.createSelectFork(rpc);
        forked = true;
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    // ------------------------------------------------------------------
    // Read-only: confirm the ABI we compiled against matches the live code
    // ------------------------------------------------------------------

    function test_Fork_ChainAndDomain() public onFork {
        assertEq(block.chainid, 11155111, "live RAMS deployment is on Ethereum Sepolia");
        assertEq(LIVE_RAMS.DOMAIN_SEPARATOR(), EXPECTED_DOMAIN_SEPARATOR, "EIP-712 domain (RAMS, 1) unchanged");
    }

    function test_Fork_Erc165Surfaces() public onFork {
        assertTrue(IERC165(address(LIVE_RAMS)).supportsInterface(type(IAgentMandate).interfaceId));
        assertTrue(LIVE_PROVIDER.supportsInterface(type(IComplianceProvider).interfaceId));
    }

    function test_Fork_ViewSurface() public onFork {
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

    function test_Fork_ExecutorWiring() public onFork {
        (bool ok, bytes memory ret) = LIVE_EXECUTOR.staticcall(abi.encodeWithSignature("rams()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), address(LIVE_RAMS), "executor bound to the live registry");

        (ok, ret) = LIVE_EXECUTOR.staticcall(abi.encodeWithSignature("principal()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), LIVE_ADMIN, "executor principal is the deployer EOA");
    }

    // ------------------------------------------------------------------
    // State-changing (fork-local only): our token composed with their live
    // registry state machine, end to end
    // ------------------------------------------------------------------

    function test_Fork_GatedUSDRamsAgainstLiveRegistry() public onFork {
        DelegationMirror mirror = new DelegationMirror();
        GatedUSDRams gusd = new GatedUSDRams(address(mirror), LIVE_RAMS, true);

        address principal = makeAddr("forkPrincipal");
        address agent = makeAddr("forkAgent");
        address sink = makeAddr("forkSink");

        gusd.faucetMint(principal, 1_000e6);
        vm.prank(principal);
        gusd.approve(agent, type(uint256).max);

        // Eligibility on the LIVE provider requires its operator; impersonate
        // the observed owner (fork-local prank, nothing broadcast).
        bytes32 identityRef = keccak256("fork-attestation");
        vm.prank(LIVE_ADMIN);
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

        vm.prank(agent);
        gusd.transferFrom(principal, sink, 90e6);
        assertEq(gusd.balanceOf(sink), 90e6);
        assertEq(LIVE_RAMS.getMandate(agent, principal).cumulativeUsed, 90e6, "recorded on the live registry");

        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(GatedUSDRams.RamsBlocked.selector, agent, principal, bytes32("RAMS_OVER_TX_CAP"))
        );
        gusd.transferFrom(principal, sink, 101e6);

        console2.log("fork: GatedUSDRams enforced caps against the live Sepolia AgentMandate");
    }
}
