// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {DelegationMirror} from "../src/DelegationMirror.sol";

/// @notice Prints and locks the EIP-712 vectors CJ's TS signer and Vlad's
///         pipeline signer must reproduce. Run:
///           forge test --match-path test/Eip712Coordination.t.sol -vv
///
///         The hashStruct and typehash are address-independent and are the
///         primary diff targets. The domain separator additionally depends on
///         verifyingContract (the deployed mirror), so it resolves at deploy;
///         the value logged here is for the in-test mirror address logged
///         alongside it, which CJ/Vlad can reproduce by plugging that address.
contract Eip712CoordinationTest is Test {
    DelegationMirror internal mirror;

    // Fixed sample so every implementation hashes the same bytes.
    address internal constant SAMPLE_AGENT = address(0xA11CE);
    address internal constant SAMPLE_PRINCIPAL = address(0xB0B);
    address internal constant SAMPLE_TOKEN = address(0xC0FFEE);
    bytes32 internal constant SAMPLE_PROOF_REF = keccak256("sample-proof");
    bytes32 internal constant SAMPLE_KYC_REF = keccak256("sample-kyc");
    uint96 internal constant SAMPLE_CAP_TX = 100_000_000; // 100 gUSD at 6 decimals
    uint96 internal constant SAMPLE_CAP_PERIOD = 1_000_000_000; // 1000 gUSD
    uint64 internal constant SAMPLE_PERIOD = 86_400; // 1 day
    uint64 internal constant SAMPLE_EXPIRY = 1_893_456_000; // 2030-01-01
    uint256 internal constant SAMPLE_NONCE = 1;

    function setUp() public {
        mirror = new DelegationMirror();
    }

    function _sample() internal pure returns (DelegationMirror.Attestation memory) {
        return DelegationMirror.Attestation({
            agent: SAMPLE_AGENT,
            principal: SAMPLE_PRINCIPAL,
            proofRef: SAMPLE_PROOF_REF,
            kycRef: SAMPLE_KYC_REF,
            spendCapPerTx: SAMPLE_CAP_TX,
            spendCapPerPeriod: SAMPLE_CAP_PERIOD,
            periodLength: SAMPLE_PERIOD,
            allowedToken: SAMPLE_TOKEN,
            expiry: SAMPLE_EXPIRY,
            nonce: SAMPLE_NONCE
        });
    }

    /// Locks the type string: if anyone reorders or retypes a field, this fails.
    function test_typehash_matchesLockedSchema() public view {
        bytes32 expected = keccak256(
            "Attestation(address agent,address principal,bytes32 proofRef,bytes32 kycRef,uint96 spendCapPerTx,uint96 spendCapPerPeriod,uint64 periodLength,address allowedToken,uint64 expiry,uint256 nonce)"
        );
        assertEq(mirror.ATTESTATION_TYPEHASH(), expected);
    }

    /// The digest must equal the standard "\x19\x01" || domainSeparator || hashStruct.
    function test_digest_isDomainPlusHashStruct() public view {
        DelegationMirror.Attestation memory a = _sample();
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", mirror.domainSeparator(), mirror.hashStruct(a)));
        assertEq(mirror.hashAttestation(a), expected);
    }

    /// Not an assertion; emits the vectors for cross-team diffing under -vv.
    function test_logCoordinationVectors() public view {
        DelegationMirror.Attestation memory a = _sample();
        console2.log("EIP-712 domain name: DelegationMirror");
        console2.log("EIP-712 domain version: 1");
        console2.log("chainId:", block.chainid);
        console2.log("verifyingContract (in-test mirror):", address(mirror));
        console2.log("ATTESTATION_TYPEHASH:");
        console2.logBytes32(mirror.ATTESTATION_TYPEHASH());
        console2.log("domainSeparator (for the address above):");
        console2.logBytes32(mirror.domainSeparator());
        console2.log("sample hashStruct (address-independent):");
        console2.logBytes32(mirror.hashStruct(a));
        console2.log("sample digest (hashAttestation):");
        console2.logBytes32(mirror.hashAttestation(a));
    }

    /// Same vectors recomputed at Arc testnet chainId 5042002. hashStruct and
    /// typehash do not change with chainId; the domain separator and digest do.
    function test_logArcChainVectors() public {
        vm.chainId(5042002);
        DelegationMirror.Attestation memory a = _sample();
        console2.log("--- chainId 5042002 (Arc testnet) ---");
        console2.log("verifyingContract (in-test mirror):", address(mirror));
        console2.log("domainSeparator @5042002:");
        console2.logBytes32(mirror.domainSeparator());
        console2.log("sample digest @5042002:");
        console2.logBytes32(mirror.hashAttestation(a));
    }
}
