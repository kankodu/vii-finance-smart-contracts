// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {EVCUtil} from "lib/ethereum-vault-connector/src/utils/EVCUtil.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {ActionConstants} from "lib/v4-periphery/src/libraries/ActionConstants.sol";

contract UniswapMintPositionHelper is EVCUtil {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    IPositionManager public immutable positionManager;

    constructor(address _evc, address _nonfungiblePositionManager, address _positionManager) EVCUtil(_evc) {
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
        positionManager = IPositionManager(_positionManager);
    }

    function mintPosition(INonfungiblePositionManager.MintParams memory params)
        external
        payable
        callThroughEVC
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IERC20(params.token0).safeTransferFrom(_msgSender(), address(this), params.amount0Desired);
        IERC20(params.token1).safeTransferFrom(_msgSender(), address(this), params.amount1Desired);

        IERC20(params.token0).forceApprove(address(nonfungiblePositionManager), params.amount0Desired);
        IERC20(params.token1).forceApprove(address(nonfungiblePositionManager), params.amount1Desired);

        (tokenId, liquidity, amount0, amount1) = (nonfungiblePositionManager.mint{value: msg.value}(params));

        uint256 leftoverToken0Balance = IERC20(params.token0).balanceOf(address(this));
        uint256 leftoverToken1Balance = IERC20(params.token1).balanceOf(address(this));

        if (leftoverToken0Balance > 0) {
            IERC20(params.token0).safeTransfer(_msgSender(), leftoverToken0Balance);
        }
        if (leftoverToken1Balance > 0) {
            IERC20(params.token1).safeTransfer(_msgSender(), leftoverToken1Balance);
        }
        return (tokenId, liquidity, amount0, amount1);
    }

    function mintPosition(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) external payable callThroughEVC returns (uint256 tokenId) {
        tokenId = positionManager.nextTokenId();

        if (!poolKey.currency0.isAddressZero()) {
            IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(
                _msgSender(), address(positionManager), amount0Max
            );
        }
        IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(_msgSender(), address(positionManager), amount1Max);
        bytes memory actions = new bytes(5);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE)); //necessary because we don't want funds to be pulled through permit2
        actions[2] = bytes1(uint8(Actions.SETTLE));
        actions[3] = bytes1(uint8(Actions.SWEEP));
        actions[4] = bytes1(uint8(Actions.SWEEP));

        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
        params[1] = abi.encode(poolKey.currency0, ActionConstants.OPEN_DELTA, false); //whatever is the open delta will be settled and the payer will be the position manager itself
        params[2] = abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false);

        params[3] = abi.encode(poolKey.currency0, _msgSender()); //if there is remaining amount of currency0, it will be swept to the user
        params[4] = abi.encode(poolKey.currency1, _msgSender());

        positionManager.modifyLiquidities{value: msg.value}(abi.encode(actions, params), block.timestamp);
    }
}
