// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";

contract UniswapV3WrapperScript is Script {
    UniswapV3Wrapper public uniswapV3Wrapper;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address poolAddress = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef; //USDC / cbBTC v3 0.05% base pool

        uniswapV3Wrapper = new UniswapV3Wrapper({
            _evc: BaseAddresses.EVC,
            _nonFungiblePositionManager: BaseAddresses.NON_FUNGIBLE_POSITION_MANAGER,
            _oracle: IEVault(BaseAddresses.WETH_EVAULT).oracle(),
            _unitOfAccount: IEVault(BaseAddresses.WETH_EVAULT).unitOfAccount(),
            _poolAddress: poolAddress
        });

        new FixedRateOracle(
            address(uniswapV3Wrapper),
            BaseAddresses.USD,
            1e18 // 1:1 price, This is because we know unitOfAccount is usd and it's decimals are 18
        );

        vm.stopBroadcast();
    }
}
