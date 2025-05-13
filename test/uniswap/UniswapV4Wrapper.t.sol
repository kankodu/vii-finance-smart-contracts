// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

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
import {LiquidityAmounts} from "src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "lib/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {FixedRateOracle} from "lib/euler-price-oracle/src/adapter/fixed/FixedRateOracle.sol";
import {IEulerRouter} from "lib/euler-interfaces/interfaces/IEulerRouter.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/interfaces/IERC721.sol";
import {IEVC} from "lib/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

contract Token is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UniswapV4WrapperTest is Test {
    uint256 constant INTERNAL_DEBT_PRECISION_SHIFT = 31;

    UniswapV4Wrapper public wrapper;
    IPositionManager public positionManager = IPositionManager(Addresses.POSITION_MANAGER);
    IPoolManager public poolManager = IPoolManager(Addresses.POOL_MANAGER);
    IEVC public evc = IEVC(Addresses.EVC);
    IEVault public eVault = IEVault(Addresses.EULER_USDC_VAULT);
    IPermit2 public permit2 = IPermit2(Addresses.PERMIT2);

    IPriceOracle oracle;
    address public unitOfAccount;
    IERC20 asset;

    Currency public currency0;
    Currency public currency1;

    uint256 unit0;
    uint256 unit1;

    uint24 constant FEE = 10; //0.001% fee
    int24 constant TICK_SPACING = 1;
    PoolKey public poolKey;
    PoolId public poolId;

    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");

    uint256 tokenId;

    using StateLibrary for IPoolManager;

    function setUp() public {
        string memory rpc_url = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpc_url, 22473612);

        unitOfAccount = eVault.unitOfAccount();
        oracle = IPriceOracle(eVault.oracle());
        asset = IERC20(eVault.asset());

        Token tokenA = Token(Addresses.USDC);
        Token tokenB = Token(Addresses.USDT);

        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));

            unit0 = 10 ** IERC20Metadata(address(tokenA)).decimals();
            unit1 = 10 ** IERC20Metadata(address(tokenB)).decimals();
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));

            unit0 = 10 ** IERC20Metadata(address(tokenB)).decimals();
            unit1 = 10 ** IERC20Metadata(address(tokenA)).decimals();
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        wrapper = new UniswapV4Wrapper(address(evc), address(positionManager), address(oracle), unitOfAccount, poolId);

        deal(address(currencyToToken(currency0)), borrower, 1000 * unit0);
        deal(address(currencyToToken(currency1)), borrower, 1000 * unit1);

        startHoax(borrower);
        SafeERC20.forceApprove(currencyToToken(currency0), address(permit2), type(uint256).max);
        SafeERC20.forceApprove(currencyToToken(currency1), address(permit2), type(uint256).max);

        startHoax(borrower);
        permit2.approve(
            address(currencyToToken(currency0)),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );
        permit2.approve(
            address(currencyToToken(currency1)),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );

        tokenId = mintPosition(poolKey, TickMath.MIN_TICK, TickMath.MAX_TICK, 100 * unit0, 100 * unit1, borrower);

        FixedRateOracle fixedRateOracle = new FixedRateOracle(
            address(wrapper),
            unitOfAccount,
            1e18 // 1:1 price, This is because we know unitOfAccount is usd and it's decimals are 18, it should be dependent on decimals of unitOfAccount
        );

        address oracleGovernor = IEulerRouter(address(oracle)).governor();
        startHoax(oracleGovernor);
        IEulerRouter(address(oracle)).govSetConfig(address(wrapper), unitOfAccount, address(fixedRateOracle));

        address governorAdmin = eVault.governorAdmin();
        startHoax(governorAdmin);
        eVault.setLTV(address(wrapper), 0.9e4, 0.9e4, 0);

        labelEverything();
    }

    function currencyToToken(Currency currency) internal pure returns (Token) {
        return Token(address(uint160(currency.toId())));
    }

    function labelEverything() public {
        vm.label(address(positionManager), "PositionManager");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(wrapper), "Wrapper");
    }

    function mintPosition(
        PoolKey memory targetPoolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address owner
    ) internal returns (uint256 tokenIdMinted) {
        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(Actions.MINT_POSITION));
        actions[1] = bytes1(uint8(Actions.SETTLE_PAIR));

        tokenIdMinted = positionManager.nextTokenId();

        (uint160 sqrtRatioX96,,,) = poolManager.getSlot0(poolId);

        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        uint128 amount0Max = type(uint128).max;
        uint128 amount1Max = type(uint128).max;

        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(targetPoolKey, tickLower, tickUpper, liquidityToAdd, amount0Max, amount1Max, owner, new bytes(0));
        params[1] = abi.encode(currency0, currency1);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function test_BasicBorrow() public {
        startHoax(borrower);
        IERC721(address(positionManager)).approve(address(wrapper), tokenId);
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

    function test_basicLiquidation_all_collateral() public {
        startHoax(borrower);
        IERC721(address(positionManager)).approve(address(wrapper), tokenId);
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
                    0.25e17 //in the actual conditions this price will always be the fixed 1:1, the balanceOf(user) will change as the price of the underlying tokens change and the position becomes liquidateable
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
