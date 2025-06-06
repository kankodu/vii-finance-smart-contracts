pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {EthereumVaultConnector} from "lib/ethereum-vault-connector/src/EthereumVaultConnector.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol";
import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IEulerRouter} from "lib/euler-interfaces/interfaces/IEulerRouter.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import {IEVC} from "lib/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {ERC721WrapperBase} from "src/ERC721WrapperBase.sol";
import {UniswapBaseTest} from "test/uniswap/UniswapBase.t.sol";
import {Fuzzers} from "@uniswap/v4-core/src/test/Fuzzers.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TestRouter, SwapParams} from "lib/v4-periphery/test/shared/TestRouter.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {UniswapPositionValueHelper} from "src/libraries/UniswapPositionValueHelper.sol";
import {PositionInfo} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {UniswapMintPositionHelper} from "src/uniswap/periphery/UniswapMintPositionHelper.sol";

contract MockUniswapV4Wrapper is UniswapV4Wrapper {
    constructor(
        address _evc,
        address _positionManager,
        address _oracle,
        address _unitOfAccount,
        PoolKey memory _poolKey
    ) UniswapV4Wrapper(_evc, _positionManager, _oracle, _unitOfAccount, _poolKey) {}

    function syncFeesOwned(uint256 tokenId) external returns (uint256 actualFees0, uint256 actualFees1) {
        uint256 amount0OwedBefore = tokensOwed[tokenId].amount0Owed;
        uint256 amount1OwedBefore = tokensOwed[tokenId].amount1Owed;

        _syncFeesOwned(tokenId);

        return
            (tokensOwed[tokenId].amount0Owed - amount0OwedBefore, tokensOwed[tokenId].amount1Owed - amount1OwedBefore);
    }

    function totalPositionValue(uint160 sqrtRatioX96, uint256 tokenId)
        external
        view
        returns (uint256 amount0Total, uint256 amount1Total)
    {
        return _totalPositionValue(sqrtRatioX96, tokenId);
    }
}

contract UniswapV4WrapperTest is Test, UniswapBaseTest {
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint24 constant FEE = 10; //0.001% fee
    int24 constant TICK_SPACING = 1;
    IPositionManager public positionManager = IPositionManager(Addresses.POSITION_MANAGER);
    IPoolManager public poolManager = IPoolManager(Addresses.POOL_MANAGER);
    IPermit2 public permit2 = IPermit2(Addresses.PERMIT2);

    PoolKey public poolKey;
    PoolId public poolId;
    Currency currency0;
    Currency currency1;

    TestRouter public router;

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        ERC721WrapperBase uniswapV4Wrapper =
            new MockUniswapV4Wrapper(address(evc), address(positionManager), address(oracle), unitOfAccount, poolKey);
        mintPositionHelper = new UniswapMintPositionHelper(address(evc), address(0), address(positionManager));

        return uniswapV4Wrapper;
    }

    function currencyToToken(Currency currency) internal pure returns (IERC20) {
        return IERC20(address(uint160(currency.toId())));
    }

    function setUp() public override {
        super.setUp();

        router = new TestRouter(poolManager);
        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(router), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token0), address(router), type(uint256).max);

        startHoax(borrower);
        SafeERC20.forceApprove(currencyToToken(currency0), address(mintPositionHelper), type(uint256).max);
        SafeERC20.forceApprove(currencyToToken(currency1), address(mintPositionHelper), type(uint256).max);

        (tokenId,,) = mintPosition(poolKey, TickMath.MIN_TICK, TickMath.MAX_TICK, 100 * unit0, 100 * unit1, 0, borrower);
    }

    function mintPosition(
        PoolKey memory targetPoolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 liquidityToAdd,
        address owner
    ) internal returns (uint256 tokenIdMinted, uint256 amount0, uint256 amount1) {
        deal(address(token0), owner, amount0Desired * 2);
        deal(address(token1), owner, amount1Desired * 2);

        tokenIdMinted = positionManager.nextTokenId();

        if (liquidityToAdd == 0) {
            (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);

            liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                amount0Desired,
                amount1Desired
            );
        }

        uint256 token0BalanceBefore = IERC20(token0).balanceOf(owner);
        uint256 token1BalanceBefore = IERC20(token1).balanceOf(owner);

        mintPositionHelper.mintPosition(
            targetPoolKey,
            tickLower,
            tickUpper,
            liquidityToAdd,
            uint128(amount0Desired) * 2,
            uint128(amount1Desired) * 2,
            owner,
            new bytes(0)
        );

        //ensure any unused tokens are returned to the borrower and position manager balance is zero
        assertEq(IERC20(token0).balanceOf(address(positionManager)), 0);
        assertEq(IERC20(token1).balanceOf(address(positionManager)), 0);

        assertEq(IERC20(token0).balanceOf(address(mintPositionHelper)), 0);
        assertEq(IERC20(token1).balanceOf(address(mintPositionHelper)), 0);

        amount0 = token0BalanceBefore - IERC20(token0).balanceOf(owner);
        amount1 = token1BalanceBefore - IERC20(token1).balanceOf(owner);
    }

    function swapExactInput(address swapper, address tokenIn, address tokenOut, uint256 inputAmount)
        internal
        returns (uint256 outputAmount)
    {
        deal(tokenIn, swapper, inputAmount);

        bool zeroForOne = tokenIn < tokenOut;

        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(inputAmount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta balanceDelta = router.swap(poolKey, swapParams, new bytes(0));

        outputAmount = zeroForOne ? uint256(int256(balanceDelta.amount1())) : uint256(int256(balanceDelta.amount0()));
    }

    function test_swapExactInput() public {
        uint256 inputAmount = 1e18;
        startHoax(borrower);
        uint256 outputAmount = swapExactInput(borrower, address(token0), address(token1), inputAmount);
        assertGt(outputAmount, 0);
    }

    function boundLiquidityParamsAndMint(LiquidityParams memory params)
        internal
        returns (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent)
    {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);
        params = createFuzzyLiquidityParams(params, poolKey.tickSpacing, sqrtRatioX96);

        (uint256 estimatedAmount0Required, uint256 estimatedAmount1Required) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        startHoax(borrower);

        (tokenIdMinted, amount0Spent, amount1Spent) = mintPosition(
            poolKey,
            params.tickLower,
            params.tickUpper,
            estimatedAmount0Required,
            estimatedAmount1Required,
            uint256(params.liquidityDelta),
            borrower
        );
    }

    function testWrapFailIfNotTheSamePoolId() public {
        //we know the first 10 tokenIds are not from the same pool
        for (uint256 i = 1; i < 10; i++) {
            startHoax(wrapper.underlying().ownerOf(i));
            wrapper.underlying().approve(address(wrapper), i);

            vm.expectRevert(UniswapV4Wrapper.InvalidPoolId.selector);
            wrapper.wrap(i, borrower);
        }
    }

    function testSkim() public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1,
            tickUpper: TickMath.MAX_TICK - 1,
            liquidityDelta: -19999
        });
        (tokenId,,) = boundLiquidityParamsAndMint(params);

        //fail if trying to skim the last minted tokenId but wrapper is not the owner
        vm.expectRevert(ERC721WrapperBase.TokenIdNotOwnedByThisContract.selector);
        wrapper.skim(borrower);

        startHoax(borrower);
        wrapper.underlying().transferFrom(borrower, address(wrapper), tokenId);

        startHoax(address(1));
        wrapper.skim(borrower);

        assertEq(wrapper.balanceOf(borrower, tokenId), FULL_AMOUNT);

        startHoax(borrower);
        wrapper.enableCurrentSkimCandidateAsCollateral();

        uint256[] memory enabledTokenIds = wrapper.getEnabledTokenIds(borrower);
        assertEq(enabledTokenIds.length, 1);
        assertEq(enabledTokenIds[0], tokenId);

        vm.expectRevert(ERC721WrapperBase.TokenIdIsAlreadyWrapped.selector);
        wrapper.skim(borrower);
    }

    function testFuzzWrapAndUnwrap(LiquidityParams memory params) public {
        (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent) = boundLiquidityParamsAndMint(params);
        tokenId = tokenIdMinted;

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        uint256 amount0InUnitOfAccount = wrapper.getQuote(amount0Spent, address(token0));
        uint256 amount1InUnitOfAccount = wrapper.getQuote(amount1Spent, address(token1));

        uint256 expectedBalance = (amount0InUnitOfAccount + amount1InUnitOfAccount);

        assertApproxEqAbs(wrapper.balanceOf(borrower), expectedBalance, 0.001 ether); //0.001$ of difference is allowed

        uint256 amount0BalanceBefore = IERC20(token0).balanceOf(borrower);
        uint256 amount1BalanceBefore = IERC20(token1).balanceOf(borrower);

        //unwrap to get the underlying tokens back
        wrapper.unwrap(borrower, tokenId, FULL_AMOUNT, borrower);

        assertApproxEqAbs(IERC20(token0).balanceOf(borrower), amount0BalanceBefore + amount0Spent, 1);
        assertApproxEqAbs(IERC20(token1).balanceOf(borrower), amount1BalanceBefore + amount1Spent, 1);
    }

    function testFuzzFeeMath(int256 liquidityDelta, uint256 swapAmount) public {
        LiquidityParams memory params = LiquidityParams({
            tickLower: TickMath.MIN_TICK + 1,
            tickUpper: TickMath.MAX_TICK - 1,
            liquidityDelta: liquidityDelta
        });

        swapAmount = bound(swapAmount, 10_000 * unit0, 100_000 * unit0);

        (tokenId,,) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        //swap so that some fees are generated
        swapExactInput(borrower, address(token0), address(token1), swapAmount);

        PositionInfo position = positionManager.positionInfo(tokenId);

        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager
            .getPositionInfo(poolId, address(positionManager), position.tickLower(), position.tickUpper(), bytes32(tokenId));

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, position.tickLower(), position.tickUpper());

        (uint256 expectedFees0, uint256 expectedFees1) = UniswapPositionValueHelper.feesOwed(
            feeGrowthInside0X128, feeGrowthInside1X128, feeGrowthInside0LastX128, feeGrowthInside1LastX128, liquidity
        );

        (uint256 actualFees0, uint256 actualFees1) = MockUniswapV4Wrapper(address(wrapper)).syncFeesOwned(tokenId);

        assertEq(actualFees0, expectedFees0);
        assertEq(actualFees1, expectedFees1);
    }

    function testFuzzTotalPositionValue(LiquidityParams memory params) public {
        uint256 amount0Spent;
        uint256 amount1Spent;

        (tokenId, amount0Spent, amount1Spent) = boundLiquidityParamsAndMint(params);

        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);

        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);

        (uint256 token0Principal, uint256 token1Principal) =
            MockUniswapV4Wrapper(address(wrapper)).totalPositionValue(sqrtRatioX96, tokenId);

        //since no swap has been the principal amount should be the same as the amount0 and amount1
        assertApproxEqAbs(token0Principal, amount0Spent, 1 wei);
        assertApproxEqAbs(token1Principal, amount1Spent, 1 wei);
    }

    function testFuzzTransfer(LiquidityParams memory params, uint256 swapAmount, uint256 transferAmount) public {
        (tokenId,,) = boundLiquidityParamsAndMint(params);

        swapAmount = bound(swapAmount, 10_000 * unit0, 100_000 * unit0);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenId);
        wrapper.wrap(tokenId, borrower);
        wrapper.enableTokenIdAsCollateral(tokenId);

        swapExactInput(borrower, address(token0), address(token1), swapAmount);

        uint256 totalValueBefore = wrapper.balanceOf(borrower);

        transferAmount = bound(transferAmount, 1 + (totalValueBefore / 0.001 ether), totalValueBefore); //minim transfer of 0.001$

        wrapper.transfer(liquidator, transferAmount);

        uint256 erc6909TokensTransferred = (transferAmount * FULL_AMOUNT) / totalValueBefore;

        assertEq(wrapper.balanceOf(liquidator, tokenId), erc6909TokensTransferred); //erc6909 check (rounding error)
        assertEq(wrapper.balanceOf(borrower, tokenId), FULL_AMOUNT - erc6909TokensTransferred);

        assertEq(wrapper.balanceOf(liquidator), 0); // because tokenId is not enabled as collateral
        assertApproxEqAbs(wrapper.balanceOf(borrower), totalValueBefore - transferAmount, 0.001 ether); //0.001$ of difference is allowed

        startHoax(liquidator);
        wrapper.enableTokenIdAsCollateral(tokenId);

        assertApproxEqAbs(wrapper.balanceOf(liquidator), transferAmount, 0.001 ether); //0.001$ of difference is allowed
        assertApproxEqRel(totalValueBefore, wrapper.balanceOf(borrower) + wrapper.balanceOf(liquidator), 1);
    }

    function test_BasicBorrowV4() public {
        borrowTest();
    }

    function test_basicLiquidationV4() public {
        basicLiquidationTest();
    }
}
