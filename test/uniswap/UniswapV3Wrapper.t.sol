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
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract MockUniswapV3Wrapper is UniswapV3Wrapper {
    constructor(address _evc, address _positionManager, address _oracle, address _unitOfAccount, address _pool)
        UniswapV3Wrapper(_evc, _positionManager, _oracle, _unitOfAccount, _pool)
    {}

    function totalPositionValue(IUniswapV3Pool pool, uint160 sqrtRatioX96, uint256 tokenId)
        external
        view
        returns (uint256 amount0Total, uint256 amount1Total)
    {
        return _totalPositionValue(pool, sqrtRatioX96, tokenId);
    }
}

contract UniswapV3WrapperTest is Test, UniswapBaseTest {
    uint24 fee;
    INonfungiblePositionManager nonFungiblePositionManager;
    IUniswapV3Pool pool;
    IUniswapV3Factory factory;
    int24 tickSpacing;

    function deployWrapper() internal override returns (ERC721WrapperBase) {
        nonFungiblePositionManager = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        fee = 100; // 0.01% fee
        factory = IUniswapV3Factory(nonFungiblePositionManager.factory());
        tickSpacing = factory.feeAmountTickSpacing(fee);
        pool = IUniswapV3Pool(factory.getPool(token0, token1, fee));

        ERC721WrapperBase uniswapV3Wrapper = new MockUniswapV3Wrapper(
            address(evc), address(nonFungiblePositionManager), address(oracle), unitOfAccount, address(pool)
        );

        return uniswapV3Wrapper;
    }

    function setUp() public override {
        super.setUp();
        startHoax(borrower);
        SafeERC20.forceApprove(IERC20(token0), address(nonFungiblePositionManager), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(nonFungiblePositionManager), type(uint256).max);
        (tokenId,,) = mintPosition(
            borrower,
            100 * unit0,
            100 * unit1,
            -887272, //minimum tick
            887272 //maximum tick
        );
    }

    function mintPosition(
        address owner,
        uint256 amount0Desired,
        uint256 amount1Desired,
        int24 tickLower,
        int24 tickUpper
    ) public returns (uint256 tokenIdMinted, uint256 amount0, uint256 amount1) {
        startHoax(owner);
        deal(address(token0), borrower, amount0Desired * 2);
        deal(address(token1), borrower, amount1Desired * 2);

        (tokenIdMinted,, amount0, amount1) = nonFungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: owner,
                deadline: block.timestamp
            })
        );
    }

    function boundLiquidityParamsAndMint(LiquidityParams memory params)
        internal
        returns (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent)
    {
        params.liquidityDelta = bound(params.liquidityDelta, 10e18, 10_000e18);
        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();

        params = createFuzzyLiquidityParams(params, tickSpacing, sqrtRatioX96);

        (uint256 estimatedAmount0Required, uint256 estimatedAmount1Required) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint128(uint256(params.liquidityDelta))
        );

        (tokenIdMinted, amount0Spent, amount1Spent) = mintPosition(
            borrower, estimatedAmount0Required, estimatedAmount1Required, params.tickLower, params.tickUpper
        );
    }

    function testFuzzWrapAndUnwrapUniV3(LiquidityParams memory params) public {
        (uint256 tokenIdMinted, uint256 amount0Spent, uint256 amount1Spent) = boundLiquidityParamsAndMint(params);

        startHoax(borrower);
        wrapper.underlying().approve(address(wrapper), tokenIdMinted);
        wrapper.wrap(tokenIdMinted, borrower);
        wrapper.enableTokenIdAsCollateral(tokenIdMinted);

        uint256 amount0InUnitOfAccount = wrapper.getQuote(amount0Spent, address(token0));
        uint256 amount1InUnitOfAccount = wrapper.getQuote(amount1Spent, address(token1));

        uint256 expectedBalance = (amount0InUnitOfAccount + amount1InUnitOfAccount);

        assertApproxEqAbs(wrapper.balanceOf(borrower), expectedBalance, 1 ether);

        uint256 amount0BalanceBefore = IERC20(token0).balanceOf(borrower);
        uint256 amount1BalanceBefore = IERC20(token1).balanceOf(borrower);

        //unwrap to get the underlying tokens back
        wrapper.unwrap(borrower, tokenIdMinted, FULL_AMOUNT, borrower);

        assertApproxEqAbs(IERC20(token0).balanceOf(borrower), amount0BalanceBefore + amount0Spent, 1);
        assertApproxEqAbs(IERC20(token1).balanceOf(borrower), amount1BalanceBefore + amount1Spent, 1);
    }

    function test_BasicBorrowV3() public {
        borrowTest();
    }

    function test_basicLiquidation() public {
        basicLiquidationTest();
    }
}
