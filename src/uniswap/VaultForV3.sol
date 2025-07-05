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
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {SignedMath} from "lib/openzeppelin-contracts/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

contract Vault is ERC4626, EVCUtil {
    uint256 public tokenId;
    UniswapV3Wrapper public immutable wrapper;

    int24 public tickLower;
    int24 public tickUpper;

    bool public immutable isToken0ToBeBorrowed;

    IUniswapV3Pool public immutable pool;
    IEVault public eVaultToBorrowFrom;

    INonfungiblePositionManager public immutable nonFungiblePositionManager;

    address public immutable token0;
    address public immutable token1;

    IPriceOracle public immutable oracle;

    address public immutable poolManager;

    constructor(
        UniswapV3Wrapper _wrapper,
        address _poolManager,
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

        //this check is not correct. We have to check that the asset other than the underlying asset should be the same as the one being borrowed
        // if (_eVaultToBorrowFrom.asset() != address(_asset)) {
        //     revert("Asset does not match the vault's asset");
        // }

        oracle = IPriceOracle(_wrapper.oracle());

        INonfungiblePositionManager _nonFungiblePositionManager =
            INonfungiblePositionManager(address(wrapper.underlying()));

        nonFungiblePositionManager = _nonFungiblePositionManager;
        token0 = wrapper.token0();
        token1 = wrapper.token1();

        isToken0ToBeBorrowed = address(_asset) == wrapper.token1();

        pool = wrapper.pool();

        SafeERC20.forceApprove(IERC20(token0), address(_nonFungiblePositionManager), type(uint256).max);
        SafeERC20.forceApprove(IERC20(token1), address(_nonFungiblePositionManager), type(uint256).max);

        poolManager = _poolManager;

        evc.enableController(address(this), address(eVaultToBorrowFrom));
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

        //disable the outdated tokenId as collateral if it exists
        if (tokenId != 0) wrapper.disableTokenIdAsCollateral(tokenId);

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

        uint160 sqrtRatioX96 = getSlot0SqrtPriceX96();
        (uint256 amount0, uint256 amount1) = wrapper.totalPositionValue(sqrtRatioX96, tokenId);

        //TODO: check if this will repay the right amount of assets. It might not
        uint256 amountToRepay = isToken0ToBeBorrowed
            ? Math.mulDiv(shares, amount0, totalSupply())
            : Math.mulDiv(shares, amount1, totalSupply());

        //make sure the error is not more than a 1 wei and there is enough balance of 1 wei extra if needed in this contract

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

        batchItems[1] = IEVC.BatchItem({
            targetContract: address(eVaultToBorrowFrom),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.repay.selector, amountToRepay, address(this))
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

        uint256 amountBorrowed = eVaultToBorrowFrom.debtOf(address(this));

        int256 effectiveAmountOfTokensBorrowed = isToken0ToBeBorrowed
            ? int256(amount0 + IERC20(token0).balanceOf(address(this))) - int256(amountBorrowed)
            : int256(amount1 + IERC20(token1).balanceOf(address(this))) - int256(amountBorrowed);

        uint256 effectiveAmountOfTokensBorrowedInOtherToken = oracle.getQuote(
            SignedMath.abs(effectiveAmountOfTokensBorrowed),
            isToken0ToBeBorrowed ? token0 : token1,
            isToken0ToBeBorrowed ? token1 : token0
        );

        uint256 otherTokenAmount = isToken0ToBeBorrowed ? amount1 : amount0;

        otherTokenAmount +=
            isToken0ToBeBorrowed ? IERC20(asset()).balanceOf(address(this)) : IERC20(asset()).balanceOf(address(this));

        return SafeCast.toUint256(
            int256(otherTokenAmount) < 0
                ? -int256(effectiveAmountOfTokensBorrowedInOtherToken)
                : int256(effectiveAmountOfTokensBorrowedInOtherToken)
        );
    }

    //three type of rebalancing
    //1. change the tick range
    //2. increase or decrease the liquidity by borrowing more or to repay the borrowed assets
    //3. change the vault where the borrowing happens from. (repay from one vault entirely and borrow from another vault )

    //why would this be needed? If there is another market that accepts the same pool LP as collateral and has a better interest rate
    function changeBorrowEVault(IEVault newEVault) external {
        if (msg.sender != address(poolManager)) revert("Only pool manager can call this function");

        //in a batch enableController for the new vault
        //borrow the current borrowed amount from the new vault
        //repay the current borrowed amount to the old vault
        //disableController for the old vault

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](4);
        batchItems[0] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeWithSelector(IEVC.enableController.selector, address(this), address(newEVault))
        });

        uint256 currentBorrowedAmount = eVaultToBorrowFrom.debtOf(address(this));

        batchItems[1] = IEVC.BatchItem({
            targetContract: address(newEVault),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.borrow.selector, currentBorrowedAmount, address(this))
        });

        batchItems[2] = IEVC.BatchItem({
            targetContract: address(eVaultToBorrowFrom),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(IEVault.repay.selector, currentBorrowedAmount, address(this))
        });

        batchItems[3] = IEVC.BatchItem({
            targetContract: address(evc),
            onBehalfOfAccount: address(0),
            value: 0,
            data: abi.encodeWithSelector(IEVC.disableController.selector, address(this), address(eVaultToBorrowFrom))
        });

        evc.batch(batchItems);

        eVaultToBorrowFrom = newEVault;
        isToken0ToBeBorrowed
            ? SafeERC20.forceApprove(IERC20(address(newEVault)), address(token0), type(uint256).max)
            : SafeERC20.forceApprove(IERC20(address(newEVault)), address(token1), type(uint256).max);
    }

    function changeTickRange(int24 newTickLower, int24 newTickUpper) external {
        if (msg.sender != address(poolManager)) revert("Only pool manager can call this function");

        uint160 sqrtRatioX96 = getSlot0SqrtPriceX96();
        (uint256 amount0, uint256 amount1) = wrapper.totalPositionValue(sqrtRatioX96, tokenId);

        tickLower = newTickLower;
        tickUpper = newTickUpper;

        //we will have to decrease the liquidity to it's entirely
        //the we call mintPosition with the new tick range and the same amount of tokens

        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](2);
        batchItems[0] = IEVC.BatchItem({
            targetContract: address(wrapper),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(
                bytes4(keccak256("unwrap(address,uint256,address,uint256,string)")),
                address(this),
                tokenId,
                address(this),
                wrapper.balanceOf(address(this), tokenId), //we want to unwrap the entire position
                ""
            )
        });

        batchItems[1] = IEVC.BatchItem({
            targetContract: address(this),
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeWithSelector(this.mintPosition.selector, amount0, amount1)
        });

        evc.batch(batchItems);

        //if there are any leftover assets and they are of the borrowed asset then we have to repay them
        uint256 leftoverAssets =
            isToken0ToBeBorrowed ? IERC20(token0).balanceOf(address(this)) : IERC20(token1).balanceOf(address(this));

        eVaultToBorrowFrom.repay(
            leftoverAssets < eVaultToBorrowFrom.debtOf(address(this)) ? leftoverAssets : type(uint256).max,
            address(this)
        );

        //we always make sure there are no leftover borrowed assets in the vault
    }

    //two types of rebalancing. borrow some more assets and increase the liquidity by swapping it or repay some assets and decrease the liquidity

    function _msgSender() internal view virtual override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }
}
