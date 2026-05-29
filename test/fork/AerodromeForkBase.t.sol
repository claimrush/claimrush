// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DexAdapter} from "src/DexAdapter.sol";
import {IDexAdapter} from "src/interfaces/IDexAdapter.sol";
import {IPoolFactory} from "src/interfaces/IPoolFactory.sol";
import {IAerodromePoolMint} from "src/interfaces/IAerodromePoolMint.sol";
import {IAerodromePoolSkim} from "src/interfaces/IAerodromePoolSkim.sol";
import {IAerodromePool} from "src/interfaces/IAerodromePool.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {ClaimToken} from "src/ClaimToken.sol";

/// @notice Shared base for fork tests against real Aerodrome on Base mainnet.
abstract contract AerodromeForkBase is Test {
    using SafeERC20 for IERC20;
    // --- Base mainnet Aerodrome addresses (pinned in Deploy.s.sol / base_mainnet.json) ---
    address internal constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address internal constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant FORK_BLOCK = 29_000_000;

    // --- Deployed on-fork state ---
    uint256 internal forkId;
    ForkClaimToken internal claimToken;
    DexAdapter internal dexAdapter;
    address internal pool;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        forkId = _createBaseMainnetFork(FORK_BLOCK);

        vm.startPrank(deployer);

        claimToken = new ForkClaimToken(deployer);
        dexAdapter = new DexAdapter(AERODROME_ROUTER, deployer);

        assertEq(dexAdapter.aerodromeFactory(), AERODROME_FACTORY, "factory mismatch");
        assertEq(dexAdapter.wrappedNative(), WETH, "weth mismatch");

        pool = IPoolFactory(AERODROME_FACTORY).createPool(WETH, address(claimToken), false);
        require(pool != address(0), "pool creation failed");

        address expectedPool = dexAdapter.poolFor(WETH, address(claimToken), false, AERODROME_FACTORY);
        assertEq(pool, expectedPool, "pool address mismatch vs poolFor");

        vm.stopPrank();
    }

    // --- Helpers ---

    /// @dev Create a Base mainnet fork preferring a private RPC (`base_mainnet` alias,
    ///      which resolves to `${BASE_MAINNET_RPC_URL}` in `foundry.toml`) and falling
    ///      back to the public endpoint (`base_mainnet_public` -> `https://mainnet.base.org`)
    ///      when the private URL is unset or unreachable. Keeps CI and contributors
    ///      without a private endpoint working out-of-the-box while giving operators
    ///      with an Alchemy/Infura/QuickNode key a faster, rate-limit-free path simply
    ///      by exporting `BASE_MAINNET_RPC_URL`.
    function _createBaseMainnetFork(uint256 blockNumber) internal returns (uint256) {
        try vm.createSelectFork("base_mainnet", blockNumber) returns (uint256 id) {
            return id;
        } catch {
            return vm.createSelectFork("base_mainnet_public", blockNumber);
        }
    }

    function _seedPool(uint256 wethAmount, uint256 claimAmount) internal returns (uint256 lpMinted) {
        _dealWeth(address(this), wethAmount);
        _dealClaim(address(this), claimAmount);

        IERC20(WETH).safeTransfer(pool, wethAmount);
        IERC20(address(claimToken)).safeTransfer(pool, claimAmount);

        lpMinted = IAerodromePoolMint(pool).mint(address(this));
        require(lpMinted > 0, "seed: zero LP");
    }

    function _seedPoolTo(uint256 wethAmount, uint256 claimAmount, address recipient)
        internal
        returns (uint256 lpMinted)
    {
        _dealWeth(address(this), wethAmount);
        _dealClaim(address(this), claimAmount);

        IERC20(WETH).safeTransfer(pool, wethAmount);
        IERC20(address(claimToken)).safeTransfer(pool, claimAmount);

        lpMinted = IAerodromePoolMint(pool).mint(recipient);
        require(lpMinted > 0, "seed: zero LP");
    }

    function _dealWeth(address to, uint256 amount) internal {
        vm.deal(address(this), amount);
        IWETH(WETH).deposit{value: amount}();
        if (to != address(this)) {
            IERC20(WETH).safeTransfer(to, amount);
        }
    }

    function _dealClaim(address to, uint256 amount) internal {
        claimToken.mint(to, amount);
    }

    function _buildRoute(address from, address to) internal pure returns (IDexAdapter.Route[] memory routes) {
        routes = new IDexAdapter.Route[](1);
        routes[0] = IDexAdapter.Route({from: from, to: to, stable: false, factory: AERODROME_FACTORY});
    }

    /// @dev Execute round-trip swaps through the real Aerodrome pool to generate trading fees.
    function _generateTradingFees(uint256 swapCount, uint256 ethPerSwap) internal {
        for (uint256 i = 0; i < swapCount; i++) {
            // WETH -> CLAIM (token swap, not ETH entry)
            _dealWeth(alice, ethPerSwap);
            vm.startPrank(alice);
            IERC20(WETH).approve(address(dexAdapter), ethPerSwap);
            IDexAdapter.Route[] memory routes = _buildRoute(WETH, address(claimToken));
            dexAdapter.swapExactTokensForTokens(ethPerSwap, 0, routes, alice, block.timestamp + 300);

            // CLAIM -> WETH (reverse to generate fees in both directions)
            uint256 claimBal = claimToken.balanceOf(alice);
            if (claimBal > 0) {
                claimToken.approve(address(dexAdapter), claimBal);
                IDexAdapter.Route[] memory reverseRoutes = _buildRoute(address(claimToken), WETH);
                dexAdapter.swapExactTokensForTokens(claimBal, 0, reverseRoutes, alice, block.timestamp + 300);
            }
            vm.stopPrank();
        }
    }

    receive() external payable {}
}

/// @dev Unrestricted ERC20 token for fork tests. Avoids ClaimToken's mineCore gating
///      while maintaining the same ERC20 interface that Aerodrome pools expect.
contract ForkClaimToken is IERC20 {
    string public constant name = "ClaimRush";
    string public constant symbol = "CLAIM";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable admin;

    constructor(address _admin) {
        admin = _admin;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "ERC20: allowance");
            allowance[from][msg.sender] = a - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
