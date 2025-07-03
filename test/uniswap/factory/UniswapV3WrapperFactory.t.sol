// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {UniswapV3WrapperFactory} from "src/uniswap/factory/UniswapV3WrapperFactory.sol";
import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
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

        address expectedWrapperAddress = factory.getUniswapV3WrapperAddress(oracle, unitOfAccount, poolAddress);
        address expectedFixedRateOracleAddress =
            factory.getFixedRateOracleAddress(expectedWrapperAddress, unitOfAccount);

        vm.expectEmit();
        emit UniswapV3WrapperFactory.UniswapV3WrapperCreated(
            expectedWrapperAddress, expectedFixedRateOracleAddress, poolAddress, oracle, unitOfAccount
        );

        (address uniswapV3Wrapper, address fixedRateOracle) =
            factory.createUniswapV3Wrapper(oracle, unitOfAccount, poolAddress);

        assertEq(uniswapV3Wrapper, expectedWrapperAddress);
        assertEq(fixedRateOracle, expectedFixedRateOracleAddress);

        assertTrue(factory.isUniswapV3WrapperValid(UniswapV3Wrapper(uniswapV3Wrapper)));
        assertTrue(factory.isFixedRateOracleValid(fixedRateOracle));

        UniswapV3Wrapper uniswapV3WrapperDeployedWithoutFactory =
            new UniswapV3Wrapper(evc, nonFungiblePositionManager, oracle, unitOfAccount, poolAddress);

        address fixedRateOracleDeployedWithoutFactory =
            address(new FixedRateOracle(address(uniswapV3WrapperDeployedWithoutFactory), unitOfAccount, 10 ** 18));

        assertFalse(factory.isUniswapV3WrapperValid(uniswapV3WrapperDeployedWithoutFactory));
        assertFalse(factory.isFixedRateOracleValid(fixedRateOracleDeployedWithoutFactory));

        //trying to create the same wrapper again
        vm.expectRevert(); //reverts with create2Collision
        factory.createUniswapV3Wrapper(oracle, unitOfAccount, poolAddress);
    }
}
