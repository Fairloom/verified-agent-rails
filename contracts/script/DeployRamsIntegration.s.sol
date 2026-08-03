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
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// Deploys the ERC-8226 integration to Ethereum Sepolia (11155111), where the
/// live RAMS registry runs (the task originally said Base Sepolia; Phase 0
/// verification found no deployment there — see docs/rams/verification-status.md):
///   1. DelegationMirror  (VAR's attestation layer for this chain)
///   2. GatedUSDRams      (strict mode) pointed at the live AgentMandate
///   3. VARComplianceProviderAdapter fronting the mirror
/// then updates ../shared/addresses.json under "eth-sepolia" and runs the
/// post-deploy sanity checks (also available standalone via RamsSanityCheck).
///
/// Run:
///   forge script script/DeployRamsIntegration.s.sol \
///     --rpc-url $ETH_SEPOLIA_RPC_URL --broadcast
///
/// Env:
///   SEPOLIA_DEPLOYER_PRIVATE_KEY  Sepolia-only deployer key (never logged)
///   RAMS_REGISTRY          override the AgentMandate address (default: live)
///   OWNER_MULTISIG         optional; receives mirror+token ownership
///
/// Verify on Etherscan (ETHERSCAN_API_KEY required), or `make verify-rams`:
///   forge verify-contract --chain sepolia <MIRROR> src/DelegationMirror.sol:DelegationMirror
///   forge verify-contract --chain sepolia <TOKEN> src/GatedUSDRams.sol:GatedUSDRams \
///     --constructor-args $(cast abi-encode "constructor(address,address,bool)" <MIRROR> <REGISTRY> true)
///   forge verify-contract --chain sepolia <ADAPTER> src/rams/VARComplianceProviderAdapter.sol:VARComplianceProviderAdapter \
///     --constructor-args $(cast abi-encode "constructor(address)" <MIRROR>)
contract DeployRamsIntegration is Script {
    /// Live AgentMandate on Ethereum Sepolia (Brickken, bytecode == EIP reference).
    address internal constant DEFAULT_RAMS_REGISTRY = 0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e;
    address internal constant LIVE_COMPLIANCE_PROVIDER = 0xa90D2503D5D9b80ECC27856Ff76F892B8C02f278;
    address internal constant LIVE_AGENT_EXECUTOR = 0xc81949Cf5b52BDc7890Fd5040A9Cd0cdb4B59952;

    /// The Arc mirror owner / proveHappyPath principal. Deploying Sepolia from
    /// this key would extend a single key's authority to a third chain and make
    /// repo-brief.md 8.3 (role concentration) worse, while we publish a review
    /// criticising exactly that. Refuse it.
    address internal constant FORBIDDEN_DEPLOYER = 0x54E7B896Fe9a5f6A55551Bb4D15A4f1175891dec;

    function run() external {
        // Dedicated Sepolia key. Deliberately NOT DEPLOYER_PRIVATE_KEY.
        uint256 deployerKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        require(vm.addr(deployerKey) != FORBIDDEN_DEPLOYER, "use a Sepolia-only key, not the Arc mirror owner");
        IAgentMandate registry = IAgentMandate(vm.envOr("RAMS_REGISTRY", DEFAULT_RAMS_REGISTRY));

        require(block.chainid == 11155111, "target Ethereum Sepolia (see verification-status.md)");
        require(address(registry).code.length > 0, "RAMS registry has no code on this chain");

        vm.startBroadcast(deployerKey);
        DelegationMirror mirror = new DelegationMirror();
        uint256 mirrorBlock = block.number;
        GatedUSDRams token = new GatedUSDRams(address(mirror), registry, true); // strict mode
        uint256 tokenBlock = block.number;
        VARComplianceProviderAdapter adapter = new VARComplianceProviderAdapter(mirror);
        uint256 adapterBlock = block.number;

        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (ownerMultisig != address(0)) {
            mirror.transferOwnership(ownerMultisig);
            token.transferOwnership(ownerMultisig);
        }
        vm.stopBroadcast();

        _sanity(registry, mirror, token, adapter);

        // A dry run deploys into the simulation EVM and gets real-looking
        // addresses that exist nowhere on chain. Writing those into the shared
        // address book is how a false "we deployed" claim gets manufactured, so
        // only persist when we are actually broadcasting.
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("DRY RUN: address book NOT written (re-run with --broadcast to persist)");
            console2.log("would-be DelegationMirror:    ", address(mirror));
            console2.log("would-be GatedUSDRams:        ", address(token));
            console2.log("would-be adapter:             ", address(adapter));
            return;
        }

        // addresses.json gains an "eth-sepolia" section; the Arc entries at the
        // top level are left untouched.
        string memory json = "eth-sepolia";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeString(json, "DelegationMirror", _entry(address(mirror), mirrorBlock));
        vm.serializeString(json, "GatedUSDRams", _entry(address(token), tokenBlock));
        vm.serializeString(json, "VARComplianceProviderAdapter", _entry(address(adapter), adapterBlock));
        vm.serializeAddress(json, "AgentMandate", address(registry));
        vm.serializeAddress(json, "ComplianceProvider", LIVE_COMPLIANCE_PROVIDER);
        string memory out = vm.serializeAddress(json, "AgentExecutor", LIVE_AGENT_EXECUTOR);
        vm.writeJson(out, "../shared/addresses.json", ".eth-sepolia");

        console2.log("DelegationMirror:            ", address(mirror));
        console2.log("GatedUSDRams (strict):       ", address(token));
        console2.log("VARComplianceProviderAdapter:", address(adapter));
    }

    /// Post-deploy sanity: read-only checks that the wiring points where we
    /// think it does before anyone grants a mandate against it.
    function _sanity(
        IAgentMandate registry,
        DelegationMirror mirror,
        GatedUSDRams token,
        VARComplianceProviderAdapter adapter
    ) internal view {
        require(address(token.rams()) == address(registry), "token -> registry wiring");
        require(address(token.mirror()) == address(mirror), "token -> mirror wiring");
        require(token.strictMandates(), "strict mode expected");
        require(token.decimals() == 6, "6 decimals");
        require(address(adapter.mirror()) == address(mirror), "adapter -> mirror wiring");
        require(
            adapter.supportsInterface(type(IComplianceProvider).interfaceId)
                && adapter.supportsInterface(type(IERC165).interfaceId),
            "adapter ERC-165"
        );
        require(
            IERC165(address(registry)).supportsInterface(type(IAgentMandate).interfaceId),
            "registry does not answer IAgentMandate ERC-165"
        );
        require(registry.DOMAIN_SEPARATOR() != bytes32(0), "registry domain separator");
        require(!registry.canExecute(address(1), address(2), address(token), bytes32(0), 0), "canExecute sane");
        console2.log("post-deploy sanity: all checks passed");
    }

    function _entry(address addr, uint256 deployBlock) internal returns (string memory) {
        string memory obj = string.concat("entry_", vm.toString(addr));
        vm.serializeAddress(obj, "address", addr);
        return vm.serializeUint(obj, "deployBlock", deployBlock);
    }
}

/// Standalone read-only sanity pass against an existing deployment:
///   forge script script/DeployRamsIntegration.s.sol:RamsSanityCheck \
///     --sig "check(address,address,address)" <MIRROR> <TOKEN> <ADAPTER> \
///     --rpc-url $ETH_SEPOLIA_RPC_URL
contract RamsSanityCheck is Script {
    function check(address mirror, address token, address adapter) external view {
        GatedUSDRams t = GatedUSDRams(token);
        require(address(t.mirror()) == mirror, "token -> mirror wiring");
        require(address(t.rams()).code.length > 0, "registry code");
        require(address(VARComplianceProviderAdapter(adapter).mirror()) == mirror, "adapter -> mirror wiring");
        (bool ok, bytes32 reason) = t.canTransferBy(address(1), address(2), 1);
        require(t.strictMandates() ? (!ok && reason == t.RAMS_NO_MANDATE()) : ok, "strictness behavior");
        console2.log("sanity: ok");
    }
}
