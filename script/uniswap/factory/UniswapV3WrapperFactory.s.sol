// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3WrapperFactory} from "src/uniswap/factory/UniswapV3WrapperFactory.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";

contract UniswapV3WrapperFactoryScript is Script {
    UniswapV3WrapperFactory public factory;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        factory = new UniswapV3WrapperFactory(BaseAddresses.EVC, BaseAddresses.NON_FUNGIBLE_POSITION_MANAGER);
        vm.stopBroadcast();
    }
}
