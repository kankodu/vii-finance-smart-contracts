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

struct TokenIdInfo {
    bool isEnabled;
    bool isWrapped;
}

contract Handler is Test, BaseSetup {
    using EnumerableSet for EnumerableSet.UintSet;

    mapping(address => EnumerableSet.UintSet tokenIds) internal tokenIdsHeldByActor;
    mapping(uint256 tokenId => TokenIdInfo) public tokenIdInfo;

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

        if (to == currentActor) {
            return; // skip if transferring to self
        }

        uint256 fromBalanceBeforeTransfer = uniswapV4Wrapper.balanceOf(currentActor, tokenId);
        uint256 toBalanceBeforeTransfer = uniswapV4Wrapper.balanceOf(to, tokenId);

        transferAmount = bound(transferAmount, 1, fromBalanceBeforeTransfer);

        uniswapV4Wrapper.transfer(to, tokenId, transferAmount);

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

        if (transferAmount == fromBalanceBeforeTransfer) tokenIdsHeldByActor[currentActor].remove(tokenId);
        tokenIdsHeldByActor[to].add(tokenId);
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

        unwrapAmount = bound(unwrapAmount, 1, currentBalance);

        uniswapV4Wrapper.unwrap(currentActor, tokenId, currentActor, unwrapAmount, "");

        //We need to independently find out the amount user spent on the tokenId
        if (unwrapAmount == currentBalance) tokenIdsHeldByActor[currentActor].remove(tokenId);

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
        if (tokenIdInfo[tokenId].isEnabled) {
            return;
        }

        uniswapV4Wrapper.enableTokenIdAsCollateral(tokenId);
    }
}
