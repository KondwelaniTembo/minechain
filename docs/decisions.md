# Decisions log

Technical decisions for MineChain, with the reason for each.

| Date | Decision | Options considered | Reason |
|---|---|---|---|
| 29 Oct 2026 | **Ethereum tooling:** Hardhat 3 | Hardhat 3, Foundry | The developer already knows Hardhat from a previous project, so time goes on the contract rather than on learning new tooling. |
| 29 Oct 2026 | **Flutter state management:** Riverpod | Riverpod, Bloc | Riverpod is easy to test and keeps logic out of widgets. |
| 29 Oct 2026 | **Local encrypted database:** SQLCipher, exact Flutter package to be confirmed before the offline storage work | None recorded | SQLCipher encrypts the local database with AES-256, which protects cached transactions on a lost or stolen device. |
| 29 Oct 2026 | **Backend hosting:** Render with PostgreSQL | None recorded | Render provides real HTTPS, which certificate pinning needs. |
| 29 Oct 2026 | **Ledger permissioning:** public Sepolia testnet, made permissioned through contract access control | None recorded | The project requires role-restricted write access, and contract access control provides it on a public testnet. Anyone can read the ledger, and only the authorised account can write to it. |
| 31 Oct 2026 | **Certificate pinning:** pin the root CA with a backup root, using a Dart `SecurityContext` that trusts only the bundled roots. The exact roots are to be confirmed from the deployed certificate chain | Pin the exact server certificate; pin the root CA with a backup; run our own server with our own certificate | Render renews certificates automatically, so pinning the exact certificate could lock the app out after a renewal, and running our own server adds too much work. Root pinning survives renewals and still blocks interception through a fake CA installed on the device. |
