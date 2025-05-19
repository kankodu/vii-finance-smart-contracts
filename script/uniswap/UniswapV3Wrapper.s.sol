// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";

contract CounterScript is Script {
    UniswapV3Wrapper public uniswapV3Wrapper;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address poolAddress = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

        uniswapV3Wrapper = new UniswapV3Wrapper(
            BaseAddresses.EVC,
            BaseAddresses.POOL_MANAGER,
            BaseAddresses.POSITION_MANAGER,
            BaseAddresses.PERMIT2,
            poolAddress
        );

        vm.stopBroadcast();
    }
}
