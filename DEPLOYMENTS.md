# Deployments — Base Sepolia (chain 84532)

| Contract | Address |
|---|---|
| `CommissionEscrow` | [`0xB57A70b874f6B291f3369994B08BD335Acd7343b`](https://sepolia.basescan.org/address/0xB57A70b874f6B291f3369994B08BD335Acd7343b) |

Verified on-chain after deployment rather than read off the deploy script's output:
`TOTAL_BPS` returns `10000`, and `nextCommissionId` starts at `1`, so id `0` always means
"does not exist".

| Role | Holder |
|---|---|
| `DEFAULT_ADMIN_ROLE` | `0xA39D127B021196AA7Eec7427d4c9af19001A086b` |
| `ARBITER_ROLE` | `0xA39D127B021196AA7Eec7427d4c9af19001A086b` |

## Trying it

```bash
# open a commission (collector locks the value; there is no amount argument)
cast send 0xB57A70b874f6B291f3369994B08BD335Acd7343b \
  "openCommission(address,uint64,uint32,string)" \
  <ARTISAN> $(( $(date +%s) + 2592000 )) 604800 "ipfs://brief" \
  --value 1000000000000 --rpc-url https://sepolia.base.org --private-key <KEY>

# the artisan marks delivery — evidence is mandatory, an empty string reverts
cast send 0xB57A70b874f6B291f3369994B08BD335Acd7343b \
  "markDelivered(uint256,string)" 1 "ipfs://delivery-photos" \
  --rpc-url https://sepolia.base.org --private-key <ARTISAN_KEY>

# read the evidence back, timestamped
cast call 0xB57A70b874f6B291f3369994B08BD335Acd7343b \
  "deliveryEvidence(uint256)(string,uint64)" 1 --rpc-url https://sepolia.base.org
```

> The deploying key is a throwaway that has only ever held Base Sepolia testnet ETH, and
> its private key was exposed during development. It holds both `DEFAULT_ADMIN_ROLE` and
> `ARBITER_ROLE` here, which makes this a demonstration rather than a production instance —
> a real deployment would put the arbiter behind a multisig, exactly as the contract's
> role-based design allows.

## Source verification

Verified on **Sourcify** with an exact match on both creation and runtime bytecode:

- https://repo.sourcify.dev/84532/0xB57A70b874f6B291f3369994B08BD335Acd7343b

```bash
curl -s https://sourcify.dev/server/v2/contract/84532/0xB57A70b874f6B291f3369994B08BD335Acd7343b
# {"match":"match","creationMatch":"match","runtimeMatch":"match", ...}
```

Sourcify rather than Basescan because it needs no API key, and Basescan surfaces
Sourcify-verified sources anyway.
