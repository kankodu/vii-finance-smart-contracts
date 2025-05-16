pragma solidity ^0.8.20;

import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {IUniswapV3Factory} from "lib/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IEVC} from "lib/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {IPriceOracle} from "lib/euler-price-oracle/src/interfaces/IPriceOracle.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IEulerRouter} from "lib/euler-interfaces/interfaces/IEulerRouter.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";

contract UniswapV3WrapperTest is Test, UniswapBaseTest {
    uint24 fee;
    INonfungiblePositionManager nonFungiblePositionManager;

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        nonFungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        fee = 100; // 0.01% fee
        address factory = nonFungiblePositionManager.factory();
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);

        ERC721WrapperBase uniswapV3Wrapper = new UniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, pool
        );

        return uniswapV3Wrapper;
    }

    function setUp() public override {
        super.setUp();
        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(nonFungiblePositionManager), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(nonFungiblePositionManager), type(uint256).max);
        (tokenId,,,) = nonFungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: -887272, //minimum tick
                tickUpper: 887272, //maximum tick
                amount0Desired: 100 * unit0,
                amount1Desired: 100 * unit1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: borrower,
                deadline: block.timestamp
            })
        );
    }

    function test_BasicBorrowV3() public {
        borrowTest();
    }

    function test_basicLiquidation() public {
        basicLiquidationTest();
    }
}
