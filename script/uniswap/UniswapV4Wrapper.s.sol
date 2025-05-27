// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";

contract UniswapV4WrapperScript is Script {
    UniswapV4Wrapper public uniswapV4Wrapper;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        PoolId poolId = PoolId.wrap(0x96d4b53a38337a5733179751781178a2613306063c511b78cd02684739288c0a); //ETH / USDC v4 0.05% base

        uniswapV4Wrapper = new UniswapV4Wrapper({
            _evc: BaseAddresses.EVC,
            _positionManager: BaseAddresses.POSITION_MANAGER,
            _oracle: IEVault(BaseAddresses.WETH_EVAULT).oracle(),
            _unitOfAccount: IEVault(BaseAddresses.WETH_EVAULT).unitOfAccount(),
            _poolId: poolId
        });

        vm.stopBroadcast();
    }
}
