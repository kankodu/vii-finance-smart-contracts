// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {BaseUniswapWrapperFactory} from "src/uniswap/factory/BaseUniswapWrapperFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract UniswapV4WrapperFactory is BaseUniswapWrapperFactory {
    address public immutable positionManager;
    address public immutable weth;

    event UniswapV4WrapperCreated(
        address indexed uniswapV4Wrapper,
        PoolId indexed poolId,
        address indexed oracle,
        address unitOfAccount,
        address fixedRateOracle
    );

    constructor(address _evc, address _positionManager, address _weth) BaseUniswapWrapperFactory(_evc) {
        positionManager = _positionManager;
        weth = _weth;
    }

    function createUniswapV4Wrapper(address oracle, address unitOfAccount, PoolKey memory poolKey)
        external
        returns (address uniswapV4Wrapper, address fixedRateOracle)
    {
        PoolId poolId = poolKey.toId();
        bytes32 wrapperSalt = _getWrapperSalt(oracle, unitOfAccount, poolId);
        uniswapV4Wrapper =
            address(new UniswapV4Wrapper{salt: wrapperSalt}(evc, positionManager, oracle, unitOfAccount, poolKey, weth));

        fixedRateOracle = _createFixedRateOracle(uniswapV4Wrapper, unitOfAccount);

        emit UniswapV4WrapperCreated(uniswapV4Wrapper, poolId, oracle, unitOfAccount, fixedRateOracle);
    }

    function _getWrapperSalt(address oracle, address unitOfAccount, PoolId poolId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(evc, positionManager, oracle, unitOfAccount, PoolId.unwrap(poolId)));
    }

    function getUniswapV4WrapperBytecode(address oracle, address unitOfAccount, PoolKey memory poolKey)
        public
        view
        returns (bytes memory)
    {
        bytes memory bytecode = type(UniswapV4Wrapper).creationCode;
        return abi.encodePacked(bytecode, abi.encode(evc, positionManager, oracle, unitOfAccount, poolKey, weth));
    }

    function getUniswapV4WrapperAddress(address oracle, address unitOfAccount, PoolKey memory poolKey)
        public
        view
        returns (address)
    {
        PoolId poolId = poolKey.toId();
        bytes32 wrapperSalt = _getWrapperSalt(oracle, unitOfAccount, poolId);
        bytes memory bytecode = getUniswapV4WrapperBytecode(oracle, unitOfAccount, poolKey);
        return _computeCreate2Address(wrapperSalt, bytecode);
    }

    //a helper function to check if a wrapper was deployed or will be using this factory
    function isUniswapV4WrapperValid(address payable uniswapV4WrapperToCheck) external view returns (bool) {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            UniswapV4Wrapper(uniswapV4WrapperToCheck).poolKey();
        PoolKey memory poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});

        address expectedAddress = getUniswapV4WrapperAddress(
            address(UniswapV4Wrapper(uniswapV4WrapperToCheck).oracle()),
            UniswapV4Wrapper(uniswapV4WrapperToCheck).unitOfAccount(),
            poolKey
        );
        return expectedAddress == uniswapV4WrapperToCheck;
    }
}
