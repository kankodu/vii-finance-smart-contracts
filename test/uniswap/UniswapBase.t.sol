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
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";

contract UniswapBaseTest is Test, Fuzzers {
    uint256 constant INTERNAL_DEBT_PRECISION_SHIFT = 31;

    IEVC evc;
    IEVault eVault; //an evk vault

    IERC20 asset;

    IPriceOracle oracle;
    address unitOfAccount;

    ERC721WrapperBase wrapper;

    uint8 constant MAX_NFT_ALLOWANCE = 2;

    address token0;
    address token1;

    uint256 unit0;
    uint256 unit1;

    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");
    UniswapMintPositionHelper public mintPositionHelper;

    uint256 tokenId;

    uint256 constant FULL_AMOUNT = 1000 ether;

    function deployWrapper() internal virtual returns (ERC721WrapperBase) {}

    function setUp() public virtual {
        vm.createSelectFork("https://eth-mainnet.g.alchemy.com/v2/tP0hVDEiLj0WU35nFeee9qlQ-84jkeQo", 22473612);

        evc = IEVC(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);
        eVault = IEVault(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9); //euler prime USDC
        asset = IERC20(eVault.asset());

        unitOfAccount = eVault.unitOfAccount();
        oracle = IPriceOracle(eVault.oracle());

        address tokenA = eVault.asset(); //usdc
        address tokenB = 0xdAC17F958D2ee523a2206206994597C13D831ec7; //USDT

        (token0, token1) = (tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        wrapper = deployWrapper();

        unit0 = 10 ** IERC20Metadata(token0).decimals();
        unit1 = 10 ** IERC20Metadata(token1).decimals();

        deal(token0, borrower, 100 * unit0); // 1 million token0
        deal(token1, borrower, 100 * unit1); // 1 million token1

        FixedRateOracle fixedRateOracle = new FixedRateOracle(
            address(wrapper),
            unitOfAccount,
            1e18 // 1:1 price, This is because we know unitOfAccount is usd and it's decimals are 18
        );

        address oracleGovernor = IEulerRouter(address(oracle)).governor();
        startHoax(oracleGovernor);
        IEulerRouter(address(oracle)).govSetConfig(address(wrapper), unitOfAccount, address(fixedRateOracle));

        address governorAdmin = eVault.governorAdmin();
        startHoax(governorAdmin);
        eVault.setLTV(address(wrapper), 0.9e4, 0.9e4, 0);
    }

    struct LiquidityParams {
        int256 liquidityDelta;
        int24 tickLower;
        int24 tickUpper;
    }

    function createFuzzyLiquidityParams(LiquidityParams memory params, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        pure
        returns (LiquidityParams memory)
    {
        (params.tickLower, params.tickUpper) = boundTicks(params.tickLower, params.tickUpper, tickSpacing);
        int256 liquidityDeltaFromAmounts =
            getLiquidityDeltaFromAmounts(params.tickLower, params.tickUpper, sqrtPriceX96);

        int256 liquidityMaxPerTick = int256(uint256(Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)));

        int256 liquidityMax =
            liquidityDeltaFromAmounts > liquidityMaxPerTick ? liquidityMaxPerTick : liquidityDeltaFromAmounts;
        _vm.assume(liquidityMax != 0);
        params.liquidityDelta = bound(liquidityDeltaFromAmounts, 1, liquidityMax);

        return params;
    }

    function borrowTest() internal {
        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.enableTokenIdAsCollateral(tokenId);
        wrapper.wrap(tokenId, borrower);

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

        evc.enableCollateral(borrower, address(wrapper));

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
        evc.disableCollateral(borrower, address(wrapper));

        //unwrap should fail
        vm.expectRevert(IEVault.E_AccountLiquidity.selector);
        wrapper.unwrap(borrower, tokenId, borrower);

        // Repay

        asset.approve(address(eVault), type(uint256).max);
        eVault.repay(type(uint256).max, borrower);

        evc.disableCollateral(borrower, address(wrapper));
        assertEq(evc.getCollaterals(borrower).length, 0);

        eVault.disableController();
        assertEq(evc.getControllers(borrower).length, 0);
    }

    function basicLiquidationTest() public {
        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.enableTokenIdAsCollateral(tokenId);
        wrapper.wrap(tokenId, borrower);

        evc.enableCollateral(borrower, address(wrapper));
        evc.enableController(borrower, address(eVault));

        eVault.borrow(5e6, borrower);

        vm.warp(block.timestamp + eVault.liquidationCoolOffTime());

        (uint256 maxRepay, uint256 yield) = eVault.checkLiquidation(liquidator, borrower, address(wrapper));
        assertEq(maxRepay, 0);
        assertEq(yield, 0);

        startHoax(IEulerRouter(address(oracle)).governor());
        IEulerRouter(address(oracle)).govSetConfig(
            address(wrapper),
            unitOfAccount,
            address(
                new FixedRateOracle(
                    address(wrapper),
                    unitOfAccount,
                    0.25e17 //in the actual conditions this price will always be the fixed 1:1, the balanceOf(user) will change as the price of the underlying tokens change and the position becomes liquidatable
                )
            )
        );

        startHoax(liquidator);
        (maxRepay, yield) = eVault.checkLiquidation(liquidator, borrower, address(wrapper));

        evc.enableCollateral(liquidator, address(wrapper));
        evc.enableController(liquidator, address(eVault));
        wrapper.enableTokenIdAsCollateral(tokenId);
        eVault.liquidate(borrower, address(wrapper), type(uint256).max, 0);

        //we know this a full liquidation so the current balanceOf of the borrower should be 0
        assertEq(wrapper.balanceOf(borrower), 0);
        //liquidator must have gotten all of the shares
        assertEq(wrapper.balanceOf(liquidator, tokenId), 1000 ether);
    }
}
