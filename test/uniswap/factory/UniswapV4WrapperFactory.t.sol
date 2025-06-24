// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {UniswapV4WrapperFactory} from "src/uniswap/factory/UniswapV4WrapperFactory.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Test} from "forge-std/Test.sol";

contract MockPositionManager {
    function poolManager() external pure returns (address) {}
}

contract UniswapV4WrapperFactoryTest is Test {
    address evc = makeAddr("evc");
    address positionManager = address(new MockPositionManager());
    address oracle = makeAddr("oracle");
    address unitOfAccount = makeAddr("unitOfAccount");
    address weth = makeAddr("weth");

    address currency0 = makeAddr("currency");
    address currency1 = makeAddr("currency");
    uint24 fee = 3000;
    int24 tickSpacing = 60;
    address hooks = makeAddr("hooks");

    UniswapV4WrapperFactory factory;

    function setUp() public {
        factory = new UniswapV4WrapperFactory(evc, positionManager, weth);
    }

    function testCreateUniswapV4Wrapper() public {
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        address expectedWrapperAddress = factory.getUniswapV4WrapperAddress(oracle, unitOfAccount, poolKey);
        address expectedFixedRateOracleAddress =
            factory.getFixedRateOracleAddress(expectedWrapperAddress, unitOfAccount);

        vm.expectEmit();
        emit UniswapV4WrapperFactory.UniswapV4WrapperCreated(
            expectedWrapperAddress, expectedFixedRateOracleAddress, poolKey.toId(), oracle, unitOfAccount, poolKey
        );

        (address uniswapV4Wrapper, address fixedRateOracle) =
            factory.createUniswapV4Wrapper(oracle, unitOfAccount, poolKey);

        assertEq(uniswapV4Wrapper, expectedWrapperAddress);
        assertEq(fixedRateOracle, expectedFixedRateOracleAddress);

        assertTrue(factory.isUniswapV4WrapperValid(payable(uniswapV4Wrapper)));
        assertTrue(factory.isFixedRateOracleValid(fixedRateOracle));

        address uniswapV4WrapperDeployedWithoutFactory =
            address(new UniswapV4Wrapper(evc, positionManager, oracle, unitOfAccount, poolKey, weth));

        address fixedRateOracleDeployedWithoutFactory =
            address(new FixedRateOracle(uniswapV4WrapperDeployedWithoutFactory, unitOfAccount, 10 ** 18));

        assertFalse(factory.isUniswapV4WrapperValid(payable(uniswapV4WrapperDeployedWithoutFactory)));
        assertFalse(factory.isFixedRateOracleValid(fixedRateOracleDeployedWithoutFactory));

        //trying to create the same wrapper again
        vm.expectRevert(); //reverts with create2Collision
        factory.createUniswapV4Wrapper(oracle, unitOfAccount, poolKey);
    }
}
