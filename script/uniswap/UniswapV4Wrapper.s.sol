// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract CounterScript is Script {
    UniswapV4Wrapper public uniswapV4Wrapper;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        PoolId poolId;

        uniswapV4Wrapper = new UniswapV4Wrapper(
            BaseAddresses.EVC, BaseAddresses.POOL_MANAGER, BaseAddresses.POSITION_MANAGER, BaseAddresses.PERMIT2, poolId
        );

        vm.stopBroadcast();
    }
}
