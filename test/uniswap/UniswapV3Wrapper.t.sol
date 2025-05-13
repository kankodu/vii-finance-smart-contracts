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

contract UniswapV3WrapperTest is Test {
    uint256 constant INTERNAL_DEBT_PRECISION_SHIFT = 31;

    IEVC evc;
    IEVault eVault; //an evk vault

    IERC20 asset;

    IPriceOracle oracle;
    address unitOfAccount;

    address token0;
    address token1;
    uint24 fee;
    INonfungiblePositionManager nonFungiblePositionManager;

    UniswapV3Wrapper uniswapV3Wrapper;

    uint8 constant MAX_NFT_ALLOWANCE = 2;

    uint256 unit0;
    uint256 unit1;

    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");

    uint256 tokenId;

    function setUp() public {
        vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/TOeb9so9DCNllHrFTfCgQFQtxpQZ1yZ0", 22022892);

        evc = IEVC(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);
        eVault = IEVault(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9); //euler prime USDC
        asset = IERC20(eVault.asset());

        unitOfAccount = eVault.unitOfAccount();
        oracle = IPriceOracle(eVault.oracle());

        address tokenA = eVault.asset(); //usdc
        address tokenB = 0xdAC17F958D2ee523a2206206994597C13D831ec7; //USDT

        (token0, token1) = (tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = 100; // 0.01% fee

        nonFungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88); //uniswap v3 position manager

        address factory = nonFungiblePositionManager.factory();
        address pool = IUniswapV3Factory(factory).getPool(token0, token1, fee);

        uniswapV3Wrapper = new UniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, pool
        );

        unit0 = 10 ** IERC20Metadata(token0).decimals();
        unit1 = 10 ** IERC20Metadata(token1).decimals();

        deal(token0, borrower, 100 * unit0); // 1 million token0
        deal(token1, borrower, 100 * unit1); // 1 million token1

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

        FixedRateOracle fixedRateOracle = new FixedRateOracle(
            address(uniswapV3Wrapper),
            unitOfAccount,
            1e18 // 1:1 price, This is because we know unitOfAccount is usd and it's decimals are 18
        );

        address oracleGovernor = IEulerRouter(address(oracle)).governor();
        startHoax(oracleGovernor);
        IEulerRouter(address(oracle)).govSetConfig(address(uniswapV3Wrapper), unitOfAccount, address(fixedRateOracle));

        address governorAdmin = eVault.governorAdmin();
        startHoax(governorAdmin);
        eVault.setLTV(address(uniswapV3Wrapper), 0.9e4, 0.9e4, 0);
    }

    function test_BasicBorrowV3() public {
        startHoax(borrower);
        nonFungiblePositionManager.approve(address(uniswapV3Wrapper), tokenId);
        uniswapV3Wrapper.enableTokenIdAsCollateral(tokenId);
        uniswapV3Wrapper.wrap(tokenId, borrower);

        uint256 assetBalanceBefore = asset.balanceOf(borrower);
        uint256 totalBorrowsBefore = eVault.totalBorrows();
        uint256 totalBorrowsExactBefore = eVault.totalBorrowsExact();

        vm.expectRevert(IEVault.E_ControllerDisabled.selector);
        eVault.borrow(5e6, borrower);

        evc.enableController(borrower, address(eVault));

        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        eVault.borrow(5e6, borrower);

        // still no borrow hence possible to disable controller
        assertEq(evc.isControllerEnabled(borrower, address(eVault)), true);
        eVault.disableController();
        assertEq(evc.isControllerEnabled(borrower, address(eVault)), false);
        evc.enableController(borrower, address(eVault));
        assertEq(evc.isControllerEnabled(borrower, address(eVault)), true);

        evc.enableCollateral(borrower, address(uniswapV3Wrapper));

        eVault.borrow(5e6, borrower);
        assertEq(asset.balanceOf(borrower) - assetBalanceBefore, 5e6);
        assertEq(eVault.debtOf(borrower), 5e6);
        assertEq(eVault.debtOfExact(borrower), 5e6 << INTERNAL_DEBT_PRECISION_SHIFT);

        assertEq(eVault.totalBorrows() - totalBorrowsBefore, 5e6);
        assertEq(eVault.totalBorrowsExact() - totalBorrowsExactBefore, 5e6 << INTERNAL_DEBT_PRECISION_SHIFT);

        // no longer possible to disable controller
        vm.expectRevert(IEVault.E_OutstandingDebt.selector);
        eVault.disableController();

        // Should be able to borrow up to 9, so this should fail:

        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        eVault.borrow(180e6, borrower);

        // Disable collateral should fail

        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        evc.disableCollateral(borrower, address(uniswapV3Wrapper));

        //unwrap should fail
        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        uniswapV3Wrapper.unwrap(borrower, tokenId, borrower);

        // Repay

        asset.approve(address(eVault), type(uint256).max);
        eVault.repay(type(uint256).max, borrower);

        evc.disableCollateral(borrower, address(uniswapV3Wrapper));
        assertEq(evc.getCollaterals(borrower).length, 0);

        eVault.disableController();
        assertEq(evc.getControllers(borrower).length, 0);
    }

    function test_basicLiquidation_all_collateralV3() public {
        startHoax(borrower);
        nonFungiblePositionManager.approve(address(uniswapV3Wrapper), tokenId);
        uniswapV3Wrapper.enableTokenIdAsCollateral(tokenId);
        uniswapV3Wrapper.wrap(tokenId, borrower);

        evc.enableCollateral(borrower, address(uniswapV3Wrapper));
        evc.enableController(borrower, address(eVault));

        eVault.borrow(5e6, borrower);

        vm.warp(block.timestamp + eVault.liquidationCoolOffTime());

        (uint256 maxRepay, uint256 yield) = eVault.checkLiquidation(liquidator, borrower, address(uniswapV3Wrapper));
        assertEq(maxRepay, 0);
        assertEq(yield, 0);

        startHoax(IEulerRouter(address(oracle)).governor());
        IEulerRouter(address(oracle)).govSetConfig(
            address(uniswapV3Wrapper),
            unitOfAccount,
            address(
                new FixedRateOracle(
                    address(uniswapV3Wrapper),
                    unitOfAccount,
                    0.25e17 //in the actual conditions this price will always be the fixed 1:1, the balanceOf(user) will change as the price of the underlying tokens change and the position becomes liquidateable
                )
            )
        );

        startHoax(liquidator);
        (maxRepay, yield) = eVault.checkLiquidation(liquidator, borrower, address(uniswapV3Wrapper));

        evc.enableCollateral(liquidator, address(uniswapV3Wrapper));
        evc.enableController(liquidator, address(eVault));
        uniswapV3Wrapper.enableTokenIdAsCollateral(tokenId);
        eVault.liquidate(borrower, address(uniswapV3Wrapper), type(uint256).max, 0);

        //we know this a full liquidation so the current balanceOf of the borrower should be 0
        assertEq(uniswapV3Wrapper.balanceOf(borrower), 0);
        //liquidator must have gotten all of the shares
        assertEq(uniswapV3Wrapper.balanceOf(liquidator, tokenId), 1000 ether);
    }
}
