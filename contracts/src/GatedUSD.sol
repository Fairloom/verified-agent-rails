// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DelegationMirror} from "./DelegationMirror.sol";

/// @title GatedUSD
/// @notice Demo stablecoin with 6 decimals, mirroring USDC on Arc. Transfers from
///         addresses holding a mandate in the DelegationMirror are gated by the
///         mirror's checkTransfer. Humans and contracts without a mandate transfer
///         freely. Exposes the ERC-7943 canTransfer surface (Final).
contract GatedUSD is ERC20, Ownable {
    DelegationMirror public immutable mirror;

    /// @notice Addresses permitted to mint. The deployer (owner) is implicitly
    ///         permitted; the yield vault is registered here so it can realize
    ///         accrued yield. A production token would have no mint at all.
    mapping(address minter => bool) public isMinter;

    error TransferBlocked(bytes32 reason);
    error NotMinter(address caller);

    event MinterSet(address indexed minter, bool allowed);

    constructor(address mirror_) ERC20("Gated USD", "gUSD") Ownable(msg.sender) {
        mirror = DelegationMirror(mirror_);
    }

    /// @notice Grant or revoke mint permission. Owner only.
    function setMinter(address minter, bool allowed) external onlyOwner {
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev Gate only registered agent addresses: a sender with no mandate in the
    ///      mirror (principal == 0) is not an agent and moves funds freely. For a
    ///      gated transfer, record the spend after it settles so the mirror can
    ///      accumulate the per-period cap (the mirror is the single source of
    ///      mandate truth; this token holds no mandate state).
    function _update(address from, address to, uint256 value) internal override {
        bool gated = from != address(0) && mirror.isRegistered(from);
        if (gated) {
            (bool ok, bytes32 reason) = mirror.checkTransfer(from, address(this), value);
            if (!ok) revert TransferBlocked(reason);
        }
        super._update(from, to, value);
        if (gated) {
            mirror.recordSpend(from, value);
        }
    }

    /// @notice ERC-7943 compliance surface. Thin wrapper over the mirror's checkTransfer.
    function canTransfer(address from, address to, uint256 amount) external view returns (bool) {
        to; // unused, kept for the ERC-7943 signature
        if (from == address(0)) return true;
        if (!mirror.isRegistered(from)) return true;
        (bool ok,) = mirror.checkTransfer(from, address(this), amount);
        return ok;
    }

    /// @notice Demo faucet mint, access-controlled: owner or a registered minter
    ///         only (the latter is the yield vault realizing accrued yield). This
    ///         keeps the reference implementation free of an unrestricted public
    ///         mint; a production token would drop this function entirely.
    function faucetMint(address to, uint256 amount) public {
        if (msg.sender != owner() && !isMinter[msg.sender]) revert NotMinter(msg.sender);
        _mint(to, amount);
    }
}
