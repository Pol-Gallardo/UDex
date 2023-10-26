-include .env

@forge script script/DeployUDex.s.sol:DeployUDex $(NETWORK_ARGS)

forge script script/DeployUDex.s.sol:DeployUDex --rpc-url https://erpc.apothem.network --private-key fdc86a4842a44401587788b8fe8d7f9acc969a94a944cf55b304f04ed95e7603  --broadcast --verify --legacy -vvvv