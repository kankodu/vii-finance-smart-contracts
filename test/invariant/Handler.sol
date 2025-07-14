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

struct TokenIdInfo {
    uint256[] tokenIds;
    bool isWrapped;
}

contract Handler is Test, BaseSetup {
    mapping(address => TokenIdInfo) internal tokenIdInfo;

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

    function getTokenIdInfo(address actor) public view returns (TokenIdInfo memory) {
        return tokenIdInfo[actor];
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
        tokenIdInfo[receiver].tokenIds.push(tokenIdMinted);
        tokenIdInfo[receiver].isWrapped = true;

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

    // function testMintPositionAndWrap(uint256 actorIndexSeed, LiquidityParams memory params) public {
    //     mintPositionAndWrap(actorIndexSeed, params);
    // }
}
