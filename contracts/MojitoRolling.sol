// SPDX-License-Identifier: MIT

pragma solidity =0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/IMojitoPair.sol";
import "./interfaces/IMojitoRouter02.sol";
import "./interfaces/IMojitoShaker.sol";
import "./interfaces/IWKCS.sol";

contract MojitoRolling is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IMojitoRouter02 public immutable ROUTER;
    IMojitoShaker public immutable SHAKER;
    address public immutable WKCS;

    mapping(address => bool) private notLP;
    mapping(address => address) private routePairAddresses;
    address[] public tokens;

    constructor(address _ROUTER, address _SHAKER, address _WKCS) public {
        ROUTER = IMojitoRouter02(_ROUTER);
        SHAKER = IMojitoShaker(_SHAKER);
        WKCS = _WKCS;
    }

    receive() external payable {}

    function isLP(address _address) public view returns (bool) {
        return !notLP[_address];
    }

    function routePair(address _address) external view returns (address) {
        return routePairAddresses[_address];
    }

    function zapInToken(address _from, uint256 amount, address _to) external {
        IERC20(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);

        if (isLP(_to)) {
            IMojitoPair pair = IMojitoPair(_to);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (_from == token0 || _from == token1) {
                // swap half amount for other
                address other = _from == token0 ? token1 : token0;
                _approveTokenIfNeeded(other);
                uint256 sellAmount = amount.div(2);
                uint256 otherAmount = _swap(_from, sellAmount, other, address(this));
                pair.skim(address(this));
                ROUTER.addLiquidity(_from, other, amount.sub(sellAmount), otherAmount, 0, 0, msg.sender, block.timestamp);
            } else {
                uint256 kcsAmount = _swapTokenForKCS(_from, amount, address(this));
                _swapKCSToLP(_to, kcsAmount, msg.sender);
            }
        } else {
            _swap(_from, amount, _to, msg.sender);
        }
    }

    function zapIn(address _to) external payable {
        _swapKCSToLP(_to, msg.value, msg.sender);
    }

    function zapOut(address _from, uint256 amount) external {
        IERC20(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);

        if (!isLP(_from)) {
            _swapTokenForKCS(_from, amount, msg.sender);
        } else {
            IMojitoPair pair = IMojitoPair(_from);
            address token0 = pair.token0();
            address token1 = pair.token1();

            if (pair.balanceOf(_from) > 0) {
                pair.burn(address(this));
            }

            if (token0 == WKCS || token1 == WKCS) {
                ROUTER.removeLiquidityETH(token0 != WKCS ? token0 : token1, amount, 0, 0, msg.sender, block.timestamp);
            } else {
                ROUTER.removeLiquidity(token0, token1, amount, 0, 0, msg.sender, block.timestamp);
            }
        }
    }

    function _approveTokenIfNeeded(address token) private {
        if (IERC20(token).allowance(address(this), address(ROUTER)) == 0) {
            IERC20(token).safeApprove(address(ROUTER), uint256(- 1));
        }
    }

    function _swapKCSToLP(address lp, uint256 amount, address receiver) private {
        if (!isLP(lp)) {
            _swapKCSForToken(lp, amount, receiver);
        } else {
            // lp
            IMojitoPair pair = IMojitoPair(lp);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WKCS || token1 == WKCS) {
                address token = token0 == WKCS ? token1 : token0;
                uint256 swapValue = amount.div(2);
                uint256 tokenAmount = _swapKCSForToken(token, swapValue, address(this));

                _approveTokenIfNeeded(token);
                pair.skim(address(this));
                ROUTER.addLiquidityETH{value : amount.sub(swapValue)}(token, tokenAmount, 0, 0, receiver, block.timestamp);
            } else {
                uint256 swapValue = amount.div(2);
                uint256 token0Amount = _swapKCSForToken(token0, swapValue, address(this));
                uint256 token1Amount = _swapKCSForToken(token1, amount.sub(swapValue), address(this));

                _approveTokenIfNeeded(token0);
                _approveTokenIfNeeded(token1);
                pair.skim(address(this));
                ROUTER.addLiquidity(token0, token1, token0Amount, token1Amount, 0, 0, receiver, block.timestamp);
            }
        }
    }

    function _swapKCSForToken(address token, uint256 value, address receiver) private returns (uint256) {
        address[] memory path;

        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = WKCS;
            path[1] = routePairAddresses[token];
            path[2] = token;
        } else {
            path = new address[](2);
            path[0] = WKCS;
            path[1] = token;
        }

        uint256[] memory amounts = ROUTER.swapExactETHForTokens{value : value}(0, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swapTokenForKCS(address token, uint256 amount, address receiver) private returns (uint256) {
        address[] memory path;
        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = token;
            path[1] = routePairAddresses[token];
            path[2] = WKCS;
        } else {
            path = new address[](2);
            path[0] = token;
            path[1] = WKCS;
        }

        uint256[] memory amounts = ROUTER.swapExactTokensForETH(amount, 0, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swap(address _from, uint256 amount, address _to, address receiver) private returns (uint256) {
        address intermediate = routePairAddresses[_from];
        if (intermediate == address(0)) {
            intermediate = routePairAddresses[_to];
        }

        address[] memory path;
        if (intermediate != address(0) && (_from == WKCS || _to == WKCS)) {
            // [WKCS, USDT, MJT] or [MJT, USDT, WKCS]
            path = new address[](3);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = _to;
        } else if (intermediate != address(0) && (_from == intermediate || _to == intermediate)) {
            // [MJT, USDT] or [USDT, MJT]
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_from] == routePairAddresses[_to]) {
            // [MJT, DAI] or [MJT, USDC]
            path = new address[](3);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = _to;
        } else if (routePairAddresses[_from] != address(0) && routePairAddresses[_to] != address(0) && routePairAddresses[_from] != routePairAddresses[_to]) {
            // routePairAddresses[xToken] = xRoute
            // [MJT, USDT, WKCS, xRoute, xToken]
            path = new address[](5);
            path[0] = _from;
            path[1] = routePairAddresses[_from];
            path[2] = WKCS;
            path[3] = routePairAddresses[_to];
            path[4] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_from] != address(0)) {
            // [MJT, USDT, WKCS, UDSC]
            path = new address[](4);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = WKCS;
            path[3] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_to] != address(0)) {
            // [USDC, WKCS, USDT, MJT]
            path = new address[](4);
            path[0] = _from;
            path[1] = WKCS;
            path[2] = intermediate;
            path[3] = _to;
        } else if (_from == WKCS || _to == WKCS) {
            // [WKCS, USDC] or [USDC, WKCS]
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            // [USDT, USDC] or [USDC, USDT]
            path = new address[](3);
            path[0] = _from;
            path[1] = WKCS;
            path[2] = _to;
        }

        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amount, 0, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function setRoutePairAddress(address asset, address route) external onlyOwner {
        routePairAddresses[asset] = route;
    }

    function setNotLP(address token) external onlyOwner {
        bool needPush = notLP[token] == false;
        notLP[token] = true;
        if (needPush) {
            tokens.push(token);
        }
    }

    function removeToken(uint256 i) external onlyOwner {
        address token = tokens[i];
        notLP[token] = false;
        tokens[i] = tokens[tokens.length - 1];
        tokens.pop();
    }

    function sweep() external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;
            uint256 amount = IERC20(token).balanceOf(address(this));
            if (amount > 0) {
                if (token == WKCS) {
                    IWKCS(token).withdraw(amount);
                } else {
                    _swapTokenForKCS(token, amount, owner());
                }
            }
        }

        uint256 balance = address(this).balance;
        if (balance > 0) {
            payable(owner()).transfer(balance);
        }
    }

    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(address(this).balance);
            return;
        }

        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    function harvest() external onlyOwner {
        SHAKER.withdraw();
    }

}