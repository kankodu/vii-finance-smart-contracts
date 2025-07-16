// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

// forge-std
import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {
    PositionManager, IAllowanceTransfer, IPositionDescriptor, IWETH9
} from "lib/v4-periphery/src/PositionManager.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {GenericFactory} from "lib/euler-vault-kit/src/GenericFactory/GenericFactory.sol";
import {EVault} from "lib/euler-vault-kit/src/EVault/EVault.sol";
import {BalanceForwarder} from "lib/euler-vault-kit/src/EVault/modules/BalanceForwarder.sol";
import {Borrowing} from "lib/euler-vault-kit/src/EVault/modules/Borrowing.sol";
import {Governance} from "lib/euler-vault-kit/src/EVault/modules/Governance.sol";
import {Initialize} from "lib/euler-vault-kit/src/EVault/modules/Initialize.sol";
import {Liquidation} from "lib/euler-vault-kit/src/EVault/modules/Liquidation.sol";
import {RiskManager} from "lib/euler-vault-kit/src/EVault/modules/RiskManager.sol";
import {Token} from "lib/euler-vault-kit/src/EVault/modules/Token.sol";
import {Vault} from "lib/euler-vault-kit/src/EVault/modules/Vault.sol";
import {Base} from "lib/euler-vault-kit/src/EVault/shared/Base.sol";
import {Dispatch} from "lib/euler-vault-kit/src/EVault/Dispatch.sol";
import {ProtocolConfig} from "lib/euler-vault-kit/src/ProtocolConfig/ProtocolConfig.sol";
import {SequenceRegistry} from "lib/euler-vault-kit/src/SequenceRegistry/SequenceRegistry.sol";
import {IEVault} from "lib/euler-vault-kit/src/EVault/IEVault.sol";

import {MockPriceOracle} from "lib/euler-vault-kit/test/mocks/MockPriceOracle.sol";
import {MockBalanceTracker} from "lib/euler-vault-kit/test/mocks/MockBalanceTracker.sol";
import {TestERC20} from "lib/euler-vault-kit/test/mocks/TestERC20.sol";
import {IRMTestDefault} from "lib/euler-vault-kit/test/mocks/IRMTestDefault.sol";

import {UniswapV4WrapperFactory} from "src/uniswap/factory/UniswapV4WrapperFactory.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";

import {BaseSetup} from "test/invariant/BaseSetup.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

struct TokenIdInfo {
    bool isWrapped;
    mapping(address user => bool isEnabled) isEnabled;
    EnumerableSet.AddressSet holders;
}

contract Handler is Test, BaseSetup {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.UintSet internal allTokenIds;

    mapping(address => EnumerableSet.UintSet tokenIds) internal tokenIdsHeldByActor;
    mapping(uint256 tokenId => TokenIdInfo) internal tokenIdInfo;

    address[] public actors;

    address internal currentActor;

    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function setUp() public override {
        BaseSetup.setUp();

        for (uint256 i = 0; i < 10; i++) {
            address actor = makeAddr(string(abi.encodePacked("Actor ", i)));
            actors.push(actor);
            vm.label(actor, string(abi.encodePacked("Actor ", i)));
        }
    }

    function actorsLength() public view returns (uint256) {
        return actors.length;
    }

    function getTokenIdsHeldByActor(address actor) public view returns (uint256[] memory tokenId) {
        return tokenIdsHeldByActor[actor].values();
    }

    function isTokenIdWrapped(uint256 tokenId) public view returns (bool isWrapped) {
        return tokenIdInfo[tokenId].isWrapped;
    }

    function getUsersHoldingWrappedTokenId(uint256 tokenId) public view returns (address[] memory users) {
        return tokenIdInfo[tokenId].holders.values();
    }

    function getAllTokenIdsLength() public view returns (uint256) {
        return allTokenIds.length();
    }

    function getAllTokenIds() public view returns (uint256[] memory) {
        return allTokenIds.values();
    }

    function mintPositionAndWrap(uint256 actorIndexSeed, LiquidityParams memory params)
        public
        useActor(actorIndexSeed)
    {
        (uint256 tokenIdMinted,,) = boundLiquidityParamsAndMint(currentActor, params);

        startHoax(currentActor);
        positionManager.approve(address(uniswapV4Wrapper), tokenIdMinted);

        //randomly generate a receiver address
        address receiver = actors[bound(actorIndexSeed / 2, 0, actors.length - 1)];

        uint256 wrapperBalanceBefore = uniswapV4Wrapper.balanceOf(receiver);
        uniswapV4Wrapper.wrap(tokenIdMinted, receiver);

        //push the tokenId to the mapping
        tokenIdsHeldByActor[receiver].add(tokenIdMinted);
        tokenIdInfo[tokenIdMinted].isWrapped = true;
        allTokenIds.add(tokenIdMinted);
        tokenIdInfo[tokenIdMinted].holders.add(receiver);

        assertEq(
            uniswapV4Wrapper.balanceOf(receiver),
            wrapperBalanceBefore,
            "UniswapV4Wrapper: wrap should not increase balance of receiver"
        );
        assertEq(
            uniswapV4Wrapper.balanceOf(receiver, tokenIdMinted),
            uniswapV4Wrapper.FULL_AMOUNT(),
            "UniswapV4Wrapper: wrap should mint FULL_AMOUNT of ERC6909 tokens"
        );
    }

    function transferWrappedTokenId(
        uint256 actorIndexSeed,
        uint256 toIndexSeed,
        uint256 tokenIdIndexSeed,
        uint256 transferAmount
    ) public useActor(actorIndexSeed) {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];
        address to = actors[bound(toIndexSeed, 0, actors.length - 1)];

        uint256 fromBalanceBeforeTransfer = uniswapV4Wrapper.balanceOf(currentActor, tokenId);
        uint256 toBalanceBeforeTransfer = uniswapV4Wrapper.balanceOf(to, tokenId);

        if (fromBalanceBeforeTransfer == 0) {
            return; //skip if transfer amount is 0
        }

        transferAmount = bound(transferAmount, 0, fromBalanceBeforeTransfer);

        uniswapV4Wrapper.transfer(to, tokenId, transferAmount);

        //if transfer to self then we make sure the balance does not change
        if (to == currentActor) {
            assertEq(
                uniswapV4Wrapper.balanceOf(currentActor, tokenId),
                fromBalanceBeforeTransfer,
                "UniswapV4Wrapper: transfer to self should not change balance"
            );
            return; //skip the rest
        }
        assertEq(
            uniswapV4Wrapper.balanceOf(currentActor, tokenId),
            fromBalanceBeforeTransfer - transferAmount,
            "UniswapV4Wrapper: transfer should decrease balance of sender"
        );
        assertEq(
            uniswapV4Wrapper.balanceOf(to, tokenId),
            toBalanceBeforeTransfer + transferAmount,
            "UniswapV4Wrapper: transfer should increase balance of receiver"
        );

        if (transferAmount == fromBalanceBeforeTransfer) {
            tokenIdsHeldByActor[currentActor].remove(tokenId);
            tokenIdInfo[tokenId].holders.remove(currentActor);
        } else {
            //if the transfer amount is less than the full balance, we should not remove the tokenId from the mapping
            //but we should still add the receiver to the holders
            if (!tokenIdInfo[tokenId].holders.contains(to)) {
                tokenIdInfo[tokenId].holders.add(to);
            }
        }
        tokenIdsHeldByActor[to].add(tokenId);
        tokenIdInfo[tokenId].holders.add(to);
    }

    function partialUnwrap(uint256 actorIndexSeed, uint256 tokenIdIndexSeed, uint256 unwrapAmount)
        public
        useActor(actorIndexSeed)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        uint256 currentBalance = uniswapV4Wrapper.balanceOf(currentActor, tokenId);

        if (currentBalance == 0) {
            return; //skip if current actor has no balance
        }

        unwrapAmount = bound(unwrapAmount, 0, currentBalance);

        uniswapV4Wrapper.unwrap(currentActor, tokenId, currentActor, unwrapAmount, "");

        //We need to independently find out the amount user spent on the tokenId
        if (unwrapAmount == currentBalance) {
            tokenIdsHeldByActor[currentActor].remove(tokenId);
            tokenIdInfo[tokenId].holders.remove(currentActor);
        }

        assertEq(
            uniswapV4Wrapper.balanceOf(currentActor, tokenId),
            currentBalance - unwrapAmount,
            "UniswapV4Wrapper: partial unwrap should decrease balance of sender"
        );
    }

    function enableTokenIdAsCollateral(uint256 actorIndexSeed, uint256 tokenIdIndexSeed)
        public
        useActor(actorIndexSeed)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        //if the tokenId is already enabled, we can skip
        if (tokenIdInfo[tokenId].isEnabled[currentActor]) {
            return;
        }

        tokenIdInfo[tokenId].isEnabled[currentActor] = true;

        uint256 enabledTokenIdsLengthBefore = uniswapV4Wrapper.totalTokenIdsEnabledBy(currentActor);

        if (enabledTokenIdsLengthBefore == 7) vm.expectRevert(); //we know it is not allowed to enable more than 7 tokenIds

        uniswapV4Wrapper.enableTokenIdAsCollateral(tokenId);

        if (enabledTokenIdsLengthBefore == 7) return; //if it reverted, we can skip the assertions

        assertEq(
            uniswapV4Wrapper.totalTokenIdsEnabledBy(currentActor),
            enabledTokenIdsLengthBefore + 1,
            "UniswapV4Wrapper: enableTokenIdAsCollateral should increase total enabled tokenIds"
        );
        assertEq(
            uniswapV4Wrapper.tokenIdOfOwnerByIndex(currentActor, enabledTokenIdsLengthBefore),
            tokenId,
            "UniswapV4Wrapper: tokenIdOfOwnerByIndex should return the correct tokenId"
        );
    }

    function disableTokenIdAsCollateral(uint256 actorIndexSeed, uint256 tokenIdIndexSeed)
        public
        useActor(actorIndexSeed)
    {
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        if (tokenIds.length == 0) {
            return; //skip if current actor has no tokenIds
        }
        uint256 tokenId = tokenIds[bound(tokenIdIndexSeed, 0, tokenIds.length - 1)];

        //if the tokenId is not enabled, we can skip
        if (!tokenIdInfo[tokenId].isEnabled[currentActor]) {
            return;
        }

        tokenIdInfo[tokenId].isEnabled[currentActor] = false;

        uint256 enabledTokenIdsLengthBefore = uniswapV4Wrapper.totalTokenIdsEnabledBy(currentActor);

        uniswapV4Wrapper.disableTokenIdAsCollateral(tokenId);

        assertEq(
            uniswapV4Wrapper.totalTokenIdsEnabledBy(currentActor),
            enabledTokenIdsLengthBefore - 1,
            "UniswapV4Wrapper: disableTokenIdAsCollateral should decrease total enabled tokenIds"
        );
    }

    function transferWithoutActiveLiquidation(uint256 actorIndexSeed, uint256 toIndexSeed, uint256 transferAmount)
        public
        useActor(actorIndexSeed)
    {
        address to = actors[bound(toIndexSeed, 0, actors.length - 1)];

        uint256 fromBalanceBeforeTransfer = uniswapV4Wrapper.balanceOf(currentActor);

        if (fromBalanceBeforeTransfer == 0) {
            return; //skip if current actor has no balance
        }

        transferAmount = bound(transferAmount, 0, fromBalanceBeforeTransfer);

        //we get all of the enabled tokenIds of the current actor
        uint256[] memory tokenIds = getTokenIdsHeldByActor(currentActor);
        uint256[] memory fromTokenIdBalancesBefore = new uint256[](tokenIds.length);
        uint256[] memory toTokenIdBalancesBefore = new uint256[](tokenIds.length);
        uint256[] memory transferAmounts = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            fromTokenIdBalancesBefore[i] = uniswapV4Wrapper.balanceOf(currentActor, tokenIds[i]);
            toTokenIdBalancesBefore[i] = uniswapV4Wrapper.balanceOf(to, tokenIds[i]);

            if (tokenIdInfo[tokenIds[i]].isEnabled[currentActor] && currentActor != to) {
                //if the tokenId is enabled, we should proportionally reduce the balance
                transferAmounts[i] = Math.mulDiv(
                    fromTokenIdBalancesBefore[i], transferAmount, fromBalanceBeforeTransfer, Math.Rounding.Ceil
                );
            } else {
                //if the tokenId is not enabled, we should not change the balance
                transferAmounts[i] = 0;
            }
        }

        uniswapV4Wrapper.transfer(to, transferAmount);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            assertEq(
                uniswapV4Wrapper.balanceOf(currentActor, tokenIds[i]),
                fromTokenIdBalancesBefore[i] - transferAmounts[i],
                "UniswapV4Wrapper: transferWithoutActiveLiquidation should proportionally reduce tokenId balances"
            );
            assertEq(
                uniswapV4Wrapper.balanceOf(to, tokenIds[i]),
                toTokenIdBalancesBefore[i] + transferAmounts[i],
                "UniswapV4Wrapper: transferWithoutActiveLiquidation should proportionally increase tokenId balances"
            );

            if (transferAmounts[i] > 0 && currentActor != to) {
                tokenIdsHeldByActor[to].add(tokenIds[i]);
                tokenIdInfo[tokenIds[i]].holders.add(to);
            }
        }
    }
}
