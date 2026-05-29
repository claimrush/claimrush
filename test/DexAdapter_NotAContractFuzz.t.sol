// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {Errors} from "src/lib/Errors.sol";

import {MockAerodromeRouter} from "./mocks/MockAerodromeRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexAdapterNotAContractFuzzTest is Test {
    MockAerodromeRouter internal router;
    DexAdapter internal adapter;

    MockERC20 internal tokenOut;

    address internal owner = address(0xA11CE);
    address internal factory = address(0xFACA);
    address internal wrappedNative = address(0xBEEF);

    function setUp() public {
        tokenOut = new MockERC20("TokenOut", "TOUT");

        vm.etch(factory, hex"00");
        vm.etch(wrappedNative, hex"00");

        router = new MockAerodromeRouter(factory, wrappedNative);
        router.setRateX18(1_000e18);

        adapter = new DexAdapter(address(router), owner);
    }

    function testFuzz_SwapExactTokensForTokens_NonContractTokenInAlwaysRevertsNotAContract(address tokenInAddr) public {
        vm.assume(tokenInAddr != address(0));
        vm.assume(tokenInAddr.code.length == 0);
        vm.assume(tokenInAddr != address(tokenOut));
        vm.assume(tokenInAddr != factory);

        IDexAdapter.Route[] memory routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({
            from: tokenInAddr, to: address(tokenOut), stable: false, factory: adapter.defaultFactory()
        });

        vm.expectRevert(Errors.NotAContract.selector);
        adapter.swapExactTokensForTokens(1, 0, routes, address(this), block.timestamp);
    }
}

