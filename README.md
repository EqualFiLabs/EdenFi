# EdenFi

This directory is named `EdenFi`, but the shared protocol substrate being built
here is **EqualFi**.

The first product being built on top of that substrate is the basket system
called **EDEN**, branded as **EDEN by EqualFi**.

The goal is to extract and harden the reusable core primitives first, then
build EDEN by EqualFi as the first focused product on top of that foundation.

Initial focus:
- position containers
- encumbrance accounting
- fee routing and fee indexes
- governance, timelock, and hardening primitives
- reusable lending and basket/accounting substrate

Out of scope for the first extraction pass:
- AMMs
- options and derivatives
- auctions
- agent-wallet and advanced account layers

Directory notes:
- `docs/` design notes and extraction plans
- `src/` shared protocol contracts
- `test/` focused validation for the extracted substrate
