# MineChain

A blockchain-anchored mobile application for secure mining supply chain verification in Zambia.

Final-year project, BSc Computer Science, ZCAS University (2026).

> 🚧 Status: in development

## Repository structure

| Folder | Contents |
|---|---|
| `contracts/` | Solidity smart contract (Ethereum Sepolia Testnet), built with Hardhat |
| `backend/` | Node.js REST API: authentication, anomaly detection, reports |
| `mobile/` | Flutter Android app for miners, transporters, buyers, officers and admins |
| `docs/` | Architecture, API and contract specifications, decisions log |

## Run the mobile app

Needs Flutter 3.47.9 (stable) and an Android phone or emulator running Android 8.0
(API 26) or later. From the `mobile/` folder, in PowerShell:

1. Copy the example settings file, then put the API's `https://` address in the copy:

   ```powershell
   Copy-Item env/api.example.json env/api.json
   ```

   `env/api.json` is git-ignored. Never commit it.

2. Install packages and run the app:

   ```powershell
   flutter pub get
   flutter run --dart-define-from-file=env/api.json
   ```

   Without the settings file the app shows "built without its server address" instead of
   starting. Only `https://` addresses are accepted.

3. Run the tests (no test makes a network connection):

   ```powershell
   flutter test
   ```