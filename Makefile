# Vadium developer entrypoints. `make help` lists targets.

FAST      := FOUNDRY_PROFILE=fast
CI        := FOUNDRY_PROFILE=ci
NO_FORK   := --no-match-path 'test/fork/*'

.PHONY: help build test test-fork test-invariant snapshot snapshot-check coverage lint fmt \
        deploy-sepolia deploy-mainnet wire verify add-liquidity services-test

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

build: ## Compile with the CI profile (via-ir)
	$(CI) forge build --sizes

test: ## Unit, integration, economics, invariant suites (fork suites skip without RPC)
	UNICHAIN_SEPOLIA_RPC= $(FAST) forge test $(NO_FORK) --summary

test-fork: ## Fork suites against UNICHAIN_SEPOLIA_RPC from the environment or .env
	$(FAST) forge test --match-path 'test/fork/*' -vv

test-invariant: ## Invariant suite with a fresh seed and deeper runs
	FOUNDRY_FUZZ_SEED=$$(date +%s) FOUNDRY_INVARIANT_RUNS=512 FOUNDRY_INVARIANT_DEPTH=30 \
		$(FAST) forge test --match-path 'test/invariant/*' -vv

snapshot: ## Regenerate .gas-snapshot (CI profile)
	UNICHAIN_SEPOLIA_RPC= $(CI) forge snapshot $(NO_FORK)

snapshot-check: ## Fail if gas moved more than 2% from .gas-snapshot
	UNICHAIN_SEPOLIA_RPC= $(CI) forge snapshot --check --tolerance 2 $(NO_FORK)

coverage: ## Line coverage for src/
	UNICHAIN_SEPOLIA_RPC= $(CI) forge coverage --report summary $(NO_FORK) --ir-minimum

fmt: ## Format
	forge fmt

lint: ## fmt check, slither, semgrep
	forge fmt --check
	slither . --config-file slither.config.json --fail-medium
	semgrep --config p/smart-contracts --error --metrics=off src/

deploy-sepolia: ## Deploy hook + pool to Unichain Sepolia and write deployments/1301.json
	GIT_SHA=$$(git rev-parse --short HEAD) forge script app/script/Deploy.s.sol:DeployVadium \
		--rpc-url unichain_sepolia --broadcast --verify -vvv

deploy-mainnet: ## Deploy to Unichain mainnet. Requires MAINNET_CONFIRM=yes, OWNER (Safe), INITIAL_SQRT_PRICE
	@test "$(MAINNET_CONFIRM)" = "yes" || (echo "set MAINNET_CONFIRM=yes" && exit 1)
	@test -n "$(OWNER)" || (echo "set OWNER to the Safe address" && exit 1)
	@test -n "$(INITIAL_SQRT_PRICE)" || (echo "set INITIAL_SQRT_PRICE" && exit 1)
	GIT_SHA=$$(git rev-parse --short HEAD) forge script app/script/Deploy.s.sol:DeployVadium \
		--rpc-url unichain -vvv
	@echo "Dry run passed. Re-running with --broadcast."
	GIT_SHA=$$(git rev-parse --short HEAD) forge script app/script/Deploy.s.sol:DeployVadium \
		--rpc-url unichain --broadcast --verify -vvv

wire: ## Set keeper / watchtower / reactive rvm from env on the chain of RPC (default sepolia)
	forge script app/script/Wire.s.sol:WireVadium --rpc-url $${RPC:-unichain_sepolia} --broadcast -vvv

add-liquidity: ## Seed liquidity through the owned router (LIQUIDITY_DELTA, ETH_BUDGET_WEI)
	forge script app/script/AddLiquidity.s.sol:AddLiquidity --rpc-url $${RPC:-unichain_sepolia} --broadcast -vvv

verify: ## Verify the deployed hook on the explorer for CHAIN (default 1301)
	@CHAIN=$${CHAIN:-1301}; HOOK=$$(jq -r .hook deployments/$$CHAIN.json); \
	forge verify-contract --chain $$CHAIN --watch $$HOOK src/hooks/VadiumHook.sol:VadiumHook \
		--constructor-args $$(cast abi-encode "c(address,address,address,address,(uint256,uint256,uint256,uint256,uint256,uint256,uint256))" \
			$$(jq -r .poolManager deployments/$$CHAIN.json) $$(jq -r .bondToken deployments/$$CHAIN.json) \
			$$(jq -r .deployer deployments/$$CHAIN.json) $$(jq -r .callbackProxy deployments/$$CHAIN.json) \
			"(100000000,7200,5000,86400,2592000,5000,2592000)")

services-test: ## Run every service's test suite
	@for d in services/*/; do echo "== $$d"; (cd $$d && pnpm test) || exit 1; done
