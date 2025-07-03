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
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";

/// @title UniswapV4Wrapper
/// @notice ERC721 wrapper for Uniswap V4 positions
/// @dev This wrapper is intended exclusively for vanilla Uniswap V4 pools.
/// @dev It does not support pools with custom hooks that alter the default liquidity provision behavior.
contract UniswapV4Wrapper is ERC721WrapperBase {
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    address public immutable weth;

    PoolId public immutable poolId;
    IPoolManager public immutable poolManager;
    uint256 public immutable unit0;
    uint256 public immutable unit1;

    PoolKey public poolKey;
    mapping(uint256 tokenId => TokensOwed) public tokensOwed;

    /// @notice Tracks the amount of fees owed to tokenId holders for both tokens.
    /// @dev In Uniswap V3, when liquidity is modified, the pool does not immediately send fees accrued to the user.
    ///      Instead, it increases the position's `tokensOwed` balance in an internal mapping, and the user must call `collect` to receive the tokens.
    ///      In Uniswap V4, the PoolManager expects fees to be settled (sent to the user) immediately when liquidity is modified.
    ///      However, since ERC6909 token IDs can have multiple holders, we only know about the share of the owner who is unwrapping their portion.
    ///      Therefore, we must keep track of `feesOwed` here to ensure each holder receives the correct amount, rather than settling all fees at once.
    ///      This state is maintained to accurately account for and distribute fees to each partial owner when they interact with their position.
    ///      For this reason, this contract is expected to hold some currency0 and currency1 tokens till all of the tokenId holders have unwrapped.
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

    error InvalidPoolId(PoolId actualPoolId, PoolId expectedPoolId);
    error InvalidWETHAddress();
    error FeesMismatch(uint256 feesOwed0, uint256 feesOwed1, uint256 amount0, uint256 amount1);

    constructor(
        address _evc,
        address _positionManager,
        address _oracle,
        address _unitOfAccount,
        PoolKey memory _poolKey,
        address _weth
    ) ERC721WrapperBase(_evc, _positionManager, _oracle, _unitOfAccount) {
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        poolManager = IPositionManager(address(_positionManager)).poolManager();

        if (_poolKey.currency0.isAddressZero()) {
            if (_weth == address(0)) revert InvalidWETHAddress();
            weth = _weth;
        }

        unit0 = 10 ** _getDecimals(_getCurrencyAddress(poolKey.currency0));
        unit1 = 10 ** _getDecimals(_getCurrencyAddress(poolKey.currency1));
    }

    /// @notice Validates that the position belongs to the pool that this wrapper is associated with
    /// @param tokenId The token ID to validate
    function validatePosition(uint256 tokenId) public view override {
        (PoolKey memory poolKeyOfTokenId,) = IPositionManager(address(underlying)).getPoolAndPositionInfo(tokenId);
        PoolId poolIdOfTokenId = poolKeyOfTokenId.toId();

        if (PoolId.unwrap(poolIdOfTokenId) != PoolId.unwrap(poolId)) {
            revert InvalidPoolId(poolIdOfTokenId, poolId);
        }
    }

    /// @notice Unwraps a position by removing proportional liquidity and send the resulting tokens and proportional fees to the recipient
    /// @param to The recipient address
    /// @param tokenId The position token ID
    /// @param amount The proportion of the position to unwrap
    /// @param extraData Additional parameters for the unwrap operation (uint128 amount0Min, uint128 amount1Min, uint256 deadline encoded)
    function _unwrap(address to, uint256 tokenId, uint256 amount, bytes calldata extraData) internal override {
        PositionState memory positionState = _getPositionState(tokenId);

        (uint256 pendingFees0, uint256 pendingFees1) = _pendingFees(positionState);
        _accumulateFees(tokenId, pendingFees0, pendingFees1);

        uint128 liquidityToRemove = proportionalShare(tokenId, positionState.liquidity, amount).toUint128();
        (uint256 amount0, uint256 amount1) = _principal(positionState, liquidityToRemove);

        _decreaseLiquidity(tokenId, liquidityToRemove, ActionConstants.MSG_SENDER, extraData);

        poolKey.currency0.transfer(to, amount0 + proportionalShare(tokenId, tokensOwed[tokenId].fees0Owed, amount));
        poolKey.currency1.transfer(to, amount1 + proportionalShare(tokenId, tokensOwed[tokenId].fees1Owed, amount));
    }

    /// @notice Calculates the proportional value of a position in unit of account terms
    /// @param tokenId The ID of the position token to evaluate
    /// @param amount The proportion of the position to value
    /// @return the proportional value of the specified position in unit of account
    function calculateValueOfTokenId(uint256 tokenId, uint256 amount) public view override returns (uint256) {
        PositionState memory positionState = _getPositionState(tokenId);

        (uint256 amount0, uint256 amount1) = _total(positionState, tokenId);

        uint256 amount0InUnitOfAccount = getQuote(amount0, _getCurrencyAddress(poolKey.currency0));
        uint256 amount1InUnitOfAccount = getQuote(amount1, _getCurrencyAddress(poolKey.currency1));

        return proportionalShare(tokenId, amount0InUnitOfAccount + amount1InUnitOfAccount, amount);
    }

    /// @notice Gets the token ID that was just minted
    /// @dev It returns the last tokenId that was minted on the positionManager,
    ///      not necessarily the last tokenId that was sent to this contract.
    /// @dev This is used so that user can directly send the freshly minted token to this wrapper and skim it
    /// @dev It helps with batching mint and wrap operations efficiently
    /// @return The latest token ID
    function getTokenIdToSkim() public view override returns (uint256) {
        return IPositionManager(address(underlying)).nextTokenId() - 1;
    }

    /// @notice Gets the current state of a position
    /// @param tokenId The position token ID
    /// @return positionState The complete position state
    function _getPositionState(uint256 tokenId) internal view returns (PositionState memory positionState) {
        PositionInfo position = IPositionManager(address(underlying)).positionInfo(tokenId);
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager
            .getPositionInfo(poolId, address(underlying), position.tickLower(), position.tickUpper(), bytes32(tokenId));

        positionState = PositionState({
            position: position,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            sqrtRatioX96: getSqrtRatioX96(
                _getCurrencyAddress(poolKey.currency0), _getCurrencyAddress(poolKey.currency1), unit0, unit1
            )
        });
    }

    /// @notice Calculates pending fees for a position
    /// @param positionState The position state
    /// @return feesOwed0 Pending fees for token0
    /// @return feesOwed1 Pending fees for token1
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

    /// @notice Calculates principal amounts for the full position
    /// @param positionState The position state
    /// @return principalAmount0 Principal amount for token0
    /// @return principalAmount1 Principal amount for token1
    function _principal(PositionState memory positionState) internal pure returns (uint256, uint256) {
        return _principal(positionState, positionState.liquidity);
    }

    /// @notice Calculates principal amounts for a specific liquidity amount
    /// @param positionState The position state
    /// @param liquidity The liquidity amount
    /// @return principalAmount0 Principal amount for token0
    /// @return principalAmount1 Principal amount for token1
    function _principal(PositionState memory positionState, uint128 liquidity)
        internal
        pure
        returns (uint256 principalAmount0, uint256 principalAmount1)
    {
        (principalAmount0, principalAmount1) = UniswapPositionValueHelper.principal(
            positionState.sqrtRatioX96,
            positionState.position.tickLower(),
            positionState.position.tickUpper(),
            liquidity
        );
    }

    /// @notice Decreases liquidity for a position
    /// @param tokenId The position token ID
    /// @param liquidity The amount of liquidity to remove
    /// @param recipient The recipient of the withdrawn tokens
    /// @param extraData Additional parameters (amount0Min, amount1Min, deadline)
    function _decreaseLiquidity(uint256 tokenId, uint128 liquidity, address recipient, bytes calldata extraData)
        internal
    {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
        actions[1] = bytes1(uint8(Actions.TAKE_PAIR));

        (uint128 amount0Min, uint128 amount1Min, uint256 deadline) = _decodeExtraData(extraData);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);

        IPositionManager(address(underlying)).modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @notice Calculates total amounts (principal + fees) for a position
    /// @param positionState The position state
    /// @param tokenId The position token ID
    /// @return amount0Total Total amount for token0
    /// @return amount1Total Total amount for token1
    function _total(PositionState memory positionState, uint256 tokenId)
        internal
        view
        returns (uint256 amount0Total, uint256 amount1Total)
    {
        (uint256 principalAmount0, uint256 principalAmount1) = _principal(positionState);
        (uint256 pendingFees0, uint256 pendingFees1) = _pendingFees(positionState);

        amount0Total = principalAmount0 + pendingFees0 + tokensOwed[tokenId].fees0Owed;
        amount1Total = principalAmount1 + pendingFees1 + tokensOwed[tokenId].fees1Owed;
    }

    /// @notice Accumulates fees for a position
    /// @param tokenId The position token ID
    /// @param fees0 Fees for token0
    /// @param fees1 Fees for token1
    function _accumulateFees(uint256 tokenId, uint256 fees0, uint256 fees1) internal {
        tokensOwed[tokenId].fees0Owed += fees0;
        tokensOwed[tokenId].fees1Owed += fees1;
    }

    /// @notice Decodes extra data or returns defaults
    /// @param extraData The encoded extra data
    /// @return amount0Min Minimum amount0
    /// @return amount1Min Minimum amount1
    /// @return deadline Transaction deadline
    function _decodeExtraData(bytes calldata extraData)
        internal
        view
        returns (uint128 amount0Min, uint128 amount1Min, uint256 deadline)
    {
        if (extraData.length > 0) {
            (amount0Min, amount1Min, deadline) = abi.decode(extraData, (uint128, uint128, uint256));
        } else {
            (amount0Min, amount1Min, deadline) = (0, 0, block.timestamp);
        }
    }

    function _getCurrencyAddress(Currency currency) internal view returns (address) {
        return currency.isAddressZero() ? weth : address(uint160(currency.toId()));
    }

    /// @notice Allows the contract to receive ETH when `currency0` is the native ETH (address(0))
    receive() external payable {}
}
