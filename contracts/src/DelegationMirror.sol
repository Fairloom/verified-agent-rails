// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title DelegationMirror
/// @notice Onchain registry of scoped authority delegated by a World ID verified
///         principal to an AI agent. Sits in the agent-standards stack as the
///         asset-layer authorization complement to identity (ERC-8004 Trustless
///         Agents) and to wallet/account-layer authorization (ERC-8118 Agent
///         Authorization): identity answers "who is behind this agent", this
///         registry answers "what may it spend", and the constraint is enforced at
///         the token via ERC-7943 canTransfer (GatedUSD), so it holds even if the
///         agent's signing key is compromised. Vocabulary — mandate, principal,
///         scoped authority — follows that line. Acts as the transfer gate
///         consulted by GatedUSD. Mandates can only be created through
///         submitAttestation with a registered attestor's EIP-712 signature; there
///         is no permissionless path, which is what closes the squatting attack.
contract DelegationMirror is Ownable, EIP712 {
    struct Mandate {
        address principal;
        bytes32 proofRef;
        bytes32 kycRef;
        uint96 spendCapPerTx;
        uint96 spendCapPerPeriod;
        uint64 periodLength;
        address allowedToken;
        uint64 expiry;
        bool revoked;
        // Cumulative-spend bookkeeping for the per-period cap. spentThisPeriod is
        // the amount spent in the window that opened at periodStart. periodStart is
        // 0 until the first gated spend, then set to that spend's block.timestamp.
        // recordSpend maintains both; checkTransfer reads them with rollover.
        uint96 spentThisPeriod;
        uint64 periodStart;
        // The attestation nonce that wrote this mandate. Mirrors lastNonce[agent].
        uint256 nonce;
    }

    /// @notice Signed payload an attestor produces offchain to authorize a mandate.
    ///         Field order is consensus-locked with CJ's TS signer and Vlad's
    ///         pipeline signer; do not reorder unilaterally.
    // TODO(workstream-A): replace this local copy with the shared schema module
    // CJ owns once it exists, so Solidity and TS share one source of truth.
    struct Attestation {
        address agent;
        address principal;
        bytes32 proofRef;
        bytes32 kycRef;
        uint96 spendCapPerTx;
        uint96 spendCapPerPeriod;
        uint64 periodLength;
        address allowedToken;
        uint64 expiry;
        uint256 nonce;
    }

    /// @dev EIP-712 type hash. Member list and order must match the Attestation
    ///      struct above and CJ's and Vlad's typed-data definitions exactly.
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(address agent,address principal,bytes32 proofRef,bytes32 kycRef,uint96 spendCapPerTx,uint96 spendCapPerPeriod,uint64 periodLength,address allowedToken,uint64 expiry,uint256 nonce)"
    );

    /// Machine readable reason codes, evaluated in this order.
    bytes32 public constant OK = "OK";
    bytes32 public constant NO_MANDATE = "NO_MANDATE";
    bytes32 public constant REVOKED = "REVOKED";
    bytes32 public constant EXPIRED = "EXPIRED";
    bytes32 public constant OVER_CAP = "OVER_CAP";
    bytes32 public constant TOKEN_NOT_ALLOWED = "TOKEN_NOT_ALLOWED";
    bytes32 public constant OVER_PERIOD_CAP = "OVER_PERIOD_CAP";

    mapping(address agent => Mandate) public mandates;

    /// @notice Addresses allowed to sign attestations. Owner-managed today; a
    ///         multisig is a later task.
    mapping(address attestor => bool) public registeredAttestor;

    /// @notice Highest attestation nonce consumed per agent. Strictly increasing,
    ///         so a replayed or equal nonce reverts and a revoked or expired
    ///         mandate can only be reopened by a fresh attestation carrying a
    ///         higher nonce. Default 0 means nonces must start at 1.
    mapping(address agent => uint256) public lastNonce;

    event Delegated(
        address indexed agent, address indexed principal, bytes32 proofRef, uint96 cap, uint64 expiry, address token
    );
    event Revoked(address indexed agent, address indexed principal);
    event AttestationSubmitted(
        address indexed agent, address indexed principal, address indexed attestor, uint256 nonce
    );
    event AttestorSet(address indexed attestor, bool allowed);
    /// @notice Emitted when a gated transfer accumulates against the period cap.
    event Spent(address indexed agent, uint256 amount, uint96 spentThisPeriod, uint64 periodStart);

    error ZeroAgent();
    error ZeroPrincipal();
    error InvalidAttestor(address signer);
    error StaleNonce(address agent, uint256 provided, uint256 last);
    error NoMandateFor(address agent);
    error NotPrincipal(address agent, address caller);
    error NotGatedToken(address caller, address agent);

    constructor() Ownable(msg.sender) EIP712("DelegationMirror", "1") {}

    /// @notice Register or deregister an attestor signing key.
    // TODO(workstream-A): move attestor management behind a multisig owner.
    function setAttestor(address attestor, bool allowed) external onlyOwner {
        registeredAttestor[attestor] = allowed;
        emit AttestorSet(attestor, allowed);
    }

    /// @notice EIP-712 domain separator for the deployed instance. Exposed so CJ
    ///         and Vlad can diff their domain builders against the live value.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice EIP-712 hashStruct of an attestation. Address-independent, so it is
    ///         the primary cross-implementation diff target for signer parity.
    function hashStruct(Attestation calldata a) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTESTATION_TYPEHASH,
                a.agent,
                a.principal,
                a.proofRef,
                a.kycRef,
                a.spendCapPerTx,
                a.spendCapPerPeriod,
                a.periodLength,
                a.allowedToken,
                a.expiry,
                a.nonce
            )
        );
    }

    /// @notice Full EIP-712 digest a signer signs and submitAttestation recovers.
    function hashAttestation(Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(hashStruct(a));
    }

    /// @notice Create or replace an agent's mandate from an attestor-signed
    ///         payload. This is the ONLY way a mandate is created. The signature
    ///         must recover to a registered attestor, and the nonce must be
    ///         strictly higher than the agent's last consumed nonce, so neither
    ///         an unauthorized party nor a replay of a previous attestation can
    ///         create or reopen a mandate. Any tampered field changes the digest,
    ///         recovers a different signer, and reverts InvalidAttestor.
    function submitAttestation(Attestation calldata a, bytes calldata sig) external {
        if (a.agent == address(0)) revert ZeroAgent();
        if (a.principal == address(0)) revert ZeroPrincipal();

        address signer = ECDSA.recover(_hashTypedDataV4(hashStruct(a)), sig);
        if (!registeredAttestor[signer]) revert InvalidAttestor(signer);

        uint256 last = lastNonce[a.agent];
        if (a.nonce <= last) revert StaleNonce(a.agent, a.nonce, last);
        lastNonce[a.agent] = a.nonce;

        mandates[a.agent] = Mandate({
            principal: a.principal,
            proofRef: a.proofRef,
            kycRef: a.kycRef,
            spendCapPerTx: a.spendCapPerTx,
            spendCapPerPeriod: a.spendCapPerPeriod,
            periodLength: a.periodLength,
            allowedToken: a.allowedToken,
            expiry: a.expiry,
            revoked: false,
            // Fresh window: no spend yet. periodStart stays 0 until the first
            // gated spend, at which point recordSpend opens the window.
            spentThisPeriod: 0,
            periodStart: 0,
            nonce: a.nonce
        });

        emit AttestationSubmitted(a.agent, a.principal, signer, a.nonce);
        emit Delegated(a.agent, a.principal, a.proofRef, a.spendCapPerTx, a.expiry, a.allowedToken);
    }

    /// @notice Kill switch. Only the principal of the mandate. Local and instant.
    function revoke(address agent) external {
        Mandate storage m = mandates[agent];
        if (m.principal == address(0)) revert NoMandateFor(agent);
        if (msg.sender != m.principal) revert NotPrincipal(agent, msg.sender);
        m.revoked = true;
        emit Revoked(agent, msg.sender);
    }

    function getMandate(address agent) external view returns (Mandate memory) {
        return mandates[agent];
    }

    /// @notice True once an agent has a mandate on record. GatedUSD uses this to
    ///         decide whether to gate a sender, so the token never destructures
    ///         the Mandate tuple and stays decoupled from its field layout. A
    ///         revoked mandate still reads as registered; checkTransfer returns
    ///         REVOKED for it.
    function isRegistered(address agent) external view returns (bool) {
        return mandates[agent].principal != address(0);
    }

    /// @notice Evaluates whether `from` may move `amount` of `token` under its mandate.
    ///         Reason codes are evaluated in declaration order; the per-period cap
    ///         is checked last, after the per-tx cap and the token, and is additive
    ///         (it never changes the per-tx outcome).
    function checkTransfer(address from, address token, uint256 amount)
        external
        view
        returns (bool ok, bytes32 reason)
    {
        Mandate storage m = mandates[from];
        if (m.principal == address(0)) return (false, NO_MANDATE);
        if (m.revoked) return (false, REVOKED);
        if (block.timestamp >= m.expiry) return (false, EXPIRED);
        if (amount > m.spendCapPerTx) return (false, OVER_CAP);
        if (token != m.allowedToken) return (false, TOKEN_NOT_ALLOWED);
        // Cumulative per-period cap. spendCapPerPeriod == 0 means no period limit
        // (per-tx only), so existing mandates are unaffected. The window rolls in
        // this VIEW too: if it has elapsed (or never opened), effective spend is 0,
        // so the view never reports stale period state before recordSpend writes it.
        if (m.spendCapPerPeriod > 0 && m.periodLength > 0) {
            uint256 spent = _periodRolled(m) ? 0 : m.spentThisPeriod;
            if (spent + amount > m.spendCapPerPeriod) return (false, OVER_PERIOD_CAP);
        }
        return (true, OK);
    }

    /// @notice Record a successful gated spend so the per-period cap accumulates.
    ///         Accumulation lives in the mirror (Option A) so the mirror stays the
    ///         single source of mandate truth and the token holds no mandate state.
    ///         Only the agent's own allowedToken (the attestor-signed gated token)
    ///         may call, which binds recording authority to the signed mandate and
    ///         needs no separate owner-managed token registry or deploy step.
    /// @dev    The caller (GatedUSD._update) calls checkTransfer first and reverts
    ///         on a non-OK reason, so by here amount <= spendCapPerTx and the
    ///         uint96 cast is exact, and spentThisPeriod <= spendCapPerPeriod holds.
    function recordSpend(address agent, uint256 amount) external {
        Mandate storage m = mandates[agent];
        if (m.principal == address(0)) revert NoMandateFor(agent);
        if (msg.sender != m.allowedToken) revert NotGatedToken(msg.sender, agent);
        if (_periodRolled(m)) {
            m.periodStart = uint64(block.timestamp);
            m.spentThisPeriod = uint96(amount);
        } else {
            m.spentThisPeriod += uint96(amount);
        }
        emit Spent(agent, amount, m.spentThisPeriod, m.periodStart);
    }

    /// @dev True when the agent's period window is fresh: none has opened yet
    ///      (periodStart == 0) or the current one has elapsed. Shared by the view
    ///      (checkTransfer) and the writer (recordSpend) so they never disagree.
    function _periodRolled(Mandate storage m) private view returns (bool) {
        return m.periodStart == 0 || block.timestamp >= uint256(m.periodStart) + uint256(m.periodLength);
    }
}
