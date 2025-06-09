// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";

contract UniswapV4Wrapper is ERC721WrapperBase {
    PoolId public immutable poolId;
    PoolKey public poolKey;
    IPoolManager public immutable poolManager;

    using SafeCast for uint256;

    struct TokensOwed {
        uint256 amount0Owed;
        uint256 amount1Owed;
    }

    mapping(uint256 tokenId => TokensOwed) public tokensOwed;

    using StateLibrary for IPoolManager;

    error InvalidPoolId();

    constructor(
        address _evc,
        address _positionManager,
        address _oracle,
        address _unitOfAccount,
        PoolKey memory _poolKey
    ) ERC721WrapperBase(_evc, _positionManager, _oracle, _unitOfAccount) {
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        poolManager = IPositionManager(address(_positionManager)).poolManager();
    }

    function _validatePosition(uint256 tokenId) internal view override {
        (PoolKey memory poolKeyOfTokenId,) = IPositionManager(address(underlying)).getPoolAndPositionInfo(tokenId);
        if (PoolId.unwrap(poolKeyOfTokenId.toId()) != PoolId.unwrap(poolId)) revert InvalidPoolId();
    }

    function _unwrap(address to, uint256 tokenId, uint256 amount) internal override {
        _syncFeesOwned(tokenId);
        uint128 liquidity = IPositionManager(address(underlying)).getPositionLiquidity(tokenId);

        //decrease proportional liquidity and send it to the recipient
        _decreaseLiquidity(tokenId, proportionalShare(uint256(liquidity), amount).toUint128(), to);

        //send part of the fees as well
        poolKey.currency0.transfer(to, proportionalShare(tokensOwed[tokenId].amount0Owed, amount));
        poolKey.currency1.transfer(to, proportionalShare(tokensOwed[tokenId].amount1Owed, amount));
    }

    ///@dev For PositionManager, we get the last tokenId that was just minted
    function _getTokenIdToSkim() internal view override returns (uint256) {
        return IPositionManager(address(underlying)).nextTokenId() - 1;
    }

    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity, address recipient) internal {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);

        IPositionManager(address(underlying)).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _decreaseLiquidityAndRecordChange(uint256 tokenId, uint128 liquidity, address recipient)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 balance0 = poolKey.currency0.balanceOf(address(this));
        uint256 balance1 = poolKey.currency1.balanceOf(address(this));

        _decreaseLiquidity(tokenId, liquidity, recipient);

        (amount0, amount1) = (
            poolKey.currency0.balanceOf(address(this)) - balance0, poolKey.currency1.balanceOf(address(this)) - balance1
        );
    }

    function _syncFeesOwned(uint256 tokenId) internal {
        (uint256 amount0, uint256 amount1) = _decreaseLiquidityAndRecordChange(tokenId, 0, ActionConstants.MSG_SENDER);

        tokensOwed[tokenId].amount0Owed += amount0;
        tokensOwed[tokenId].amount1Owed += amount1;
    }

    function _calculateValueOfTokenId(uint256 tokenId, uint256 amount) internal view override returns (uint256) {
        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);

        (uint256 amount0, uint256 amount1) = _totalPositionValue(sqrtRatioX96, tokenId);
        //TODO: make the sure native ETH when currency0 is address(0) is handled correctly
        uint256 amount0InUnitOfAccount = getQuote(amount0, address(uint160(poolKey.currency0.toId())));
        uint256 amount1InUnitOfAccount = getQuote(amount1, address(uint160(poolKey.currency1.toId())));

        return proportionalShare(amount0InUnitOfAccount + amount1InUnitOfAccount, amount);
    }

    function _totalPositionValue(uint160 sqrtRatioX96, uint256 tokenId)
        internal
        view
        returns (uint256 amount0Total, uint256 amount1Total)
    {
        PositionInfo position = IPositionManager(address(underlying)).positionInfo(tokenId);

        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager
            .getPositionInfo(poolId, address(underlying), position.tickLower(), position.tickUpper(), bytes32(tokenId));

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, position.tickLower(), position.tickUpper());

        (uint256 amount0Principal, uint256 amount1Principal) =
            UniswapPositionValueHelper.principal(sqrtRatioX96, position.tickLower(), position.tickUpper(), liquidity);

        (uint256 feesOwed0, uint256 feesOwed1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128, feeGrowthInside1X128, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity
        );

        amount0Total = amount0Principal + feesOwed0 + tokensOwed[tokenId].amount0Owed;
        amount1Total = amount1Principal + feesOwed1 + tokensOwed[tokenId].amount1Owed;
    }
    /// @notice Allows the contract to receive ETH when `currency0` is the native ETH (address(0)).

    receive() external payable {}
}
