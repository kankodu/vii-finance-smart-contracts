// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {Vault} from "src/uniswap/VaultForV3.sol";
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";
import {MockUniswapV3Wrapper} from "test/uniswap/UniswapV3Wrapper.t.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

contract VaultERC4626Test is ERC4626Test, UniswapBaseTest {
    uint24 fee;
    INonfungiblePositionManager nonFungiblePositionManager;
    IUniswapV3Pool pool;
    IUniswapV3Factory factory;
    int24 tickSpacing;

    address poolManager = makeAddr("poolManager");

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        nonFungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        fee = 100; // 0.01% fee
        factory = IUniswapV3Factory(nonFungiblePositionManager.factory());
        tickSpacing = factory.feeAmountTickSpacing(fee);
        pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

        ERC721WrapperBase uniswapV3Wrapper = new MockUniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, address(pool)
        );
        mintPositionHelper =
            new UniswapMintPositionHelper(address(evc), address(nonFungiblePositionManager), address(0));

        return uniswapV3Wrapper;
    }

    function setUp() public override(UniswapBaseTest, ERC4626Test) {
        UniswapBaseTest.setUp();
        vm.stopPrank();

        _underlying_ = 0xdAC17F958D2ee523a2206206994597C13D831ec7; //USDT

        _vault_ = address(
            new Vault(
                MockUniswapV3Wrapper(address(wrapper)),
                poolManager,
                -887272, //minimum tick
                887272, //maximum tick
                IERC20(_underlying_),
                IEVault(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9), //euler prime USDC,
                "Uniswap V3 Vault",
                "UV3"
            )
        );
    }

    function setUpVault(Init memory init) public override {
        // setup initial shares and assets for individual users
        for (uint256 i = 0; i < N; i++) {
            address user = init.user[i];
            vm.assume(_isEOA(user));
            // shares
            uint256 shares = init.share[i];
            deal(_underlying_, user, shares);

            _approve(_underlying_, user, _vault_, shares);
            vm.prank(user);
            try IERC4626(_vault_).deposit(shares, user) {}
            catch {
                vm.assume(false);
            }
            // assets
            uint256 assets = init.asset[i];
            deal(_underlying_, user, assets);
        }

        // setup initial yield for vault
        setUpYield(init);
    }
}
