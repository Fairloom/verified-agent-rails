// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";

/// Registers (or deregisters) an attestor on a deployed DelegationMirror. The
/// mirror rejects any signer that is not a registered attestor, so the attestor
/// key the builder signs with must be set here by the owner before any real
/// submit. This is the single most trust-sensitive call in the system: whoever
/// holds a registered attestor key can mint mandates. Today it points at one
/// dedicated operator key; production moves it behind a multisig via
/// setAttestor(multisig, true) then setAttestor(oldKey, false).
///
/// Run:
///   MIRROR_ADDRESS=0x.. ATTESTOR_ADDRESS=0x.. \
///   forge script script/SetAttestor.s.sol --rpc-url $ARC_TESTNET_RPC_URL --broadcast
///
/// The owner key is read from DEPLOYER_PRIVATE_KEY (env, never a CLI flag) and
/// never logged. ALLOWED defaults to true; set ALLOWED=false to deregister.
contract SetAttestor is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address mirrorAddr = vm.envAddress("MIRROR_ADDRESS");
        address attestor = vm.envAddress("ATTESTOR_ADDRESS");
        bool allowed = vm.envOr("ALLOWED", true);

        DelegationMirror mirror = DelegationMirror(mirrorAddr);

        vm.startBroadcast(ownerKey);
        mirror.setAttestor(attestor, allowed);
        vm.stopBroadcast();

        // Confirm the write landed so a silent no-op cannot pass for success.
        require(
            mirror.registeredAttestor(attestor) == allowed,
            "setAttestor did not take effect"
        );
    }
}
