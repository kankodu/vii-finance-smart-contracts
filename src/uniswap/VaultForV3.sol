// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {ERC4626} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {UniswapV3Wrapper} from "src/uniswap/UniswapV3Wrapper.sol";
import {LiquidityAmounts} from "lib/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {EVCUtil} from "lib/ethereum-vault-connector/src/utils/EVCUtil.sol";
import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {IEVC} from "lib/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "lib/euler-interfaces/interfaces/IEVault.sol";
import {INonfungiblePositionManager} from "lib/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

contract Vault is ERC4626, EVCUtil {
    uint256 public tokenId; //one at a time or will be hold multiple tokens?
    UniswapV3Wrapper public immutable wrapper;

    int24 public tickLower;
    int24 public tickUpper;

    bool public immutable isToken0ToBeBorrowed;

    IUniswapV3Pool public immutable pool;
    IEVault public immutable eVaultToBorrowFrom;

    INonfungiblePositionManager public immutable nonFungiblePositionManager;

    address public immutable token0;
    address public immutable token1;

    //three type of rebalancing
    //1. change the tick range
    //2. increase or decrease the liquidity by borrowing more or to repay the borrowed assets
    //3. change the vault where the borrowing happens from. (repay from one vault entirely and borrow from another vault )

    constructor(
        UniswapV3Wrapper _wrapper,
        int24 _tickLower,
        int24 _tickUpper,
        IERC20 _asset,
        IEVault _eVaultToBorrowFrom,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) EVCUtil(_wrapper.EVC()) {
        wrapper = _wrapper;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        eVaultToBorrowFrom = _eVaultToBorrowFrom;

        INonfungiblePositionManager _nonFungiblePositionManager =
            INonfungiblePositionManager(address(wrapper.underlying()));

        nonFungiblePositionManager = _nonFungiblePositionManager;
        token0 = wrapper.token0();
        token1 = wrapper.token1();

        isToken0ToBeBorrowed = address(_asset) == wrapper.token1();

        pool = wrapper.pool();

        SafeERC20.forceApprove(IERC20(token0), address(_nonFungiblePositionManager), type(uint256).max);

        SafeERC20.forceApprove(IERC20(token1), address(_nonFungiblePositionManager), type(uint256).max);
    }

    function getSlot0SqrtPriceX96() public view returns (uint160 sqrtRatioX96) {
        (sqrtRatioX96,,,,,,) = pool.slot0();
    }

    function _getTokenIdToSkim() internal view returns (uint256) {
        uint256 totalTokensOwnedByThis = nonFungiblePositionManager.balanceOf(address(wrapper));
        return nonFungiblePositionManager.tokenOfOwnerByIndex(address(this), totalTokensOwnedByThis - 1);
    }

    function mintPosition(uint256 token0Amount, uint256 token1Amount) external {
        if (msg.sender != address(evc)) revert("Only EVC can call this function");
        if (_msgSender() != address(this)) revert("Only this contract can call this function");

        //we have to call the nonFungible position manager to mint the position
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: wrapper.fee(),
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: token0Amount,
            amount1Desired: token1Amount,
            amount0Min: token0Amount,
            amount1Min: token1Amount,
            recipient: address(wrapper),
            deadline: block.timestamp
        });

        (tokenId,,,) = nonFungiblePositionManager.mint(params);

        //ask wrapper to skim the newly minted position
        wrapper.skim(address(this));

        //enable the newly skimmed position as collateral
        wrapper.enableTokenIdAsCollateral(tokenId);
    }

    //for v4 we might have to unwrap, increase liquidity and then wrap it again because adding liquidity on behalf of someone is not allowed
    function increaseLiquidity(uint256 token0Amount, uint256 token1Amount) external {
        if (msg.sender != address(evc)) revert("Only EVC can call this function");
        if (_msgSender() != address(this)) revert("Only this contract can call this function");

        //here we do only one thing call increaseLiquidity for the tokenId that is already wrapped

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: tokenId,
            amount0Desired: token0Amount,
            amount1Desired: token1Amount,
            amount0Min: token0Amount,
            amount1Min: token1Amount,
            deadline: block.timestamp
        });

        nonFungiblePositionManager.increaseLiquidity(params);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        //we have to know how much tokens needs to be borrowed
        //we have to know much liquidity we can get for the given assets

        uint160 sqrtRatioLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            getSlot0SqrtPriceX96(),
            sqrtRatioLowerX96,
            sqrtRatioUpperX96,
            isToken0ToBeBorrowed ? type(uint256).max : assets,
            isToken0ToBeBorrowed ? assets : type(uint256).max
        );

        //now we know how much assets we have to borrow
        uint256 assetsToBorrow = isToken0ToBeBorrowed
            ? LiquidityAmounts.getAmount0ForLiquidity(sqrtRatioLowerX96, sqrtRatioLowerX96, liquidity)
            : LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioLowerX96, sqrtRatioUpperX96, liquidity);

        //evc batch to
        //1. borrow the assets
        //2. mint the position if it's the first time or unwrap the position increase the liquidity and wrap it again if it's not the first time (for univ3 it's ok we don't unwrap it. We just increase the liquidity )

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](2);

        //first borrow

        batchItems[0] = IEVC.BatchItem({
            targetContract: address(eVaultToBorrowFrom),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.borrow.selector, assetsToBorrow, address(this))
        });

        //now either mintPosition or increaseLiquidity

        batchItems[1] =
            IEVC.BatchItem({targetContract: address(this), onBehalfOfAccount: address(this), value: 0, data: ""});

        {
            uint256 token0Amount = isToken0ToBeBorrowed ? assetsToBorrow : assets;
            uint256 token1Amount = isToken0ToBeBorrowed ? assets : assetsToBorrow;

            batchItems[1].data = tokenId == 0
                ? abi.encodeWithSelector(this.mintPosition.selector, token0Amount, token1Amount) //if tokenId is 0 then we mint the position
                : abi.encodeWithSelector(this.increaseLiquidity.selector, token0Amount, token1Amount); //if tokenId is not 0 then we increase the liquidity
        }

        evc.batch(batchItems);

        //this shouldn't increase or decrease the share price.
        //calculate the totalAssets to make sure
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        //what do we need to do here?
        //decrease the liquidity first and then repay the borrowed assets

        //we assume that the user is the vault itself has not been liquidated

        //we partially unwrap

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](2);

        uint256 sharesToUnwrap = Math.mulDiv(shares, wrapper.balanceOf(address(this), tokenId), totalSupply());

        //    function unwrap(address from, uint256 tokenId, address to, uint256 amount, bytes calldata extraData)

        // we have estimate how much we will get back after unwrapping the sharesToUnwrap and that is how much we repay

        batchItems[0] = IEVC.BatchItem({
            targetContract: address(wrapper),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(
                bytes4(keccak256("unwrap(address,uint256,address,uint256,string)")),
                address(this),
                tokenId,
                address(this),
                sharesToUnwrap,
                ""
            )
        });

        uint256 currentBorrowedAmount = Math.mulDiv(shares, eVaultToBorrowFrom.debtOf(address(this)), totalSupply());

        batchItems[1] = IEVC.BatchItem({
            targetContract: address(eVaultToBorrowFrom),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.repay.selector, currentBorrowedAmount, address(this))
        });

        evc.batch(batchItems);

        //no we repay the borrowed assets

        //we can just do it here itself
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    //calculate the total assets of the vault

    function totalAssets() public view override returns (uint256) {
        if (tokenId == 0) return 0; //no position minted yet

        //we have to calculate the total assets of the vault
        //we have to get the position value and then we have to get the borrowed amount

        uint160 sqrtRatioX96 = getSlot0SqrtPriceX96();

        (uint256 amount0, uint256 amount1) = wrapper.totalPositionValue(sqrtRatioX96, tokenId);

        // uint256 totalValueInUnitOfAccount = wrapper.getQuote(amount0, token0) + wrapper.getQuote(amount1, token1);

        // uint256 currentBorrowedAmount = eVaultToBorrowFrom.debtOf(address(this));

        return amount0;
    }

    function _msgSender() internal view virtual override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }
}
