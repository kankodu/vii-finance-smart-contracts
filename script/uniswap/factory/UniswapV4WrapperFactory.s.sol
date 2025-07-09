// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV4WrapperFactory} from "src/uniswap/factory/UniswapV4WrapperFactory.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";

contract UniswapV4WrapperFactoryScript is Script {
    UniswapV4WrapperFactory public factory;
    uint24 constant FEE = 500; // 0.05% fee, adjust as needed
    int24 constant TICK_SPACING = 10; // adjust as needed

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        factory = new UniswapV4WrapperFactory(BaseAddresses.EVC, BaseAddresses.POSITION_MANAGER, BaseAddresses.WETH);

        // PoolKey memory poolKey = PoolKey({
        //     currency0: Currency.wrap(address(BaseAddresses.ETH)),
        //     currency1: Currency.wrap(address(BaseAddresses.USDC)),
        //     fee: FEE,
        //     tickSpacing: TICK_SPACING,
        //     hooks: IHooks(address(0))
        // });

        // factory.createUniswapV4Wrapper(
        //     IEVault(BaseAddresses.WETH_EVAULT).oracle(), IEVault(BaseAddresses.WETH_EVAULT).unitOfAccount(), poolKey
        // );

        vm.stopBroadcast();
    }
}
