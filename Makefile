# Load environment variables
include .env
export

# Default target
.PHONY: help
help:
	@echo "Available commands:"
	@echo "  make anvil                    - Start Anvil with tracing enabled"
	@echo "  make deploy-anvil             - Deploy Bazaar to local Anvil"
	@echo "  make deploy-pair-anvil        - Deploy a pair (FEED_ID=0x... CONTINUOUS=true|false DESC=...)"
	@echo "  make deploy-arb-sepolia       - Deploy Bazaar to Arbitrum Sepolia"
	@echo "  make deploy-arb-mainnet       - Deploy Bazaar to Arbitrum Mainnet"
	@echo "  make set-price-anvil          - Set mock price (FEED_ID=0x... PRICE=2000)"
	@echo "  make create-order-anvil       - Create limit order (PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true)"
	@echo "  make warp-anvil SECONDS=N     - Warp Anvil forward N seconds"
	@echo "  make build                    - Build the project"
	@echo "  make test                     - Run tests"
	@echo "  make balance-usdc             - Check USDC balance (ADDR=0x... optional)"
	@echo "  make clean                    - Clean build artifacts"
	@echo "  make install                  - Install dependencies"

# Build
.PHONY: build
build:
	forge build

# Test
.PHONY: test
test:
	forge test

.PHONY: test-factory
test-factory:
	forge test --match-contract BazaarFactoryTest -vv

# Clean
.PHONY: clean
clean:
	forge clean

# Install dependencies
.PHONY: install
install:
	forge install

# Start Anvil
.PHONY: anvil
anvil:
	anvil --steps-tracing --code-size-limit 100000

# ---------- Anvil Local Deployment ----------

.PHONY: deploy-anvil
deploy-anvil:
	@echo "=== Deploying Bazaar to Anvil ===" && \
	forge script script/DeployBazaar.s.sol \
		--rpc-url $(ANVIL_RPC_URL) \
		--broadcast \
		--private-key $(ANVIL_PRIVATE_KEY) \
		--code-size-limit 100000 2>&1 | tee /tmp/bazaar-deploy.log && \
	FACTORY_ADDR=$$(grep "BazaarFactory:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	ORACLE_ADDR=$$(grep "BazaarOracle:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	PAIR_IMPL_ADDR=$$(grep "BazaarPair implementation:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	SEQUENCER_ADDR=$$(grep "BazaarSequencer:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	LENS_ADDR=$$(grep "BazaarPairLens:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	TERMINATOR_ADDR=$$(grep "BazaarTerminatePair:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	USDC_ADDR=$$(grep "USDC:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	OOV3_ADDR=$$(grep "OptimisticOracleV3:" /tmp/bazaar-deploy.log | head -1 | awk '{print $$NF}') && \
	echo "" && \
	echo "=== Etching MockArbSys at the ArbSys precompile address (0x64) ===" && \
	([ -f out/MockArbSys.sol/MockArbSys.json ] || forge build > /dev/null) && \
	ARBSYS_CODE=$$(jq -r '.deployedBytecode.object' out/MockArbSys.sol/MockArbSys.json) && \
	cast rpc anvil_setCode 0x0000000000000000000000000000000000000064 $$ARBSYS_CODE \
		--rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	echo "" && \
	echo "=== Minting 10,000 MockUSDC to $(ANVIL_WALLET) ===" && \
	cast send $$USDC_ADDR \
		"mint(address,uint256)" \
		$(ANVIL_WALLET) 10000000000 \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) && \
	echo "" && \
	echo "=== Deployment Complete ===" && \
	echo "  MockUSDC:              $$USDC_ADDR" && \
	echo "  MockOptimisticOracleV3:$$OOV3_ADDR" && \
	echo "  BazaarFactory:         $$FACTORY_ADDR" && \
	echo "  BazaarOracle:          $$ORACLE_ADDR" && \
	echo "  BazaarPair (impl):     $$PAIR_IMPL_ADDR" && \
	echo "  BazaarSequencer:       $$SEQUENCER_ADDR" && \
	echo "  BazaarPairLens:        $$LENS_ADDR" && \
	echo "  BazaarTerminatePair:   $$TERMINATOR_ADDR" && \
	printf "OOV3=%s\nUSDC=%s\nFACTORY=%s\nORACLE=%s\nPAIR_IMPL=%s\nSEQUENCER=%s\nLENS=%s\nTERMINATOR=%s\n" \
		$$OOV3_ADDR $$USDC_ADDR $$FACTORY_ADDR $$ORACLE_ADDR $$PAIR_IMPL_ADDR $$SEQUENCER_ADDR $$LENS_ADDR $$TERMINATOR_ADDR \
		> .anvil-addresses

# ---------- Anvil Utilities ----------

.PHONY: warp-anvil
warp-anvil:
	@if [ -z "$(SECONDS)" ]; then echo "Usage: make warp-anvil SECONDS=43200"; exit 1; fi
	@echo "Warping Anvil forward $(SECONDS) seconds..."
	@cast rpc evm_increaseTime $(SECONDS) --rpc-url $(ANVIL_RPC_URL) > /dev/null
	@cast rpc evm_mine --rpc-url $(ANVIL_RPC_URL) > /dev/null
	@echo "Done. Block mined at new timestamp."

# These read addresses saved by deploy-anvil in .anvil-addresses

.PHONY: balance-usdc
balance-usdc:
	@. ./.anvil-addresses && \
	cast call $$USDC "balanceOf(address)(uint256)" $(or $(ADDR),$(ANVIL_WALLET)) --rpc-url $(ANVIL_RPC_URL)

# Set mock Pyth price on Anvil
# Usage: make set-price-anvil FEED_ID=0x... PRICE=2000 (USD price as integer)
# Sets both the base feed and USDC/USD feed (at $1.00)
USDC_FEED_ID=0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a
.PHONY: set-price-anvil
set-price-anvil:
	@if [ -z "$(FEED_ID)" ] || [ -z "$(PRICE)" ]; then echo "Usage: make set-price-anvil FEED_ID=0x... PRICE=2000"; exit 1; fi
	@. ./.anvil-addresses && \
	PYTH=$$(cast call $$ORACLE "pyth()(address)" --rpc-url $(ANVIL_RPC_URL)) && \
	TIMESTAMP=$$(cast block latest --rpc-url $(ANVIL_RPC_URL) --json | jq -r '.timestamp' | xargs printf "%d") && \
	echo "=== Setting base price: $(PRICE) USD ===" && \
	BASE_UPDATE=$$(cast call $$PYTH \
		"createPriceFeedUpdateData(bytes32,int64,uint64,int32,int64,uint64,uint64,uint64)(bytes)" \
		$(FEED_ID) $(PRICE)00000000 0 -8 $(PRICE)00000000 0 $$TIMESTAMP $$((TIMESTAMP - 1)) \
		--rpc-url $(ANVIL_RPC_URL)) && \
	echo "=== Setting USDC price: 1.00 USD ===" && \
	USDC_UPDATE=$$(cast call $$PYTH \
		"createPriceFeedUpdateData(bytes32,int64,uint64,int32,int64,uint64,uint64,uint64)(bytes)" \
		$(USDC_FEED_ID) 100000000 0 -8 100000000 0 $$TIMESTAMP $$((TIMESTAMP - 1)) \
		--rpc-url $(ANVIL_RPC_URL)) && \
	echo "=== Updating MockPyth ===" && \
	cast send $$PYTH \
		"updatePriceFeeds(bytes[])" "[$$BASE_UPDATE,$$USDC_UPDATE]" \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) > /dev/null && \
	echo "Done. Price set to $(PRICE) USD" && \
	echo "" && \
	echo "=== Price update data for Remix (pass as priceUpdate) ===" && \
	echo "[\"$$BASE_UPDATE\",\"$$USDC_UPDATE\"]"

# Create a limit order on Anvil (generates fresh price data in the same command)
# Usage: make create-order-anvil PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true
# LIMIT_PRICE is in USD (integer), SIZE is in units of the asset (e.g. 0.01 ETH)
# Expiration is passed as uint64-max, which the contract clamps to the ~1-year protocol max.
.PHONY: create-order-anvil
create-order-anvil:
	@if [ -z "$(PAIR)" ] || [ -z "$(LIMIT_PRICE)" ] || [ -z "$(SIZE)" ]; then \
		echo "Usage: make create-order-anvil PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true"; exit 1; fi
	@. ./.anvil-addresses && \
	PYTH=$$(cast call $$ORACLE "pyth()(address)" --rpc-url $(ANVIL_RPC_URL)) && \
	BASE_FEED=$$(cast call $(PAIR) "baseFeedId()(bytes32)" --rpc-url $(ANVIL_RPC_URL)) && \
	TIMESTAMP=$$(cast block latest --rpc-url $(ANVIL_RPC_URL) --json | jq -r '.timestamp' | xargs printf "%d") && \
	BASE_UPDATE=$$(cast call $$PYTH \
		"createPriceFeedUpdateData(bytes32,int64,uint64,int32,int64,uint64,uint64,uint64)(bytes)" \
		$$BASE_FEED $(LIMIT_PRICE)00000000 0 -8 $(LIMIT_PRICE)00000000 0 $$TIMESTAMP $$((TIMESTAMP - 1)) \
		--rpc-url $(ANVIL_RPC_URL)) && \
	USDC_UPDATE=$$(cast call $$PYTH \
		"createPriceFeedUpdateData(bytes32,int64,uint64,int32,int64,uint64,uint64,uint64)(bytes)" \
		$(USDC_FEED_ID) 100000000 0 -8 100000000 0 $$TIMESTAMP $$((TIMESTAMP - 1)) \
		--rpc-url $(ANVIL_RPC_URL)) && \
	SIZE_WEI=$$(cast to-wei $(SIZE)) && \
	LIMIT_WEI=$$(cast to-wei $(LIMIT_PRICE)) && \
	echo "=== Creating limit order ===" && \
	echo "  Pair:        $(PAIR)" && \
	echo "  Size:        $(SIZE) ($$SIZE_WEI)" && \
	echo "  Limit price: $(LIMIT_PRICE) USD" && \
	echo "  Long:        $(or $(IS_LONG),true)" && \
	cast send $(PAIR) \
		"createOrder(uint8,uint256,uint256,uint256,uint256,bool,bool,uint64,address,bytes[],uint256,uint256,uint256,bytes)" \
		1 0 $$LIMIT_WEI 0 $$SIZE_WEI $(or $(IS_LONG),true) false 18446744073709551615 \
		0x0000000000000000000000000000000000000000 \
		"[$$BASE_UPDATE,$$USDC_UPDATE]" 0 0 0 0x \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) \
		--gas-limit 5000000 && \
	echo "=== Order created ==="

# Deploy a pair on Anvil
# Usage: make deploy-pair-anvil FEED_ID=0xff61... CONTINUOUS=true DESC="ETH/USD"
.PHONY: deploy-pair-anvil
deploy-pair-anvil:
	@if [ -z "$(FEED_ID)" ]; then echo "Usage: make deploy-pair-anvil FEED_ID=0x... CONTINUOUS=true|false DESC=\"ETH/USD\""; exit 1; fi
	@set -e && . ./.anvil-addresses && \
	AMOUNT=5000000000000000000000 && \
	AMOUNT_USDC=5000000000 && \
	echo "=== Step 1: Approving 5000 USDC for Factory ===" && \
	cast send $$USDC "approve(address,uint256)" $$FACTORY $$AMOUNT_USDC \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) > /dev/null && \
	echo "=== Step 2: Proposing Pair Deployment ===" && \
	PROPOSE_JSON=$$(cast send $$FACTORY \
		"proposePairDeployment(bytes32,bool,uint256,string)" \
		$(FEED_ID) $(or $(CONTINUOUS),true) $$AMOUNT "$(or $(DESC),Pair)" \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) --json) && \
	TX_HASH=$$(echo "$$PROPOSE_JSON" | jq -r '.transactionHash') && \
	ASSERTION_ID=$$(cast receipt $$TX_HASH --rpc-url $(ANVIL_RPC_URL) --json | \
		jq -r '.logs[] | select(.topics[0] == "0xb3076a86f17e6bb64607292bdf4d72989c0cbe43651a097d912dd1a4b9c82dd6") | .topics[2]') && \
	echo "  Assertion ID: $$ASSERTION_ID" && \
	echo "=== Step 3: Warping 48 hours (DEPLOYMENT_LIVENESS) ===" && \
	cast rpc evm_increaseTime 172801 --rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	cast rpc evm_mine --rpc-url $(ANVIL_RPC_URL) > /dev/null && \
	echo "=== Step 4: Settling Deployment ===" && \
	cast send $$FACTORY \
		"settleDeploymentProposal(bytes32)" $$ASSERTION_ID \
		--rpc-url $(ANVIL_RPC_URL) \
		--private-key $(ANVIL_PRIVATE_KEY) \
		--gas-limit 5000000 2>/dev/null; \
	PAIR_ADDR=$$(cast call $$FACTORY "getPairAddress(bytes32)(address)" $(FEED_ID) --rpc-url $(ANVIL_RPC_URL)) && \
	if [ "$$PAIR_ADDR" = "0x0000000000000000000000000000000000000000" ]; then \
		echo "ERROR: Pair deployment failed!" && exit 1; \
	fi && \
	echo "" && \
	echo "=== Pair Deployed ===" && \
	echo "  Feed ID:      $(FEED_ID)" && \
	echo "  Continuous:   $(or $(CONTINUOUS),true)" && \
	echo "  Description:  $(or $(DESC),Pair)" && \
	echo "  Assertion ID: $$ASSERTION_ID" && \
	echo "  Pair Address: $$PAIR_ADDR"

# ---------- Arbitrum Sepolia ----------

.PHONY: deploy-arb-sepolia
deploy-arb-sepolia:
	@echo "Deploying Bazaar to Arbitrum Sepolia..."
	forge script script/DeployBazaar.s.sol \
		--rpc-url arbitrum_sepolia \
		--account $(ACCOUNT) \
		--sender $(SENDER) \
		--broadcast \
		--verify

# ---------- Arbitrum Mainnet ----------

.PHONY: deploy-arb-mainnet
deploy-arb-mainnet:
	@echo "Deploying to Arbitrum Mainnet..."
	@read -p "Are you sure you want to deploy to mainnet? (y/N): " confirm && [ "$$confirm" = "y" ]
	forge script script/DeployBazaar.s.sol \
		--rpc-url arbitrum_mainnet \
		--account $(ACCOUNT) \
		--sender $(SENDER) \
		--broadcast \
		--verify
