# EdenFi Substrate Extract

Initial ported systems from EqualFi:

- `PositionNFT`
- pool initialization and managed-pool foundation via `PoolManagementFacet`
- encumbrance accounting via `LibEncumbrance`
- index/module encumbrance adapters
- fee routing via `LibFeeRouter`
- fee index accounting via `LibFeeIndex`
- active credit index and maintenance helpers
- shared app storage, access, diamond-owner helpers, and core types

Intentional simplification in this first EdenFi pass:

- `LibFeeIndex` is adapted to depend on shared pool ledgers only
- direct-lending and other product-specific debt systems are not pulled in yet
- the goal is a reusable protocol substrate, not a full EqualFi product port

This gives EdenFi a clean starting point for:

- position-owned collateral
- module-safe encumbrance expansion
- pool-native yield routing
- future EDEN-on-EdenFi rebuilding
