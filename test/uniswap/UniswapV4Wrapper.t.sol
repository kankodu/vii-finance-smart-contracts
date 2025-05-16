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
import {LiquidityAmounts} from "src/libraries/LiquidityAmounts.sol";
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

contract UniswapV4WrapperTest is Test, UniswapBaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 10; //0.001% fee
    int24 constant TICK_SPACING = 1;
    IPositionManager public positionManager = IPositionManager(Addresses.POSITION_MANAGER);
    IPoolManager public poolManager = IPoolManager(Addresses.POOL_MANAGER);
    IPermit2 public permit2 = IPermit2(Addresses.PERMIT2);

    PoolKey public poolKey;
    PoolId public poolId;
    Currency currency0;
    Currency currency1;

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
            new UniswapV4Wrapper(address(evc), address(positionManager), address(oracle), unitOfAccount, poolId);

        return uniswapV4Wrapper;
    }

    function currencyToToken(Currency currency) internal pure returns (IERC20) {
        return IERC20(address(uint160(currency.toId())));
    }

    function setUp() public override {
        super.setUp();

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

    function test_BasicBorrowV4() public {
        borrowTest();
    }

    function test_basicLiquidationV4() public {
        basicLiquidationTest();
    }
}
