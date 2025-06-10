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
        uint256 fees0Owed;
        uint256 fees1Owed;
    }

    struct PositionState {
        PositionInfo position;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint160 sqrtRatioX96;
    }

    mapping(uint256 tokenId => TokensOwed) public tokensOwed;

    using StateLibrary for IPoolManager;

    error InvalidPoolId();

    error FeesMismatch(uint256 feesOwed0, uint256 feesOwed1, uint256 amount0, uint256 amount1);

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
        PositionState memory positionState = _getPositionState(tokenId);

        (uint256 pendingFees0, uint256 pendingFees1) = _pendingFees(positionState);

        tokensOwed[tokenId].fees0Owed += pendingFees0;
        tokensOwed[tokenId].fees1Owed += pendingFees1;

        uint128 liquidityToRemove = proportionalShare(positionState.liquidity, amount).toUint128();
        (uint256 amount0, uint256 amount1) = _principal(positionState, liquidityToRemove);

        //decrease proportional liquidity and send it to the recipient
        _decreaseLiquidity(tokenId, liquidityToRemove, ActionConstants.MSG_SENDER);

        //send part of the fees as well
        poolKey.currency0.transfer(to, amount0 + proportionalShare(tokensOwed[tokenId].fees0Owed, amount));
        poolKey.currency1.transfer(to, amount1 + proportionalShare(tokensOwed[tokenId].fees1Owed, amount));
    }

    function _calculateValueOfTokenId(uint256 tokenId, uint256 amount) internal view override returns (uint256) {
        PositionState memory positionState = _getPositionState(tokenId);

        (uint256 amount0, uint256 amount1) = _total(positionState, tokenId);

        //TODO: make the sure native ETH when currency0 is address(0) is handled correctly
        uint256 amount0InUnitOfAccount = getQuote(amount0, address(uint160(poolKey.currency0.toId())));
        uint256 amount1InUnitOfAccount = getQuote(amount1, address(uint160(poolKey.currency1.toId())));

        return proportionalShare(amount0InUnitOfAccount + amount1InUnitOfAccount, amount);
    }

    ///@dev For PositionManager, we get the last tokenId that was just minted
    function _getTokenIdToSkim() internal view override returns (uint256) {
        return IPositionManager(address(underlying)).nextTokenId() - 1;
    }

    function _getPositionState(uint256 tokenId) internal view returns (PositionState memory positionState) {
        PositionInfo position = IPositionManager(address(underlying)).positionInfo(tokenId);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager
            .getPositionInfo(poolId, address(underlying), position.tickLower(), position.tickUpper(), bytes32(tokenId));

        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);

        positionState = PositionState({
            position: position,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            sqrtRatioX96: sqrtRatioX96
        });
    }

    function _pendingFees(PositionState memory positionState)
        internal
        view
        returns (uint256 feesOwed0, uint256 feesOwed1)
    {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = poolManager.getFeeGrowthInside(
            poolId, positionState.position.tickLower(), positionState.position.tickUpper()
        );
        (feesOwed0, feesOwed1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128,
            feeGrowthInside1X128,
            positionState.feeGrowthInside0LastX128,
            positionState.feeGrowthInside1LastX128,
            positionState.liquidity
        );
    }

    function _principal(PositionState memory positionState) internal pure returns (uint256, uint256) {
        return _principal(positionState, positionState.liquidity);
    }

    function _principal(PositionState memory positionState, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0Principal, uint256 amount1Principal)
    {
        (amount0Principal, amount1Principal) = UniswapPositionValueHelper.principal(
            positionState.sqrtRatioX96,
            positionState.position.tickLower(),
            positionState.position.tickUpper(),
            liquidity
        );
    }

    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity, address recipient) internal {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        //TODO: add extraData to accept amount0Min and amount1Min from the user
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);

        IPositionManager(address(underlying)).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _total(PositionState memory positionState, uint256 tokenId)
        internal
        view
        returns (uint256 amount0Total, uint256 amount1Total)
    {
        (uint256 amount0Principal, uint256 amount1Principal) = _principal(positionState);
        (uint256 pendingFees0, uint256 pendingFees1) = _pendingFees(positionState);

        amount0Total = amount0Principal + pendingFees0 + tokensOwed[tokenId].fees0Owed;
        amount1Total = amount1Principal + pendingFees1 + tokensOwed[tokenId].fees1Owed;
    }

    /// @notice Allows the contract to receive ETH when `currency0` is the native ETH (address(0))
    receive() external payable {}
}
