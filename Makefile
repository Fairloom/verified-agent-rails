# Verified Agent Rails — ERC-8226 (RAMS) integration targets.
# The live RAMS deployment is on Ethereum Sepolia (11155111); set
# ETH_SEPOLIA_RPC_URL for the fork/deploy/verify targets.

CONTRACTS := contracts

# Filled in after `make deploy-rams` from shared/addresses.json (eth-sepolia).
MIRROR   ?=
TOKEN    ?=
ADAPTER  ?=
RAMS_REGISTRY ?= 0xD68E1bb972cA4EF7F5764FBf6d685a6DfC26778e

.PHONY: test test-rams demo-compromised-key fork-test-rams rams-ref-artifacts \
        deploy-rams sanity-rams verify-rams

test:
	cd $(CONTRACTS) && forge test

test-rams:
	cd $(CONTRACTS) && forge test --match-path 'test/rams/*' --match-path 'test/demo/*'

demo-compromised-key:
	cd $(CONTRACTS) && forge test --match-contract CompromisedKeyDemo -vv

fork-test-rams:
	@test -n "$(ETH_SEPOLIA_RPC_URL)" || (echo "set ETH_SEPOLIA_RPC_URL"; exit 1)
	cd $(CONTRACTS) && forge test --match-contract RamsForkTest -vv

# Rebuild the prebuilt reference artifacts (solc 0.8.30) used by the tests.
rams-ref-artifacts:
	./scripts/build-rams-ref-artifacts.sh

deploy-rams:
	@test -n "$(ETH_SEPOLIA_RPC_URL)" || (echo "set ETH_SEPOLIA_RPC_URL"; exit 1)
	cd $(CONTRACTS) && forge script script/DeployRamsIntegration.s.sol \
	  --rpc-url $(ETH_SEPOLIA_RPC_URL) --broadcast

sanity-rams:
	cd $(CONTRACTS) && forge script script/DeployRamsIntegration.s.sol:RamsSanityCheck \
	  --sig "check(address,address,address)" $(MIRROR) $(TOKEN) $(ADAPTER) \
	  --rpc-url $(ETH_SEPOLIA_RPC_URL)

# Etherscan verification for the three deployed integration contracts.
# Requires ETHERSCAN_API_KEY plus MIRROR/TOKEN/ADAPTER from addresses.json.
verify-rams:
	cd $(CONTRACTS) && forge verify-contract --chain sepolia $(MIRROR) \
	  src/DelegationMirror.sol:DelegationMirror --watch
	cd $(CONTRACTS) && forge verify-contract --chain sepolia $(TOKEN) \
	  src/GatedUSDRams.sol:GatedUSDRams --watch \
	  --constructor-args $$(cast abi-encode "constructor(address,address,bool)" $(MIRROR) $(RAMS_REGISTRY) true)
	cd $(CONTRACTS) && forge verify-contract --chain sepolia $(ADAPTER) \
	  src/rams/VARComplianceProviderAdapter.sol:VARComplianceProviderAdapter --watch \
	  --constructor-args $$(cast abi-encode "constructor(address)" $(MIRROR))
