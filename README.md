

## VII Finance

VII Finance builds on top of the Euler v2 Protocol, extending its functionality to allow Uniswap V3 and V4 LP positions to be used as collateral in any Euler vault built with the Euler Vault Kit (EVK).

---

### High-Level Overview

We have developed two collateral-only wrapper vaults:

1. UniswapV3Wrapper
2. UniswapV4Wrapper

These vaults enable users to wrap their Uniswap V3/V4 LP NFTs (which represent their LP positions) and receive ERC6909 tokens in return.

* Each ERC6909 token retains the original `tokenId` from the NFT.
* Holding the full amount of ERC6909 tokens represents full ownership of the original LP NFT.

Once wrapped, users can enable specific tokenIds as collateral within any compatible Euler vault.

---

### Borrow Flow

When a user borrows from an Euler vault that accepts our wrapper vault as collateral:

1. The Euler vault calls `balanceOf` on our wrapper contract.
2. The `balanceOf` function:

   * Iterates through all enabled `tokenIds`
   * Calculates the value of each LP position
   * Returns the aggregate value
3. The Euler vault uses this returned value to:

   * Verify that the collateral is sufficient based on the configured Loan-to-Value (LTV) ratio

---

### Liquidation Flow

If liquidation is triggered:

1. The Euler vault calls `transfer` on our wrapper vault, instructing a transfer from the violator to the liquidator
2. Our wrapper contract:

   * Iterates over all tokenIds enabled as collateral
   * Transfers a proportional amount of ERC6909 tokens to the liquidator
3. The liquidator can unwrap the received ERC6909 tokens to claim the underlying LP positions


