// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {UniswapV4Wrapper} from "src/uniswap/UniswapV4Wrapper.sol";
import {Addresses} from "test/helpers/Addresses.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {EthereumVaultConnector} from "lib/ethereum-vault-connector/src/EthereumVaultConnector.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "lib/v4-periphery/lib/v4-core/test/utils/Constants.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract Token is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UniswapV4WrapperTest is Test {
    UniswapV4Wrapper public wrapper;
    IPositionManager public positionManager = IPositionManager(Addresses.POSITION_MANAGER);
    IPoolManager public poolManager = IPoolManager(Addresses.POOL_MANAGER);
    EthereumVaultConnector public evc = new EthereumVaultConnector();

    PoolId public poolId;

    Currency public currency0;
    Currency public currency1;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    PoolKey public poolKey;

    function setUp() public {
        string memory rpc_url = vm.envOr("MAINNET_RPC_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(rpc_url, 22360694);

        Token tokenA = new Token();
        Token tokenB = new Token();

        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));
        }

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        labelEverything();
    }

    function currencyToToken(Currency currency) internal pure returns (Token) {
        return Token(address(uint160(currency.toId())));
    }

    function labelEverything() public {
        vm.label(address(positionManager), "PositionManager");
        vm.label(address(poolManager), "PoolManager");
        vm.label(address(uint160(currency0.toId())), "Currency0");
        vm.label(address(uint160(currency1.toId())), "Currency1");
        vm.label(address(wrapper), "Wrapper");
    }

    function test_wrapAndUnwrapShouldReturnTheSameTokens() public {}
}
