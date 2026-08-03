// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AttestationHelper} from "../AttestationHelper.sol";
import {DelegationMirror} from "../../src/DelegationMirror.sol";
import {GatedUSDRams} from "../../src/GatedUSDRams.sol";
import {IAgentMandate} from "../../src/interfaces/rams/IAgentMandate.sol";
import {IComplianceProvider} from "../../src/interfaces/rams/IComplianceProvider.sol";
import {IAgentExecutor} from "../../src/interfaces/rams/IAgentExecutor.sol";

/// @dev Owner surface of the reference ComplianceProvider/AgentExecutor,
///      beyond what the ERC-8226 interfaces expose.
interface IRefExecutorAdmin {
    function setAction(bytes4 selector, bool supported, bool hasAmount, uint8 amountIndex) external;
}

/// @notice Shared fixture for the ERC-8226 integration suites. Deploys the
///         REAL reference implementation (bytecode-identical to the live
///         Ethereum Sepolia deployment, prebuilt at test/rams-artifacts since
///         the reference needs solc 0.8.30 and this repo pins 0.8.26) next to
///         the VAR stack, and signs GrantMandate over the spec's EIP-712
///         domain ("RAMS", "1").
abstract contract RamsTestBase is AttestationHelper {
    bytes32 internal constant GRANT_MANDATE_TYPEHASH = keccak256(
        "GrantMandate(address agent,uint48 validFrom,uint48 validUntil,"
        "address principal,address complianceProvider,bytes32 identityRef,"
        "address asset,uint256 maxTransactionValue,uint256 maxCumulativeValue,"
        "bytes32 metadata,bytes32[] actions,uint256 nonce,uint256 deadline)"
    );
    bytes32 internal constant REVOKE_MANDATE_TYPEHASH =
        keccak256("RevokeMandate(address agent,address principal,uint256 nonce,uint256 deadline)");

    // Local copies of GatedUSDRams' reason codes so expectRevert encodings make
    // no external calls (which would consume vm.prank). Parity with the
    // contract's constants is asserted in test_ReasonCodeParity.
    bytes32 internal constant ACTION_TRANSFER_FROM = bytes32(GatedUSDRams.transferFrom.selector);
    bytes32 internal constant RAMS_NO_MANDATE = "RAMS_NO_MANDATE";
    bytes32 internal constant RAMS_WRONG_ASSET = "RAMS_WRONG_ASSET";
    bytes32 internal constant RAMS_NOT_YET_VALID = "RAMS_NOT_YET_VALID";
    bytes32 internal constant RAMS_EXPIRED = "RAMS_EXPIRED";
    bytes32 internal constant RAMS_REVOKED = "RAMS_REVOKED";
    bytes32 internal constant RAMS_ACTION_DISABLED = "RAMS_ACTION_DISABLED";
    bytes32 internal constant RAMS_FROZEN = "RAMS_FROZEN";
    bytes32 internal constant RAMS_OVER_TX_CAP = "RAMS_OVER_TX_CAP";
    bytes32 internal constant RAMS_OVER_CUM_CAP = "RAMS_OVER_CUM_CAP";
    bytes32 internal constant RAMS_PRINCIPAL_INELIGIBLE = "RAMS_PRINCIPAL_INELIGIBLE";
    bytes32 internal constant VAR_OVER_CAP = "OVER_CAP";

    address internal ramsAdmin = makeAddr("ramsAdmin");
    address internal complianceOperator = makeAddr("complianceOperator");
    address internal enforcer = makeAddr("enforcer");

    IAgentMandate internal rams;
    IComplianceProvider internal refProvider;

    DelegationMirror internal mirror;
    GatedUSDRams internal gusd; // strict by default; suites can deploy others

    function _deployRamsStack() internal {
        rams = IAgentMandate(_deployArtifact("AgentMandate", abi.encode(ramsAdmin)));
        refProvider = IComplianceProvider(_deployArtifact("ComplianceProvider", abi.encode(complianceOperator)));
        vm.prank(ramsAdmin);
        (bool ok,) = address(rams).call(abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("ENFORCER_ROLE"), enforcer));
        require(ok, "enforcer grant failed");

        mirror = new DelegationMirror();
        _registerAttestor(mirror);
        gusd = new GatedUSDRams(address(mirror), rams, true);
    }

    /// @dev Deploy a prebuilt reference artifact with constructor args.
    function _deployArtifact(string memory name, bytes memory ctorArgs) internal returns (address deployed) {
        bytes memory creation =
            bytes.concat(vm.getCode(string.concat("test/rams-artifacts/", name, ".json")), ctorArgs);
        assembly {
            deployed := create(0, add(creation, 0x20), mload(creation))
        }
        require(deployed != address(0), "artifact deploy failed");
    }

    function _deployExecutor(address principal, address owner) internal returns (IAgentExecutor exec) {
        exec = IAgentExecutor(_deployArtifact("AgentExecutor", abi.encode(address(rams), principal, owner)));
        // transferFrom(address from, address to, uint256 amount): amount at arg index 2.
        vm.prank(owner);
        IRefExecutorAdmin(address(exec)).setAction(GatedUSDRams.transferFrom.selector, true, true, 2);
        // The reference executor records executions itself, so the registry
        // admin must grant it RECORDER_ROLE — recordExecution only admits the
        // mandate's asset, the principal, or a recorder. (The live Sepolia
        // deployment has granted no recorder, so its executor path cannot
        // record; see the security review notes.)
        vm.prank(ramsAdmin);
        (bool ok,) = address(rams).call(
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("RECORDER_ROLE"), address(exec))
        );
        require(ok, "recorder grant failed");
    }

    // -------------------------------------------------------------------
    // GrantMandate helpers (spec EIP-712 domain: name "RAMS", version "1")
    // -------------------------------------------------------------------

    function _defaultParams(address agent, address principal, address asset)
        internal
        view
        returns (IAgentMandate.GrantMandateParams memory p)
    {
        bytes32[] memory actions = new bytes32[](1);
        actions[0] = bytes32(GatedUSDRams.transferFrom.selector);
        p = IAgentMandate.GrantMandateParams({
            agent: agent,
            validFrom: uint48(block.timestamp),
            validUntil: uint48(block.timestamp + 7 days),
            principal: principal,
            complianceProvider: address(refProvider),
            identityRef: keccak256("test-attestation-id"),
            asset: asset,
            maxTransactionValue: 100e6,
            maxCumulativeValue: 250e6,
            metadata: bytes32(0),
            actions: actions,
            deadline: block.timestamp + 1 hours
        });
    }

    function _grantDigest(IAgentMandate.GrantMandateParams memory p) internal view returns (bytes32) {
        // Split encode (byte-identical to one abi.encode) to dodge stack-too-deep
        // on the 14-field struct without via-IR.
        bytes32 actionsHash = keccak256(abi.encodePacked(p.actions));
        uint256 nonce = rams.nonces(p.principal);
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    GRANT_MANDATE_TYPEHASH, p.agent, p.validFrom, p.validUntil, p.principal, p.complianceProvider
                ),
                abi.encode(
                    p.identityRef, p.asset, p.maxTransactionValue, p.maxCumulativeValue, p.metadata, actionsHash,
                    nonce, p.deadline
                )
            )
        );
        return _ramsTypedDigest(structHash);
    }

    function _revokeDigest(address agent, address principal, uint256 deadline) internal view returns (bytes32) {
        return _ramsTypedDigest(
            keccak256(abi.encode(REVOKE_MANDATE_TYPEHASH, agent, principal, rams.nonces(principal), deadline))
        );
    }

    function _ramsTypedDigest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", rams.DOMAIN_SEPARATOR(), structHash));
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Make `principal` eligible on the reference provider, then grant via
    ///      the direct (msg.sender == principal, empty signature) path.
    function _grantDirect(IAgentMandate.GrantMandateParams memory p) internal {
        vm.prank(complianceOperator);
        refProvider.grantPrincipal(p.principal, p.identityRef, uint48(block.timestamp + 30 days));
        vm.prank(p.principal);
        rams.grantMandate(p, "");
    }

    /// @dev Make `principal` eligible, then grant via the EIP-712 signed path
    ///      submitted by an unrelated relayer.
    function _grantSigned(IAgentMandate.GrantMandateParams memory p, uint256 principalKey) internal {
        vm.prank(complianceOperator);
        refProvider.grantPrincipal(p.principal, p.identityRef, uint48(block.timestamp + 30 days));
        bytes memory sig = _signDigest(principalKey, _grantDigest(p));
        vm.prank(makeAddr("relayer"));
        rams.grantMandate(p, sig);
    }
}
