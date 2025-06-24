// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {UniswapV3WrapperFactory} from "src/uniswap/factory/UniswapV3WrapperFactory.sol";
import {Test} from "forge-std/Test.sol";

contract MockUniswapV3Pool {
    function token0() external pure returns (address) {}
    function token1() external pure returns (address) {}
    function fee() external pure returns (uint24) {}
}

contract MockNonfungiblePositionManager {
    function factory() external pure returns (address) {}
}

contract UniswapV3WrapperFactoryTest is Test {
    address evc = makeAddr("evc");
    address nonFungiblePositionManager = address(new MockNonfungiblePositionManager());
    address oracle = makeAddr("oracle");
    address unitOfAccount = makeAddr("unitOfAccount");

    UniswapV3WrapperFactory factory;

    function setUp() public {
        factory = new UniswapV3WrapperFactory(evc, nonFungiblePositionManager);
    }

    function testCreateUniswapV3Wrapper() public {
        address poolAddress = address(new MockUniswapV3Pool());
        (address uniswapV3Wrapper, address fixedRateOracle) =
            factory.createUniswapV3Wrapper(oracle, unitOfAccount, poolAddress);

        assertEq(uniswapV3Wrapper, factory.getUniswapV3WrapperAddress(oracle, unitOfAccount, poolAddress));
        assertEq(fixedRateOracle, factory.getFixedRateOracleAddress(uniswapV3Wrapper, unitOfAccount));

        //trying to create the same wrapper again
        vm.expectRevert(); //reverts with create2Collision
        factory.createUniswapV3Wrapper(oracle, unitOfAccount, poolAddress);
    }
}
