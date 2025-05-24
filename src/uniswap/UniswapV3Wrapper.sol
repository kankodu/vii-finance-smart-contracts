// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {console} from "forge-std/console.sol";

contract UniswapV3Wrapper is ERC721WrapperBase {
    address public immutable poolAddress;
    IUniswapV3Factory public immutable factory;

    error InvalidPoolAddress();

    using SafeCast for uint256;

    constructor(
        address _evc,
        address _nonFungiblePositionManager,
        address _oracle,
        address _unitOfAccount,
        address _poolAddress
    ) ERC721WrapperBase(_evc, _nonFungiblePositionManager, _oracle, _unitOfAccount) {
        poolAddress = _poolAddress;
        factory = IUniswapV3Factory(INonfungiblePositionManager(address(underlying)).factory());
    }

    function _validatePosition(uint256 tokenId) internal view override {
        (,, address token0, address token1, uint24 fee,,,,,,,) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);
        ///@dev external calls are not really required to get the pool address
        address pool = factory.getPool(token0, token1, fee);
        if (pool != poolAddress) revert InvalidPoolAddress();
    }

    function _unwrap(address to, uint256 tokenId, uint256 amount) internal override {
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(address(underlying)).decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: proportionalShare(uint256(liquidity), amount).toUint128(),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        (,,,,,,,,,, uint256 tokensOwed0, uint256 tokensOwed1) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);

        //amount0 and amount1 is the part of the liquidity
        //token0Owed - amount0 and token1Owed - amount1 are the total fees. part of the fees needs to be sent to the recipient as well

        INonfungiblePositionManager(address(underlying)).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: to,
                amount0Max: (amount0 + proportionalShare((tokensOwed0 - amount0), amount)).toUint128(),
                amount1Max: (amount1 + proportionalShare((tokensOwed1 - amount1), amount)).toUint128()
            })
        );
    }

    function _calculateValueOfTokenId(uint256 tokenId, uint256 amount) internal view override returns (uint256) {
        (,, address token0, address token1, uint24 fee,,,,,,,) =
            INonfungiblePositionManager(address(underlying)).positions(tokenId);
        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();

        (uint256 amount0, uint256 amount1) = _totalPositionValue(pool, sqrtRatioX96, tokenId);

        uint256 amount0InUnitOfAccount = getQuote(amount0, token0);
        uint256 amount1InUnitOfAccount = getQuote(amount1, token1);

        return proportionalShare(amount0InUnitOfAccount + amount1InUnitOfAccount, amount);
    }

    function _totalPositionValue(IUniswapV3Pool pool, uint160 sqrtRatioX96, uint256 tokenId)
        internal
        view
        returns (uint256 amount0Total, uint256 amount1Total)
    {
        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(address(underlying)).positions(tokenId);

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(pool, tickLower, tickUpper);

        (uint256 amount0Principal, uint256 amount1Principal) =
            UniswapPositionValueHelper.principal(sqrtRatioX96, tickLower, tickUpper, liquidity);

        //fees that are not accounted for yet
        (uint256 feesOwed0, uint256 feesOwed1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128, feeGrowthInside1X128, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity
        );

        amount0Total = amount0Principal + feesOwed0 + tokensOwed0;
        amount1Total = amount1Principal + feesOwed1 + tokensOwed1;
    }

    function _getFeeGrowthInside(IUniswapV3Pool pool, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent,,,,,) = pool.slot0();
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
                uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            }
        }
    }
}
