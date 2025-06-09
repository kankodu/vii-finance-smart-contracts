// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BaseAddresses} from "script/BaseAddresses.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";

contract UniswapMintPositionHelperScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        new UniswapMintPositionHelper({
            _evc: BaseAddresses.EVC,
            _nonfungiblePositionManager: BaseAddresses.NON_FUNGIBLE_POSITION_MANAGER,
            _positionManager: BaseAddresses.POSITION_MANAGER
        });

        vm.stopBroadcast();
    }
}
