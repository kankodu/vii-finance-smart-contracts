// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Handler, TokenIdInfo} from "test/invariant/Handler.sol";

contract UniswapV4WrapperInvariants is Test {
    Handler public handler;

    function setUp() public {
        handler = new Handler();
        handler.setUp();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = Handler.mintPositionAndWrap.selector;
        selectors[1] = Handler.transferWrappedTokenId.selector;
        selectors[2] = Handler.partialUnwrap.selector;
        selectors[3] = Handler.enableTokenIdAsCollateral.selector;
        selectors[4] = Handler.disableTokenIdAsCollateral.selector;
        selectors[5] = Handler.transferWithoutActiveLiquidation.selector;
        selectors[6] = Handler.borrowTokenA.selector;
        selectors[7] = Handler.borrowTokenB.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    //make sure totalSupply of any tokenId is in uniswapV4Wrapper is not greater than FULL_AMOUNT
    function invariant_totalSupplyNotGreaterThanFullAmount() public view {
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            address actor = handler.actors(i);
            //get all wrapped tokenIds
            uint256[] memory tokenIds = handler.getTokenIdsHeldByActor(actor);

            for (uint256 j = 0; j < tokenIds.length; j++) {
                uint256 tokenId = tokenIds[j];
                bool isWrapped = handler.isTokenIdWrapped(tokenId);
                if (!isWrapped) {
                    continue;
                }
                assertLe(handler.uniswapV4Wrapper().totalSupply(tokenId), handler.uniswapV4Wrapper().FULL_AMOUNT());
            }
        }
    }

    function invariant_total6909SupplyEqualsSumOfBalances() public view {
        uint256[] memory allTokenIds = handler.getAllTokenIds();
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            uint256 tokenId = allTokenIds[i];
            address[] memory users = handler.getUsersHoldingWrappedTokenId(tokenId);
            uint256 totalBalance;
            for (uint256 j = 0; j < users.length; j++) {
                address user = users[j];
                totalBalance += handler.uniswapV4Wrapper().balanceOf(user, tokenId);
            }
            uint256 total6909Supply = handler.uniswapV4Wrapper().totalSupply(tokenId);
            assertEq(totalBalance, total6909Supply, "Total 6909 supply does not equal sum of balances");
        }
    }
}
