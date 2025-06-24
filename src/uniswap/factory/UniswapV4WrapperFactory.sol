// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Create2} from "lib/openzeppelin-contracts/contracts/utils/Create2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract UniswapV4WrapperFactory {
    address public immutable evc;
    address public immutable positionManager;
    address public immutable weth;

    event UniswapV4WrapperCreated(
        address indexed uniswapV4Wrapper,
        PoolId indexed poolId,
        address indexed oracle,
        address unitOfAccount,
        address fixedRateOracle
    );

    constructor(address _evc, address _positionManager, address _weth) {
        evc = _evc;
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

        uint256 unit = 10 ** _getDecimals(unitOfAccount);
        bytes32 fixedRateOracleSalt = _getFixedRateOracleSalt(uniswapV4Wrapper, unitOfAccount, unit);
        fixedRateOracle = address(new FixedRateOracle{salt: fixedRateOracleSalt}(uniswapV4Wrapper, unitOfAccount, unit)); //1:1 price

        emit UniswapV4WrapperCreated(uniswapV4Wrapper, poolId, oracle, unitOfAccount, fixedRateOracle);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

    function _getWrapperSalt(address oracle, address unitOfAccount, PoolId poolId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(evc, positionManager, oracle, unitOfAccount, PoolId.unwrap(poolId)));
    }

    function _getFixedRateOracleSalt(address uniswapV4Wrapper, address unitOfAccount, uint256 unit)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(uniswapV4Wrapper, unitOfAccount, unit));
    }

    function getUniswapV4WrapperBytecode(address oracle, address unitOfAccount, PoolKey memory poolKey)
        public
        view
        returns (bytes memory)
    {
        bytes memory bytecode = type(UniswapV4Wrapper).creationCode;
        return abi.encodePacked(bytecode, abi.encode(evc, positionManager, oracle, unitOfAccount, poolKey, weth));
    }

    function _computeCreate2Address(bytes32 salt, bytes memory bytecode) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
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

    function getFixedRateOracleBytecode(address uniswapV4Wrapper, address unitOfAccount)
        public
        view
        returns (bytes memory)
    {
        uint256 unit = 10 ** _getDecimals(unitOfAccount);
        bytes memory bytecode = type(FixedRateOracle).creationCode;
        return abi.encodePacked(bytecode, abi.encode(uniswapV4Wrapper, unitOfAccount, unit));
    }

    function getFixedRateOracleAddress(address uniswapV4Wrapper, address unitOfAccount) public view returns (address) {
        uint256 unit = 10 ** _getDecimals(unitOfAccount);
        bytes32 fixedRateOracleSalt = _getFixedRateOracleSalt(uniswapV4Wrapper, unitOfAccount, unit);
        bytes memory bytecode = getFixedRateOracleBytecode(uniswapV4Wrapper, unitOfAccount);
        return _computeCreate2Address(fixedRateOracleSalt, bytecode);
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

    function isFixedRateOracleValid(address fixedRateOracleToCheck) external view returns (bool) {
        address expectedAddress = getFixedRateOracleAddress(
            FixedRateOracle(fixedRateOracleToCheck).base(), FixedRateOracle(fixedRateOracleToCheck).quote()
        );
        return expectedAddress == fixedRateOracleToCheck;
    }
}
