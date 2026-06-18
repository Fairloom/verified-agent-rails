// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {GatedUSD} from "./GatedUSD.sol";

/// @title MockYieldVault
/// @notice Production target is USYC on Arc (allowlist-gated); mocked for the weekend.
///         Minimal ERC-4626 over GatedUSD. The exchange rate ticks up deterministically
///         per block so the UI shows a growing number. Yield is realized by faucet
///         minting gUSD to the vault on sync, keeping share math solvent.
contract MockYieldVault is ERC4626 {
    /// 1 basis point of yield per block on vault assets.
    uint256 public constant YIELD_BPS_PER_BLOCK = 1;
    uint256 public constant BPS = 10_000;

    uint256 public lastSyncBlock;

    constructor(GatedUSD asset_) ERC4626(IERC20(address(asset_))) ERC20("Mock Yield gUSD", "mygUSD") {
        lastSyncBlock = block.number;
    }

    /// @dev Pending yield accrued since the last sync, deterministic per block.
    function pendingYield() public view returns (uint256) {
        uint256 held = IERC20(asset()).balanceOf(address(this));
        uint256 blocksElapsed = block.number - lastSyncBlock;
        return (held * YIELD_BPS_PER_BLOCK * blocksElapsed) / BPS;
    }

    /// @dev Virtual balance including unrealized yield, so the exchange rate grows every block.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + pendingYield();
    }

    /// @notice Realize pending yield by faucet minting it into the vault.
    function sync() public {
        uint256 accrued = pendingYield();
        lastSyncBlock = block.number;
        if (accrued > 0) {
            GatedUSD(asset()).faucetMint(address(this), accrued);
        }
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        sync();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        sync();
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
