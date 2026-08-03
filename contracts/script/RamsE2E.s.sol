// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";
import {GatedUSDRams} from "../src/GatedUSDRams.sol";
import {VARComplianceProviderAdapter} from "../src/rams/VARComplianceProviderAdapter.sol";
import {IAgentMandate} from "../src/interfaces/rams/IAgentMandate.sol";
import {IComplianceProvider} from "../src/interfaces/rams/IComplianceProvider.sol";

/// End-to-end proof against Brickken's LIVE AgentMandate on Ethereum Sepolia.
///
/// Produces the pair that is the actual demonstration:
///   1. a CLEARED agent-initiated transfer through our token, which calls their
///      canExecute and their recordExecution, followed by a read-back of
///      cumulativeUsed from THEIR registry showing it moved;
///   2. a BLOCKED transfer with our diagnostic returning the specific reason.
///
/// The read-back is the proof, not the receipt.
///
/// Dry run (no broadcast, deploys fresh contracts inside the simulation and
/// exercises the whole flow against the live registry):
///   forge script script/RamsE2E.s.sol --tc RamsE2E --rpc-url $ETH_SEPOLIA_RPC_URL
///
/// For real, after DeployRamsIntegration has run:
///   MIRROR=0x.. TOKEN=0x.. ADAPTER=0x.. \
///   forge script script/RamsE2E.s.sol --tc RamsE2E --rpc-url $ETH_SEPOLIA_RPC_URL --broadcast
///
/// Env:
///   SEPOLIA_DEPLOYER_PRIVATE_KEY  funds everything; acts as mirror owner,
///                                 attestor and principal
///   MIRROR / TOKEN / ADAPTER      optional; deployed in-simulation if unset
contract RamsE2E is Script {
    address internal constant LIVE_RAMS = 0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e;

    /// Real humanId for agent 0x69e170Dd…cC54 from AgentBook.lookupHuman on
    /// World Chain 480. keccak256(bytes32(HUMAN_ID)) is the proofRef its live
    /// Arc mandate carries, so the personhood binding here uses real data.
    uint256 internal constant HUMAN_ID =
        0x026c28de5fd602d237997e3ba77dac46a9a2e6750a59f68a4ae98d626f71db46; // pragma: allowlist secret

    uint256 internal constant MINT = 1_000e6;
    uint256 internal constant CLEARED = 90e6;
    uint256 internal constant MAX_PER_TX = 100e6;
    uint256 internal constant BLOCKED = 101e6; // deliberately over the per-tx cap
    uint256 internal constant AGENT_GAS = 0.004 ether; // enough for the agent's transferFrom

    struct Ctx {
        uint256 pk;
        uint256 agentPk;
        address principal;
        address agent;
        address sink;
        DelegationMirror mirror;
        GatedUSDRams token;
        VARComplianceProviderAdapter adapter;
    }

    function run() external {
        require(block.chainid == 11155111, "Ethereum Sepolia only");
        require(LIVE_RAMS.code.length > 0, "live registry has no code");

        Ctx memory c;
        c.pk = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        c.principal = vm.addr(c.pk);
        c.agentPk = uint256(keccak256(abi.encodePacked("var-rams-e2e-agent", c.principal)));
        c.agent = vm.addr(c.agentPk);
        c.sink = address(uint160(uint256(keccak256("var-rams-e2e-sink"))));
        (c.mirror, c.token, c.adapter) = _stack(c.pk);

        console2.log("principal :", c.principal);
        console2.log("agent     :", c.agent);
        console2.log("token     :", address(c.token));
        console2.log("adapter   :", address(c.adapter));

        bytes32 identityRef = _makeEligible(c);
        _grantMandate(c, identityRef);
        _cleared(c);
        _blocked(c);

        console2.log("E2E COMPLETE: one cleared with a registry read-back, one blocked with a reason code");
    }

    /// The cleared transfer, and the read-back from THEIR registry that proves it.
    function _cleared(Ctx memory c) internal {
        IAgentMandate rams = IAgentMandate(LIVE_RAMS);
        uint256 before = rams.getMandate(c.agent, c.principal).cumulativeUsed;
        console2.log("cumulativeUsed BEFORE (their registry):", before);

        vm.broadcast(c.agentPk);
        c.token.transferFrom(c.principal, c.sink, CLEARED);

        uint256 afterUsed = rams.getMandate(c.agent, c.principal).cumulativeUsed;
        console2.log("cumulativeUsed AFTER  (their registry):", afterUsed);
        require(afterUsed == before + CLEARED, "cumulativeUsed did not move on their registry");
        require(c.token.balanceOf(c.sink) == CLEARED, "sink did not receive");
        console2.log("CLEARED: their recordExecution accepted our token on the msg.sender == m.asset branch");
    }

    /// The blocked case, proven WITHOUT broadcasting.
    ///
    /// Deliberately not a broadcast transaction: forge simulates the whole batch
    /// before sending, and a batch containing an intentionally-reverting call is
    /// refused ("Simulated execution failed"), which would block the cleared
    /// transfer too. So the revert is proven here by staticcall -- same code
    /// path, same revert data, no state change -- and the operator lands a real
    /// reverted transaction afterwards with the `cast send` line printed below,
    /// which yields a receipt with status 0 for the writeup.
    function _blocked(Ctx memory c) internal {
        (bool ok, bytes32 reason) = c.token.canTransferBy(c.agent, c.principal, BLOCKED);
        require(!ok, "over-cap transfer should not pre-flight clean");
        require(reason == c.token.RAMS_OVER_TX_CAP(), "expected RAMS_OVER_TX_CAP");
        console2.log("BLOCKED pre-flight reason (canTransferBy):", vm.toString(reason));

        // Exercise the real transferFrom path AS THE AGENT, read-only. Without
        // the prank msg.sender would be this script, which has no mandate and
        // would revert RamsMandateRequired -- a different, misleading path.
        vm.prank(c.agent);
        (bool success, bytes memory err) = address(c.token).staticcall(
            abi.encodeCall(GatedUSDRams.transferFrom, (c.principal, c.sink, BLOCKED))
        );
        require(!success, "over-cap transfer unexpectedly succeeded");
        require(bytes4(err) == GatedUSDRams.RamsBlocked.selector, "expected RamsBlocked");
        (,, bytes32 blockedReason) = abi.decode(_strip(err), (address, address, bytes32));
        require(blockedReason == c.token.RAMS_OVER_TX_CAP(), "RamsBlocked carried the wrong reason");
        console2.log("BLOCKED: RamsBlocked(agent, holder, RAMS_OVER_TX_CAP), no funds moved");

        console2.log("To land a real reverted tx for the receipt, run:");
        console2.log(
            string.concat(
                "  cast send ",
                vm.toString(address(c.token)),
                ' "transferFrom(address,address,uint256)" ',
                vm.toString(c.principal),
                " ",
                vm.toString(c.sink),
                " 101000000 --private-key $AGENT_KEY --rpc-url $ETH_SEPOLIA_RPC_URL"
            )
        );
    }

    /// Drop the 4-byte selector so the error args can be decoded.
    function _strip(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i = 0; i < out.length; i++) out[i] = err[i + 4];
    }

    /// Load the deployed stack from env, or deploy one (used by the dry run).
    function _stack(uint256 pk)
        internal
        returns (DelegationMirror mirror, GatedUSDRams token, VARComplianceProviderAdapter adapter)
    {
        address m = vm.envOr("MIRROR", address(0));
        if (m != address(0)) {
            return (
                DelegationMirror(m),
                GatedUSDRams(vm.envAddress("TOKEN")),
                VARComplianceProviderAdapter(vm.envAddress("ADAPTER"))
            );
        }
        console2.log("MIRROR unset: deploying a fresh stack (dry run / first pass)");
        vm.startBroadcast(pk);
        mirror = new DelegationMirror();
        token = new GatedUSDRams(address(mirror), IAgentMandate(LIVE_RAMS), true);
        adapter = new VARComplianceProviderAdapter(mirror);
        vm.stopBroadcast();
    }

    /// Mirror attestation + adapter identity binding + personhood + funding.
    /// Split across helpers to stay under the stack limit without via-IR.
    function _makeEligible(Ctx memory c) internal returns (bytes32 identityRef) {
        identityRef = _attestAndBind(c);
        _submitPersonhood(c);
        _fund(c);

        (bool eligible, IComplianceProvider.ReasonCode reason,) =
            c.adapter.checkPrincipal(c.principal, identityRef);
        console2.log("adapter.checkPrincipal eligible:", eligible);
        console2.log("adapter.checkPrincipal reason  :", uint8(reason));
        require(eligible, "adapter must certify the principal before granting");
    }

    function _attestAndBind(Ctx memory c) internal returns (bytes32 identityRef) {
        DelegationMirror.Attestation memory a = DelegationMirror.Attestation({
            agent: c.agent,
            principal: c.principal,
            proofRef: c.adapter.proofRefFor(HUMAN_ID),
            kycRef: bytes32(0),
            spendCapPerTx: uint96(MAX_PER_TX),
            spendCapPerPeriod: uint96(MAX_PER_TX * 10),
            periodLength: 1 days,
            allowedToken: address(c.token),
            expiry: uint64(block.timestamp + 7 days),
            nonce: c.mirror.lastNonce(c.agent) + 1
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(c.pk, c.mirror.hashAttestation(a));

        vm.startBroadcast(c.pk);
        c.mirror.setAttestor(c.principal, true); // deployer is the mirror owner here
        c.mirror.submitAttestation(a, abi.encodePacked(r, s, v));
        identityRef = c.adapter.bindIdentity(a);
        vm.stopBroadcast();
    }

    function _submitPersonhood(Ctx memory c) internal {
        VARComplianceProviderAdapter.PersonhoodAttestation memory p = VARComplianceProviderAdapter
            .PersonhoodAttestation({
            agent: c.agent,
            humanId: HUMAN_ID,
            expiresAt: uint48(block.timestamp + 30 days),
            nonce: c.adapter.personhoodNonces(c.agent) + 1
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(c.pk, _personhoodDigest(c.adapter, p));

        vm.broadcast(c.pk);
        c.adapter.submitPersonhood(p, abi.encodePacked(r, s, v));
    }

    function _fund(Ctx memory c) internal {
        vm.startBroadcast(c.pk);
        c.token.faucetMint(c.principal, MINT);
        c.token.approve(c.agent, type(uint256).max);
        vm.stopBroadcast();

        // The agent broadcasts its own transferFrom, so it needs gas. Without
        // this a real run stalls halfway: mandate granted, nothing executed.
        // Only tops up if short, so re-runs do not drain the deployer.
        if (c.agent.balance < AGENT_GAS) {
            uint256 need = AGENT_GAS - c.agent.balance;
            if (c.principal.balance < need) {
                // Expected in a dry run against an unfunded key: report the
                // real requirement instead of failing on a simulated shortfall.
                require(
                    !vm.isContext(VmSafe.ForgeContext.ScriptBroadcast),
                    "deployer cannot fund the agent for gas; top up the deployer first"
                );
                console2.log("DRY RUN: deployer unfunded, skipping agent gas top-up. Real run needs (wei):", need);
                return;
            }
            vm.broadcast(c.pk);
            (bool sent,) = c.agent.call{value: need}("");
            require(sent, "could not fund the agent for gas");
        }
    }

    /// Grant on THEIR registry, with OUR adapter as the complianceProvider.
    function _grantMandate(Ctx memory c, bytes32 identityRef) internal {
        uint256 pk = c.pk;
        IAgentMandate rams = IAgentMandate(LIVE_RAMS);
        VARComplianceProviderAdapter adapter = c.adapter;
        GatedUSDRams token = c.token;
        address principal = c.principal;
        address agent = c.agent;
        bytes32[] memory actions = new bytes32[](1);
        actions[0] = bytes32(GatedUSDRams.transferFrom.selector);

        vm.broadcast(pk); // msg.sender == principal, so no signature needed
        rams.grantMandate(
            IAgentMandate.GrantMandateParams({
                agent: agent,
                validFrom: uint48(block.timestamp),
                validUntil: uint48(block.timestamp + 1 days),
                principal: principal,
                complianceProvider: address(adapter),
                identityRef: identityRef,
                asset: address(token),
                maxTransactionValue: MAX_PER_TX,
                maxCumulativeValue: MAX_PER_TX * 5,
                metadata: bytes32(0),
                actions: actions,
                deadline: block.timestamp + 1 hours
            }),
            ""
        );
        console2.log("mandate granted on their registry, complianceProvider = our adapter");
    }

    function _personhoodDigest(
        VARComplianceProviderAdapter adapter,
        VARComplianceProviderAdapter.PersonhoodAttestation memory p
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("PersonhoodAttestation(address agent,uint256 humanId,uint48 expiresAt,uint256 nonce)"),
                p.agent,
                p.humanId,
                p.expiresAt,
                p.nonce
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("VARPersonhood"),
                keccak256("1"),
                block.chainid,
                address(adapter)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
