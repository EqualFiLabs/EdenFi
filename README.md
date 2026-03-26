# EdenFi

EdenFi is the shared protocol substrate intended to sit between the current
EDEN launch product and the broader long-term EqualFi architecture.

The goal is to extract and harden the reusable core primitives first, then
build EDEN as the first focused product on top of that foundation.

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
