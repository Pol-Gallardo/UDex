// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {UDex} from "../src/UDex.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUDex is Script {
    function run() external returns (UDex, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address xdcPriceFeed, address xdc, uint256 deployerKey) = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);
        UDex uDex = new UDex(
            xdcPriceFeed,
            IERC20(xdc)
        );
        vm.stopBroadcast();

        return (uDex, config);
    }
}
