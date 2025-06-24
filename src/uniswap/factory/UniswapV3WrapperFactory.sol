// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Create2} from "lib/openzeppelin-contracts/contracts/utils/Create2.sol";

contract UniswapV3WrapperFactory {
    address public immutable evc;
    address public immutable nonFungiblePositionManager;

    event UniswapV3WrapperCreated(
        address indexed uniswapV3Wrapper,
        address indexed poolAddress,
        address indexed oracle,
        address unitOfAccount,
        address fixedRateOracle
    );

    constructor(address _evc, address _nonFungiblePositionManager) {
        evc = _evc;
        nonFungiblePositionManager = _nonFungiblePositionManager;
    }

    function createUniswapV3Wrapper(address oracle, address unitOfAccount, address poolAddress)
        external
        returns (address uniswapV3Wrapper, address fixedRateOracle)
    {
        bytes32 wrapperSalt = _getWrapperSalt(oracle, unitOfAccount, poolAddress);
        uniswapV3Wrapper = address(
            new UniswapV3Wrapper{salt: wrapperSalt}(evc, nonFungiblePositionManager, oracle, unitOfAccount, poolAddress)
        );

        uint256 unit = 10 ** _getDecimals(unitOfAccount);
        bytes32 fixedRateOracleSalt = _getFixedRateOracleSalt(uniswapV3Wrapper, unitOfAccount, unit);
        fixedRateOracle = address(new FixedRateOracle{salt: fixedRateOracleSalt}(uniswapV3Wrapper, unitOfAccount, unit)); //1:1 price

        emit UniswapV3WrapperCreated(uniswapV3Wrapper, poolAddress, oracle, unitOfAccount, fixedRateOracle);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

    function _getWrapperSalt(address oracle, address unitOfAccount, address poolAddress)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(evc, nonFungiblePositionManager, oracle, unitOfAccount, poolAddress));
    }

    function _getFixedRateOracleSalt(address uniswapV3Wrapper, address unitOfAccount, uint256 unit)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(uniswapV3Wrapper, unitOfAccount, unit));
    }

    function getUniswapV3WrapperBytecode(address oracle, address unitOfAccount, address poolAddress)
        public
        view
        returns (bytes memory)
    {
        bytes memory bytecode = type(UniswapV3Wrapper).creationCode;
        return
            abi.encodePacked(bytecode, abi.encode(evc, nonFungiblePositionManager, oracle, unitOfAccount, poolAddress));
    }

    function _computeCreate2Address(bytes32 salt, bytes memory bytecode) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    function getUniswapV3WrapperAddress(address oracle, address unitOfAccount, address poolAddress)
        public
        view
        returns (address)
    {
        bytes32 wrapperSalt = _getWrapperSalt(oracle, unitOfAccount, poolAddress);
        bytes memory bytecode = getUniswapV3WrapperBytecode(oracle, unitOfAccount, poolAddress);
        return _computeCreate2Address(wrapperSalt, bytecode);
    }

    function getFixedRateOracleBytecode(address uniswapV3Wrapper, address unitOfAccount)
        public
        view
        returns (bytes memory)
    {
        uint256 unit = 10 ** _getDecimals(unitOfAccount);
        bytes memory bytecode = type(FixedRateOracle).creationCode;
        return abi.encodePacked(bytecode, abi.encode(uniswapV3Wrapper, unitOfAccount, unit));
    }

    function getFixedRateOracleAddress(address uniswapV3Wrapper, address unitOfAccount) public view returns (address) {
        uint256 unit = 10 ** _getDecimals(unitOfAccount);
        bytes32 fixedRateOracleSalt = _getFixedRateOracleSalt(uniswapV3Wrapper, unitOfAccount, unit);
        bytes memory bytecode = getFixedRateOracleBytecode(uniswapV3Wrapper, unitOfAccount);
        return _computeCreate2Address(fixedRateOracleSalt, bytecode);
    }

    //a helper function to check if a wrapper was deployed or will be using this factory
    function isUniswapV3WrapperValid(address uniswapV3WrapperToCheck) external view returns (bool) {
        address expectedAddress = getUniswapV3WrapperAddress(
            address(UniswapV3Wrapper(uniswapV3WrapperToCheck).oracle()),
            UniswapV3Wrapper(uniswapV3WrapperToCheck).unitOfAccount(),
            address(UniswapV3Wrapper(uniswapV3WrapperToCheck).pool())
        );
        return expectedAddress == uniswapV3WrapperToCheck;
    }

    function isFixedRateOracleValid(address fixedRateOracleToCheck) external view returns (bool) {
        address expectedAddress = getFixedRateOracleAddress(
            FixedRateOracle(fixedRateOracleToCheck).base(), FixedRateOracle(fixedRateOracleToCheck).quote()
        );
        return expectedAddress == fixedRateOracleToCheck;
    }
}
