# Tasks

## Task 1: Rewrite the EDEN Architecture Spec As a Clean Break
- [x] 1. Update `.kiro/specs/eden-steve-only-clean-break/requirements.md` to explicitly state the clean-break boundary
  - [x] 1.1 EDEN is **not** a generic basket protocol
  - [x] 1.2 EqualIndex owns the generic basket / index lane
  - [x] 1.3 EDEN is a singleton product surface centered on `stEVE`
  - [x] 1.4 EDEN rewards are `EVE` emissions for PNFT-held `stEVE`
  - [x] 1.5 EDEN lending is only against the canonical EDEN product
  - [x] 1.6 Pool flash loans stay in substrate; index flash loans stay in EqualIndex
- [x] 2. Update `.kiro/specs/eden-steve-only-clean-break/design.md` to remove any multi-basket EDEN target state
  - [x] 2.1 Remove registry-shaped EDEN assumptions
  - [x] 2.2 Remove arbitrary `basketId` admin / lending / view assumptions
  - [x] 2.3 Make the final target architecture explicitly: EqualFi substrate + EqualIndex generic layer + singleton EDEN product

## Task 2: Delete Dead Duplicate EDEN Facets
- [x] 1. Remove `src/eden/EdenBasketFacet.sol`
- [x] 2. Remove `src/eden/EdenStEVEFacet.sol`
- [x] 3. Remove or update imports/tests/selectors that still reference those files
- [x] 4. Prove deploy wiring and tests no longer depend on the duplicate facets

## Task 3: Rewrite EDEN Storage From Basket Registry to Singleton Product Storage
- [x] 1. Rewrite `src/libraries/LibEdenBasketStorage.sol` into singleton EDEN product storage
  - [x] 1.1 Remove `basketCount`
  - [x] 1.2 Remove arbitrary `baskets[basketId]` mapping
  - [x] 1.3 Remove arbitrary `basketMetadata[basketId]` mapping
  - [x] 1.4 Remove arbitrary `tokenToBasketIdPlusOne`
  - [x] 1.5 Replace registry-style `vaultBalances[basketId][asset]` with singleton product state
  - [x] 1.6 Replace registry-style `feePots[basketId][asset]` with singleton product state
  - [x] 1.7 Rename structs and fields so they describe the EDEN product, not a basket catalog
- [x] 2. Update downstream EDEN code to use the singleton storage model only

## Task 4: Replace EDEN Wallet Flows With stEVE-Only Wallet Flows
- [x] 1. Remove generic wallet basket creation from `src/eden/EdenBasketWalletFacet.sol`
  - [x] 1.1 Delete `createBasket(...)`
- [x] 2. Remove generic wallet basket mint / burn entrypoints
  - [x] 2.1 Delete generic `mintBasket(...)`
  - [x] 2.2 Delete generic `burnBasket(...)`
- [x] 3. Replace them with explicit wallet-mode `stEVE` mint / burn flows
- [x] 4. Rename the facet if needed so the ABI reads as `stEVE`-specific, not generic-basket

## Task 5: Replace EDEN Position Flows With stEVE-Only Position Flows
- [x] 1. Remove generic position basket entrypoints from `src/eden/EdenBasketPositionFacet.sol`
  - [x] 1.1 Delete `mintBasketFromPosition(...)`
  - [x] 1.2 Delete `burnBasketFromPosition(...)`
- [x] 2. Replace them with explicit position-mode `stEVE` flows
- [x] 3. Ensure PNFT-owned `stEVE` principal remains substrate-native and reward-eligible

## Task 6: Replace EDEN View/Data Surfaces With Singleton Product Views
- [x] 1. Delete `src/eden/EdenBasketDataFacet.sol`
- [x] 2. Remove basket-registry views from `src/eden/EdenViewFacet.sol`
  - [x] 2.1 Remove `basketCount()`
  - [x] 2.2 Remove `getBasketIds(...)`
  - [x] 2.3 Remove `getBasketSummary(...)`
  - [x] 2.4 Remove `getBasketSummaries(...)`
  - [x] 2.5 Remove generic `canMint(...)`
  - [x] 2.6 Remove generic `canBurn(...)`
  - [x] 2.7 Remove `_positionBaskets(...)`
- [x] 3. Add explicit EDEN product views
  - [x] 3.1 Product config / metadata view
  - [x] 3.2 Product pool id view
  - [x] 3.3 Product fee config view
  - [x] 3.4 `stEVE` eligibility / reward state views
  - [x] 3.5 Position-facing EDEN product views

## Task 7: Replace EDEN Admin With Singleton Product Admin
- [x] 1. Remove arbitrary basket admin surfaces from `src/eden/EdenAdminFacet.sol`
  - [x] 1.1 Remove `setBasketMetadata(...)`
  - [x] 1.2 Remove `setBasketPaused(...)`
  - [x] 1.3 Remove `setBasketFees(...)`
- [x] 2. Replace them with EDEN-product config entrypoints
  - [x] 2.1 Product metadata config
  - [x] 2.2 Product pause config
  - [x] 2.3 Product fee config
  - [x] 2.4 Product reward config if needed
- [x] 3. Rename basket-oriented events into EDEN-product events
- [x] 4. Keep only governance-wide config that still makes sense (`protocolURI`, `contractVersion`, timelock config, etc.)

## Task 8: Replace EDEN Lending With Singleton-Product Lending
- [x] 1. Rewrite `src/libraries/LibEdenLendingStorage.sol` from per-basket state to singleton-product state
  - [x] 1.1 Remove per-`basketId` lending config
  - [x] 1.2 Remove per-`basketId` locked collateral accounting
  - [x] 1.3 Remove per-`basketId` outstanding principal accounting
- [x] 2. Rewrite `src/eden/EdenLendingFacet.sol` so lending is only against the canonical EDEN product
  - [x] 2.1 Remove `basketId` from public lending APIs
  - [x] 2.2 Replace `configureLending(basketId, ...)` with EDEN-product lending config
  - [x] 2.3 Replace `configureBorrowFeeTiers(basketId, ...)` with EDEN-product fee tiers
  - [x] 2.4 Keep repay / extend / recovery logic only where it still applies to the singleton product
  - [x] 2.5 Keep redeemability invariants for the singleton product
- [x] 3. Delete lending state/logic whose only purpose was arbitrary basket support

## Task 9: Make Rewards Explicitly and Only About PNFT-held stEVE
- [x] 1. Audit `src/eden/EdenRewardFacet.sol` for generic-basket assumptions
- [x] 2. Audit `src/eden/EdenStEVEActionFacet.sol` so it is the only reward-eligible PNFT entry surface
- [x] 3. Remove any residual implication that arbitrary EDEN products can become reward-bearing
- [x] 4. Tighten views and tests so the rule is explicit
  - [x] 4.1 Wallet-held `stEVE` does not earn `EVE`
  - [x] 4.2 PNFT-held `stEVE` does earn `EVE`
  - [x] 4.3 Rewards accrue to the position, not directly to the wallet

## Task 10: Remove EDEN Generic Mint/Burn Logic From Shared Internals
- [x] 1. Audit `src/eden/EdenBasketLogic.sol` for generic basket machinery
- [x] 2. Delete internal paths supporting arbitrary basket creation
- [x] 3. Delete internal paths supporting arbitrary basket mint / burn
- [x] 4. Retain only the internal logic needed for the singleton EDEN product
- [x] 5. Rename helpers so they read as EDEN-product / `stEVE` logic rather than generic basket logic

## Task 11: Keep Canonical Non-EDEN Capabilities In the Right Layers
- [x] 1. Verify pool flash loans remain in `src/equallend/FlashLoanFacet.sol`
- [x] 2. Verify index flash loans remain in `src/equalindex/EqualIndexActionsFacetV3.sol`
- [x] 3. Verify generic structured exposure remains in EqualIndex, not EDEN
- [x] 4. Verify EDEN cleanup does not delete or orphan those selectors/tests

## Task 12: Rewrite Deployment and Selector Wiring To Match the New Boundary
- [x] 1. Update `script/DeployEdenByEqualFi.s.sol`
- [x] 2. Remove selector groups for EDEN generic basket surfaces
- [x] 3. Remove selector groups for deleted legacy facets
- [x] 4. Ensure only intended EDEN singleton-product facets are cut into the diamond
- [x] 5. Update loupe and facet-count assertions in deploy tests

## Task 13: Add Regression Tests For the Clean Break
- [ ] 1. Add tests proving arbitrary EDEN basket creation is impossible
- [ ] 2. Add tests proving arbitrary EDEN wallet mint / burn is impossible
- [ ] 3. Add tests proving arbitrary EDEN position mint / burn is impossible
- [ ] 4. Add tests proving wallet-mode `stEVE` mint / burn still works
- [ ] 5. Add tests proving PNFT-mode `stEVE` deposit / withdraw still works
- [ ] 6. Add tests proving only PNFT-held `stEVE` earns `EVE`
- [ ] 7. Add tests proving EDEN lending works against the singleton EDEN product
- [ ] 8. Add tests proving pool flash loans still work
- [ ] 9. Add tests proving index flash loans still work
- [ ] 10. Add tests proving EqualIndex generic mint / burn still works for non-EDEN products
- [ ] 11. Add tests proving deploy selector set matches the intended final surface
