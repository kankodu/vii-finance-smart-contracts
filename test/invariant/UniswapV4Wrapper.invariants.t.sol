// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Handler, TokenIdInfo} from "test/invariant/Handler.sol";

contract UniswapV4WrapperInvariants is Test {
    Handler public handler;

    function setUp() public {
        handler = new Handler();
        handler.setUp();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Handler.mintPositionAndWrap.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    //make sure totalSupply of any tokenId is in uniswapV4Wrapper is not greater than FULL_AMOUNT
    function invariant_totalSupplyNotGreaterThanFullAmount() public view {
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address actor = handler.actors(i);
            //get all wrapped tokenIds
            TokenIdInfo memory tokenIdInfo = handler.getTokenIdInfo(actor);

            for (uint256 j = 0; j < tokenIdInfo.tokenIds.length; j++) {
                uint256 tokenId = tokenIdInfo.tokenIds[j];
                if (tokenIdInfo.isWrapped == false) {
                    continue;
                }
                assertLe(handler.uniswapV4Wrapper().totalSupply(tokenId), handler.uniswapV4Wrapper().FULL_AMOUNT());
            }
        }
    }
}
