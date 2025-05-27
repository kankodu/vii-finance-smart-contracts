// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract UniswapV4WrapperScript is Script {
    UniswapV4Wrapper public uniswapV4Wrapper;

    function setUp() public {}

    // Define the fee and tick spacing constants
    uint24 constant FEE = 500; // 0.05% fee, adjust as needed
    int24 constant TICK_SPACING = 10; // adjust as needed

    function run() public {
        vm.startBroadcast();

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(BaseAddresses.ETH)),
            currency1: Currency.wrap(address(BaseAddresses.USDC)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        if (PoolId.unwrap(poolKey.toId()) != (0x96d4b53a38337a5733179751781178a2613306063c511b78cd02684739288c0a)) {
            revert("not the right pool");
        }

        // //ETH / USDC v4 0.05% base

        uniswapV4Wrapper = new UniswapV4Wrapper({
            _evc: BaseAddresses.EVC,
            _positionManager: BaseAddresses.POSITION_MANAGER,
            _oracle: IEVault(BaseAddresses.WETH_EVAULT).oracle(),
            _unitOfAccount: IEVault(BaseAddresses.WETH_EVAULT).unitOfAccount(),
            _poolKey: poolKey
        });

        vm.stopBroadcast();
    }
}
